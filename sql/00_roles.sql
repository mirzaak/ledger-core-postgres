-- Cluster-level roles. Safe to run repeatedly.

DO $$
DECLARE
    v_role text;
BEGIN
    FOREACH v_role IN ARRAY ARRAY['ledger_owner', 'ledger_app', 'ledger_auditor', 'ledger_customer'] LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_role) THEN
            EXECUTE format('CREATE ROLE %I NOLOGIN', v_role);
        END IF;
    END LOOP;
    EXECUTE format('GRANT CREATE ON DATABASE %I TO ledger_owner', current_database());
END $$;
