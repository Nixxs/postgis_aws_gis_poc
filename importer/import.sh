#!/usr/bin/env bash
set -euo pipefail

required=(SOURCE_URL SOURCE_FILENAME IMPORT_MANIFEST DB_HOST DB_PORT DB_NAME DB_USER DB_PASSWORD)
for name in "${required[@]}"; do
  if [[ -z "${!name:-}" ]]; then
    echo "Required environment variable is missing: ${name}" >&2
    exit 2
  fi
done

export PGPASSWORD="${DB_PASSWORD}"
pg="PG:host='${DB_HOST}' port='${DB_PORT}' dbname='${DB_NAME}' user='${DB_USER}' sslmode='require'"
if [[ "${IMPORT_MODE:-import}" == "inspect" ]]; then
  # Enforce read-only transactions on the server, not merely by convention.
  pg="${pg} options='-c default_transaction_read_only=on -c statement_timeout=300000'"
  printf 'READ-ONLY DATABASE INSPECTION\n'
  ogrinfo -ro -q "${pg}" -sql "SELECT current_database() AS database, current_setting('default_transaction_read_only') AS read_only, postgis_lib_version() AS postgis_version"
  ogrinfo -ro -q "${pg}" -sql "SELECT g.f_table_schema AS schema, g.f_table_name AS table_name, g.f_geometry_column AS geometry_column, g.type AS geometry_type, g.srid, pg_size_pretty(pg_total_relation_size(format('%I.%I', g.f_table_schema, g.f_table_name)::regclass)) AS total_size FROM geometry_columns g WHERE g.f_table_schema = 'public' ORDER BY g.f_table_name"
  while IFS= read -r table; do
    if [[ ! "${table}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      echo 'Invalid inspection table identifier.' >&2; exit 2
    fi
    printf 'ROW COUNT: public.%s\n' "${table}"
    ogrinfo -ro -q "${pg}" -sql "SELECT '${table}' AS table_name, count(*) AS row_count FROM public.\"${table}\""
  done < <(jq -r '.layers[].target' <<<"${IMPORT_MANIFEST}")
  ogrinfo -ro -q "${pg}" -sql "SELECT table_name, string_agg(column_name || ' (' || data_type || ')', ', ' ORDER BY ordinal_position) AS columns FROM information_schema.columns WHERE table_schema = 'public' GROUP BY table_name ORDER BY table_name"
  printf 'Read-only inspection complete. No database data was changed.\n'
  exit 0
fi
work_dir=/tmp/import-source
mkdir -p "${work_dir}"
source_file="${work_dir}/${SOURCE_FILENAME##*/}"

case "${source_file}" in
  *.zip) ;;
  *)
    if [[ "$(jq -r '.archive // "none"' <<<"${IMPORT_MANIFEST}")" == "zip" ]]; then
      source_file="${source_file}.zip"
    fi
    ;;
esac

printf 'Downloading source object to temporary task storage...\n'
curl --fail --location --retry 5 --retry-all-errors --output "${source_file}" "${SOURCE_URL}"

archive="$(jq -r '.archive // "none"' <<<"${IMPORT_MANIFEST}")"
suffix="$(jq -r '.datasetPathSuffix // ""' <<<"${IMPORT_MANIFEST}")"
case "${archive}" in
  zip) dataset="/vsizip/${source_file}${suffix}" ;;
  none) dataset="${source_file}${suffix}" ;;
  *) echo "Unsupported archive type: ${archive}" >&2; exit 2 ;;
esac

printf 'Enabling PostGIS if needed...\n'
ogrinfo "${pg}" -sql 'CREATE EXTENSION IF NOT EXISTS postgis' >/dev/null

layer_count="$(jq '.layers | length' <<<"${IMPORT_MANIFEST}")"
if [[ "${layer_count}" -lt 1 ]]; then
  echo 'Manifest must contain at least one layer.' >&2
  exit 2
fi

for ((index=0; index<layer_count; index++)); do
  source_layer="$(jq -r ".layers[${index}].source" <<<"${IMPORT_MANIFEST}")"
  target_layer="$(jq -r ".layers[${index}].target" <<<"${IMPORT_MANIFEST}")"
  if [[ ! "${source_layer}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || [[ ! "${target_layer}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "Layer names must be unqualified SQL identifiers: ${source_layer} -> ${target_layer}" >&2
    exit 2
  fi

  printf 'Importing %s as public.%s...\n' "${source_layer}" "${target_layer}"
  ogr2ogr \
    -f PostgreSQL "${pg}" "${dataset}" "${source_layer}" \
    -nln "${target_layer}" -overwrite \
    -nlt PROMOTE_TO_MULTI \
    -lco SCHEMA=public \
    -lco GEOMETRY_NAME=geom \
    -lco FID=OBJECTID \
    -lco SPATIAL_INDEX=GIST \
    -progress
  ogrinfo "${pg}" -sql "ANALYZE public.\"${target_layer}\"" >/dev/null
 done

printf 'Imported %s layer(s) successfully.\n' "${layer_count}"
