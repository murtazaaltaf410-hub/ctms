"""Stop alerts, driver prefs, pickup decisions (supabase/migrations/0012_stop_alerts_pickup_decisions.sql).

Revision ID: 0012
Revises: 0011
"""

from migrations.sqlfile import run_sql_file

revision = "0012"
down_revision = "0011"
branch_labels = None
depends_on = None


def upgrade() -> None:
    run_sql_file("0012_stop_alerts_pickup_decisions.sql")


def downgrade() -> None:
    raise NotImplementedError("Forward-only migrations; restore from backup instead.")
