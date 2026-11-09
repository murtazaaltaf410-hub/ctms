"""Driver route allow-list (supabase/migrations/0010_driver_route_assignments.sql).

Revision ID: 0010
Revises: 0009
"""

from migrations.sqlfile import run_sql_file

revision = "0010"
down_revision = "0009"
branch_labels = None
depends_on = None


def upgrade() -> None:
    run_sql_file("0010_driver_route_assignments.sql")


def downgrade() -> None:
    raise NotImplementedError("Forward-only migrations; restore from backup instead.")
