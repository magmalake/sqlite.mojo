"""SQLite bindings for Mojo — a dependency-free fork of ehsanmok/sqlite.

``sqlite`` provides two layers of abstraction over the SQLite C library:

**Layer 1, FFI** (``sqlite.ffi``): raw ``sqlite3_*`` wrappers with
handles stored as ``Int``.  Not intended for direct use.  ``libsqlite3`` is
``dlopen``ed once per process and its entry points resolved once, so opening a
connection or compiling a statement costs no dynamic linking.

**Layer 2, Safe API** (``sqlite.db``): ``Database``, ``Statement``,
``Row``, and ``Transaction`` structs that own their handles and clean up on
destruction.

Upstream carries a third layer, an ORM built on compile-time reflection via
`morph <https://github.com/ehsanmok/morph>`_.  This fork deliberately drops it
so the package depends on nothing outside conda-forge's ``libsqlite`` — use
`ehsanmok/sqlite <https://github.com/ehsanmok/sqlite>`_ if you want the ORM.

## Quick Start

```mojo
from sqlite import Database

def main() raises:
    var db = Database(":memory:")
    db.execute("CREATE TABLE people (name TEXT, age INTEGER, score REAL)")

    var ins = db.prepare("INSERT INTO people VALUES (?, ?, ?)")
    ins.bind_text(1, "Alice")
    ins.bind_int(2, 30)
    ins.bind_float(3, 9.5)
    _ = ins.step()

    var q = db.prepare("SELECT name, age, score FROM people")
    while True:
        var row = q.step()
        if not row:
            break
        ref r = row.value()
        print(r.text_val(0), r.int_val(1), r.float_val(2))
```

## Transaction API: context manager (recommended)

``db.transaction()`` supports Mojo's ``with`` statement.  The ``with`` block
auto-commits on clean exit and auto-rolls back (re-raising) if any statement
raises, identical to Python's ``with conn:`` pattern.

```mojo
from sqlite import Database

def transfer(db: Database, from_id: Int, to_id: Int, amount: Int) raises:
    with db.transaction():
        db.execute(
            "UPDATE accounts SET balance = balance - "
            + String(amount) + " WHERE id = " + String(from_id)
        )
        db.execute(
            "UPDATE accounts SET balance = balance + "
            + String(amount) + " WHERE id = " + String(to_id)
        )
    # -> COMMIT on success; ROLLBACK + re-raise if either UPDATE failed
```

For fine-grained control (conditional rollback without raising, multiple
commit points), use the ``var tx`` manual form.  Note: Mojo's
``with``/``__exit__`` protocol requires a non-consuming ``__enter__``, so
``with ... as tx:`` would bind ``tx`` to ``None``, so use ``var tx`` instead:

```mojo
var tx = db.transaction()   # BEGIN
db.execute("INSERT ...")
if some_condition:
    tx.rollback()           # abort without raising
    return
tx.commit()                 # explicit COMMIT
```

## Raw statement API

```mojo
from sqlite import Database

var db = Database(":memory:")
db.execute("CREATE TABLE t (id INTEGER, label TEXT)")
var stmt = db.prepare("INSERT INTO t VALUES (?, ?)")
stmt.bind_int(1, 42)
stmt.bind_text(2, "hello")
_ = stmt.step()

var q = db.prepare("SELECT id, label FROM t")
while True:
    var row = q.step()
    if not row:
        break
    print(row.value().int_val(0), row.value().text_val(1))
```
"""

from .db import Database, Statement, Row, Transaction
