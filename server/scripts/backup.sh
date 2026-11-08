#!/usr/bin/env bash
# Weekly CTMS database backup (runbook "Backups": pg_dump weekly to storage the
# team controls; test one restore before launch). Procedure: docs/v1/runbook.md.
#
#   DATABASE_URL='postgresql://postgres.<ref>:<pw>@aws-...pooler.supabase.com:5432/postgres' \
#     server/scripts/backup.sh [output-dir]          # default ./backups
#
# Writes <output-dir>/ctms-<UTC timestamp>.dump (pg_dump custom format, schema
# `public` only: Supabase's own schemas are recreated by Supabase) plus a
# .sha256 next to it. Needs pg_dump 16+ on PATH (Supabase runs Postgres 15/17;
# pg_dump must be >= the server major version). No pg_dump locally? Use Docker:
#
#   docker run --rm -e DATABASE_URL -v "$PWD/backups:/backups" postgres:17-alpine \
#     sh -c 'pg_dump --format=custom --no-owner --no-privileges --schema=public \
#            --file=/backups/ctms-$(date -u +%Y%m%dT%H%M%SZ).dump "$DATABASE_URL"'
#
# The dump contains personal data (names, emails, phones, trip history): store
# it only in the team's private drive/bucket, never in git, and delete dumps
# older than the retention you agree with the university (suggested: 8 weekly).
set -euo pipefail

: "${DATABASE_URL:?set DATABASE_URL (Supabase session pooler URL, port 5432)}"
out_dir="${1:-backups}"
keep="${BACKUP_KEEP:-8}"   # local copies to keep (newest first)

command -v pg_dump >/dev/null || { echo "pg_dump not found (install PostgreSQL client 16+ or use the Docker command in this file)" >&2; exit 1; }

mkdir -p "$out_dir"
umask 077
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
file="$out_dir/ctms-$stamp.dump"

echo "pg_dump $(pg_dump --version | awk '{print $NF}') -> $file"
pg_dump --format=custom --no-owner --no-privileges --schema=public --file="$file" "$DATABASE_URL"

# Sanity check: the archive lists the tables we expect.
tables="$(pg_restore --list "$file" | grep -c ' TABLE public ' || true)"
if [ "$tables" -lt 19 ]; then
  echo "backup looks incomplete: $tables tables in the archive (expected 19+)" >&2
  exit 1
fi

if command -v sha256sum >/dev/null; then
  (cd "$out_dir" && sha256sum "$(basename "$file")" > "$(basename "$file").sha256")
fi
echo "ok: $file ($(du -h "$file" | cut -f1), $tables tables)"

# Keep only the newest $keep dumps in this directory.
ls -1t "$out_dir"/ctms-*.dump 2>/dev/null | tail -n +"$((keep + 1))" | while read -r old; do
  rm -f -- "$old" "$old.sha256"
done

echo "Now copy $file to the team storage (see docs/v1/runbook.md, Backups)."
