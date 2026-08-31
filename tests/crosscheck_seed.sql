-- Fixture for tests/crosscheck.sh: the sqlite3 shell writes exactly what
-- tests/crosscheck_write.mojo writes, for tests/crosscheck_read.mojo to check.
CREATE TABLE widgets (
  id    INTEGER PRIMARY KEY,
  name  TEXT    NOT NULL,
  qty   INTEGER NOT NULL,
  ratio REAL    NOT NULL,
  note  TEXT
);
INSERT INTO widgets VALUES (1, 'widget-α',      42,                    0.5,  'first');
INSERT INTO widgets VALUES (2, 'o''brien 中文', -7,                    1.25, NULL);
INSERT INTO widgets VALUES (3, 'line' || char(10) || 'break', 9223372036854775807, -2.75, 'third');
