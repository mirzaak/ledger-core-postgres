-- Stored-procedure API. Applications never write to tables directly.

SET ROLE ledger_owner;
SET search_path = ledger;

INSERT INTO account (account_no, account_class, currency_code)
SELECT 'SYS-' || k.kind || '-' || c.currency_code, k.class::account_class, c.currency_code
FROM currency c
CROSS JOIN (VALUES ('VAULT', 'ASSET'), ('FEES', 'REVENUE'), ('FX', 'ASSET')) k(kind, class);

CREATE FUNCTION system_account(p_kind text, p_currency char(3)) RETURNS bigint
LANGUAGE sql STABLE SET search_path = ledger, pg_temp AS $$
    SELECT account_id FROM account WHERE account_no = 'SYS-' || p_kind || '-' || p_currency
$$;

-- Single write path for every journal. Accounts are locked in ascending id order,
-- which removes the classic A->B / B->A deadlock.
CREATE FUNCTION _post_journal(
    p_key         uuid,
    p_type        text,
    p_description text,
    p_legs        leg[],
    p_reverses    bigint DEFAULT NULL,
    p_posted_at   timestamptz DEFAULT now()
) RETURNS bigint
LANGUAGE plpgsql SET search_path = ledger, pg_temp AS $$
DECLARE
    v_hash     text;
    v_id       bigint;
    v_existing text;
BEGIN
    IF p_key IS NULL THEN
        RAISE EXCEPTION 'idempotency key is required' USING ERRCODE = 'LG009';
    END IF;

    SELECT md5(p_type || '|' || string_agg(format('%s:%s:%s', l.account_id, l.side, l.amount_minor), ','
               ORDER BY l.account_id, l.side, l.amount_minor))
    INTO v_hash
    FROM unnest(p_legs) l;

    INSERT INTO journal (idempotency_key, request_hash, journal_type, description, reverses_journal_id, posted_at)
    VALUES (p_key, v_hash, p_type, p_description, p_reverses, p_posted_at)
    ON CONFLICT (idempotency_key) DO NOTHING
    RETURNING journal_id INTO v_id;

    IF v_id IS NULL THEN
        SELECT journal_id, request_hash INTO v_id, v_existing FROM journal WHERE idempotency_key = p_key;
        IF v_existing <> v_hash THEN
            RAISE EXCEPTION 'idempotency key % was used for a different request', p_key USING ERRCODE = 'LG004';
        END IF;
        RETURN v_id;
    END IF;

    PERFORM 1
    FROM account_balance
    WHERE account_id IN (SELECT l.account_id FROM unnest(p_legs) l)
    ORDER BY account_id
    FOR UPDATE;

    INSERT INTO entry (journal_id, account_id, currency_code, side, amount_minor, posted_at)
    SELECT v_id, l.account_id, a.currency_code, l.side, l.amount_minor, p_posted_at
    FROM unnest(p_legs) l
    JOIN account a ON a.account_id = l.account_id;

    RETURN v_id;
END $$;

CREATE FUNCTION _require_account(p_account bigint) RETURNS account
LANGUAGE plpgsql STABLE SET search_path = ledger, pg_temp AS $$
DECLARE
    v_account account%ROWTYPE;
BEGIN
    SELECT * INTO v_account FROM account WHERE account_id = p_account;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'account % not found', p_account USING ERRCODE = 'LG007';
    END IF;
    RETURN v_account;
END $$;

CREATE FUNCTION _require_positive(p_amount bigint) RETURNS void
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'amount must be positive' USING ERRCODE = 'LG009';
    END IF;
END $$;

CREATE FUNCTION deposit(p_key uuid, p_account bigint, p_amount bigint, p_description text DEFAULT 'Cash deposit')
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ledger, pg_temp AS $$
DECLARE
    v_account account := _require_account(p_account);
BEGIN
    PERFORM _require_positive(p_amount);
    RETURN _post_journal(p_key, 'DEPOSIT', p_description, ARRAY[
        (system_account('VAULT', v_account.currency_code), 'DEBIT', p_amount)::leg,
        (p_account, 'CREDIT', p_amount)::leg]);
END $$;

CREATE FUNCTION withdraw(p_key uuid, p_account bigint, p_amount bigint, p_description text DEFAULT 'Cash withdrawal')
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ledger, pg_temp AS $$
DECLARE
    v_account account := _require_account(p_account);
BEGIN
    PERFORM _require_positive(p_amount);
    RETURN _post_journal(p_key, 'WITHDRAWAL', p_description, ARRAY[
        (p_account, 'DEBIT', p_amount)::leg,
        (system_account('VAULT', v_account.currency_code), 'CREDIT', p_amount)::leg]);
END $$;

CREATE FUNCTION transfer(
    p_key uuid, p_from bigint, p_to bigint, p_amount bigint,
    p_description text DEFAULT 'Transfer', p_fee bigint DEFAULT 0
) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ledger, pg_temp AS $$
DECLARE
    v_from account := _require_account(p_from);
    v_to   account := _require_account(p_to);
    v_legs leg[];
BEGIN
    PERFORM _require_positive(p_amount);
    IF p_from = p_to THEN
        RAISE EXCEPTION 'source and destination must differ' USING ERRCODE = 'LG009';
    END IF;
    IF v_from.currency_code <> v_to.currency_code THEN
        RAISE EXCEPTION 'currency mismatch: use fx_transfer' USING ERRCODE = 'LG009';
    END IF;
    IF p_fee IS NULL OR p_fee < 0 THEN
        RAISE EXCEPTION 'fee cannot be negative' USING ERRCODE = 'LG009';
    END IF;

    v_legs := ARRAY[(p_from, 'DEBIT', p_amount + p_fee)::leg, (p_to, 'CREDIT', p_amount)::leg];
    IF p_fee > 0 THEN
        v_legs := v_legs || (system_account('FEES', v_from.currency_code), 'CREDIT', p_fee)::leg;
    END IF;
    RETURN _post_journal(p_key, 'TRANSFER', p_description, v_legs);
END $$;

-- Four legs through FX position accounts keep each currency balanced on its own.
CREATE FUNCTION fx_transfer(
    p_key uuid, p_from bigint, p_to bigint, p_amount bigint, p_rate numeric,
    p_description text DEFAULT 'FX transfer'
) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ledger, pg_temp AS $$
DECLARE
    v_from     account := _require_account(p_from);
    v_to       account := _require_account(p_to);
    v_credit   bigint;
BEGIN
    PERFORM _require_positive(p_amount);
    IF p_rate IS NULL OR p_rate <= 0 THEN
        RAISE EXCEPTION 'rate must be positive' USING ERRCODE = 'LG009';
    END IF;
    IF v_from.currency_code = v_to.currency_code THEN
        RAISE EXCEPTION 'fx_transfer requires two currencies' USING ERRCODE = 'LG009';
    END IF;

    SELECT round(p_amount * p_rate * power(10::numeric, t.minor_units - f.minor_units))::bigint
    INTO v_credit
    FROM currency f, currency t
    WHERE f.currency_code = v_from.currency_code AND t.currency_code = v_to.currency_code;
    PERFORM _require_positive(v_credit);

    RETURN _post_journal(p_key, 'FX_TRANSFER', p_description, ARRAY[
        (p_from, 'DEBIT', p_amount)::leg,
        (system_account('FX', v_from.currency_code), 'CREDIT', p_amount)::leg,
        (system_account('FX', v_to.currency_code), 'DEBIT', v_credit)::leg,
        (p_to, 'CREDIT', v_credit)::leg]);
END $$;

CREATE FUNCTION reverse_journal(p_key uuid, p_journal bigint, p_reason text)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ledger, pg_temp AS $$
DECLARE
    v_original journal%ROWTYPE;
    v_legs     leg[];
BEGIN
    SELECT * INTO v_original FROM journal WHERE journal_id = p_journal;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'journal % not found', p_journal USING ERRCODE = 'LG007';
    END IF;
    IF v_original.journal_type = 'REVERSAL' THEN
        RAISE EXCEPTION 'a reversal cannot be reversed' USING ERRCODE = 'LG005';
    END IF;

    SELECT array_agg((e.account_id,
                      CASE e.side WHEN 'DEBIT' THEN 'CREDIT' ELSE 'DEBIT' END::entry_side,
                      e.amount_minor)::leg)
    INTO v_legs
    FROM entry e
    WHERE e.journal_id = p_journal AND e.posted_at = v_original.posted_at;

    RETURN _post_journal(p_key, 'REVERSAL', p_reason, v_legs, p_journal);
EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'journal % was already reversed', p_journal USING ERRCODE = 'LG005';
END $$;

CREATE FUNCTION place_hold(p_account bigint, p_amount bigint, p_ttl interval DEFAULT interval '7 days')
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ledger, pg_temp AS $$
DECLARE
    v_account account := _require_account(p_account);
    v_balance account_balance%ROWTYPE;
    v_hold    bigint;
BEGIN
    PERFORM _require_positive(p_amount);
    IF v_account.status <> 'ACTIVE' THEN
        RAISE EXCEPTION 'account % is not active', p_account USING ERRCODE = 'LG002';
    END IF;

    SELECT * INTO v_balance FROM account_balance WHERE account_id = p_account FOR UPDATE;
    IF v_balance.posted_minor - v_balance.held_minor - p_amount < -v_account.overdraft_limit_minor THEN
        RAISE EXCEPTION 'insufficient funds on account %', p_account USING ERRCODE = 'LG001';
    END IF;

    UPDATE account_balance SET held_minor = held_minor + p_amount, updated_at = now()
    WHERE account_id = p_account;

    INSERT INTO hold (account_id, amount_minor, expires_at)
    VALUES (p_account, p_amount, now() + p_ttl)
    RETURNING hold_id INTO v_hold;
    RETURN v_hold;
END $$;

-- Captures all or part of a hold; any uncaptured remainder returns to available funds.
CREATE FUNCTION capture_hold(p_key uuid, p_hold bigint, p_to bigint, p_amount bigint)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ledger, pg_temp AS $$
DECLARE
    v_hold    hold%ROWTYPE;
    v_journal bigint;
BEGIN
    PERFORM _require_positive(p_amount);

    SELECT * INTO v_hold FROM hold WHERE hold_id = p_hold FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'hold % not found', p_hold USING ERRCODE = 'LG007';
    END IF;
    IF v_hold.status = 'CAPTURED'
       AND v_hold.capture_journal_id = (SELECT journal_id FROM journal WHERE idempotency_key = p_key) THEN
        RETURN v_hold.capture_journal_id;
    END IF;
    IF v_hold.status <> 'ACTIVE' OR v_hold.expires_at <= now() THEN
        RAISE EXCEPTION 'hold % cannot be captured', p_hold USING ERRCODE = 'LG008';
    END IF;
    IF p_amount > v_hold.amount_minor THEN
        RAISE EXCEPTION 'capture exceeds held amount' USING ERRCODE = 'LG009';
    END IF;

    PERFORM 1 FROM account_balance WHERE account_id IN (v_hold.account_id, p_to) ORDER BY account_id FOR UPDATE;

    UPDATE account_balance SET held_minor = held_minor - v_hold.amount_minor, updated_at = now()
    WHERE account_id = v_hold.account_id;

    v_journal := _post_journal(p_key, 'HOLD_CAPTURE', format('Capture of hold %s', p_hold), ARRAY[
        (v_hold.account_id, 'DEBIT', p_amount)::leg,
        (p_to, 'CREDIT', p_amount)::leg]);

    UPDATE hold
    SET status = 'CAPTURED', captured_minor = p_amount, capture_journal_id = v_journal, resolved_at = now()
    WHERE hold_id = p_hold;
    RETURN v_journal;
END $$;

CREATE FUNCTION release_hold(p_hold bigint) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ledger, pg_temp AS $$
DECLARE
    v_hold hold%ROWTYPE;
BEGIN
    SELECT * INTO v_hold FROM hold WHERE hold_id = p_hold FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'hold % not found', p_hold USING ERRCODE = 'LG007';
    END IF;
    IF v_hold.status <> 'ACTIVE' THEN
        RAISE EXCEPTION 'hold % is not active', p_hold USING ERRCODE = 'LG008';
    END IF;

    UPDATE account_balance SET held_minor = held_minor - v_hold.amount_minor, updated_at = now()
    WHERE account_id = v_hold.account_id;
    UPDATE hold SET status = 'RELEASED', resolved_at = now() WHERE hold_id = p_hold;
END $$;

-- SKIP LOCKED lets several workers expire holds in parallel without blocking each other.
CREATE FUNCTION expire_holds() RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ledger, pg_temp AS $$
DECLARE
    v_hold  hold%ROWTYPE;
    v_count integer := 0;
BEGIN
    FOR v_hold IN
        SELECT * FROM hold
        WHERE status = 'ACTIVE' AND expires_at <= now()
        ORDER BY account_id, hold_id
        FOR UPDATE SKIP LOCKED
    LOOP
        UPDATE account_balance SET held_minor = held_minor - v_hold.amount_minor, updated_at = now()
        WHERE account_id = v_hold.account_id;
        UPDATE hold SET status = 'EXPIRED', resolved_at = now() WHERE hold_id = v_hold.hold_id;
        v_count := v_count + 1;
    END LOOP;
    RETURN v_count;
END $$;

CREATE FUNCTION set_account_status(p_account bigint, p_status account_status) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ledger, pg_temp AS $$
BEGIN
    PERFORM _require_account(p_account);
    UPDATE account SET status = p_status WHERE account_id = p_account;
END $$;

CREATE FUNCTION balance_as_of(p_account bigint, p_at timestamptz) RETURNS bigint
LANGUAGE sql STABLE SET search_path = ledger, pg_temp AS $$
    SELECT COALESCE(sum(CASE WHEN e.side = a.normal_side THEN e.amount_minor ELSE -e.amount_minor END), 0)::bigint
    FROM entry e
    JOIN account a USING (account_id)
    WHERE e.account_id = p_account AND e.posted_at < p_at
$$;

CREATE FUNCTION account_statement(p_account bigint, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (posted_at timestamptz, journal_id bigint, description text,
               debit_minor bigint, credit_minor bigint, balance_minor bigint)
LANGUAGE sql STABLE SET search_path = ledger, pg_temp AS $$
    SELECT e.posted_at, e.journal_id, j.description,
           CASE WHEN e.side = 'DEBIT' THEN e.amount_minor END,
           CASE WHEN e.side = 'CREDIT' THEN e.amount_minor END,
           (balance_as_of(p_account, p_from)
             + sum(CASE WHEN e.side = a.normal_side THEN e.amount_minor ELSE -e.amount_minor END)
               OVER (ORDER BY e.posted_at, e.entry_id))::bigint
    FROM entry e
    JOIN account a USING (account_id)
    JOIN journal j ON j.journal_id = e.journal_id
    WHERE e.account_id = p_account AND e.posted_at >= p_from AND e.posted_at < p_to
    ORDER BY e.posted_at, e.entry_id
$$;
