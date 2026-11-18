-- Monthly volume by product with month-over-month growth and fee income.

WITH monthly AS (
    SELECT date_trunc('month', j.posted_at AT TIME ZONE 'UTC')::date AS month,
           e.currency_code,
           j.journal_type,
           count(DISTINCT j.journal_id) AS journals,
           sum(e.amount_minor) FILTER (WHERE a.customer_id IS NOT NULL AND e.side = 'CREDIT') AS customer_inflow_minor,
           sum(e.amount_minor) FILTER (WHERE a.account_no LIKE 'SYS-FEES-%') AS fee_income_minor
    FROM ledger.journal j
    JOIN ledger.entry e ON e.journal_id = j.journal_id AND e.posted_at = j.posted_at
    JOIN ledger.account a ON a.account_id = e.account_id
    WHERE j.description <> 'Opening deposit'
    GROUP BY 1, 2, 3
)
SELECT month, currency_code, journal_type, journals,
       round(COALESCE(customer_inflow_minor, 0) / 100.0, 2) AS customer_inflow,
       round(COALESCE(fee_income_minor, 0) / 100.0, 2) AS fee_income,
       round(100.0 * (journals::numeric
             / nullif(LAG(journals) OVER (PARTITION BY currency_code, journal_type ORDER BY month), 0) - 1), 1) AS journals_mom_pct
FROM monthly
ORDER BY month, currency_code, journal_type;
