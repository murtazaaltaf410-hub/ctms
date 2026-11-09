"""Student registration, profiles and bus capacity (supabase/migrations/0008_students.sql).

Revision ID: 0008
Revises: 0007
"""

from migrations.sqlfile import run_sql_file

revision = "0008"
down_revision = "0007"
branch_labels = None
depends_on = None


def upgrade() -> None:
    run_sql_file("0008_students.sql")


def downgrade() -> None:
    raise NotImplementedError("Forward-only migrations; restore from backup instead.")
