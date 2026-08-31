"""Write a database with this binding, for the sqlite3 shell to read back.

Half of the cross-check driven by ``tests/crosscheck.sh``: proves the bytes
this binding writes are a genuine SQLite database that an independent SQLite
implementation reads with identical values.

Writes ``build/crosscheck/from_mojo.db``.  The float values are exact binary
fractions so they survive a REAL round-trip bit-for-bit.
"""

from sqlite.db import Database


def main() raises:
    var db = Database("build/crosscheck/from_mojo.db")
    db.execute(
        "CREATE TABLE widgets ("
        "  id    INTEGER PRIMARY KEY,"
        "  name  TEXT    NOT NULL,"
        "  qty   INTEGER NOT NULL,"
        "  ratio REAL    NOT NULL,"
        "  note  TEXT"
        ")"
    )

    var tx = db.transaction()
    var stmt = db.prepare(
        "INSERT INTO widgets (id, name, qty, ratio, note) VALUES (?, ?, ?, ?, ?)"
    )

    # (id, name, qty, ratio, note) -- note is NULL on the middle row, and the
    # names exercise multi-byte UTF-8 and an embedded single quote.
    stmt.bind_int(1, 1)
    stmt.bind_text(2, "widget-α")
    stmt.bind_int(3, 42)
    stmt.bind_float(4, 0.5)
    stmt.bind_text(5, "first")
    _ = stmt.step()
    stmt.reset()

    stmt.bind_int(1, 2)
    stmt.bind_text(2, "o'brien 中文")
    stmt.bind_int(3, -7)
    stmt.bind_float(4, 1.25)
    stmt.bind_null(5)
    _ = stmt.step()
    stmt.reset()

    stmt.bind_int(1, 3)
    stmt.bind_text(2, "line\nbreak")
    stmt.bind_int(3, 9223372036854775807)
    stmt.bind_float(4, -2.75)
    stmt.bind_text(5, "third")
    _ = stmt.step()
    stmt.reset()

    tx.commit()
    print("wrote build/crosscheck/from_mojo.db")
