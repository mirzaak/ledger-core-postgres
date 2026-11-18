-- Least-privilege access.
--   ledger_app       executes the API only; no direct table access
--   ledger_auditor   reads everything, writes nothing
--   ledger_customer  reads only their own data through row-level security

SET ROLE ledger_owner;
SET search_path = ledger;

REVOKE ALL ON SCHEMA ledger FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA ledger FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA ledger FROM PUBLIC;

GRANT USAGE ON SCHEMA ledger TO ledger_app, ledger_auditor, ledger_customer;

GRANT EXECUTE ON FUNCTION
    deposit(uuid, bigint, bigint, text),
    withdraw(uuid, bigint, bigint, text),
    transfer(uuid, bigint, bigint, bigint, text, bigint),
    fx_transfer(uuid, bigint, bigint, bigint, numeric, text),
    reverse_journal(uuid, bigint, text),
    place_hold(bigint, bigint, interval),
    capture_hold(uuid, bigint, bigint, bigint),
    release_hold(bigint),
    expire_holds(),
    set_account_status(bigint, account_status)
TO ledger_app;

GRANT SELECT ON ALL TABLES IN SCHEMA ledger TO ledger_auditor;
GRANT EXECUTE ON FUNCTION
    balance_as_of(bigint, timestamptz),
    account_statement(bigint, timestamptz, timestamptz),
    detect_velocity(integer, interval),
    detect_structuring(bigint, numeric, integer, interval),
    detect_circular_flows(interval, integer, numeric),
    detect_dormant_drain(interval, numeric)
TO ledger_auditor;

GRANT SELECT ON customer, account, account_balance, journal, entry, hold TO ledger_customer;
GRANT EXECUTE ON FUNCTION
    balance_as_of(bigint, timestamptz),
    account_statement(bigint, timestamptz, timestamptz)
TO ledger_customer;

CREATE FUNCTION current_customer_id() RETURNS bigint
LANGUAGE sql STABLE AS $$
    SELECT nullif(current_setting('app.customer_id', true), '')::bigint
$$;
GRANT EXECUTE ON FUNCTION current_customer_id() TO ledger_customer;

ALTER TABLE customer        ENABLE ROW LEVEL SECURITY;
ALTER TABLE account         ENABLE ROW LEVEL SECURITY;
ALTER TABLE account_balance ENABLE ROW LEVEL SECURITY;
ALTER TABLE journal         ENABLE ROW LEVEL SECURITY;
ALTER TABLE entry           ENABLE ROW LEVEL SECURITY;
ALTER TABLE hold            ENABLE ROW LEVEL SECURITY;

CREATE POLICY auditor_all ON customer        FOR SELECT TO ledger_auditor USING (true);
CREATE POLICY auditor_all ON account         FOR SELECT TO ledger_auditor USING (true);
CREATE POLICY auditor_all ON account_balance FOR SELECT TO ledger_auditor USING (true);
CREATE POLICY auditor_all ON journal         FOR SELECT TO ledger_auditor USING (true);
CREATE POLICY auditor_all ON entry           FOR SELECT TO ledger_auditor USING (true);
CREATE POLICY auditor_all ON hold            FOR SELECT TO ledger_auditor USING (true);

CREATE POLICY own_row ON customer FOR SELECT TO ledger_customer
    USING (customer_id = current_customer_id());
CREATE POLICY own_accounts ON account FOR SELECT TO ledger_customer
    USING (customer_id = current_customer_id());
CREATE POLICY own_balances ON account_balance FOR SELECT TO ledger_customer
    USING (account_id IN (SELECT a.account_id FROM account a));
CREATE POLICY own_entries ON entry FOR SELECT TO ledger_customer
    USING (account_id IN (SELECT a.account_id FROM account a));
CREATE POLICY own_holds ON hold FOR SELECT TO ledger_customer
    USING (account_id IN (SELECT a.account_id FROM account a));
CREATE POLICY own_journals ON journal FOR SELECT TO ledger_customer
    USING (EXISTS (SELECT 1 FROM entry e WHERE e.journal_id = journal.journal_id AND e.posted_at = journal.posted_at));
