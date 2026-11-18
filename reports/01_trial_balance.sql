-- Control report: debits must equal credits in every currency.

SELECT currency_code,
       round(total_debit_minor / 100.0, 2)  AS total_debit,
       round(total_credit_minor / 100.0, 2) AS total_credit,
       round(difference_minor / 100.0, 2)   AS difference,
       CASE WHEN difference_minor = 0 THEN 'BALANCED' ELSE 'OUT OF BALANCE' END AS control_status
FROM ledger.v_trial_balance
ORDER BY currency_code;
