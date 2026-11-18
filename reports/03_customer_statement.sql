-- Sample statement with a running balance for one account in March 2026.

SELECT s.posted_at AT TIME ZONE 'UTC' AS posted_at_utc,
       s.journal_id,
       s.description,
       round(s.debit_minor / 100.0, 2)   AS debit,
       round(s.credit_minor / 100.0, 2)  AS credit,
       round(s.balance_minor / 100.0, 2) AS balance
FROM ledger.account a
CROSS JOIN LATERAL ledger.account_statement(
    a.account_id, timestamptz '2026-03-01 00:00+00', timestamptz '2026-04-01 00:00+00') s
WHERE a.account_no = 'ACC-000001'
ORDER BY s.posted_at, s.journal_id;
