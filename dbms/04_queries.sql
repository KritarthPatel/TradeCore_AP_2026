-- TradeCore PostgreSQL query catalog (dbms/03_schema.sql).
-- No application source exists in this repository yet. These are the proposed
-- queries for every feature described in README.md, not an extracted call list.
-- Execute statements individually using driver-bound :named parameters (the
-- notation is illustrative; translate to the driver's placeholders). Never
-- concatenate input into SQL. :page_size and :offset must be bounded integers.
-- READ includes SELECT ... FOR UPDATE: it reads data but also acquires locks.
-- WRITE denotes statements that change persistent data.
--
-- Transaction contract for the future application:
-- * Account creation and initial cash allocation are one transaction.
-- * Order placement, matching, cancellation, and settlement run in transactions.
--   Serialize ALL such operations by locking ALL cash_balances rows in user_id
--   order with Q05 first. This simple simulator-wide lock also protects absent
--   position rows; every account must have a cash row. A production engine can
--   replace this with a carefully designed finer-grained locking protocol.
-- * Placement checks Q06/Q07 before Q08: reserve outstanding buy limit notional
--   and outstanding sell shares logically, without deducting them twice.
-- * Match the oldest incoming order against the best eligible resting order;
--   Q11/Q12 exclude self-trades and break price/time ties with order_id.
-- * Recheck remaining quantities under the lock. Fill quantity must be positive
--   and <= both remaining quantities. Execution price is the resting limit price
--   and must lie between the sell and buy limits. Verify sides, instrument,
--   active statuses, and different owners. Reject invalid caller-supplied IDs.
-- * Q13-Q18 are one settlement transaction: record fill, update both orders,
--   transfer cash, and transfer shares. Pass identical fill values throughout.
--   Require one affected row for each expected update; otherwise ROLLBACK.
--   COMMIT only after all checks and updates succeed. Do not run the catalog
--   as a migration or execute its write examples against real user data.

-- WRITE Q01: Create a user; returned user_id feeds Q02.
INSERT INTO users (email, display_name)
VALUES (:email, :display_name)
RETURNING user_id, email, display_name, created_at;

-- WRITE Q02: Allocate virtual starting cash once, in the Q01 transaction.
INSERT INTO cash_balances (user_id, balance)
VALUES (:user_id, :initial_balance)
RETURNING user_id, balance;

-- READ Q03: User profile and cash balance (email identifies a profile, not auth).
SELECT u.user_id, u.email, u.display_name, u.created_at, c.balance
FROM users AS u
JOIN cash_balances AS c ON c.user_id = u.user_id
WHERE u.email = :email;

-- READ Q04: Instrument picker and symbol lookup; NULL lists all instruments.
SELECT instrument_id, symbol, display_name
FROM instruments
WHERE CAST(:symbol AS TEXT) IS NULL OR symbol = :symbol
ORDER BY symbol;

-- READ Q05: Acquire the simulator settlement/placement/cancellation mutex.
-- Must finish acquiring all rows before reading trading state or writing it.
SELECT user_id, balance
FROM cash_balances
ORDER BY user_id
FOR UPDATE;

-- READ Q06: Cash available for a new buy, after active buy reservations.
WITH fills AS (
    SELECT buy_order_id AS order_id, SUM(quantity) AS quantity
    FROM trades
    GROUP BY buy_order_id
), reserved AS (
    SELECT o.user_id,
           SUM((o.original_quantity - COALESCE(f.quantity, 0))
               * o.limit_price) AS amount
    FROM orders AS o
    LEFT JOIN fills AS f ON f.order_id = o.order_id
    WHERE o.side = 'buy' AND o.status IN ('open', 'partially_filled')
    GROUP BY o.user_id
)
SELECT c.balance, COALESCE(r.amount, 0) AS reserved_cash,
       c.balance - COALESCE(r.amount, 0) AS available_cash
FROM cash_balances AS c
LEFT JOIN reserved AS r ON r.user_id = c.user_id
WHERE c.user_id = :user_id;

-- READ Q07: Shares available for a new sell, after active sell reservations.
WITH fills AS (
    SELECT sell_order_id AS order_id, SUM(quantity) AS quantity
    FROM trades
    GROUP BY sell_order_id
), reserved AS (
    SELECT o.user_id, o.instrument_id,
           SUM(o.original_quantity - COALESCE(f.quantity, 0)) AS quantity
    FROM orders AS o
    LEFT JOIN fills AS f ON f.order_id = o.order_id
    WHERE o.side = 'sell' AND o.status IN ('open', 'partially_filled')
    GROUP BY o.user_id, o.instrument_id
)
SELECT i.instrument_id, COALESCE(p.quantity, 0) AS held_quantity,
       COALESCE(r.quantity, 0) AS reserved_quantity,
       COALESCE(p.quantity, 0) - COALESCE(r.quantity, 0) AS available_quantity
FROM instruments AS i
LEFT JOIN positions AS p
    ON p.instrument_id = i.instrument_id AND p.user_id = :user_id
LEFT JOIN reserved AS r
    ON r.instrument_id = i.instrument_id AND r.user_id = :user_id
WHERE i.instrument_id = :instrument_id;

-- WRITE Q08: Place a validated, fully funded buy or covered sell order.
INSERT INTO orders (user_id, instrument_id, side, limit_price, original_quantity)
VALUES (:user_id, :instrument_id, :side, :limit_price, :quantity)
RETURNING order_id, status, created_at;

-- READ Q09: User order history with filled and remaining quantities.
WITH fills AS (
    SELECT buy_order_id AS order_id, quantity FROM trades
    UNION ALL
    SELECT sell_order_id AS order_id, quantity FROM trades
), totals AS (
    SELECT order_id, SUM(quantity) AS quantity FROM fills GROUP BY order_id
)
SELECT o.order_id, i.symbol, o.side, o.limit_price, o.original_quantity,
       COALESCE(t.quantity, 0) AS filled_quantity,
       o.original_quantity - COALESCE(t.quantity, 0) AS remaining_quantity,
       o.status, o.created_at, o.cancelled_at
FROM orders AS o
JOIN instruments AS i ON i.instrument_id = o.instrument_id
LEFT JOIN totals AS t ON t.order_id = o.order_id
WHERE o.user_id = :user_id
ORDER BY o.created_at DESC, o.order_id DESC
LIMIT :page_size OFFSET :offset;

-- READ Q10: Aggregated order-book depth; bids descending, asks ascending.
WITH fills AS (
    SELECT buy_order_id AS order_id, quantity FROM trades
    UNION ALL
    SELECT sell_order_id AS order_id, quantity FROM trades
), totals AS (
    SELECT order_id, SUM(quantity) AS quantity FROM fills GROUP BY order_id
)
SELECT i.symbol, o.side, o.limit_price,
       SUM(o.original_quantity - COALESCE(t.quantity, 0)) AS quantity,
       COUNT(*) AS order_count
FROM orders AS o
JOIN instruments AS i ON i.instrument_id = o.instrument_id
LEFT JOIN totals AS t ON t.order_id = o.order_id
WHERE o.instrument_id = :instrument_id
  AND o.status IN ('open', 'partially_filled')
  AND o.original_quantity > COALESCE(t.quantity, 0)
GROUP BY i.symbol, o.side, o.limit_price
ORDER BY o.side,
         CASE WHEN o.side = 'buy' THEN o.limit_price END DESC,
         CASE WHEN o.side = 'sell' THEN o.limit_price END ASC;

-- READ Q11: Best resting sell for a buy; execute at this resting limit price.
SELECT o.order_id, o.user_id, o.limit_price,
       o.original_quantity - COALESCE(f.quantity, 0) AS remaining_quantity
FROM orders AS o
LEFT JOIN LATERAL (
    SELECT SUM(t.quantity) AS quantity FROM trades AS t
    WHERE t.sell_order_id = o.order_id
) AS f ON TRUE
WHERE o.instrument_id = :instrument_id AND o.side = 'sell'
  AND o.user_id <> :incoming_user_id
  AND o.status IN ('open', 'partially_filled')
  AND o.limit_price <= :incoming_limit_price
  AND o.original_quantity > COALESCE(f.quantity, 0)
ORDER BY o.limit_price ASC, o.created_at ASC, o.order_id ASC
LIMIT 1;

-- READ Q12: Best resting buy for a sell; execute at this resting limit price.
SELECT o.order_id, o.user_id, o.limit_price,
       o.original_quantity - COALESCE(f.quantity, 0) AS remaining_quantity
FROM orders AS o
LEFT JOIN LATERAL (
    SELECT SUM(t.quantity) AS quantity FROM trades AS t
    WHERE t.buy_order_id = o.order_id
) AS f ON TRUE
WHERE o.instrument_id = :instrument_id AND o.side = 'buy'
  AND o.user_id <> :incoming_user_id
  AND o.status IN ('open', 'partially_filled')
  AND o.limit_price >= :incoming_limit_price
  AND o.original_quantity > COALESCE(f.quantity, 0)
ORDER BY o.limit_price DESC, o.created_at ASC, o.order_id ASC
LIMIT 1;

-- WRITE Q13: Record one validated fill, including partial executions.
INSERT INTO trades (buy_order_id, sell_order_id, execution_price, quantity)
VALUES (:buy_order_id, :sell_order_id, :execution_price, :fill_quantity)
RETURNING trade_id, executed_at;

-- WRITE Q14: Recompute status after Q13; run once for EACH matched order.
WITH fills AS (
    SELECT quantity FROM trades WHERE buy_order_id = :order_id
    UNION ALL
    SELECT quantity FROM trades WHERE sell_order_id = :order_id
)
UPDATE orders
SET status = CASE
    WHEN (SELECT COALESCE(SUM(quantity), 0) FROM fills) = original_quantity
    THEN 'filled' ELSE 'partially_filled' END
WHERE order_id = :order_id AND status IN ('open', 'partially_filled')
RETURNING order_id, status;

-- WRITE Q15: Debit buyer cash. Round once to the schema's cash precision;
-- Q16 MUST use the same rounding so the transfer conserves cash.
UPDATE cash_balances
SET balance = balance - ROUND(CAST(:execution_price AS NUMERIC)
                              * CAST(:fill_quantity AS NUMERIC), 4),
    updated_at = CURRENT_TIMESTAMP
WHERE user_id = :buyer_id
  AND balance >= ROUND(CAST(:execution_price AS NUMERIC)
                       * CAST(:fill_quantity AS NUMERIC), 4)
RETURNING balance;

-- WRITE Q16: Credit seller cash.
UPDATE cash_balances
SET balance = balance + ROUND(CAST(:execution_price AS NUMERIC)
                              * CAST(:fill_quantity AS NUMERIC), 4),
    updated_at = CURRENT_TIMESTAMP
WHERE user_id = :seller_id
RETURNING balance;

-- WRITE Q17: Add buyer shares and maintain weighted average acquisition cost.
INSERT INTO positions (user_id, instrument_id, quantity, average_cost)
VALUES (:buyer_id, :instrument_id, :fill_quantity, :execution_price)
ON CONFLICT (user_id, instrument_id) DO UPDATE
SET average_cost = (positions.quantity * positions.average_cost
                   + EXCLUDED.quantity * EXCLUDED.average_cost)
                  / (positions.quantity + EXCLUDED.quantity),
    quantity = positions.quantity + EXCLUDED.quantity,
    updated_at = CURRENT_TIMESTAMP
RETURNING quantity, average_cost;

-- WRITE Q18: Remove seller shares; reset cost when the position closes.
UPDATE positions
SET quantity = quantity - :fill_quantity,
    average_cost = CASE WHEN quantity = :fill_quantity THEN 0 ELSE average_cost END,
    updated_at = CURRENT_TIMESTAMP
WHERE user_id = :seller_id AND instrument_id = :instrument_id
  AND quantity >= :fill_quantity
RETURNING quantity, average_cost;

-- WRITE Q19: Cancel the unfilled remainder of an owned active order.
-- Reservations disappear automatically because Q06/Q07 exclude cancelled orders.
UPDATE orders
SET status = 'cancelled', cancelled_at = CURRENT_TIMESTAMP
WHERE order_id = :order_id AND user_id = :user_id
  AND status IN ('open', 'partially_filled')
RETURNING order_id, status, cancelled_at;

-- READ Q20: User trade history, with instrument and counterparty order IDs.
SELECT t.trade_id, i.symbol,
       CASE WHEN b.user_id = :user_id THEN 'buy' ELSE 'sell' END AS side,
       t.buy_order_id, t.sell_order_id, t.execution_price, t.quantity,
       ROUND(t.execution_price * t.quantity, 4) AS cash_amount, t.executed_at
FROM trades AS t
JOIN orders AS b ON b.order_id = t.buy_order_id
JOIN orders AS s ON s.order_id = t.sell_order_id
JOIN instruments AS i ON i.instrument_id = b.instrument_id
WHERE b.user_id = :user_id OR s.user_id = :user_id
ORDER BY t.executed_at DESC, t.trade_id DESC
LIMIT :page_size OFFSET :offset;

-- READ Q21: Market tape / price-chart points in a half-open time interval.
SELECT t.trade_id, i.symbol, t.execution_price, t.quantity, t.executed_at
FROM trades AS t
JOIN orders AS o ON o.order_id = t.buy_order_id
JOIN instruments AS i ON i.instrument_id = o.instrument_id
WHERE o.instrument_id = :instrument_id
  AND t.executed_at >= :from_time AND t.executed_at < :to_time
ORDER BY t.executed_at, t.trade_id;

-- READ Q22: Market statistics (includes instruments with no trades).
SELECT i.instrument_id, i.symbol, COUNT(t.trade_id) AS trade_count,
       COALESCE(SUM(t.quantity), 0) AS volume,
       MIN(t.execution_price) AS low_price, MAX(t.execution_price) AS high_price,
       SUM(t.execution_price * t.quantity) / NULLIF(SUM(t.quantity), 0) AS vwap
FROM instruments AS i
LEFT JOIN orders AS o ON o.instrument_id = i.instrument_id AND o.side = 'buy'
LEFT JOIN trades AS t ON t.buy_order_id = o.order_id
    AND t.executed_at >= :from_time AND t.executed_at < :to_time
GROUP BY i.instrument_id, i.symbol
ORDER BY i.symbol;

-- READ Q23: Portfolio holdings, allocation, and unrealized gain chart data.
-- Before the first trade, use acquisition cost as the valuation fallback.
SELECT i.symbol, p.quantity, p.average_cost, last_trade.execution_price AS last_price,
       p.quantity * p.average_cost AS cost_basis,
       p.quantity * COALESCE(last_trade.execution_price, p.average_cost) AS market_value,
       p.quantity * (COALESCE(last_trade.execution_price, p.average_cost)
                     - p.average_cost) AS unrealized_gain
FROM positions AS p
JOIN instruments AS i ON i.instrument_id = p.instrument_id
LEFT JOIN LATERAL (
    SELECT t.execution_price
    FROM trades AS t
    JOIN orders AS o ON o.order_id = t.buy_order_id
    WHERE o.instrument_id = p.instrument_id
    ORDER BY t.executed_at DESC, t.trade_id DESC
    LIMIT 1
) AS last_trade ON TRUE
WHERE p.user_id = :user_id AND p.quantity > 0
ORDER BY i.symbol;

-- READ Q24: Dashboard total equity; cash includes funds reserved by open buys.
SELECT c.balance AS cash_balance, COALESCE(holdings.market_value, 0) AS holdings_value,
       c.balance + COALESCE(holdings.market_value, 0) AS total_equity
FROM cash_balances AS c
LEFT JOIN LATERAL (
    SELECT SUM(p.quantity * COALESCE(last_trade.execution_price, p.average_cost))
           AS market_value
    FROM positions AS p
    LEFT JOIN LATERAL (
        SELECT t.execution_price
        FROM trades AS t
        JOIN orders AS o ON o.order_id = t.buy_order_id
        WHERE o.instrument_id = p.instrument_id
        ORDER BY t.executed_at DESC, t.trade_id DESC
        LIMIT 1
    ) AS last_trade ON TRUE
    WHERE p.user_id = c.user_id
) AS holdings ON TRUE
WHERE c.user_id = :user_id;

-- READ Q25: Order detail / matching recheck for either side under Q05's lock.
SELECT o.order_id, o.user_id, o.instrument_id, i.symbol, o.side, o.limit_price,
       o.status, o.original_quantity,
       o.original_quantity - COALESCE(f.quantity, 0) AS remaining_quantity
FROM orders AS o
JOIN instruments AS i ON i.instrument_id = o.instrument_id
LEFT JOIN LATERAL (
    SELECT SUM(t.quantity) AS quantity
    FROM trades AS t
    WHERE t.buy_order_id = o.order_id OR t.sell_order_id = o.order_id
) AS f ON TRUE
WHERE o.order_id = :order_id;
