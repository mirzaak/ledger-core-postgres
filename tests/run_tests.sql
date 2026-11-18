-- Behavioural test suite. Runs inside one transaction and rolls everything back.

\set ON_ERROR_STOP on
\o /dev/null

BEGIN;

CREATE TEMP TABLE test_result (
    test_no   integer GENERATED ALWAYS AS IDENTITY,
    test_name text NOT NULL,
    passed    boolean NOT NULL,
    detail    text
);

CREATE FUNCTION pg_temp.ok(p_name text, p_passed boolean, p_detail text DEFAULT NULL) RETURNS void
LANGUAGE sql AS $$
    INSERT INTO test_result (test_name, passed, detail) VALUES (p_name, COALESCE(p_passed, false), p_detail)
$$;

CREATE FUNCTION pg_temp.eq(p_name text, p_actual bigint, p_expected bigint) RETURNS void
LANGUAGE sql AS $$
    SELECT pg_temp.ok(p_name, p_actual IS NOT DISTINCT FROM p_expected,
                      format('expected %s, got %s', p_expected, p_actual))
$$;

CREATE FUNCTION pg_temp.raises(p_name text, p_sql text, p_sqlstate text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_state text;
BEGIN
    BEGIN
        EXECUTE p_sql;
        SET CONSTRAINTS ALL IMMEDIATE;
        v_state := 'no error';
        RAISE EXCEPTION USING ERRCODE = 'ZZ999';
    EXCEPTION WHEN OTHERS THEN
        IF SQLSTATE <> 'ZZ999' THEN
            v_state := SQLSTATE;
        END IF;
    END;
    SET CONSTRAINTS ALL DEFERRED;
    RESET ROLE;
    PERFORM pg_temp.ok(p_name, v_state = p_sqlstate, format('expected %s, got %s', p_sqlstate, v_state));
END $$;

CREATE FUNCTION pg_temp.count_as(p_role text, p_customer bigint, p_sql text) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
    v_count bigint;
BEGIN
    PERFORM set_config('app.customer_id', COALESCE(p_customer::text, ''), true);
    EXECUTE format('SET LOCAL ROLE %I', p_role);
    EXECUTE p_sql INTO v_count;
    RESET ROLE;
    PERFORM set_config('app.customer_id', '', true);
    RETURN v_count;
END $$;

CREATE FUNCTION pg_temp.balance(p_account bigint) RETURNS bigint
LANGUAGE sql AS $$ SELECT posted_minor FROM ledger.account_balance WHERE account_id = p_account $$;

CREATE FUNCTION pg_temp.held(p_account bigint) RETURNS bigint
LANGUAGE sql AS $$ SELECT held_minor FROM ledger.account_balance WHERE account_id = p_account $$;

INSERT INTO ledger.customer (full_name, email) VALUES
    ('Test Alice', 'alice@example.com'), ('Test Bob', 'bob@example.com');

INSERT INTO ledger.account (account_no, customer_id, account_class, currency_code, overdraft_limit_minor)
SELECT v.no, c.customer_id, 'LIABILITY', v.cur, v.od
FROM (VALUES ('T-ALICE-EUR', 'alice@example.com', 'EUR', 0),
             ('T-BOB-EUR',   'bob@example.com',   'EUR', 0),
             ('T-BOB-BAM',   'bob@example.com',   'BAM', 0),
             ('T-OD-EUR',    'bob@example.com',   'EUR', 5000)) v(no, email, cur, od)
JOIN ledger.customer c USING (email);

SELECT max(account_id) FILTER (WHERE account_no = 'T-ALICE-EUR') AS alice,
       max(account_id) FILTER (WHERE account_no = 'T-BOB-EUR')   AS bob,
       max(account_id) FILTER (WHERE account_no = 'T-BOB-BAM')   AS bob_bam,
       max(account_id) FILTER (WHERE account_no = 'T-OD-EUR')    AS od,
       max(account_id) FILTER (WHERE account_no = 'SYS-FEES-EUR') AS fees
FROM ledger.account \gset

SELECT customer_id AS alice_customer FROM ledger.customer WHERE email = 'alice@example.com' \gset

-- Posting ---------------------------------------------------------------------
SELECT ledger.deposit(gen_random_uuid(), :alice, 100000);
SELECT pg_temp.eq('deposit increases the customer balance', pg_temp.balance(:alice), 100000);

SELECT ledger.transfer(gen_random_uuid(), :alice, :bob, 30000, 'Rent', 150);
SELECT pg_temp.eq('transfer debits amount plus fee', pg_temp.balance(:alice), 69850);
SELECT pg_temp.eq('transfer credits the recipient', pg_temp.balance(:bob), 30000);

SELECT pg_temp.raises('zero amount is rejected',
    format('SELECT ledger.transfer(gen_random_uuid(), %s, %s, 0)', :alice, :bob), 'LG009');
SELECT pg_temp.raises('negative amount is rejected',
    format('SELECT ledger.deposit(gen_random_uuid(), %s, -5)', :alice), 'LG009');
SELECT pg_temp.raises('transfer to the same account is rejected',
    format('SELECT ledger.transfer(gen_random_uuid(), %s, %s, 10)', :alice, :alice), 'LG009');
SELECT pg_temp.raises('cross-currency transfer is rejected',
    format('SELECT ledger.transfer(gen_random_uuid(), %s, %s, 10)', :alice, :bob_bam), 'LG009');
SELECT pg_temp.raises('unknown account is rejected',
    format('SELECT ledger.deposit(gen_random_uuid(), %s, 10)', 999999999), 'LG007');
SELECT pg_temp.raises('insufficient funds are rejected',
    format('SELECT ledger.withdraw(gen_random_uuid(), %s, 99999999)', :alice), 'LG001');

SELECT ledger.withdraw(gen_random_uuid(), :od, 5000);
SELECT pg_temp.eq('overdraft can be used up to its limit', pg_temp.balance(:od), -5000);
SELECT pg_temp.raises('overdraft limit cannot be exceeded',
    format('SELECT ledger.withdraw(gen_random_uuid(), %s, 1)', :od), 'LG001');

SELECT ledger.set_account_status(:bob_bam, 'FROZEN');
SELECT pg_temp.raises('frozen account cannot post',
    format('SELECT ledger.deposit(gen_random_uuid(), %s, 100)', :bob_bam), 'LG002');
SELECT pg_temp.eq('status change is written to the audit log',
    (SELECT count(*) FROM ledger.audit_log WHERE table_name = 'account' AND row_id = :bob_bam
       AND old_row ->> 'status' = 'ACTIVE' AND new_row ->> 'status' = 'FROZEN'), 1);
SELECT ledger.set_account_status(:bob_bam, 'ACTIVE');

-- Ledger invariants -----------------------------------------------------------
SELECT pg_temp.raises('unbalanced journal is rejected at commit', format($q$
    WITH j AS (
        INSERT INTO ledger.journal (idempotency_key, request_hash, journal_type, description)
        VALUES (gen_random_uuid(), 'x', 'TRANSFER', 'bad') RETURNING journal_id, posted_at
    )
    INSERT INTO ledger.entry (journal_id, account_id, currency_code, side, amount_minor, posted_at)
    SELECT j.journal_id, a.account_id, 'EUR', s.side::ledger.entry_side, s.amount, j.posted_at
    FROM j
    CROSS JOIN (VALUES (%s::bigint, 'CREDIT', 100), (%s::bigint, 'DEBIT', 99)) s(account_id, side, amount)
    JOIN ledger.account a ON a.account_id = s.account_id
$q$, :alice, :bob), 'LG003');

SELECT pg_temp.raises('journal without entries is rejected at commit', $q$
    INSERT INTO ledger.journal (idempotency_key, request_hash, journal_type, description)
    VALUES (gen_random_uuid(), 'x', 'TRANSFER', 'empty')
$q$, 'LG003');

SELECT pg_temp.raises('entries are immutable: UPDATE',
    'UPDATE ledger.entry SET amount_minor = 1 WHERE entry_id = (SELECT min(entry_id) FROM ledger.entry)', 'LG005');
SELECT pg_temp.raises('entries are immutable: DELETE',
    'DELETE FROM ledger.entry WHERE entry_id = (SELECT min(entry_id) FROM ledger.entry)', 'LG005');
SELECT pg_temp.raises('journals are immutable: UPDATE',
    $q$UPDATE ledger.journal SET description = 'edited' WHERE journal_id = 1$q$, 'LG005');
SELECT pg_temp.raises('entries are immutable: TRUNCATE', 'TRUNCATE ledger.entry', 'LG005');
SELECT pg_temp.raises('committed journal cannot receive new entries', format($q$
    INSERT INTO ledger.entry (journal_id, account_id, currency_code, side, amount_minor, posted_at)
    SELECT journal_id, %s, 'EUR', 'CREDIT', 1, posted_at FROM ledger.journal WHERE journal_id = 1
$q$, :alice), 'LG006');

-- Idempotency -----------------------------------------------------------------
SELECT gen_random_uuid() AS idem_key \gset
SELECT ledger.transfer(:'idem_key', :alice, :bob, 1000) AS first_id \gset
SELECT ledger.transfer(:'idem_key', :alice, :bob, 1000) AS second_id \gset
SELECT pg_temp.eq('retry returns the original journal', :second_id, :first_id);
SELECT pg_temp.eq('retry does not move money twice', pg_temp.balance(:alice), 68850);
SELECT pg_temp.raises('key reuse with a different payload is rejected',
    format('SELECT ledger.transfer(%L, %s, %s, 2000)', :'idem_key', :alice, :bob), 'LG004');

-- Reversal --------------------------------------------------------------------
SELECT ledger.reverse_journal(gen_random_uuid(), :first_id, 'Customer dispute');
SELECT pg_temp.eq('reversal restores the sender', pg_temp.balance(:alice), 69850);
SELECT pg_temp.eq('reversal restores the recipient', pg_temp.balance(:bob), 30000);
SELECT pg_temp.raises('journal cannot be reversed twice',
    format('SELECT ledger.reverse_journal(gen_random_uuid(), %s, %L)', :first_id, 'again'), 'LG005');
SELECT pg_temp.raises('reversal cannot be reversed', format(
    'SELECT ledger.reverse_journal(gen_random_uuid(), (SELECT journal_id FROM ledger.journal WHERE reverses_journal_id = %s), %L)',
    :first_id, 'undo'), 'LG005');

-- Foreign exchange ------------------------------------------------------------
SELECT ledger.fx_transfer(gen_random_uuid(), :alice, :bob_bam, 10000, 1.95583) AS fx_id \gset
SELECT pg_temp.eq('FX debits the source currency', pg_temp.balance(:alice), 59850);
SELECT pg_temp.eq('FX credits the converted amount', pg_temp.balance(:bob_bam), 19558);
SELECT pg_temp.eq('FX journal balances per currency',
    (SELECT count(*) FROM (
        SELECT currency_code FROM ledger.entry WHERE journal_id = :fx_id GROUP BY currency_code
        HAVING sum(CASE side WHEN 'DEBIT' THEN amount_minor ELSE -amount_minor END) <> 0) x), 0);

-- Holds -----------------------------------------------------------------------
SELECT ledger.place_hold(:alice, 50000) AS hold_a \gset
SELECT pg_temp.eq('hold reserves funds', pg_temp.held(:alice), 50000);
SELECT pg_temp.eq('hold leaves the posted balance unchanged', pg_temp.balance(:alice), 59850);
SELECT pg_temp.raises('held funds cannot be spent',
    format('SELECT ledger.withdraw(gen_random_uuid(), %s, 20000)', :alice), 'LG001');
SELECT pg_temp.raises('hold cannot exceed available funds',
    format('SELECT ledger.place_hold(%s, 20000)', :alice), 'LG001');
SELECT pg_temp.raises('capture cannot exceed the hold',
    format('SELECT ledger.capture_hold(gen_random_uuid(), %s, %s, 60000)', :hold_a, :bob), 'LG009');

SELECT ledger.capture_hold(gen_random_uuid(), :hold_a, :bob, 20000);
SELECT pg_temp.eq('partial capture moves the captured amount', pg_temp.balance(:alice), 39850);
SELECT pg_temp.eq('partial capture releases the remainder', pg_temp.held(:alice), 0);
SELECT pg_temp.raises('hold cannot be captured twice',
    format('SELECT ledger.capture_hold(gen_random_uuid(), %s, %s, 100)', :hold_a, :bob), 'LG008');

SELECT ledger.place_hold(:alice, 5000) AS hold_b \gset
SELECT ledger.release_hold(:hold_b);
SELECT pg_temp.eq('release returns held funds', pg_temp.held(:alice), 0);

SELECT ledger.place_hold(:alice, 7000, interval '-1 second') AS hold_c \gset
SELECT pg_temp.raises('expired hold cannot be captured',
    format('SELECT ledger.capture_hold(gen_random_uuid(), %s, %s, 100)', :hold_c, :bob), 'LG008');
SELECT pg_temp.eq('expiry job processes due holds', ledger.expire_holds(), 1);
SELECT pg_temp.eq('expiry returns held funds', pg_temp.held(:alice), 0);

-- Access control --------------------------------------------------------------
SELECT pg_temp.raises('application role cannot write entries directly', $q$
    SET LOCAL ROLE ledger_app;
    INSERT INTO ledger.entry (journal_id, account_id, currency_code, side, amount_minor, posted_at)
    VALUES (1, 1, 'EUR', 'DEBIT', 1, now())
$q$, '42501');
SELECT pg_temp.raises('application role cannot read tables directly', $q$
    SET LOCAL ROLE ledger_app;
    SELECT * FROM ledger.account
$q$, '42501');
SELECT pg_temp.raises('application role cannot call internal posting', $q$
    SET LOCAL ROLE ledger_app;
    SELECT ledger._post_journal(gen_random_uuid(), 'TRANSFER', 'x', ARRAY[]::ledger.leg[])
$q$, '42501');
SELECT pg_temp.raises('auditor cannot write', $q$
    SET LOCAL ROLE ledger_auditor;
    UPDATE ledger.account SET status = 'CLOSED'
$q$, '42501');

SET LOCAL ROLE ledger_app;
SELECT ledger.deposit(gen_random_uuid(), :alice, 150) AS app_deposit \gset
RESET ROLE;
SELECT pg_temp.ok('application role can use the API', :app_deposit > 0);

SELECT pg_temp.eq('customer sees only their own accounts',
    pg_temp.count_as('ledger_customer', :alice_customer, 'SELECT count(*) FROM ledger.account'), 1);
SELECT pg_temp.eq('customer sees no accounts without a session identity',
    pg_temp.count_as('ledger_customer', NULL, 'SELECT count(*) FROM ledger.account'), 0);
SELECT pg_temp.eq('customer cannot read another customer''s entries',
    pg_temp.count_as('ledger_customer', :alice_customer,
        format('SELECT count(*) FROM ledger.entry WHERE account_id = %s', :bob)), 0);
SELECT pg_temp.ok('auditor sees every account',
    pg_temp.count_as('ledger_auditor', NULL, 'SELECT count(*) FROM ledger.account')
    = (SELECT count(*) FROM ledger.account));

-- Reporting and detection -----------------------------------------------------
SELECT pg_temp.eq('statement closes at the posted balance',
    (SELECT balance_minor FROM ledger.account_statement(:alice, '-infinity', 'infinity')
     ORDER BY posted_at DESC, journal_id DESC LIMIT 1),
    pg_temp.balance(:alice));
SELECT pg_temp.eq('balance as of a past date ignores later entries',
    ledger.balance_as_of(:alice, timestamptz '2020-01-01'), 0);
SELECT pg_temp.eq('seeded entries land in monthly partitions',
    (SELECT count(*) FROM ledger.entry_default WHERE posted_at < timestamptz '2028-01-01'), 0);
SELECT pg_temp.ok('January partition holds January entries',
    (SELECT count(*) FROM ledger.entry_2026_01) > 0);

SELECT pg_temp.eq('velocity detector flags only the planted account',
    (SELECT count(*) FROM ledger.detect_velocity() v JOIN ledger.account a USING (account_id)
     WHERE a.account_no <> 'FLAG-velocity'), 0);
SELECT pg_temp.eq('velocity detector finds the planted account',
    (SELECT count(*) FROM ledger.detect_velocity() v JOIN ledger.account a USING (account_id)
     WHERE a.account_no = 'FLAG-velocity'), 1);
SELECT pg_temp.eq('structuring detector finds exactly the planted account',
    (SELECT count(*) FILTER (WHERE a.account_no = 'FLAG-struct') - count(*) FILTER (WHERE a.account_no <> 'FLAG-struct')
     FROM ledger.detect_structuring() s JOIN ledger.account a USING (account_id)), 1);
SELECT pg_temp.eq('circular-flow detector finds the planted loop',
    (SELECT count(*) FROM ledger.detect_circular_flows() c
     JOIN ledger.account a ON a.account_id = c.origin_account WHERE a.account_no = 'FLAG-circa' AND c.hops = 3), 1);
SELECT pg_temp.eq('dormant-drain detector finds exactly the planted account',
    (SELECT count(*) FILTER (WHERE a.account_no = 'FLAG-dormant') - count(*) FILTER (WHERE a.account_no <> 'FLAG-dormant')
     FROM ledger.detect_dormant_drain() d JOIN ledger.account a USING (account_id)), 1);

-- Global controls -------------------------------------------------------------
SET CONSTRAINTS ALL IMMEDIATE;
SELECT pg_temp.eq('trial balance is zero in every currency',
    (SELECT count(*) FROM ledger.v_trial_balance WHERE difference_minor <> 0), 0);
SELECT pg_temp.eq('stored balances match the entries', (SELECT count(*) FROM ledger.v_balance_drift), 0);
SELECT pg_temp.eq('held amounts match active holds', (SELECT count(*) FROM ledger.v_hold_drift), 0);

\o
\pset format aligned
\pset footer off
SELECT CASE WHEN passed THEN 'PASS' ELSE 'FAIL' END AS result, test_name, CASE WHEN NOT passed THEN detail END AS detail
FROM test_result ORDER BY passed, test_no;

DO $$
DECLARE
    v_failed bigint;
    v_total  bigint;
BEGIN
    SELECT count(*) FILTER (WHERE NOT passed), count(*) INTO v_failed, v_total FROM test_result;
    IF v_failed > 0 THEN
        RAISE EXCEPTION '% of % tests failed', v_failed, v_total;
    END IF;
    RAISE NOTICE 'All % tests passed', v_total;
END $$;

ROLLBACK;
