# sqlite.mojo

[![mojoshelf](https://mojoshelf.org/badge/sqlite-mojo.svg)](https://mojoshelf.org/tins/sqlite-mojo) [![mojo nightly](https://mojoshelf.org/badge/sqlite-mojo/nightly.svg)](https://mojoshelf.org/tins/sqlite-mojo)

[![CI](https://github.com/magmalake/sqlite.mojo/actions/workflows/ci.yml/badge.svg)](https://github.com/magmalake/sqlite.mojo/actions/workflows/ci.yml) [![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

> Part of [**magmalake**](https://magmalake.org) — data lake building blocks in Mojo.

SQLite bindings for Mojo: a safe `Database` / `Statement` / `Row` API over
libsqlite3, with Pythonic context-manager transactions.

## This is a fork

This repository is a fork of
**[ehsanmok/sqlite](https://github.com/ehsanmok/sqlite) by Ehsan Mokhtarian**,
MIT-licensed, and it stays MIT-licensed with his copyright — the FFI layer, the
safe API, the transaction guard and most of the test suite are his work. Thank
you.

**What changed here, and why.** Upstream ships a third layer on top of the safe
API: an ORM (`create_table` / `insert` / `query`) driven by compile-time struct
reflection through [morph](https://github.com/ehsanmok/morph), plus property
tests driven by [mozz](https://github.com/ehsanmok/mozz). Both are git
dependencies, so a package built from that source cannot be installed from a
registry and compiled — the ORM's imports are unresolvable and the C library it
needs is never declared. This fork is deliberately dependency-free instead:

- The ORM layer is **removed**. `libsqlite` from conda-forge is the only thing
  this package depends on, and it is declared properly, so
  `pixi shelf add sqlite-mojo` gives you something that compiles.
- The property tests carry their own generators (a seeded xoshiro256\*\*) in
  place of mozz, and the ORM examples were rewritten against the safe API.
- `pixi build` produces a real `sqlite.mojoc` via the `pixi-build-mojo`
  backend, rather than copying raw source into the prefix.
- libsqlite3 is `dlopen`ed **once per process** rather than once per
  `Database`, `Statement` and `Transaction` — see [Performance](#performance).

That is a scope difference, not a criticism.
**If you want the ORM, use [upstream](https://github.com/ehsanmok/sqlite)** —
it is the more featureful library, and this fork tracks a narrower need.

## Why magmalake wants SQLite

Iceberg's **SQL catalog** — what PyIceberg calls `SqlCatalog`, and what
`iceberg-rs.mojo` uses for its fixtures — is the one catalog family
[`iceberg.mojo`](https://github.com/magmalake/iceberg.mojo) cannot implement
without a SQL engine to talk to. It is also how nearly every local and
single-node Iceberg deployment starts. This tin is the missing piece; the
catalog itself is **not** implemented here, and belongs in `iceberg.mojo`.

## Install

```toml
[workspace]
channels = ["https://conda.modular.com/max-nightly", "conda-forge"]
preview = ["pixi-build"]

[dependencies]
sqlite-mojo = "*"
```

```bash
pixi shelf add sqlite-mojo   # or add the dependency by hand, as above
pixi install
```

Working with a coding agent? `npx skills add mojoshelf/mojoshelf --skill mojoshelf-consume --yes` teaches it to find and install tins itself — it installs the `shelf` CLI too.

The conda package is **`sqlite-mojo`** (conda-forge owns the name `sqlite`);
the Mojo import stays `from sqlite import …`. Nothing else to install — the C
library comes along as a normal conda dependency.

## Use

```mojo
from sqlite import Database

def main() raises:
    var db = Database(":memory:")          # or a file path
    db.execute("CREATE TABLE t (id INTEGER, label TEXT)")

    var stmt = db.prepare("INSERT INTO t VALUES (?, ?)")
    stmt.bind_int(1, 42)                   # parameters are 1-based
    stmt.bind_text(2, "hello")
    _ = stmt.step()

    var q = db.prepare("SELECT id, label FROM t")
    while True:
        var row = q.step()                 # Optional[Row]; None when exhausted
        if not row:
            break
        ref r = row.value()
        print(r.int_val(0), r.text_val(1))  # columns are 0-based
        # 42 hello
```

`Row` is a **snapshot**: every column is copied out when the row is produced,
so a `Row` outlives the `Statement` that made it. Read values with
`int_val` / `float_val` / `text_val` / `is_null`, all 0-based.

`Database` closes its connection and `Statement` finalizes itself on
destruction; there is nothing to close by hand.

### Transactions

`db.transaction()` issues `BEGIN` immediately and returns an RAII guard that
supports Mojo's `with` statement, giving the same auto-commit / auto-rollback
semantics as Python's `with conn:`.

```mojo
def transfer(mut db: Database, from_id: Int, to_id: Int, amount: Int) raises:
    with db.transaction():
        db.execute(
            "UPDATE accounts SET balance = balance - "
            + String(amount) + " WHERE id = " + String(from_id)
        )
        db.execute(
            "UPDATE accounts SET balance = balance + "
            + String(amount) + " WHERE id = " + String(to_id)
        )
    # -> COMMIT on success; ROLLBACK + re-raise if either UPDATE raised
```

For fine-grained control — conditional rollback without raising, several commit
points — use the `var tx` form. Mojo's `with`/`__exit__` protocol requires a
non-consuming `__enter__`, so `with ... as tx:` would bind `tx` to `None`:

```mojo
var tx = db.transaction()   # BEGIN
db.execute("INSERT ...")
if some_condition:
    tx.rollback()           # abort without raising
    return
tx.commit()                 # explicit COMMIT; the destructor becomes a no-op

var tx2 = db.transaction()
db.execute("INSERT ...")
_ = tx2^                    # consume the guard -> ROLLBACK right here
```

Nested transactions are not supported through `BEGIN`/`COMMIT`; use `SAVEPOINT`
directly if you need nesting.

## Performance

libsqlite3 is loaded through an `OwnedDLHandle` opened **once per process** and
never closed, with all eighteen entry points resolved at that same moment.
Upstream constructed one handle per `Database`, per `Statement` and per
`Transaction`, so every `db.prepare(...)` paid for a full dynamic-link cycle
before it compiled any SQL. On an M4 (Mojo 1.0.0, macOS), open + `CREATE TABLE`
+ prepare:

| | per iteration |
|---|---|
| handle per object (upstream) | 1.19 ms |
| one handle per process | 20 µs |

A fresh `Sqlite3FFI()` measures 22.8 µs against 15 ns to borrow the cached one.
This is the same trap `zstd.mojo` hit — a `dlopen` is cheap enough to look free
and expensive enough to dominate everything around it.

## Correctness

- **51 unit tests** over the lifecycle, every bind and column variant, text and
  integer and float edge cases, NULL handling, statement reuse, DML, and all
  the transaction paths including the context-manager ones.
- **7 property tests, 13 500 trials**: arbitrary UTF-8 and arbitrary bytes
  executed as SQL never crash; `bind_text` / `bind_int` / `bind_float` round-trip
  exactly; `COUNT(*)` matches the inserts; and no `bind_text` payload can escape
  its placeholder to run as SQL.
- **A cross-check against real SQLite, in both directions** (`tests/crosscheck.sh`):
  this binding writes a database that the `sqlite3` shell reads back
  value-for-value and finds intact under `PRAGMA integrity_check`, and reads
  back one the shell wrote. Verified against CPython's `sqlite3` module too
  (libsqlite 3.50.4, a different build from the one the binding loads).

Everything above runs on **both** Mojo 1.0.0 (stable) and the current nightly,
on Linux and macOS.

## Examples

Progressive examples live in [`examples/`](examples/):

| File | What it shows |
|---|---|
| `01_hello_sqlite.mojo` | Open a database, `CREATE TABLE`, `INSERT`, `SELECT` |
| `02_prepared_statements.mojo` | Bind parameters, iterate rows, reuse statements |
| `03_all_types.mojo` | Every supported column type round-trip |
| `04_contacts_app.mojo` | CRUD mini-app: nullable columns, filtering, transactions |
| `05_transactions.mojo` | Bank-transfer demo: `with`, manual, `_ = tx^` |

## Scope

BLOB columns are not exposed yet — `Row` reports their type as neither text nor
integer and returns an empty value. `sqlite3_bind_blob` and
`sqlite3_column_blob` are the two entry points that would need adding. There is
no connection pooling, no async, and no query builder.

## Development

```bash
pixi run test              # db suite + property suite + sqlite3 cross-check
pixi run test-db           # 51 unit tests
pixi run test-fuzz         # 7 properties, 13 500 trials
pixi run test-crosscheck   # round-trip against the sqlite3 shell
pixi run examples          # run all five examples
pixi run format            # auto-format source

pixi run -e stable test    # the same, on Mojo 1.0.0 instead of nightly
```

## License

[MIT](LICENSE), unchanged from upstream — Copyright (c) 2026 Ehsan M. Kermani.

Note that the rest of magmalake is Apache-2.0; this tin is MIT because its
upstream is, and that takes precedence.
