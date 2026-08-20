-- =============================================================================
-- Karma: real training data from Aave v3 on Ethereum.
--
-- HOW TO RUN
--   1. Sign in at https://dune.com (the free tier is enough for this query).
--   2. Paste this into a new query, set the engine to "Dune SQL" (Trino).
--   3. Adjust the three dates in the `params` CTE if you want a different
--      window. Defaults give a 2-year observation window and a 90-day forward
--      window for the label.
--   4. Run, then "Download CSV" into model/data/aave_v3_ethereum_<date>.csv
--   5. Register it so the pipeline will accept it as real data:
--        python -m model.dataset declare model/data/aave_v3_ethereum_<date>.csv \
--          --kind dune --query-url <the dune query permalink>
--   6. Train against it:
--        python -m model.train --data model/data/aave_v3_ethereum_<date>.csv
--
-- STATUS: this query is documented but has NOT been executed by the authors.
-- Running it needs a Dune account, so every metric currently in
-- model/model_report.json comes from the labelled bootstrap generator instead.
-- Treat the column semantics below as the specification the bootstrap
-- generator imitates, not as verified output.
--
-- WHAT IT PRODUCES
--   One row per borrowing wallet, with the eight features Karma scores on and
--   a `defaulted` label. Column names match model/features.py exactly, so the
--   CSV drops straight into the training pipeline.
--
-- THE LABEL
--   `defaulted` = the wallet was the `user` of at least one LiquidationCall
--   during the forward window, which starts the day the observation window
--   ends. Features are computed strictly inside the observation window, so a
--   liquidation that defines the label can never leak into a feature. That
--   split is the whole reason for the two windows.
-- =============================================================================

WITH params AS (
    SELECT
        DATE '2023-01-01' AS observation_start,
        DATE '2024-12-31' AS observation_end,   -- features use [start, end)
        DATE '2025-03-31' AS forward_end        -- label uses [end, forward_end)
),

-- ---------------------------------------------------------------- borrowing
borrows AS (
    SELECT
        b.onBehalfOf                                   AS wallet,
        b.evt_block_time,
        b.reserve,
        b.amount / POWER(10, t.decimals) * p.price      AS amount_usd
    FROM aave_v3_ethereum.Pool_evt_Borrow b
    JOIN params ON TRUE
    LEFT JOIN tokens.erc20 t
           ON t.contract_address = b.reserve AND t.blockchain = 'ethereum'
    LEFT JOIN prices.usd p
           ON p.contract_address = b.reserve
          AND p.blockchain = 'ethereum'
          AND p.minute = DATE_TRUNC('minute', b.evt_block_time)
    WHERE b.evt_block_time >= params.observation_start
      AND b.evt_block_time <  params.observation_end
),

repays AS (
    SELECT
        r.user                                         AS wallet,
        r.evt_block_time,
        r.amount / POWER(10, t.decimals) * p.price      AS amount_usd
    FROM aave_v3_ethereum.Pool_evt_Repay r
    JOIN params ON TRUE
    LEFT JOIN tokens.erc20 t
           ON t.contract_address = r.reserve AND t.blockchain = 'ethereum'
    LEFT JOIN prices.usd p
           ON p.contract_address = r.reserve
          AND p.blockchain = 'ethereum'
          AND p.minute = DATE_TRUNC('minute', r.evt_block_time)
    WHERE r.evt_block_time >= params.observation_start
      AND r.evt_block_time <  params.observation_end
),

-- Liquidations INSIDE the observation window are a feature (past behaviour).
liquidations_observed AS (
    SELECT l.user AS wallet, COUNT(*) AS liquidation_count
    FROM aave_v3_ethereum.Pool_evt_LiquidationCall l
    JOIN params ON TRUE
    WHERE l.evt_block_time >= params.observation_start
      AND l.evt_block_time <  params.observation_end
    GROUP BY 1
),

-- Liquidations AFTER it are the label. Never mix these two.
liquidations_forward AS (
    SELECT DISTINCT l.user AS wallet
    FROM aave_v3_ethereum.Pool_evt_LiquidationCall l
    JOIN params ON TRUE
    WHERE l.evt_block_time >= params.observation_end
      AND l.evt_block_time <  params.forward_end
),

-- ------------------------------------------------- position open/close pairs
-- Approximates position duration as the gap between a borrow and the wallet's
-- next repay on the same reserve. Wallets that never repaid are left out of the
-- average rather than counted as duration zero.
position_spans AS (
    SELECT
        b.wallet,
        DATE_DIFF('second', b.evt_block_time, MIN(r.evt_block_time)) / 86400.0 AS days_open
    FROM borrows b
    JOIN repays r
      ON r.wallet = b.wallet
     AND r.evt_block_time > b.evt_block_time
    GROUP BY b.wallet, b.evt_block_time
),

-- --------------------------------------------------------- wallet-level tx
wallet_activity AS (
    SELECT
        tx."from" AS wallet,
        DATE_DIFF('day', MIN(tx.block_time), (SELECT observation_end FROM params)) AS wallet_age_days,
        COUNT_IF(tx.block_time >= (SELECT observation_end FROM params) - INTERVAL '90' DAY)
            AS tx_count_90d
    FROM ethereum.transactions tx
    JOIN params ON TRUE
    WHERE tx.block_time < params.observation_end
      AND tx."from" IN (SELECT wallet FROM borrows)
    GROUP BY 1
),

-- ---------------------------------------------------- peak leverage per wallet
-- Debt-to-collateral at its worst, from the reserve-level running balances.
leverage AS (
    SELECT
        wallet,
        MAX(CASE WHEN collateral_usd > 0 THEN debt_usd / collateral_usd ELSE 0 END) AS max_leverage_ratio
    FROM (
        SELECT
            b.wallet,
            SUM(b.amount_usd) OVER (PARTITION BY b.wallet ORDER BY b.evt_block_time) AS debt_usd,
            COALESCE(s.collateral_usd, 0) AS collateral_usd
        FROM borrows b
        LEFT JOIN (
            SELECT
                sup.onBehalfOf AS wallet,
                SUM(sup.amount / POWER(10, t.decimals) * p.price) AS collateral_usd
            FROM aave_v3_ethereum.Pool_evt_Supply sup
            JOIN params ON TRUE
            LEFT JOIN tokens.erc20 t
                   ON t.contract_address = sup.reserve AND t.blockchain = 'ethereum'
            LEFT JOIN prices.usd p
                   ON p.contract_address = sup.reserve
                  AND p.blockchain = 'ethereum'
                  AND p.minute = DATE_TRUNC('minute', sup.evt_block_time)
            WHERE sup.evt_block_time >= params.observation_start
              AND sup.evt_block_time <  params.observation_end
            GROUP BY 1
        ) s ON s.wallet = b.wallet
    )
    GROUP BY 1
)

-- ------------------------------------------------------------------ output
SELECT
    b.wallet                                                           AS wallet_address,
    COALESCE(wa.wallet_age_days, 0)                                    AS wallet_age_days,
    COALESCE(wa.tx_count_90d, 0)                                       AS tx_count_90d,
    ROUND(SUM(b.amount_usd), 2)                                        AS total_borrow_usd,
    ROUND(
        LEAST(COALESCE(rp.repaid_usd, 0) / NULLIF(SUM(b.amount_usd), 0), 1.2),
        6
    )                                                                  AS repay_to_borrow_ratio,
    COALESCE(lo.liquidation_count, 0)                                  AS liquidation_count,
    ROUND(LEAST(COALESCE(lv.max_leverage_ratio, 0), 0.98), 6)          AS max_leverage_ratio,
    COUNT(DISTINCT b.reserve)                                          AS distinct_assets_borrowed,
    ROUND(COALESCE(ps.avg_days_open, 0), 3)                            AS avg_position_duration_days,
    CASE WHEN lf.wallet IS NOT NULL THEN 1 ELSE 0 END                  AS defaulted
FROM borrows b
LEFT JOIN wallet_activity        wa ON wa.wallet = b.wallet
LEFT JOIN liquidations_observed  lo ON lo.wallet = b.wallet
LEFT JOIN liquidations_forward   lf ON lf.wallet = b.wallet
LEFT JOIN leverage               lv ON lv.wallet = b.wallet
LEFT JOIN (SELECT wallet, SUM(amount_usd) AS repaid_usd FROM repays GROUP BY 1) rp
       ON rp.wallet = b.wallet
LEFT JOIN (SELECT wallet, AVG(days_open) AS avg_days_open FROM position_spans GROUP BY 1) ps
       ON ps.wallet = b.wallet
GROUP BY
    b.wallet, wa.wallet_age_days, wa.tx_count_90d, rp.repaid_usd,
    lo.liquidation_count, lv.max_leverage_ratio, ps.avg_days_open, lf.wallet
-- Wallets with a trivial borrow history carry no signal and drag the base rate.
HAVING SUM(b.amount_usd) >= 100
ORDER BY total_borrow_usd DESC;
