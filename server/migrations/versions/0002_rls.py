"""Enable RLS everywhere, revoke Supabase API roles (supabase/migrations/0002_rls.sql).

Idempotent, so it always runs; this also puts RLS on alembic_version.

Revision ID: 0002
Revises: 0001
"""

from migrations.sqlfile import run_sql_file

revision = "0002"
down_revision = "0001"
branch_labels = None
depends_on = None


def upgrade() -> None:
    run_sql_file("0002_rls.sql")


def downgrade() -> None:
    raise NotImplementedError("Forward-only migrations; restore from backup instead.")
