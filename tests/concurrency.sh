#!/usr/bin/env bash
# Concurrency proof using pgbench: real parallel sessions racing against the ledger.
set -euo pipefail

DB_NAME="${DB_NAME:-ledger_core}"
CLIENTS="${CLIENTS:-16}"
TRANSACTIONS="${TRANSACTIONS:-500}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

sql() { psql -X -q -v ON_ERROR_STOP=1 -d "$DB_NAME" "$@"; }

RUN_ID="$(sql -At -c 'SELECT gen_random_uuid()')"

sql > /dev/null <<'SQL'
DROP SCHEMA IF EXISTS ledger_load CASCADE;
CREATE SCHEMA ledger_load;

INSERT INTO ledger.customer (full_name, email)
VALUES ('Load Test', 'load-' || gen_random_uuid() || '@example.com');

CREATE TABLE ledger_load.pool AS
WITH created AS (
    INSERT INTO ledger.account (account_no, customer_id, account_class, currency_code)
    SELECT 'LOAD-' || n || '-' || gen_random_uuid(), (SELECT max(customer_id) FROM ledger.customer), 'LIABILITY', 'EUR'
    FROM generate_series(1, 22) n
    RETURNING account_id
)
SELECT row_number() OVER (ORDER BY account_id)::int AS n, account_id FROM created;

SELECT ledger.deposit(gen_random_uuid(), account_id, 100000000) FROM ledger_load.pool WHERE n <= 20;
SELECT ledger.deposit(gen_random_uuid(), account_id, 10000) FROM ledger_load.pool WHERE n = 22;

CREATE FUNCTION ledger_load.account(p_n int) RETURNS bigint
LANGUAGE sql STABLE AS $$ SELECT account_id FROM ledger_load.pool WHERE n = p_n $$;

CREATE TABLE ledger_load.withdrawal_result (succeeded boolean NOT NULL);

CREATE FUNCTION ledger_load.try_withdraw(p_account bigint, p_amount bigint) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM ledger.withdraw(gen_random_uuid(), p_account, p_amount);
    INSERT INTO ledger_load.withdrawal_result VALUES (true);
EXCEPTION WHEN SQLSTATE 'LG001' THEN
    INSERT INTO ledger_load.withdrawal_result VALUES (false);
END $$;
SQL

cat > "$WORK_DIR/transfers.sql" <<PGB
\set a random(1, 20)
\set shift random(1, 19)
\set b 1 + ((:a - 1 + :shift) % 20)
\set amount random(1, 500)
SELECT ledger.transfer(gen_random_uuid(), ledger_load.account(:a), ledger_load.account(:b), :amount, 'load test ${RUN_ID}');
PGB

cat > "$WORK_DIR/idempotent.sql" <<PGB
SELECT ledger.transfer('${RUN_ID}', ledger_load.account(1), ledger_load.account(21), 7777, 'idempotency race ${RUN_ID}');
PGB

cat > "$WORK_DIR/double_spend.sql" <<'PGB'
SELECT ledger_load.try_withdraw(ledger_load.account(22), 3000);
PGB

echo "==> Scenario 1: ${CLIENTS} clients x ${TRANSACTIONS} random bidirectional transfers"
pgbench -n -c "$CLIENTS" -j 4 -t "$TRANSACTIONS" -f "$WORK_DIR/transfers.sql" "$DB_NAME" \
    | grep -E 'number of transactions actually processed|number of failed|^tps' | sed 's/^/    /'

echo "==> Scenario 2: ${CLIENTS} clients race on one idempotency key"
pgbench -n -c "$CLIENTS" -j 4 -t 3 -f "$WORK_DIR/idempotent.sql" "$DB_NAME" > /dev/null

echo "==> Scenario 3: ${CLIENTS} clients race to overspend 100.00 in 30.00 withdrawals"
pgbench -n -c "$CLIENTS" -j 4 -t 5 -f "$WORK_DIR/double_spend.sql" "$DB_NAME" > /dev/null

PGOPTIONS="-c load.expected=$((CLIENTS * TRANSACTIONS)) -c load.run_id=${RUN_ID}" sql <<'SQL'
DO $$
DECLARE
    v_expected bigint := current_setting('load.expected')::bigint;
    v_run      text   := current_setting('load.run_id');
    v_count    bigint;
    v_total    bigint;
    v_ok       bigint;
BEGIN
    SELECT count(*) INTO v_count FROM ledger.journal
    WHERE description = 'load test ' || v_run;
    IF v_count <> v_expected THEN
        RAISE EXCEPTION 'expected % committed transfers, found %', v_expected, v_count;
    END IF;

    SELECT count(*) INTO v_count FROM ledger.journal WHERE description = 'idempotency race ' || v_run;
    SELECT b.posted_minor INTO v_total FROM ledger.account_balance b WHERE b.account_id = ledger_load.account(21);
    IF v_count <> 1 OR v_total <> 7777 THEN
        RAISE EXCEPTION 'idempotency race posted % journals and moved %', v_count, v_total;
    END IF;

    SELECT count(*) FILTER (WHERE succeeded) INTO v_ok FROM ledger_load.withdrawal_result;
    SELECT b.posted_minor INTO v_total FROM ledger.account_balance b WHERE b.account_id = ledger_load.account(22);
    IF v_ok <> 3 OR v_total <> 1000 THEN
        RAISE EXCEPTION 'double-spend race: % withdrawals succeeded, balance %', v_ok, v_total;
    END IF;

    SELECT sum(b.posted_minor) INTO v_total
    FROM ledger.account_balance b JOIN ledger_load.pool p USING (account_id) WHERE p.n <= 21;
    IF v_total <> 2000000000 THEN
        RAISE EXCEPTION 'money was created or destroyed: pool total %', v_total;
    END IF;

    IF EXISTS (SELECT 1 FROM ledger.v_trial_balance WHERE difference_minor <> 0) THEN
        RAISE EXCEPTION 'trial balance is out of balance';
    END IF;
    IF EXISTS (SELECT 1 FROM ledger.v_balance_drift) THEN
        RAISE EXCEPTION 'stored balances drifted from entries';
    END IF;
END $$;
SQL

echo "All concurrency invariants held."
