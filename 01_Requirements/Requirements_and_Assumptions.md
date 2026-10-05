# SALESTORM – Requirements & Assumptions

## 1. Problem Statement
A limited-stock flash sale: **10,000 concurrent "Buy Now" requests for 100 units** of Product X. The platform must never oversell, must process payments idempotently, and must keep the order lifecycle correct even when services, the database or the payment gateway fail.

**Business question:** How do we handle thousands of simultaneous purchase requests for limited inventory without overselling, while keeping payment and order processing reliable?

## 2. Scope
**In scope:** product discovery, cart, inventory check, reservation, checkout, payment, order, fulfilment, shipment, notification, delivery tracking.
**Out of scope:** recommendation engine, seller onboarding, returns/refund portal (refund is only used as a compensation action), tax engine internals.

## 3. Functional Requirements
| ID | Requirement |
|----|-------------|
| FR-1 | Customers browse sale/product pages (served mostly from CDN/cache). |
| FR-2 | Customers manage a cart (add, update, remove). |
| FR-3 | System shows approximate stock ("Few left", "Sold out") without hitting the DB per view. |
| FR-4 | "Buy Now" atomically reserves quantity for the customer; reservation has a TTL (default 10 min, configurable per sale). |
| FR-5 | Reservation is confirmed on payment success, released on payment failure, cancellation or TTL expiry. |
| FR-6 | Checkout computes price using sale/deal/coupon rules (pluggable pricing strategies). |
| FR-7 | Payment is initiated via a gateway, with idempotency, retry and reconciliation. |
| FR-8 | A successful payment always leads to exactly one order (eventually). |
| FR-9 | Order follows a defined lifecycle (CREATED → … → DELIVERED) with audit history. |
| FR-10 | Shipment creation, notification (email/SMS/push) and delivery tracking are triggered by order events. |
| FR-11 | Customers see deterministic outcomes: RESERVED, OUT_OF_STOCK, DUPLICATE (returns original result), PAYMENT_FAILED, EXPIRED, CONFIRMED. |
| FR-12 | Per-customer purchase limit per sale (default 1 unit per customer for Product X). |
| FR-13 | Operators can view inventory, reservations, payments and order state and trigger reconciliation. |

## 4. Non-Functional Requirements
| Category | Requirement | Type |
|----------|-------------|------|
| Correctness | `sold + reserved <= total` always; sold units never exceed 100 for Product X | **Strict guarantee** |
| Idempotency | Same idempotency key → same outcome; no duplicate reservation, payment or order | **Strict guarantee** |
| Payment integrity | Exactly one captured payment per reservation; no payment without an eventual order or refund | **Strict guarantee** |
| Throughput | Normal: ~10,000 req/s; flash-sale design envelope: 500,000 req/s at the edge | Target |
| Latency | Product page p95 < 200 ms (CDN hit < 50 ms); Buy Now reservation response p95 < 300 ms, p99 < 800 ms; checkout p95 < 1 s excluding gateway | Target |
| Availability | Browse/discovery 99.99%; reservation/checkout 99.95%; payment/order pipeline never loses accepted work | Target |
| Consistency | Inventory: strong (single authority per product). Catalogue, counters shown to users: eventual (≤ 2 s) | Strict / Target |
| Durability | Reservation, payment, order records RPO = 0 (synchronous replication); event log RPO ≈ 0 | Strict |
| Recovery | RTO < 5 min for service failure; < 15 min for DB primary failure (automatic failover) | Target |
| Security | TLS 1.2+, OAuth2/JWT, PCI-DSS scope minimisation (tokenised cards), rate limiting, audit logging | Strict |
| Observability | Metrics, structured logs, trace across checkout→payment→order, alerts on inventory inconsistency | Strict |
| Scalability | Stateless services scale horizontally; 50× traffic handled by edge absorption, queueing and shedding | Target |

## 5. Assumptions
1. Sale start time is known in advance → capacity can be pre-warmed.
2. A customer is logged in (or must log in) before Buy Now; anonymous users can browse only.
3. Product X inventory is a **hot SKU**; other SKUs have low contention.
4. The payment gateway offers idempotency keys / merchant reference and webhooks, typical rate limit and occasional timeouts.
5. Payment success rate in the test case is 95%, failure 5%, duplicate requests 2%, Order Service outage 30 s.
6. Reservation TTL = 10 minutes (payment window); shorter (e.g. 5 min) is configurable for hot sales.
7. Single-region active deployment with multi-AZ; a warm standby region for DR.
8. Message broker provides at-least-once delivery; consumers must be idempotent.
9. Clock skew bounded (NTP); expiry uses the DB clock, not app server clocks.

## 6. Constraints
- Over-selling is unacceptable; under-selling for short periods (units held in reservation) is acceptable.
- Payment gateway is a third party with limited throughput and latency outside our control.
- Fairness: first-come-first-served by arrival at the admission queue, not strictly guaranteed across regions.

## 7. Expected Traffic Model
| Item | Value |
|------|-------|
| Normal traffic | 10,000 req/s |
| Flash peak at edge | up to 500,000 req/s (page views, polling, refresh storms, bots) |
| Buy Now attempts | 10,000 users within ~1–3 seconds for 100 units |
| Reserve success | 100 (exactly) |
| Out-of-stock responses | ~9,900 (mostly answered from a cache "sold-out" flag, never reaching DB) |
| Payments attempted | 100 (+ re-attempts for failed ones released back to stock) |
| Payment success / fail | 95% / 5% → ~95 confirmed, ~5 released and re-offered to waitlist |

Note: the 5 failed payments release units; these are re-offered to the **waitlist** (see HLD), so the sale can finish with exactly 100 sold.

## 8. Critical Dependencies
Payment gateway, primary DB (inventory authority), Redis (admission/stock counter), message broker, notification providers, courier APIs.

## 9. Strict Guarantees vs Targets
**Strict:** no oversell, no duplicate reservation/payment/order, no lost paid order, audit trail complete.
**Targets:** latencies, availability percentages, throughput numbers, 2 s freshness of displayed stock.

## 10. Success Criteria Mapping
| Criterion | How satisfied |
|-----------|---------------|
| Concurrency | Edge absorbs, virtual waiting room + token bucket admit a bounded flow; atomic stock gate |
| Inventory | Atomic conditional UPDATE at DB (`available_quantity >= n`) is the source of truth |
| Reservation | TTL + sweeper + DB-side expiry, release returns stock |
| Payment | Idempotency key + gateway reference + reconciliation job |
| Order | Transactional outbox + saga + reconciliation guarantee eventual order |
| Reliability | Circuit breaker, retries, DLQ, failover, degraded modes |
| Scalability | Stateless horizontal scaling, sharded Redis, CDN, partitioned queue |
