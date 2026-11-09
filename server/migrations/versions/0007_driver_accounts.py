"""Admin-managed driver accounts and driver profiles (supabase/migrations/0007_driver_accounts.sql).

Revision ID: 0007
Revises: 0006
"""

from migrations.sqlfile import run_sql_file

revision = "0007"
down_revision = "0006"
branch_labels = None
depends_on = None


def upgrade() -> None:
    run_sql_file("0007_driver_accounts.sql")


def downgrade() -> None:
    raise NotImplementedError("Forward-only migrations; restore from backup instead.")
