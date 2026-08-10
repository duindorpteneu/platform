#!/usr/bin/env sh
set -eu

: "${SOURCE_DB_URL:?SOURCE_DB_URL ontbreekt}"
: "${SOURCE_INVENTORY_MODE:?SOURCE_INVENTORY_MODE ontbreekt}"
test -r /run/restore-inventory-key
test -r /harness/scripts/staging/source-restore-inventory.sql
test -d /work

umask 077
snapshot_path=/work/source.snapshot
snapshot_pending_path=/work/source.snapshot.pending
dump_path=/work/source.dump
inventory_path=/work/source-inventory.json
export_complete_path=/work/source.export.complete
exporter_pid=

cleanup() {
  status=$?
  if test -n "${exporter_pid}"; then
    kill "${exporter_pid}" >/dev/null 2>&1 || true
    wait "${exporter_pid}" >/dev/null 2>&1 || true
  fi
  rm -f -- \
    "${snapshot_path}" \
    "${snapshot_pending_path}" \
    "${export_complete_path}"
  exit "${status}"
}
trap cleanup EXIT HUP INT TERM

psql "${SOURCE_DB_URL}" -X -q -A -t -v ON_ERROR_STOP=1 \
  > /work/source-exporter.log 2>&1 <<'SQL' &
begin isolation level repeatable read read only;
\o /work/source.snapshot.pending
select pg_export_snapshot();
\o /dev/null
\! mv /work/source.snapshot.pending /work/source.snapshot
\! while test ! -f /work/source.export.complete; do sleep 1; done
rollback;
SQL
exporter_pid=$!

attempt=0
while test ! -s "${snapshot_path}"; do
  attempt=$((attempt + 1))
  if test "${attempt}" -gt 300 || ! kill -0 "${exporter_pid}" 2>/dev/null; then
    echo "De consistente databasesnapshot kon niet worden geopend." >&2
    exit 1
  fi
  sleep 0.1
done

snapshot_id="$(tr -d '\r\n' < "${snapshot_path}")"
case "${snapshot_id}" in
  *[!0-9A-Fa-f:-]*|'')
    echo "De geëxporteerde snapshotidentiteit is ongeldig." >&2
    exit 1
    ;;
esac
inventory_hmac_key="$(tr -d '\r\n' < /run/restore-inventory-key)"
test "${#inventory_hmac_key}" -eq 64

psql "${SOURCE_DB_URL}" -X -q -A -t -v ON_ERROR_STOP=1 \
  -v snapshot_mode=1 \
  -v snapshot_id="${snapshot_id}" \
  -v inventory_hmac_key="${inventory_hmac_key}" \
  -f /harness/scripts/staging/source-restore-inventory.sql \
  > "${inventory_path}"

pg_dump --format=custom --compress=6 --strict-names \
  --snapshot="${snapshot_id}" \
  --schema=app --schema=private --schema=public --schema=auth \
  --schema=supabase_migrations \
  --dbname="${SOURCE_DB_URL}" \
  > "${dump_path}"

test -s "${inventory_path}"
test -s "${dump_path}"
chmod 0600 "${inventory_path}" "${dump_path}"
: > "${export_complete_path}"
wait "${exporter_pid}" >/dev/null 2>&1 || true
exporter_pid=
