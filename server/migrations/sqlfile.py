"""Run one of the hand-written SQL files in supabase/migrations/ (ADR-2).

The same files are pasted into the Supabase SQL editor and mounted into the
dev Postgres container, so they keep their own ``begin;``/``commit;`` lines.
Alembic already wraps each migration in a transaction, so those two lines are
stripped here and the rest runs inside Alembic's transaction.

``op.execute(str)`` is avoided: it wraps the text in ``text()``, which treats
``:name`` as a bind parameter. ``exec_driver_sql`` with ``no_parameters=True``
calls ``cursor.execute(sql)`` with no parameters, so psycopg 3 sends the whole
multi-statement file as one simple query.
"""

from __future__ import annotations

import os
import re
from pathlib import Path

from alembic import op

# server/migrations/sqlfile.py -> repo root is two levels above server/.
_DEFAULT_SQL_DIR = Path(__file__).resolve().parents[2] / "supabase" / "migrations"
_TX_LINE = re.compile(r"^\s*(begin|commit)\s*;\s*$", re.IGNORECASE | re.MULTILINE)


def sql_dir() -> Path:
    """Directory holding the SQL files; ``CTMS_SQL_DIR`` overrides it (e.g. in a container)."""
    return Path(os.environ.get("CTMS_SQL_DIR", _DEFAULT_SQL_DIR))


def read_sql(filename: str) -> str:
    return _TX_LINE.sub("", (sql_dir() / filename).read_text(encoding="utf-8"))


def run_sql_file(filename: str) -> None:
    bind = op.get_bind()
    bind.execution_options(no_parameters=True).exec_driver_sql(read_sql(filename))


def table_exists(qualified_name: str) -> bool:
    bind = op.get_bind()
    return bind.exec_driver_sql("select to_regclass(%(n)s) is not null", {"n": qualified_name}).scalar()
