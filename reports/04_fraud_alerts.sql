-- Unified transaction-monitoring alert queue across all four detectors.

WITH alerts AS (
    SELECT 'VELOCITY' AS alert_type, v.account_id, v.peak_at AS alert_at, v.total_minor AS exposure_minor,
           format('%s outgoing payments within 10 minutes', v.transfers) AS evidence
    FROM ledger.detect_velocity() v
    UNION ALL
    SELECT 'STRUCTURING', s.account_id, s.peak_at, s.total_minor,
           format('%s cash deposits just below the threshold within 7 days', s.deposits)
    FROM ledger.detect_structuring() s
    UNION ALL
    SELECT 'CIRCULAR_FLOW', c.origin_account, c.closed_at, c.first_amount_minor,
           format('funds returned to origin in %s hops via accounts %s', c.hops, c.account_path::text)
    FROM ledger.detect_circular_flows() c
    UNION ALL
    SELECT 'DORMANT_DRAIN', d.account_id, d.drained_at, d.amount_minor,
           format('%s days silent, then %s%% of the balance left', d.silent_days,
                  round(100.0 * d.amount_minor / d.balance_before_minor))
    FROM ledger.detect_dormant_drain() d
)
SELECT al.alert_type, a.account_no, c.full_name, c.risk_rating,
       al.alert_at AT TIME ZONE 'UTC' AS alert_at_utc,
       round(al.exposure_minor / 100.0, 2) AS exposure,
       al.evidence
FROM alerts al
JOIN ledger.account a ON a.account_id = al.account_id
JOIN ledger.customer c ON c.customer_id = a.customer_id
ORDER BY al.alert_at;
