"""Trip and schedule direction (supabase/migrations/0005_trip_direction.sql).

Revision ID: 0005
Revises: 0004
"""

from migrations.sqlfile import run_sql_file

revision = "0005"
down_revision = "0004"
branch_labels = None
depends_on = None


def upgrade() -> None:
    run_sql_file("0005_trip_direction.sql")


def downgrade() -> None:
    raise NotImplementedError("Forward-only migrations; restore from backup instead.")
