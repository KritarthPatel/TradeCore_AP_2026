# TradeCore data normalization

## Scope and assumptions

TradeCore is a virtual stock market simulator with users, buy and sell orders, partial fills, trades, cash balances, and portfolios. The repository currently documents these features but does not include an implemented database schema. This note therefore gives a proposed relational design consistent with the app description. Names and constraints can be adjusted when the SQL schema is added.

Assumptions used below:

- A user can place many orders; each order is for one instrument and has one side (buy or sell).
- An order can be filled multiple times. Each fill is a trade between one buy order and one sell order.
- An instrument has a unique symbol. A user/instrument pair has at most one current portfolio position.
- Order and trade prices, quantities, timestamps, and cash amounts are stored as scalar values. Money and share quantities should use suitable fixed-precision numeric types, not floating point.

## 1NF — atomic values and identifiable rows

First, represent each repeating event as its own row. Do not put multiple order IDs, fills, or holdings into comma-separated fields or arrays. A single flat event view could be written as:

```text
MarketEvent(
  event_id, event_type,
  user_id, user_name,
  instrument_id, symbol,
  order_id, side, order_price, order_quantity, order_status, order_time,
  trade_id, trade_price, trade_quantity, trade_time,
  counterparty_order_id
)
```

Each row has atomic column values and a unique `event_id`, so this is in 1NF. However, the view mixes different entities. Names and symbols are repeated, and most columns are null for a given event type. A trade row may also repeat order and user details. 1NF does not eliminate those update and deletion anomalies.

## 2NF — remove partial dependencies

For trade fills, a natural key in a flat order/fill listing may be `(trade_id, order_id)` because a trade references two orders. Attributes such as `trade_time` and `trade_price` depend only on `trade_id`; order attributes such as `side` and `order_quantity` depend only on `order_id`. They depend on only part of the composite key, violating 2NF.

Separate the entities so attributes depend on the whole key:

```text
Users(user_id, user_name, email, created_at)
Instruments(instrument_id, symbol, display_name)
Orders(order_id, user_id, instrument_id, side, limit_price,
       original_quantity, status, created_at, cancelled_at)
Trades(trade_id, buy_order_id, sell_order_id, execution_price,
       quantity, executed_at)
```

Each relation has a single-column primary key, so there are no partial-key dependencies. `buy_order_id` and `sell_order_id` reference `Orders.order_id`. If an explicit association relation is used instead, trade-level attributes stay in `Trades`, while order-level attributes stay in `Orders`.

## 3NF — remove transitive dependencies

Keep descriptive facts with the entity they describe. For example, if a flat relation contains `order_id, user_id, email`, then `order_id → user_id → email`; email is transitively dependent on the order key. Likewise, `instrument_id → symbol`, so a symbol should not be copied into every order or trade as the authoritative value.

The 3NF design keeps user and instrument descriptions in their own tables, and references them by key:

```text
Users(user_id PK, email UNIQUE, display_name, created_at)
Instruments(instrument_id PK, symbol UNIQUE, display_name)
Orders(order_id PK, user_id FK, instrument_id FK, side, limit_price,
       original_quantity, status, created_at, cancelled_at)
Trades(trade_id PK, buy_order_id FK, sell_order_id FK,
       execution_price, quantity, executed_at)
```

Order status can be stored as a domain value (for example, `open`, `partially_filled`, `filled`, `cancelled`). If statuses need independent metadata or administration, use a `OrderStatuses(status_code PK, label)` lookup relation and store `status_code` as a foreign key. Avoid duplicating user email or instrument symbol in `Orders` as source data.

For portfolio state, a compact normalized relation is:

```text
Positions(user_id FK, instrument_id FK, quantity, average_cost,
          PRIMARY KEY (user_id, instrument_id))
```

Here both `quantity` and `average_cost` depend on the whole composite key `(user_id, instrument_id)`. This is suitable for a current-position snapshot. The trade ledger remains the source of transaction history; a position snapshot may be maintained transactionally or recomputed from trades, depending on the app's consistency and performance needs.

## BCNF — stronger determinant rule (where practical)

BCNF requires every determinant to be a candidate key. The proposed core tables meet BCNF under these business rules:

- `user_id` determines the attributes of `Users`; `email` is also unique and therefore a candidate key.
- `instrument_id` determines instrument attributes; `symbol` is unique and is also a candidate key.
- `order_id` determines order attributes.
- `trade_id` determines one execution. The buy and sell order IDs are foreign keys, not determinants of all trade attributes: one order can participate in many fills.
- In `Positions`, `(user_id, instrument_id)` is the candidate key and determines the snapshot values.

One constraint deserves care: if the product guarantees one trade per pair of orders, `(buy_order_id, sell_order_id)` could be a candidate key too. Partial fills commonly allow the same pair to produce multiple fills, so that uniqueness rule should not be imposed unless the matching engine guarantees it. In that model, `trade_id` is the stable key and each fill is one row.

## Suggested integrity constraints

- Foreign keys from `Orders.user_id` to `Users`, and from `Orders.instrument_id` to `Instruments`.
- Foreign keys from both trade order references to `Orders`; enforce that the referenced sides are buy and sell respectively, using application logic or database constraints/triggers where supported.
- Positive order and trade quantities; nonnegative prices and balances where applicable.
- `UNIQUE` constraints on user email and instrument symbol.
- A check that `side` is one of the supported values and a trade quantity does not exceed the remaining quantity on either order. Concurrent matching requires transactional locking or equivalent safeguards.

These relations describe durable business facts. An order book, market statistics, and portfolio charts can be derived from orders, trades, and positions rather than stored as duplicated authoritative data.
