-- SALESTORM reference schema (PostgreSQL 15+)
-- Logical per-service schemas shown together for readability.

-- ===================== CATALOGUE / SALE =====================
CREATE TABLE customer (
    customer_id UUID PRIMARY KEY,
    email       VARCHAR(255) NOT NULL UNIQUE,
    phone       VARCHAR(20),
    name        VARCHAR(150) NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE category (
    category_id SERIAL PRIMARY KEY,
    name        VARCHAR(100) NOT NULL,
    parent_id   INT REFERENCES category(category_id)
);

CREATE TABLE product (
    product_id  UUID PRIMARY KEY,
    category_id INT NOT NULL REFERENCES category(category_id),
    sku         VARCHAR(64) NOT NULL UNIQUE,
    name        VARCHAR(255) NOT NULL,
    base_price  NUMERIC(12,2) NOT NULL CHECK (base_price >= 0),
    active      BOOLEAN NOT NULL DEFAULT TRUE
);
CREATE INDEX idx_product_category ON product(category_id);

CREATE TABLE sale (
    sale_id                 UUID PRIMARY KEY,
    name                    VARCHAR(150) NOT NULL,
    starts_at               TIMESTAMPTZ NOT NULL,
    ends_at                 TIMESTAMPTZ NOT NULL,
    per_customer_limit      INT NOT NULL DEFAULT 1 CHECK (per_customer_limit > 0),
    reservation_ttl_seconds INT NOT NULL DEFAULT 600 CHECK (reservation_ttl_seconds > 0),
    CHECK (ends_at > starts_at)
);

CREATE TABLE sale_item (
    sale_id       UUID NOT NULL REFERENCES sale(sale_id),
    product_id    UUID NOT NULL REFERENCES product(product_id),
    sale_price    NUMERIC(12,2) NOT NULL CHECK (sale_price >= 0),
    sale_quantity INT NOT NULL CHECK (sale_quantity > 0),
    PRIMARY KEY (sale_id, product_id)
);

CREATE TABLE deal (
    deal_id     UUID PRIMARY KEY,
    sale_id     UUID NOT NULL REFERENCES sale(sale_id),
    rule_type   VARCHAR(50) NOT NULL,
    rule_config JSONB NOT NULL
);

CREATE TABLE coupon (
    coupon_id     UUID PRIMARY KEY,
    code          VARCHAR(40) NOT NULL UNIQUE,
    discount_type VARCHAR(20) NOT NULL CHECK (discount_type IN ('PERCENT','FLAT')),
    value         NUMERIC(12,2) NOT NULL CHECK (value > 0),
    valid_until   TIMESTAMPTZ NOT NULL
);

CREATE TABLE cart (
    cart_id     UUID PRIMARY KEY,
    customer_id UUID NOT NULL REFERENCES customer(customer_id),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE cart_item (
    cart_item_id UUID PRIMARY KEY,
    cart_id      UUID NOT NULL REFERENCES cart(cart_id) ON DELETE CASCADE,
    product_id   UUID NOT NULL REFERENCES product(product_id),
    quantity     INT NOT NULL CHECK (quantity > 0),
    UNIQUE (cart_id, product_id)
);

-- ===================== INVENTORY (hot path) =====================
CREATE TABLE inventory (
    inventory_id       UUID PRIMARY KEY,
    product_id         UUID NOT NULL UNIQUE REFERENCES product(product_id),
    total_quantity     INT NOT NULL CHECK (total_quantity >= 0),
    available_quantity INT NOT NULL CHECK (available_quantity >= 0),   -- never negative
    reserved_quantity  INT NOT NULL CHECK (reserved_quantity  >= 0),
    sold_quantity      INT NOT NULL CHECK (sold_quantity      >= 0),
    version            BIGINT NOT NULL DEFAULT 0,
    updated_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- conservation invariant enforced by the database itself
    CONSTRAINT inv_conservation CHECK
        (available_quantity + reserved_quantity + sold_quantity = total_quantity)
);

CREATE TABLE inventory_reservation (
    reservation_id  UUID PRIMARY KEY,
    customer_id     UUID NOT NULL,
    product_id      UUID NOT NULL REFERENCES product(product_id),
    sale_id         UUID NOT NULL REFERENCES sale(sale_id),
    quantity        INT  NOT NULL CHECK (quantity > 0),
    state           VARCHAR(20) NOT NULL CHECK (state IN
                    ('RESERVED','PAYMENT_PENDING','CONFIRMED','SOLD','RELEASED')),
    release_reason  VARCHAR(30),   -- TIMEOUT | PAYMENT_FAILED | USER_CANCEL | ORDER_FAILED
    expires_at      TIMESTAMPTZ NOT NULL,
    idempotency_key VARCHAR(100) NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- duplicate request prevention
    CONSTRAINT uq_res_idem UNIQUE (customer_id, idempotency_key)
);
-- sweeper index: only unpaid, expiring rows
CREATE INDEX idx_res_expiry ON inventory_reservation (expires_at)
    WHERE state IN ('RESERVED','PAYMENT_PENDING');
CREATE INDEX idx_res_customer_sale ON inventory_reservation (customer_id, sale_id);
-- per-customer purchase limit support: only one live reservation per customer/product/sale
CREATE UNIQUE INDEX uq_res_live_per_customer ON inventory_reservation (customer_id, product_id, sale_id)
    WHERE state IN ('RESERVED','PAYMENT_PENDING','CONFIRMED','SOLD');

-- ===================== PAYMENT =====================
CREATE TABLE payment (
    payment_id      UUID PRIMARY KEY,
    reservation_id  UUID NOT NULL UNIQUE,            -- one payment per reservation
    idempotency_key VARCHAR(100) NOT NULL UNIQUE,
    merchant_ref    VARCHAR(100) NOT NULL UNIQUE,    -- sent to gateway: gateway-side dedupe
    gateway_txn_id  VARCHAR(100),
    amount          NUMERIC(12,2) NOT NULL CHECK (amount >= 0),
    currency        CHAR(3) NOT NULL DEFAULT 'INR',
    status          VARCHAR(20) NOT NULL CHECK (status IN
                    ('INITIATED','PENDING','SUCCEEDED','FAILED','TIMED_OUT','REFUND_PENDING','REFUNDED')),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_payment_status_updated ON payment (status, updated_at)
    WHERE status IN ('PENDING','TIMED_OUT','INITIATED');

CREATE TABLE payment_attempt (
    attempt_id  BIGSERIAL PRIMARY KEY,
    payment_id  UUID NOT NULL REFERENCES payment(payment_id),
    attempt_no  INT NOT NULL,
    outcome     VARCHAR(20) NOT NULL,
    error_code  VARCHAR(50),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (payment_id, attempt_no)
);

-- gateway webhook dedupe
CREATE TABLE gateway_event (
    gateway_event_id VARCHAR(100) PRIMARY KEY,
    payment_id       UUID,
    received_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ===================== ORDER =====================
CREATE TABLE orders (
    order_id       UUID PRIMARY KEY,
    customer_id    UUID NOT NULL,
    reservation_id UUID NOT NULL UNIQUE,          -- exactly one order per reservation
    payment_id     UUID NOT NULL UNIQUE,
    state          VARCHAR(25) NOT NULL CHECK (state IN
                   ('CREATED','PAYMENT_PENDING','CONFIRMED','PROCESSING','SHIPPED',
                    'OUT_FOR_DELIVERY','DELIVERED','CANCELLED','RETURNED_TO_SENDER')),
    total_amount   NUMERIC(12,2) NOT NULL CHECK (total_amount >= 0),
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_orders_customer ON orders (customer_id, created_at DESC);

CREATE TABLE order_item (
    order_item_id UUID PRIMARY KEY,
    order_id      UUID NOT NULL REFERENCES orders(order_id),
    product_id    UUID NOT NULL,
    quantity      INT NOT NULL CHECK (quantity > 0),
    unit_price    NUMERIC(12,2) NOT NULL CHECK (unit_price >= 0)
);
CREATE INDEX idx_order_item_order ON order_item(order_id);

CREATE TABLE order_status_history (
    history_id BIGSERIAL PRIMARY KEY,
    order_id   UUID NOT NULL REFERENCES orders(order_id),
    from_state VARCHAR(25),
    to_state   VARCHAR(25) NOT NULL,
    reason     VARCHAR(200),
    changed_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_osh_order ON order_status_history (order_id, changed_at);

-- ===================== SHIPMENT / NOTIFICATION =====================
CREATE TABLE shipment (
    shipment_id UUID PRIMARY KEY,
    order_id    UUID NOT NULL UNIQUE,
    courier     VARCHAR(50),
    tracking_no VARCHAR(80),
    status      VARCHAR(25) NOT NULL,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE notification (
    notification_id UUID PRIMARY KEY,
    customer_id     UUID NOT NULL,
    order_id        UUID,
    channel         VARCHAR(10) NOT NULL CHECK (channel IN ('EMAIL','SMS','PUSH')),
    template        VARCHAR(50) NOT NULL,
    status          VARCHAR(15) NOT NULL,
    dedupe_key      VARCHAR(120) NOT NULL UNIQUE,   -- one notification per event+channel
    sent_at         TIMESTAMPTZ
);

-- ===================== INFRASTRUCTURE TABLES =====================
CREATE TABLE outbox_event (
    event_id     UUID PRIMARY KEY,
    aggregate_id UUID NOT NULL,
    event_type   VARCHAR(60) NOT NULL,
    payload      JSONB NOT NULL,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    published_at TIMESTAMPTZ
);
CREATE INDEX idx_outbox_unpublished ON outbox_event (created_at) WHERE published_at IS NULL;

CREATE TABLE processed_event (          -- consumer-side dedupe
    consumer   VARCHAR(60) NOT NULL,
    event_id   UUID NOT NULL,
    processed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (consumer, event_id)
);

CREATE TABLE audit_log (
    audit_id    BIGSERIAL PRIMARY KEY,
    actor       VARCHAR(100) NOT NULL,
    action      VARCHAR(60) NOT NULL,
    entity      VARCHAR(40) NOT NULL,
    entity_id   UUID,
    detail      JSONB,
    occurred_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ===================== CORE CONCURRENCY STATEMENTS =====================
-- 1) Atomic reserve (inside one transaction with the reservation INSERT):
--    UPDATE inventory
--       SET available_quantity = available_quantity - :q,
--           reserved_quantity  = reserved_quantity  + :q,
--           version = version + 1, updated_at = now()
--     WHERE product_id = :pid AND available_quantity >= :q;
--    -- rows affected = 0  => OUT_OF_STOCK (nothing changed)
--
-- 2) Release (expiry / failure), guarded by state so it is idempotent:
--    UPDATE inventory_reservation SET state='RELEASED', release_reason=:r, updated_at=now()
--     WHERE reservation_id=:rid AND state IN ('RESERVED','PAYMENT_PENDING');
--    -- only if that updated 1 row:
--    UPDATE inventory SET available_quantity = available_quantity + :q,
--                         reserved_quantity  = reserved_quantity  - :q, version = version+1
--     WHERE product_id=:pid;
--
-- 3) Confirm sold:
--    UPDATE inventory_reservation SET state='SOLD' WHERE reservation_id=:rid AND state='CONFIRMED';
--    UPDATE inventory SET reserved_quantity = reserved_quantity - :q,
--                         sold_quantity = sold_quantity + :q WHERE product_id=:pid;
--
-- 4) Expiry sweep:
--    SELECT reservation_id FROM inventory_reservation
--     WHERE state IN ('RESERVED','PAYMENT_PENDING') AND expires_at <= now()
--     ORDER BY expires_at LIMIT 500 FOR UPDATE SKIP LOCKED;
