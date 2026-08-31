#!/bin/sh
# Cross-check against a real SQLite implementation, in both directions.
#
# 1. This binding writes a database; the sqlite3 shell reads it back and must
#    report the same values, and PRAGMA integrity_check must say "ok".
# 2. The sqlite3 shell writes a database; this binding reads it back and
#    checks every column.
#
# REAL columns are compared as CAST(ratio*1000 AS INTEGER) so the check never
# depends on how either side formats a float as text.
set -eu

out=build/crosscheck
rm -rf "$out"
mkdir -p "$out"

query='SELECT id || "|" || name || "|" || qty || "|"
              || CAST(ratio * 1000 AS INTEGER) || "|"
              || COALESCE(note, "<null>")
       FROM widgets ORDER BY id;'

# --- 1. written here, read by the sqlite3 shell -----------------------------
mojo run -I . tests/crosscheck_write.mojo

# A genuine SQLite database begins with the 16-byte magic "SQLite format 3\0".
magic=$(dd if="$out/from_mojo.db" bs=1 count=15 2>/dev/null)
if [ "$magic" != "SQLite format 3" ]; then
    echo "not a SQLite file: header is '$magic'" >&2
    exit 1
fi

integrity=$(sqlite3 "$out/from_mojo.db" 'PRAGMA integrity_check;')
if [ "$integrity" != "ok" ]; then
    echo "integrity_check said '$integrity'" >&2
    exit 1
fi

sqlite3 "$out/from_mojo.db" "$query" > "$out/shell_read.txt"
diff -u tests/crosscheck_expected.txt "$out/shell_read.txt"
echo "the sqlite3 shell read back every value this binding wrote"

# --- 2. written by the sqlite3 shell, read here -----------------------------
sqlite3 "$out/from_shell.db" < tests/crosscheck_seed.sql
mojo run -I . tests/crosscheck_read.mojo

# And the shell agrees with itself on its own file, so the fixture and the
# expectation cannot drift apart silently.
sqlite3 "$out/from_shell.db" "$query" > "$out/shell_selfread.txt"
diff -u tests/crosscheck_expected.txt "$out/shell_selfread.txt"

echo "cross-check passed in both directions"
