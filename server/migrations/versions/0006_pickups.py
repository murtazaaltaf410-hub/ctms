"""Student pickup pins and their alert log (supabase/migrations/0006_pickups.sql).

Revision ID: 0006
Revises: 0005
"""

from migrations.sqlfile import run_sql_file

revision = "0006"
down_revision = "0005"
branch_labels = None
depends_on = None


def upgrade() -> None:
    run_sql_file("0006_pickups.sql")


def downgrade() -> None:
    raise NotImplementedError("Forward-only migrations; restore from backup instead.")
