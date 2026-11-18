-- Core double-entry model. Amounts are stored as bigint minor units (cents),
-- never as floating point.

SET ROLE ledger_owner;

CREATE SCHEMA ledger;
SET search_path = ledger;

CREATE TYPE account_class  AS ENUM ('ASSET', 'LIABILITY', 'EQUITY', 'REVENUE', 'EXPENSE');
CREATE TYPE entry_side     AS ENUM ('DEBIT', 'CREDIT');
CREATE TYPE account_status AS ENUM ('ACTIVE', 'FROZEN', 'CLOSED');
CREATE TYPE hold_status    AS ENUM ('ACTIVE', 'CAPTURED', 'RELEASED', 'EXPIRED');
CREATE TYPE leg            AS (account_id bigint, side entry_side, amount_minor bigint);

CREATE TABLE currency (
    currency_code char(3) PRIMARY KEY CHECK (currency_code = upper(currency_code)),
    minor_units   smallint NOT NULL CHECK (minor_units BETWEEN 0 AND 4)
);

INSERT INTO currency VALUES ('EUR', 2), ('BAM', 2), ('USD', 2);

CREATE TABLE customer (
    customer_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name   text NOT NULL,
    email       text NOT NULL UNIQUE CHECK (email LIKE '%_@_%'),
    risk_rating text NOT NULL DEFAULT 'STANDARD' CHECK (risk_rating IN ('LOW', 'STANDARD', 'HIGH')),
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE account (
    account_id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_no            text NOT NULL UNIQUE,
    customer_id           bigint REFERENCES customer,
    account_class         account_class NOT NULL,
    currency_code         char(3) NOT NULL REFERENCES currency,
    status                account_status NOT NULL DEFAULT 'ACTIVE',
    overdraft_limit_minor bigint NOT NULL DEFAULT 0 CHECK (overdraft_limit_minor >= 0),
    opened_at             timestamptz NOT NULL DEFAULT now(),
    normal_side           entry_side GENERATED ALWAYS AS (
        CASE WHEN account_class IN ('ASSET', 'EXPENSE') THEN 'DEBIT'::entry_side ELSE 'CREDIT'::entry_side END
    ) STORED,
    UNIQUE (account_id, currency_code),
    CHECK (customer_id IS NULL OR account_class = 'LIABILITY')
);

CREATE INDEX account_customer_idx ON account (customer_id) WHERE customer_id IS NOT NULL;

CREATE TABLE account_balance (
    account_id   bigint PRIMARY KEY REFERENCES account,
    posted_minor bigint NOT NULL DEFAULT 0,
    held_minor   bigint NOT NULL DEFAULT 0 CHECK (held_minor >= 0),
    updated_at   timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE journal (
    journal_id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    idempotency_key     uuid NOT NULL UNIQUE,
    request_hash        text NOT NULL,
    journal_type        text NOT NULL CHECK (journal_type IN
                        ('DEPOSIT', 'WITHDRAWAL', 'TRANSFER', 'FX_TRANSFER', 'HOLD_CAPTURE', 'REVERSAL')),
    description         text NOT NULL,
    reverses_journal_id bigint UNIQUE REFERENCES journal,
    posted_at           timestamptz NOT NULL DEFAULT now(),
    created_xid         xid8 NOT NULL DEFAULT pg_current_xact_id()
);

CREATE INDEX journal_type_time_idx ON journal (journal_type, posted_at);

-- Monthly range partitions keep statement queries and archiving fast as history grows.
CREATE TABLE entry (
    entry_id      bigint GENERATED ALWAYS AS IDENTITY,
    journal_id    bigint NOT NULL REFERENCES journal,
    account_id    bigint NOT NULL,
    currency_code char(3) NOT NULL,
    side          entry_side NOT NULL,
    amount_minor  bigint NOT NULL CHECK (amount_minor > 0),
    posted_at     timestamptz NOT NULL,
    PRIMARY KEY (entry_id, posted_at),
    FOREIGN KEY (account_id, currency_code) REFERENCES account (account_id, currency_code)
) PARTITION BY RANGE (posted_at);

CREATE INDEX entry_account_time_idx ON entry (account_id, posted_at, entry_id);
CREATE INDEX entry_journal_idx ON entry (journal_id, posted_at);

CREATE TABLE entry_default PARTITION OF entry DEFAULT;

CREATE FUNCTION ensure_entry_partition(p_month date) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
    v_start date := date_trunc('month', p_month)::date;
    v_name  text := 'entry_' || to_char(p_month, 'YYYY_MM');
BEGIN
    EXECUTE format(
        'CREATE TABLE IF NOT EXISTS ledger.%I PARTITION OF ledger.entry FOR VALUES FROM (%L) TO (%L)',
        v_name, v_start::text || ' 00:00:00+00', (v_start + interval '1 month')::date::text || ' 00:00:00+00');
    RETURN v_name;
END $$;

SELECT ensure_entry_partition(m::date)
FROM generate_series(date '2026-01-01', date '2027-12-01', interval '1 month') m;

CREATE TABLE hold (
    hold_id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_id         bigint NOT NULL REFERENCES account,
    amount_minor       bigint NOT NULL CHECK (amount_minor > 0),
    captured_minor     bigint CHECK (captured_minor > 0 AND captured_minor <= amount_minor),
    status             hold_status NOT NULL DEFAULT 'ACTIVE',
    capture_journal_id bigint REFERENCES journal,
    expires_at         timestamptz NOT NULL,
    created_at         timestamptz NOT NULL DEFAULT now(),
    resolved_at        timestamptz,
    CHECK ((status = 'ACTIVE') = (resolved_at IS NULL)),
    CHECK ((status = 'CAPTURED') = (capture_journal_id IS NOT NULL))
);

CREATE INDEX hold_expiry_idx ON hold (expires_at) WHERE status = 'ACTIVE';

CREATE TABLE audit_log (
    audit_id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    table_name text NOT NULL,
    row_id     bigint NOT NULL,
    action     text NOT NULL,
    old_row    jsonb,
    new_row    jsonb,
    actor      text NOT NULL DEFAULT session_user,
    logged_at  timestamptz NOT NULL DEFAULT now()
);
