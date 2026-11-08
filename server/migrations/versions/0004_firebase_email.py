"""Link verified Firebase email/password identities (supabase/migrations/0004_firebase_email.sql).

Revision ID: 0004
Revises: 0003
"""

from migrations.sqlfile import run_sql_file

revision = "0004"
down_revision = "0003"
branch_labels = None
depends_on = None


def upgrade() -> None:
    run_sql_file("0004_firebase_email.sql")


def downgrade() -> None:
    raise NotImplementedError("Forward-only migrations; restore from backup instead.")
