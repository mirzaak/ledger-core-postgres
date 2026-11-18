#!/usr/bin/env bash
# Rebuilds the ledger from scratch, then runs the tests, reports and concurrency suite.
# Connection settings come from the standard PGHOST, PGPORT, PGUSER, PGPASSWORD variables.
set -euo pipefail

cd "$(dirname "$0")/.."
export DB_NAME="${DB_NAME:-ledger_core}"

psql -X -q -v ON_ERROR_STOP=1 -d postgres -c "DROP DATABASE IF EXISTS ${DB_NAME}" -c "CREATE DATABASE ${DB_NAME}"

run() { psql -X -q -v ON_ERROR_STOP=1 -d "$DB_NAME" "$@"; }

for file in sql/0*.sql; do
    echo "==> ${file}"
    run -f "$file" > /dev/null
done
run -c "ANALYZE"

echo "==> Running behavioural tests"
run -f tests/run_tests.sql

mkdir -p output
for file in reports/*.sql; do
    name="$(basename "$file" .sql)"
    echo "==> ${file}"
    run --csv -f "$file" > "output/${name}.csv"
done

echo "==> Running concurrency tests"
./tests/concurrency.sh

echo "Done. Report results are in output/."
