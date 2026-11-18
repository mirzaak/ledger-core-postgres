-- Deterministic synthetic history for January to June 2026. All people are invented.
-- Four suspicious patterns are planted on dedicated accounts for the detectors to find.

SET ROLE ledger_owner;
SET search_path = ledger;

SELECT setseed(0.77);

INSERT INTO customer (full_name, email, risk_rating, created_at)
SELECT 'Customer ' || lpad(n::text, 3, '0'),
       'customer' || lpad(n::text, 3, '0') || '@example.com',
       (ARRAY['LOW', 'STANDARD', 'STANDARD', 'STANDARD', 'HIGH'])[1 + floor(random() * 5)::int],
       timestamptz '2026-01-01 08:00+00'
FROM generate_series(1, 200) n;

INSERT INTO account (account_no, customer_id, account_class, currency_code, overdraft_limit_minor, opened_at)
SELECT 'ACC-' || lpad(row_number() OVER (ORDER BY customer_id, currency_code)::text, 6, '0'),
       customer_id, 'LIABILITY', currency_code, 0, timestamptz '2026-01-01 08:00+00'
FROM (
    SELECT customer_id, 'EUR' AS currency_code FROM customer
    UNION ALL SELECT customer_id, 'BAM' FROM customer WHERE customer_id % 3 = 0
    UNION ALL SELECT customer_id, 'USD' FROM customer WHERE customer_id % 8 = 0
) x;

INSERT INTO customer (full_name, email, risk_rating, created_at)
SELECT 'Monitored Customer ' || tag, lower(tag) || '@example.com', 'HIGH', timestamptz '2026-01-01 08:00+00'
FROM unnest(ARRAY['VELOCITY', 'STRUCT', 'CIRCA', 'CIRCB', 'CIRCC', 'DORMANT']) tag;

INSERT INTO account (account_no, customer_id, account_class, currency_code, opened_at)
SELECT 'FLAG-' || split_part(email, '@', 1), customer_id, 'LIABILITY', 'EUR', timestamptz '2026-01-01 08:00+00'
FROM customer WHERE full_name LIKE 'Monitored Customer %';

DO $$
DECLARE
    v_seq     bigint := 0;
    v_at      timestamptz := timestamptz '2026-01-05 07:00+00';
    v_pools   jsonb;
    v_cur     char(3);
    v_pool    bigint[];
    v_from    bigint;
    v_to      bigint;
    v_amount  bigint;
    v_fee     bigint;
    v_balance bigint;
    v_roll    float8;
    r         record;
    v_vel     bigint := (SELECT account_id FROM account WHERE account_no = 'FLAG-velocity');
    v_struct  bigint := (SELECT account_id FROM account WHERE account_no = 'FLAG-struct');
    v_a       bigint := (SELECT account_id FROM account WHERE account_no = 'FLAG-circa');
    v_b       bigint := (SELECT account_id FROM account WHERE account_no = 'FLAG-circb');
    v_c       bigint := (SELECT account_id FROM account WHERE account_no = 'FLAG-circc');
    v_dormant bigint := (SELECT account_id FROM account WHERE account_no = 'FLAG-dormant');
    v_payee   bigint := (SELECT min(account_id) FROM account WHERE account_no LIKE 'ACC-%' AND currency_code = 'EUR');

    v_eur     bigint[] := ARRAY(SELECT account_id FROM account WHERE account_no LIKE 'ACC-%' AND currency_code = 'EUR' ORDER BY account_id);
    v_prefix  CONSTANT text := 'ledger-seed-';
BEGIN
    SELECT jsonb_object_agg(currency_code, ids) INTO v_pools
    FROM (
        SELECT currency_code, jsonb_agg(account_id ORDER BY account_id) AS ids
        FROM account WHERE account_no LIKE 'ACC-%' GROUP BY currency_code
    ) p;

    FOR r IN
        SELECT account_id, currency_code FROM account
        WHERE customer_id IS NOT NULL ORDER BY account_id
    LOOP
        v_seq := v_seq + 1;
        v_amount := CASE WHEN r.account_id = v_dormant THEN 4000000
                         WHEN r.account_id IN (v_a, v_b, v_c) THEN 2000000
                         WHEN r.account_id = v_struct THEN 50000
                         ELSE 3000000 + floor(random() * 5000000)::bigint END;
        PERFORM _post_journal(md5(v_prefix || v_seq)::uuid, 'DEPOSIT', 'Opening deposit', ARRAY[
            (system_account('VAULT', r.currency_code), 'DEBIT', v_amount)::leg,
            (r.account_id, 'CREDIT', v_amount)::leg], NULL, timestamptz '2026-01-02 09:00+00');
    END LOOP;

    FOR i IN 1..24000 LOOP
        v_at := v_at + (random() * 1290) * interval '1 second';
        v_roll := random();
        v_cur := CASE WHEN v_roll < 0.72 THEN 'EUR' WHEN v_roll < 0.93 THEN 'BAM' ELSE 'USD' END;
        SELECT array_agg(value::bigint) INTO v_pool FROM jsonb_array_elements_text(v_pools -> v_cur);

        v_from   := v_pool[1 + floor(random() * cardinality(v_pool))::int];
        v_to     := v_pool[1 + floor(random() * cardinality(v_pool))::int];
        v_amount := 500 + floor(power(random(), 4) * 200000)::bigint;
        v_roll   := random();
        v_seq    := v_seq + 1;

        SELECT posted_minor INTO v_balance FROM account_balance WHERE account_id = v_from;

        IF v_roll < 0.10 THEN
            PERFORM _post_journal(md5(v_prefix || v_seq)::uuid, 'DEPOSIT', 'Cash deposit', ARRAY[
                (system_account('VAULT', v_cur), 'DEBIT', v_amount)::leg,
                (v_from, 'CREDIT', v_amount)::leg], NULL, v_at);
        ELSIF v_balance < v_amount + 100 THEN
            CONTINUE;
        ELSIF v_roll < 0.16 THEN
            PERFORM _post_journal(md5(v_prefix || v_seq)::uuid, 'WITHDRAWAL', 'Cash withdrawal', ARRAY[
                (v_from, 'DEBIT', v_amount)::leg,
                (system_account('VAULT', v_cur), 'CREDIT', v_amount)::leg], NULL, v_at);
        ELSIF v_from <> v_to THEN
            v_fee := CASE WHEN random() < 0.30 THEN 50 ELSE 0 END;
            IF v_fee > 0 THEN
                PERFORM _post_journal(md5(v_prefix || v_seq)::uuid, 'TRANSFER', 'Payment', ARRAY[
                    (v_from, 'DEBIT', v_amount + v_fee)::leg,
                    (v_to, 'CREDIT', v_amount)::leg,
                    (system_account('FEES', v_cur), 'CREDIT', v_fee)::leg], NULL, v_at);
            ELSE
                PERFORM _post_journal(md5(v_prefix || v_seq)::uuid, 'TRANSFER', 'Payment', ARRAY[
                    (v_from, 'DEBIT', v_amount)::leg,
                    (v_to, 'CREDIT', v_amount)::leg], NULL, v_at);
            END IF;
        END IF;
    END LOOP;

    -- Velocity: twelve payments in under six minutes.
    v_seq := v_seq + 1;
    PERFORM _post_journal(md5(v_prefix || v_seq)::uuid, 'DEPOSIT', 'Cash deposit', ARRAY[
        (system_account('VAULT', 'EUR'), 'DEBIT', 900000)::leg, (v_vel, 'CREDIT', 900000)::leg],
        NULL, timestamptz '2026-03-10 09:00+00');
    FOR i IN 1..12 LOOP
        v_seq := v_seq + 1;
        PERFORM _post_journal(md5(v_prefix || v_seq)::uuid, 'TRANSFER', 'Payment', ARRAY[
            (v_vel, 'DEBIT', 45000)::leg, (v_eur[i], 'CREDIT', 45000)::leg],
            NULL, timestamptz '2026-03-10 14:00+00' + i * interval '28 seconds');
    END LOOP;

    -- Structuring: six cash deposits just under the 10,000.00 threshold in five days.
    FOR i IN 1..6 LOOP
        v_seq := v_seq + 1;
        PERFORM _post_journal(md5(v_prefix || v_seq)::uuid, 'DEPOSIT', 'Cash deposit', ARRAY[
            (system_account('VAULT', 'EUR'), 'DEBIT', 940000 + i * 9000)::leg,
            (v_struct, 'CREDIT', 940000 + i * 9000)::leg],
            NULL, timestamptz '2026-04-06 10:00+00' + (i - 1) * interval '20 hours');
    END LOOP;

    -- Circular flow: A -> B -> C -> A within five hours, shrinking slightly each hop.
    v_seq := v_seq + 1;
    PERFORM _post_journal(md5(v_prefix || v_seq)::uuid, 'TRANSFER', 'Consulting invoice', ARRAY[
        (v_a, 'DEBIT', 800000)::leg, (v_b, 'CREDIT', 800000)::leg], NULL, timestamptz '2026-05-12 08:00+00');
    v_seq := v_seq + 1;
    PERFORM _post_journal(md5(v_prefix || v_seq)::uuid, 'TRANSFER', 'Supplier payment', ARRAY[
        (v_b, 'DEBIT', 780000)::leg, (v_c, 'CREDIT', 780000)::leg], NULL, timestamptz '2026-05-12 10:00+00');
    v_seq := v_seq + 1;
    PERFORM _post_journal(md5(v_prefix || v_seq)::uuid, 'TRANSFER', 'Loan repayment', ARRAY[
        (v_c, 'DEBIT', 765000)::leg, (v_a, 'CREDIT', 765000)::leg], NULL, timestamptz '2026-05-12 13:00+00');

    -- Dormant drain: silent since January, then 90% of the balance leaves in one payment.
    v_seq := v_seq + 1;
    PERFORM _post_journal(md5(v_prefix || v_seq)::uuid, 'TRANSFER', 'Payment', ARRAY[
        (v_dormant, 'DEBIT', 3600000)::leg, (v_payee, 'CREDIT', 3600000)::leg],
        NULL, timestamptz '2026-04-20 03:12+00');
END $$;
