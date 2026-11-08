"""Default settings, first-admin placeholder, optional demo data (supabase/migrations/0003_seed.sql).

Idempotent (on conflict do nothing). Demo data is skipped when the database
setting ctms.seed_demo is 'off', e.g. `alter database ... set ctms.seed_demo = 'off'`.

Revision ID: 0003
Revises: 0002
"""

from migrations.sqlfile import run_sql_file

revision = "0003"
down_revision = "0002"
branch_labels = None
depends_on = None


def upgrade() -> None:
    run_sql_file("0003_seed.sql")


def downgrade() -> None:
    raise NotImplementedError("Forward-only migrations; restore from backup instead.")
