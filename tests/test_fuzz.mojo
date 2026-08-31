"""Property-based fuzz tests for sqlite.

Upstream drove these with `mozz <https://github.com/ehsanmok/mozz>`_; this fork
keeps the properties but carries its own generators so the repo has no
dependency outside conda-forge's ``libsqlite``.  The harness is deliberately
small: a seeded xoshiro256** stream, a handful of biased generators, and a
plain loop per property.  There is no shrinking — a failure reports the trial
index and the offending input, and the seed makes the run reproducible.

All tests use in-memory SQLite databases so there are no side effects.

Properties verified:
- **SQL safety**: executing any random UTF-8 string as SQL either succeeds or
  raises ``Error`` — never panics or corrupts memory.
- **SQL byte safety**: the same, for random printable-ASCII byte sequences.
- **bind_text round-trip**: for any random String ``s``, inserting it via
  ``bind_text`` and reading it back returns the original value.
- **bind_int round-trip**: for any random ``Int`` ``v`` (full signed 64-bit
  range, boundary-biased), inserting via ``bind_int`` and reading back returns
  the original value.
- **bind_float round-trip**: for any finite ``Float64``, bind_float →
  read-back preserves the value exactly.
- **count invariant**: after ``N`` inserts (1 ≤ N ≤ 50), ``COUNT(*)`` equals N.
- **injection safety**: no ``bind_text`` payload can escape its placeholder and
  execute as SQL.
"""

from std.memory import bitcast
from std.testing import assert_equal, assert_true
from sqlite.db import Database


# ---------------------------------------------------------------------------
# xoshiro256** — a small, fast, seedable PRNG
# ---------------------------------------------------------------------------


def _splitmix64(mut x: UInt64) -> UInt64:
    """One step of SplitMix64, used only to expand a seed into RNG state."""
    x += 0x9E3779B97F4A7C15
    var z = x
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9
    z = (z ^ (z >> 27)) * 0x94D049BB133111EB
    return z ^ (z >> 31)


def _rotl(x: UInt64, k: UInt64) -> UInt64:
    """Rotate ``x`` left by ``k`` bits."""
    return (x << k) | (x >> (64 - k))


struct Xoshiro256(Movable):
    """A xoshiro256** generator: 256 bits of state, period 2^256-1."""

    var s0: UInt64
    var s1: UInt64
    var s2: UInt64
    var s3: UInt64

    def __init__(out self, seed: UInt64):
        """Seed the generator; SplitMix64 spreads one word over all four."""
        var x = seed
        self.s0 = _splitmix64(x)
        self.s1 = _splitmix64(x)
        self.s2 = _splitmix64(x)
        self.s3 = _splitmix64(x)

    def next(mut self) -> UInt64:
        """Return the next 64-bit output and advance the state."""
        var result = _rotl(self.s1 * 5, 7) * 9
        var t = self.s1 << 17
        self.s2 ^= self.s0
        self.s3 ^= self.s1
        self.s1 ^= self.s2
        self.s0 ^= self.s3
        self.s2 ^= t
        self.s3 = _rotl(self.s3, 45)
        return result

    def below(mut self, n: Int) -> Int:
        """Return a value in ``[0, n)``.  Modulo bias is irrelevant here."""
        return Int(self.next() % UInt64(n))


# ---------------------------------------------------------------------------
# Generators
# ---------------------------------------------------------------------------


def _sql_tokens() -> List[String]:
    """SQL metacharacters and injection payloads, over-represented on purpose."""
    var out: List[String] = [
        String("'"),
        String('"'),
        String("`"),
        String(";"),
        String("--"),
        String("/*"),
        String("*/"),
        String("\\"),
        String("%"),
        String("_"),
        String("?"),
        String("\n"),
        String("\t"),
        String("' OR 1=1 --"),
        String("'); DROP TABLE victims; --"),
        String("' UNION SELECT 1 --"),
        String("SELECT"),
        String("x'00'"),
    ]
    return out^


def _gen_string(mut rng: Xoshiro256, imm tokens: List[String]) -> String:
    """Generate a random UTF-8 String: ASCII, SQL tokens, and non-Latin text.

    NUL bytes are never generated — ``sqlite3_column_text`` hands back a C
    string, so a value containing NUL could not round-trip through it and the
    property would report a false failure.
    """
    var n = rng.below(24)
    var s = String()
    for _i in range(n):
        var pick = rng.below(100)
        if pick < 50:
            # Printable ASCII, 0x20..0x7E.
            s += chr(32 + rng.below(95))
        elif pick < 75:
            s += tokens[rng.below(len(tokens))]
        elif pick < 90:
            # Latin-1 supplement / Greek / Cyrillic — 2-byte UTF-8.
            s += chr(0x00A1 + rng.below(0x0400))
        else:
            # CJK and emoji — 3- and 4-byte UTF-8.
            if rng.below(2) == 0:
                s += chr(0x4E00 + rng.below(0x1000))
            else:
                s += chr(0x1F300 + rng.below(0x200))
    return s^


def _gen_int(mut rng: Xoshiro256) -> Int:
    """Boundary-biased Int over the full signed 64-bit range."""
    var pick = rng.below(10)
    if pick == 0:
        return 0
    if pick == 1:
        return 1
    if pick == 2:
        return -1
    if pick == 3:
        return 9223372036854775807  # Int64 max
    if pick == 4:
        return -9223372036854775807 - 1  # Int64 min
    if pick == 5:
        return rng.below(1000) - 500
    return Int(bitcast[DType.int64](rng.next()))


def _gen_float(mut rng: Xoshiro256) -> Float64:
    """Boundary-biased finite Float64."""
    var pick = rng.below(8)
    if pick == 0:
        return 0.0
    if pick == 1:
        return -0.0
    if pick == 2:
        return 1.0
    if pick == 3:
        return -1.0
    if pick == 4:
        return Float64(rng.below(1_000_000)) / 1000.0
    if pick == 5:
        return -Float64(rng.below(1_000_000)) / 1000.0
    # An arbitrary bit pattern, rejected and retried if it is NaN or infinite.
    var bits = rng.next()
    var f = bitcast[DType.float64](bits)
    if not (f == f) or f - f != 0.0:  # NaN or +/-Inf
        return Float64(rng.below(1_000_000))
    return Float64(f)


def _gen_bytes(mut rng: Xoshiro256, max_len: Int) -> List[UInt8]:
    """Generate up to ``max_len`` arbitrary bytes."""
    var n = rng.below(max_len + 1)
    var out = List[UInt8](capacity=n)
    for _i in range(n):
        out.append(UInt8(rng.below(256)))
    return out^


def _fail(imm name: String, trial: Int, imm detail: String) raises:
    """Raise a reproducible counterexample report."""
    raise Error(
        name + ": property failed on trial " + String(trial) + " — " + detail
    )


# ---------------------------------------------------------------------------
# Property 1: SQL safety, arbitrary UTF-8
# ---------------------------------------------------------------------------


def test_fuzz_sql_safety() raises:
    """Any random UTF-8 string passed to execute is handled safely.

    ``db.execute(any_string)`` must either succeed or raise ``Error``.  A
    crash or memory corruption would take the process down, which is exactly
    what this loop is watching for.
    """
    var rng = Xoshiro256(1)
    var tokens = _sql_tokens()
    for _i in range(2000):
        var sql = _gen_string(rng, tokens)
        var db = Database(":memory:")
        try:
            db.execute(sql)
        except:
            pass  # Error is the correct outcome for invalid SQL.


# ---------------------------------------------------------------------------
# Property 2: SQL safety, raw bytes
# ---------------------------------------------------------------------------


def test_fuzz_sql_bytes_safety() raises:
    """Executing random ASCII-printable byte sequences as SQL is always safe."""
    var rng = Xoshiro256(2)
    for _i in range(3000):
        var data = _gen_bytes(rng, 128)
        var s = String()
        for j in range(len(data)):
            var c = data[j]
            if c >= 0x20 and c <= 0x7E:
                s += chr(Int(c))
        var db = Database(":memory:")
        try:
            db.execute(s)
        except:
            pass


# ---------------------------------------------------------------------------
# Property 3: bind_text round-trip
# ---------------------------------------------------------------------------


def test_fuzz_bind_text_roundtrip() raises:
    """``bind_text`` → SELECT round-trips any random String value."""
    var rng = Xoshiro256(3)
    var tokens = _sql_tokens()
    for i in range(2000):
        var s = _gen_string(rng, tokens)
        var db = Database(":memory:")
        db.execute("CREATE TABLE t (v TEXT)")

        var ins = db.prepare("INSERT INTO t VALUES (?)")
        ins.bind_text(1, s)
        _ = ins.step()

        var q = db.prepare("SELECT v FROM t")
        var maybe = q.step()
        if not maybe:
            _fail("bind_text roundtrip", i, "no row returned for " + repr(s))
        if maybe.value().text_val(0) != s:
            _fail(
                "bind_text roundtrip",
                i,
                "read back "
                + repr(maybe.value().text_val(0))
                + ", expected "
                + repr(s),
            )


# ---------------------------------------------------------------------------
# Property 4: bind_int round-trip
# ---------------------------------------------------------------------------


def test_fuzz_bind_int_roundtrip() raises:
    """``bind_int`` → SELECT round-trips any random Int value."""
    var rng = Xoshiro256(4)
    for i in range(2000):
        var v = _gen_int(rng)
        var db = Database(":memory:")
        db.execute("CREATE TABLE t (v INTEGER)")

        var ins = db.prepare("INSERT INTO t VALUES (?)")
        ins.bind_int(1, v)
        _ = ins.step()

        var q = db.prepare("SELECT v FROM t")
        var maybe = q.step()
        if not maybe:
            _fail("bind_int roundtrip", i, "no row for " + String(v))
        if maybe.value().int_val(0) != v:
            _fail(
                "bind_int roundtrip",
                i,
                "read back "
                + String(maybe.value().int_val(0))
                + ", expected "
                + String(v),
            )


# ---------------------------------------------------------------------------
# Property 5: bind_float round-trip
# ---------------------------------------------------------------------------


def test_fuzz_bind_float_roundtrip() raises:
    """``bind_float`` → SELECT round-trips any finite Float64 exactly."""
    var rng = Xoshiro256(5)
    for i in range(2000):
        var v = _gen_float(rng)
        var db = Database(":memory:")
        db.execute("CREATE TABLE t (v REAL)")

        var ins = db.prepare("INSERT INTO t VALUES (?)")
        ins.bind_float(1, v)
        _ = ins.step()

        var q = db.prepare("SELECT v FROM t")
        var maybe = q.step()
        if not maybe:
            _fail("bind_float roundtrip", i, "no row for " + String(v))
        if maybe.value().float_val(0) != v:
            _fail(
                "bind_float roundtrip",
                i,
                "read back "
                + String(maybe.value().float_val(0))
                + ", expected "
                + String(v),
            )


# ---------------------------------------------------------------------------
# Property 6: count invariant
# ---------------------------------------------------------------------------


def test_fuzz_count_invariant() raises:
    """COUNT(*) always equals the number of INSERTs performed (1–50 rows)."""
    var rng = Xoshiro256(6)
    for i in range(500):
        var n = rng.below(50) + 1
        var db = Database(":memory:")
        db.execute("CREATE TABLE t (id INTEGER)")
        var ins = db.prepare("INSERT INTO t VALUES (?)")
        for j in range(n):
            ins.bind_int(1, j)
            _ = ins.step()
            ins.reset()

        var q = db.prepare("SELECT COUNT(*) FROM t")
        var maybe = q.step()
        if not maybe:
            _fail("count invariant", i, "COUNT(*) returned no row")
        if maybe.value().int_val(0) != n:
            _fail(
                "count invariant",
                i,
                "counted "
                + String(maybe.value().int_val(0))
                + " after "
                + String(n)
                + " inserts",
            )


# ---------------------------------------------------------------------------
# Property 7: prepared-statement injection safety
# ---------------------------------------------------------------------------


def test_fuzz_sql_injection_safety() raises:
    """``bind_text`` prevents SQL injection for any random String payload.

    The payload goes in as the table's only row; afterwards the table must
    still exist and hold exactly one row, which it would not if the text had
    escaped its placeholder and run as SQL.
    """
    var rng = Xoshiro256(7)
    var tokens = _sql_tokens()
    for i in range(2000):
        var s = _gen_string(rng, tokens)
        var db = Database(":memory:")
        db.execute("CREATE TABLE victims (val TEXT)")

        var ins = db.prepare("INSERT INTO victims VALUES (?)")
        ins.bind_text(1, s)
        _ = ins.step()

        var q = db.prepare("SELECT COUNT(*) FROM victims")
        var maybe = q.step()
        if not maybe:
            _fail("injection safety", i, "victims table is gone")
        if maybe.value().int_val(0) != 1:
            _fail(
                "injection safety",
                i,
                "victims holds "
                + String(maybe.value().int_val(0))
                + " rows after payload "
                + repr(s),
            )


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main() raises:
    test_fuzz_sql_safety()
    print("test_fuzz_sql_safety                 PASSED (2000 trials)")

    test_fuzz_sql_bytes_safety()
    print("test_fuzz_sql_bytes_safety           PASSED (3000 trials)")

    test_fuzz_bind_text_roundtrip()
    print("test_fuzz_bind_text_roundtrip        PASSED (2000 trials)")

    test_fuzz_bind_int_roundtrip()
    print("test_fuzz_bind_int_roundtrip         PASSED (2000 trials)")

    test_fuzz_bind_float_roundtrip()
    print("test_fuzz_bind_float_roundtrip       PASSED (2000 trials)")

    test_fuzz_count_invariant()
    print("test_fuzz_count_invariant            PASSED  (500 trials)")

    test_fuzz_sql_injection_safety()
    print("test_fuzz_sql_injection_safety       PASSED (2000 trials)")

    print("\nAll fuzz/property tests passed.")
