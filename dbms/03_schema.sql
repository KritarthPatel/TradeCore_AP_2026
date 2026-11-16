-- TradeCore PostgreSQL schema
-- Core entities: users, instruments, orders, trade fills, positions, and cash balances.

CREATE TABLE users (
    user_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email         TEXT NOT NULL UNIQUE,
    display_name  TEXT NOT NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT users_email_nonempty CHECK (length(btrim(email)) > 0),
    CONSTRAINT users_display_name_nonempty CHECK (length(btrim(display_name)) > 0)
);

CREATE TABLE instruments (
    instrument_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    symbol        TEXT NOT NULL UNIQUE,
    display_name  TEXT NOT NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT instruments_symbol_nonempty CHECK (length(btrim(symbol)) > 0),
    CONSTRAINT instruments_display_name_nonempty CHECK (length(btrim(display_name)) > 0)
);

CREATE TABLE cash_balances (
    user_id       BIGINT PRIMARY KEY REFERENCES users (user_id) ON DELETE CASCADE,
    balance       NUMERIC(20, 4) NOT NULL DEFAULT 0,
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT cash_balances_nonnegative CHECK (balance >= 0)
);

CREATE TABLE orders (
    order_id           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id            BIGINT NOT NULL REFERENCES users (user_id) ON DELETE RESTRICT,
    instrument_id      BIGINT NOT NULL REFERENCES instruments (instrument_id) ON DELETE RESTRICT,
    side               TEXT NOT NULL,
    limit_price        NUMERIC(20, 4) NOT NULL,
    original_quantity  NUMERIC(20, 8) NOT NULL,
    status             TEXT NOT NULL DEFAULT 'open',
    created_at         TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    cancelled_at       TIMESTAMPTZ,
    CONSTRAINT orders_side_valid CHECK (side IN ('buy', 'sell')),
    CONSTRAINT orders_price_nonnegative CHECK (limit_price >= 0),
    CONSTRAINT orders_quantity_positive CHECK (original_quantity > 0),
    CONSTRAINT orders_status_valid CHECK (status IN ('open', 'partially_filled', 'filled', 'cancelled')),
    CONSTRAINT orders_cancel_timestamp_consistent CHECK (
        (status = 'cancelled' AND cancelled_at IS NOT NULL)
        OR (status <> 'cancelled' AND cancelled_at IS NULL)
    )
);

CREATE TABLE trades (
    trade_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    buy_order_id    BIGINT NOT NULL REFERENCES orders (order_id) ON DELETE RESTRICT,
    sell_order_id   BIGINT NOT NULL REFERENCES orders (order_id) ON DELETE RESTRICT,
    execution_price NUMERIC(20, 4) NOT NULL,
    quantity        NUMERIC(20, 8) NOT NULL,
    executed_at     TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT trades_distinct_orders CHECK (buy_order_id <> sell_order_id),
    CONSTRAINT trades_price_nonnegative CHECK (execution_price >= 0),
    CONSTRAINT trades_quantity_positive CHECK (quantity > 0)
);

CREATE TABLE positions (
    user_id       BIGINT NOT NULL REFERENCES users (user_id) ON DELETE CASCADE,
    instrument_id BIGINT NOT NULL REFERENCES instruments (instrument_id) ON DELETE RESTRICT,
    quantity      NUMERIC(20, 8) NOT NULL DEFAULT 0,
    average_cost  NUMERIC(20, 4) NOT NULL DEFAULT 0,
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (user_id, instrument_id),
    CONSTRAINT positions_quantity_nonnegative CHECK (quantity >= 0),
    CONSTRAINT positions_average_cost_nonnegative CHECK (average_cost >= 0)
);

CREATE INDEX orders_instrument_side_status_price_created_idx
    ON orders (instrument_id, side, status, limit_price, created_at);
CREATE INDEX orders_user_created_idx
    ON orders (user_id, created_at DESC);
CREATE INDEX trades_buy_order_idx ON trades (buy_order_id);
CREATE INDEX trades_sell_order_idx ON trades (sell_order_id);
CREATE INDEX trades_executed_at_idx ON trades (executed_at DESC);
