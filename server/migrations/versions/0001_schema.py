"""Full V1 schema (supabase/migrations/0001_schema.sql).

Revision ID: 0001
Revises:
"""

import logging

from migrations.sqlfile import run_sql_file, table_exists

revision = "0001"
down_revision = None
branch_labels = None
depends_on = None


def upgrade() -> None:
    # The user may already have run the file in the Supabase SQL editor; adopt
    # that schema instead of failing on the file's "already applied" guard.
    if table_exists("public.users"):
        logging.getLogger("alembic").info("0001: public.users exists (applied via SQL editor) - skipping")
        return
    run_sql_file("0001_schema.sql")


def downgrade() -> None:
    raise NotImplementedError("Forward-only migrations (no DROP); restore from backup instead.")
