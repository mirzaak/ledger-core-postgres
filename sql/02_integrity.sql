-- Accounting invariants enforced by the database itself, so no application bug
-- can write an unbalanced or altered ledger.
--
-- Error codes
--   LG001 insufficient funds          LG006 journal is closed
--   LG002 account not active          LG007 account or hold not found
--   LG003 unbalanced journal          LG008 hold not capturable
--   LG004 idempotency key conflict    LG009 invalid request
--   LG005 ledger record is immutable or already reversed

SET ROLE ledger_owner;
SET search_path = ledger;

CREATE FUNCTION trg_create_balance() RETURNS trigger
LANGUAGE plpgsql SET search_path = ledger, pg_temp AS $$
BEGIN
    INSERT INTO account_balance (account_id) VALUES (NEW.account_id);
    RETURN NULL;
END $$;

CREATE TRIGGER account_create_balance AFTER INSERT ON account
FOR EACH ROW EXECUTE FUNCTION trg_create_balance();

CREATE FUNCTION trg_forbid_mutation() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION '% is append-only: % is not allowed', TG_TABLE_NAME, TG_OP USING ERRCODE = 'LG005';
END $$;

CREATE TRIGGER journal_immutable BEFORE UPDATE OR DELETE ON journal
FOR EACH ROW EXECUTE FUNCTION trg_forbid_mutation();
CREATE TRIGGER journal_no_truncate BEFORE TRUNCATE ON journal
FOR EACH STATEMENT EXECUTE FUNCTION trg_forbid_mutation();
CREATE TRIGGER entry_immutable BEFORE UPDATE OR DELETE ON entry
FOR EACH ROW EXECUTE FUNCTION trg_forbid_mutation();
CREATE TRIGGER entry_no_truncate BEFORE TRUNCATE ON entry
FOR EACH STATEMENT EXECUTE FUNCTION trg_forbid_mutation();

CREATE FUNCTION trg_entry_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path = ledger, pg_temp AS $$
DECLARE
    v_journal journal%ROWTYPE;
    v_status  account_status;
BEGIN
    SELECT * INTO v_journal FROM journal WHERE journal_id = NEW.journal_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'journal % does not exist', NEW.journal_id USING ERRCODE = 'LG007';
    END IF;
    IF v_journal.created_xid <> pg_current_xact_id() THEN
        RAISE EXCEPTION 'journal % is closed', NEW.journal_id USING ERRCODE = 'LG006';
    END IF;
    IF NEW.posted_at <> v_journal.posted_at THEN
        RAISE EXCEPTION 'entry time must match journal time' USING ERRCODE = 'LG009';
    END IF;

    SELECT status INTO v_status FROM account WHERE account_id = NEW.account_id;
    IF v_status IS DISTINCT FROM 'ACTIVE' THEN
        RAISE EXCEPTION 'account % is not active', NEW.account_id USING ERRCODE = 'LG002';
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER entry_guard BEFORE INSERT ON entry
FOR EACH ROW EXECUTE FUNCTION trg_entry_guard();

CREATE FUNCTION trg_entry_apply() RETURNS trigger
LANGUAGE plpgsql SET search_path = ledger, pg_temp AS $$
DECLARE
    v_account account%ROWTYPE;
    v_delta   bigint;
    v_posted  bigint;
    v_held    bigint;
BEGIN
    SELECT * INTO v_account FROM account WHERE account_id = NEW.account_id;
    v_delta := CASE WHEN NEW.side = v_account.normal_side THEN NEW.amount_minor ELSE -NEW.amount_minor END;

    UPDATE account_balance
    SET posted_minor = posted_minor + v_delta, updated_at = now()
    WHERE account_id = NEW.account_id
    RETURNING posted_minor, held_minor INTO v_posted, v_held;

    IF v_delta < 0 AND v_account.customer_id IS NOT NULL
       AND v_posted - v_held < -v_account.overdraft_limit_minor THEN
        RAISE EXCEPTION 'insufficient funds on account %', NEW.account_id USING ERRCODE = 'LG001';
    END IF;
    RETURN NULL;
END $$;

CREATE TRIGGER entry_apply AFTER INSERT ON entry
FOR EACH ROW EXECUTE FUNCTION trg_entry_apply();

-- Deferred to COMMIT so all legs of a journal exist before the check runs.
CREATE FUNCTION trg_journal_balanced() RETURNS trigger
LANGUAGE plpgsql SET search_path = ledger, pg_temp AS $$
DECLARE
    v_legs       integer;
    v_unbalanced integer;
BEGIN
    SELECT count(*) INTO v_legs
    FROM entry WHERE journal_id = NEW.journal_id AND posted_at = NEW.posted_at;

    SELECT count(*) INTO v_unbalanced
    FROM (
        SELECT currency_code
        FROM entry
        WHERE journal_id = NEW.journal_id AND posted_at = NEW.posted_at
        GROUP BY currency_code
        HAVING sum(CASE side WHEN 'DEBIT' THEN amount_minor ELSE -amount_minor END) <> 0
    ) x;

    IF v_legs < 2 OR v_unbalanced > 0 THEN
        RAISE EXCEPTION 'journal % is unbalanced', NEW.journal_id USING ERRCODE = 'LG003';
    END IF;
    RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER journal_balanced AFTER INSERT ON journal
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION trg_journal_balanced();

CREATE FUNCTION trg_audit_row() RETURNS trigger
LANGUAGE plpgsql SET search_path = ledger, pg_temp AS $$
BEGIN
    INSERT INTO audit_log (table_name, row_id, action, old_row, new_row)
    VALUES (TG_TABLE_NAME, NEW.account_id, TG_OP, to_jsonb(OLD), to_jsonb(NEW));
    RETURN NULL;
END $$;

CREATE TRIGGER account_audit AFTER UPDATE ON account
FOR EACH ROW WHEN (OLD IS DISTINCT FROM NEW)
EXECUTE FUNCTION trg_audit_row();
