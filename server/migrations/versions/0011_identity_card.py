"""Student/driver identity, photos, deregistration requests (supabase/migrations/0011_identity_card.sql).

Revision ID: 0011
Revises: 0010
"""

from migrations.sqlfile import run_sql_file

revision = "0011"
down_revision = "0010"
branch_labels = None
depends_on = None


def upgrade() -> None:
    run_sql_file("0011_identity_card.sql")


def downgrade() -> None:
    raise NotImplementedError("Forward-only migrations; restore from backup instead.")
