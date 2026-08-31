"""Example 4 — Contacts mini-application.

A realistic, self-contained CRUD demo that combines everything the safe API
offers:

- ``CREATE TABLE`` + parameterised ``INSERT`` inside a ``db.transaction()``
  guard, so the seed data lands atomically.
- Raw prepared statements for ``UPDATE`` and aggregation.
- ``NULL`` columns read back via ``Row.is_null``.
- ``WHERE`` filtering.

The application manages a simple contacts list: add contacts, update a phone
number, soft-delete a contact, then print a filtered directory.
"""

from sqlite.db import Database, Row, Transaction


# ---------------------------------------------------------------------------
# Domain struct
# ---------------------------------------------------------------------------


@fieldwise_init
struct Contact(Copyable, Movable):
    """One entry in a contacts list.

    Fields:
        id:      Surrogate integer key.
        name:    Full display name.
        email:   E-mail address.
        phone:   Phone number (``None`` when unknown → SQL NULL).
        active:  False when the contact has been soft-deleted.
    """

    var id: Int
    var name: String
    var email: String
    var phone: Optional[String]
    var active: Bool


# ---------------------------------------------------------------------------
# Schema and row mapping
# ---------------------------------------------------------------------------

comptime SCHEMA = String(
    "CREATE TABLE contacts ("
    "  id     INTEGER PRIMARY KEY,"
    "  name   TEXT    NOT NULL,"
    "  email  TEXT    NOT NULL,"
    "  phone  TEXT,"
    "  active INTEGER NOT NULL"
    ")"
)

comptime SELECT_COLS = String("SELECT id, name, email, phone, active FROM contacts")


def _row_to_contact(imm row: Row) -> Contact:
    """Map a five-column result row onto a ``Contact``."""
    var phone = Optional[String](None)
    if not row.is_null(3):
        phone = Optional[String](row.text_val(3))
    return Contact(
        id=row.int_val(0),
        name=row.text_val(1),
        email=row.text_val(2),
        phone=phone^,
        active=row.int_val(4) != 0,
    )


def _select(mut db: Database, var where: String) raises -> List[Contact]:
    """Run ``SELECT … FROM contacts`` with an optional ``WHERE`` clause."""
    var sql = SELECT_COLS
    if where:
        sql += " WHERE "
        sql += where
    var stmt = db.prepare(sql)
    var out = List[Contact]()
    while True:
        var maybe_row = stmt.step()
        if not maybe_row:
            break
        out.append(_row_to_contact(maybe_row.value()))
    return out^


def _insert(mut db: Database, imm c: Contact) raises:
    """Insert one contact through a parameterised statement."""
    var stmt = db.prepare(
        "INSERT INTO contacts (id, name, email, phone, active)"
        " VALUES (?, ?, ?, ?, ?)"
    )
    stmt.bind_int(1, c.id)
    stmt.bind_text(2, c.name)
    stmt.bind_text(3, c.email)
    if c.phone:
        stmt.bind_text(4, c.phone.value())
    else:
        stmt.bind_null(4)
    stmt.bind_int(5, 1 if c.active else 0)
    _ = stmt.step()


# ---------------------------------------------------------------------------
# Helper: print a contact line
# ---------------------------------------------------------------------------


def _print_contact(imm c: Contact):
    var phone = c.phone.value() if c.phone else String("(none)")
    var status = String("active") if c.active else String("inactive")
    print(
        "  [" + String(c.id) + "]",
        c.name,
        "<" + c.email + ">",
        "| phone:",
        phone,
        "| status:",
        status,
    )


# ---------------------------------------------------------------------------
# Application helpers
# ---------------------------------------------------------------------------


def _seed_contacts(mut db: Database) raises:
    """Insert initial contacts inside a transaction for atomicity."""
    var tx = db.transaction()  # BEGIN
    try:
        var contacts = List[Contact]()
        contacts.append(
            Contact(
                id=1,
                name="Alice Nguyen",
                email="alice@example.com",
                phone=Optional[String]("+1-415-555-0101"),
                active=True,
            )
        )
        contacts.append(
            Contact(
                id=2,
                name="Bob Martínez",
                email="bob@example.com",
                phone=None,
                active=True,
            )
        )
        contacts.append(
            Contact(
                id=3,
                name="Carol Smith",
                email="carol@example.com",
                phone=Optional[String]("+44-20-7946-0958"),
                active=True,
            )
        )
        contacts.append(
            Contact(
                id=4,
                name="Dave Kim",
                email="dave@example.com",
                phone=Optional[String]("+82-2-555-0199"),
                active=True,
            )
        )

        for i in range(len(contacts)):
            _insert(db, contacts[i])

        tx.commit()  # COMMIT — all contacts inserted atomically
    except e:
        tx.rollback()  # ROLLBACK — no contacts inserted
        raise e.copy()


def _update_phone(mut db: Database, contact_id: Int, imm new_phone: String) raises:
    """Set a new phone number for a contact by id (raw prepared statement)."""
    var stmt = db.prepare("UPDATE contacts SET phone = ? WHERE id = ?")
    stmt.bind_text(1, new_phone)
    stmt.bind_int(2, contact_id)
    _ = stmt.step()


def _deactivate(mut db: Database, contact_id: Int) raises:
    """Soft-delete: mark a contact inactive rather than removing the row."""
    var stmt = db.prepare("UPDATE contacts SET active = 0 WHERE id = ?")
    stmt.bind_int(1, contact_id)
    _ = stmt.step()


def _count_active(mut db: Database) raises -> Int:
    """Return the count of active contacts via a raw aggregation query."""
    var stmt = db.prepare("SELECT COUNT(*) FROM contacts WHERE active = 1")
    var maybe_row = stmt.step()
    if not maybe_row:
        return 0
    return maybe_row.value().int_val(0)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main() raises:
    var db = Database(":memory:")
    db.execute(SCHEMA)

    # -----------------------------------------------------------------------
    # 1. Seed initial data.
    # -----------------------------------------------------------------------
    _seed_contacts(db)
    print("After seeding:")
    var all_contacts = _select(db, "")
    for i in range(len(all_contacts)):
        _print_contact(all_contacts[i])
    print()

    # -----------------------------------------------------------------------
    # 2. Update Bob's phone number.
    # -----------------------------------------------------------------------
    _update_phone(db, 2, "+1-212-555-0188")
    print("After updating Bob's phone:")
    var bob_rows = _select(db, "id = 2")
    _print_contact(bob_rows[0])
    print()

    # -----------------------------------------------------------------------
    # 3. Soft-delete Dave.
    # -----------------------------------------------------------------------
    _deactivate(db, 4)
    print("After deactivating Dave:")
    print("  Active contact count:", _count_active(db))
    print()

    # -----------------------------------------------------------------------
    # 4. Print active contacts only.
    # -----------------------------------------------------------------------
    print("Active contacts:")
    var active = _select(db, "active = 1")
    for i in range(len(active)):
        _print_contact(active[i])
    print()

    # -----------------------------------------------------------------------
    # 5. Contacts whose phone is still unknown.
    # -----------------------------------------------------------------------
    print("Contacts without a phone number:")
    var no_phone = _select(db, "phone IS NULL AND active = 1")
    if len(no_phone) == 0:
        print("  (none)")
    else:
        for i in range(len(no_phone)):
            _print_contact(no_phone[i])
    print()

    print("Done.")
