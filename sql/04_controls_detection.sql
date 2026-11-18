-- Financial controls and transaction-monitoring detectors.

SET ROLE ledger_owner;
SET search_path = ledger;

CREATE VIEW v_trial_balance AS
SELECT currency_code,
       sum(amount_minor) FILTER (WHERE side = 'DEBIT')  AS total_debit_minor,
       sum(amount_minor) FILTER (WHERE side = 'CREDIT') AS total_credit_minor,
       COALESCE(sum(amount_minor) FILTER (WHERE side = 'DEBIT'), 0)
         - COALESCE(sum(amount_minor) FILTER (WHERE side = 'CREDIT'), 0) AS difference_minor
FROM entry
GROUP BY currency_code;

-- Must always be empty: the cached balance has to equal the sum of its entries.
CREATE VIEW v_balance_drift AS
SELECT b.account_id, b.posted_minor AS stored_minor, COALESCE(e.computed_minor, 0) AS computed_minor
FROM account_balance b
JOIN account a USING (account_id)
LEFT JOIN LATERAL (
    SELECT sum(CASE WHEN x.side = a.normal_side THEN x.amount_minor ELSE -x.amount_minor END)::bigint AS computed_minor
    FROM entry x WHERE x.account_id = b.account_id
) e ON true
WHERE b.posted_minor <> COALESCE(e.computed_minor, 0);

-- Must always be empty: held funds have to equal the sum of active holds.
CREATE VIEW v_hold_drift AS
SELECT b.account_id, b.held_minor, COALESCE(h.active_minor, 0) AS active_minor
FROM account_balance b
LEFT JOIN (
    SELECT account_id, sum(amount_minor)::bigint AS active_minor
    FROM hold WHERE status = 'ACTIVE' GROUP BY account_id
) h USING (account_id)
WHERE b.held_minor <> COALESCE(h.active_minor, 0);

CREATE VIEW v_customer_transfer AS
SELECT j.journal_id, j.posted_at, d.account_id AS from_account, c.account_id AS to_account,
       c.amount_minor, c.currency_code
FROM journal j
JOIN entry d ON d.journal_id = j.journal_id AND d.posted_at = j.posted_at AND d.side = 'DEBIT'
JOIN entry c ON c.journal_id = j.journal_id AND c.posted_at = j.posted_at AND c.side = 'CREDIT'
JOIN account ca ON ca.account_id = c.account_id AND ca.customer_id IS NOT NULL
WHERE j.journal_type = 'TRANSFER';

-- Rapid-fire outgoing payments from a single account.
CREATE FUNCTION detect_velocity(p_min_count integer DEFAULT 8, p_window interval DEFAULT interval '10 minutes')
RETURNS TABLE (account_id bigint, peak_at timestamptz, transfers bigint, total_minor bigint)
LANGUAGE sql STABLE SET search_path = ledger, pg_temp AS $$
    SELECT DISTINCT ON (w.from_account) w.from_account, w.posted_at, w.n, w.total
    FROM (
        SELECT t.from_account, t.posted_at,
               count(*) OVER r AS n,
               sum(t.amount_minor) OVER r::bigint AS total
        FROM v_customer_transfer t
        WINDOW r AS (PARTITION BY t.from_account ORDER BY t.posted_at
                     RANGE BETWEEN p_window PRECEDING AND CURRENT ROW)
    ) w
    WHERE w.n >= p_min_count
    ORDER BY w.from_account, w.n DESC, w.posted_at
$$;

-- Repeated cash deposits sized just below the reporting threshold.
CREATE FUNCTION detect_structuring(
    p_threshold_minor bigint DEFAULT 1000000,
    p_band numeric DEFAULT 0.90,
    p_min_count integer DEFAULT 3,
    p_window interval DEFAULT interval '7 days'
)
RETURNS TABLE (account_id bigint, peak_at timestamptz, deposits bigint, total_minor bigint)
LANGUAGE sql STABLE SET search_path = ledger, pg_temp AS $$
    SELECT DISTINCT ON (w.account_id) w.account_id, w.posted_at, w.n, w.total
    FROM (
        SELECT e.account_id, e.posted_at,
               count(*) OVER r AS n,
               sum(e.amount_minor) OVER r::bigint AS total
        FROM entry e
        JOIN journal j ON j.journal_id = e.journal_id AND j.posted_at = e.posted_at
        JOIN account a ON a.account_id = e.account_id AND a.customer_id IS NOT NULL
        WHERE j.journal_type = 'DEPOSIT'
          AND e.side = 'CREDIT'
          AND e.amount_minor >= p_threshold_minor * p_band
          AND e.amount_minor < p_threshold_minor
        WINDOW r AS (PARTITION BY e.account_id ORDER BY e.posted_at
                     RANGE BETWEEN p_window PRECEDING AND CURRENT ROW)
    ) w
    WHERE w.n >= p_min_count AND w.total >= p_threshold_minor
    ORDER BY w.account_id, w.n DESC, w.posted_at
$$;

-- Money that returns to its origin through a chain of accounts (layering).
CREATE FUNCTION detect_circular_flows(
    p_window interval DEFAULT interval '24 hours',
    p_max_hops integer DEFAULT 5,
    p_tolerance numeric DEFAULT 0.15
)
RETURNS TABLE (origin_account bigint, account_path bigint[], hops integer,
               first_amount_minor bigint, last_amount_minor bigint, started_at timestamptz, closed_at timestamptz)
LANGUAGE sql STABLE SET search_path = ledger, pg_temp AS $$
    WITH RECURSIVE transfers AS MATERIALIZED (
        SELECT from_account, to_account, amount_minor, posted_at FROM v_customer_transfer
    ), walk AS (
        SELECT t.from_account AS origin, ARRAY[t.from_account, t.to_account] AS path, 1 AS hops,
               t.to_account AS head, t.amount_minor AS first_amount, t.amount_minor AS last_amount,
               t.posted_at AS started_at, t.posted_at AS last_at
        FROM transfers t
        UNION ALL
        SELECT w.origin, w.path || t.to_account, w.hops + 1, t.to_account, w.first_amount, t.amount_minor,
               w.started_at, t.posted_at
        FROM walk w
        JOIN transfers t ON t.from_account = w.head
                        AND t.posted_at > w.last_at
                        AND t.posted_at <= w.started_at + p_window
                        AND t.amount_minor BETWEEN w.last_amount * (1 - p_tolerance) AND w.last_amount
        WHERE w.hops < p_max_hops
          AND w.head <> w.origin
          AND (t.to_account = w.origin OR NOT t.to_account = ANY (w.path))
    )
    SELECT origin, path, hops, first_amount, last_amount, started_at, last_at
    FROM walk
    WHERE head = origin AND hops >= 3
    ORDER BY started_at
$$;

-- A long-silent account suddenly draining most of its balance.
CREATE FUNCTION detect_dormant_drain(p_dormant interval DEFAULT interval '45 days', p_share numeric DEFAULT 0.70)
RETURNS TABLE (account_id bigint, drained_at timestamptz, silent_days integer,
               balance_before_minor bigint, amount_minor bigint)
LANGUAGE sql STABLE SET search_path = ledger, pg_temp AS $$
    WITH activity AS (
        SELECT e.account_id, e.posted_at, e.side, e.amount_minor,
               LAG(e.posted_at) OVER w AS previous_at,
               COALESCE(sum(CASE WHEN e.side = 'CREDIT' THEN e.amount_minor ELSE -e.amount_minor END)
                        OVER (w ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0)::bigint AS balance_before
        FROM entry e
        JOIN account a ON a.account_id = e.account_id AND a.customer_id IS NOT NULL
        WINDOW w AS (PARTITION BY e.account_id ORDER BY e.posted_at, e.entry_id)
    )
    SELECT account_id, posted_at, (extract(epoch FROM posted_at - previous_at) / 86400)::integer,
           balance_before, amount_minor
    FROM activity
    WHERE side = 'DEBIT'
      AND posted_at - previous_at >= p_dormant
      AND balance_before > 0
      AND amount_minor >= balance_before * p_share
$$;
