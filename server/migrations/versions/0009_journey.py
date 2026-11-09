"""Trip moved/arrived times, arrival closure and campus settings (supabase/migrations/0009_journey.sql).

Revision ID: 0009
Revises: 0008
"""

from migrations.sqlfile import run_sql_file

revision = "0009"
down_revision = "0008"
branch_labels = None
depends_on = None


def upgrade() -> None:
    run_sql_file("0009_journey.sql")


def downgrade() -> None:
    raise NotImplementedError("Forward-only migrations; restore from backup instead.")
