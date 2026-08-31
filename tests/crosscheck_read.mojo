"""Read a database the sqlite3 shell wrote, and check every value.

The other half of the cross-check driven by ``tests/crosscheck.sh``.  Reads
``build/crosscheck/from_shell.db``, seeded by ``tests/crosscheck_seed.sql``,
and asserts each column against the values the shell inserted -- REAL columns
by exact equality, since the fixtures are exact binary fractions.
"""

from std.testing import assert_equal, assert_true
from sqlite.db import Database, Row


def main() raises:
    var db = Database("build/crosscheck/from_shell.db")
    var q = db.prepare(
        "SELECT id, name, qty, ratio, note FROM widgets ORDER BY id"
    )

    var ids = List[Int]()
    var names = List[String]()
    var qtys = List[Int]()
    var ratios = List[Float64]()
    var notes = List[String]()
    while True:
        var maybe = q.step()
        if not maybe:
            break
        ref row = maybe.value()
        ids.append(row.int_val(0))
        names.append(row.text_val(1))
        qtys.append(row.int_val(2))
        ratios.append(row.float_val(3))
        notes.append(String("<null>") if row.is_null(4) else row.text_val(4))

    assert_equal(len(ids), 3, "expected three rows")

    assert_equal(ids[0], 1)
    assert_equal(names[0], "widget-α")
    assert_equal(qtys[0], 42)
    assert_equal(ratios[0], 0.5)
    assert_equal(notes[0], "first")

    assert_equal(ids[1], 2)
    assert_equal(names[1], "o'brien 中文")
    assert_equal(qtys[1], -7)
    assert_equal(ratios[1], 1.25)
    assert_equal(notes[1], "<null>")

    assert_equal(ids[2], 3)
    assert_equal(names[2], "line\nbreak")
    assert_equal(qtys[2], 9223372036854775807)
    assert_equal(ratios[2], -2.75)
    assert_equal(notes[2], "third")

    print("read build/crosscheck/from_shell.db: all 15 values match")
