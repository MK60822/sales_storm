# 5-Minute Pitch Script (matches SALESTORM_Pitch.pptx; speaker notes are also in the deck)

| Time | Slide | Say |
|------|-------|-----|
| 0:00–0:30 | 1–2 Problem + Requirements | A flash sale: 100 units, 10,000 simultaneous buyers. Strict guarantees: no oversell, no duplicate reservation/payment/order, no lost paid order. Latency and availability are targets. |
| 0:30–1:00 | 2 Requirements | Non-functional numbers: 10k req/s normal, 500k req/s flash envelope, reserve p99 < 800 ms, RPO 0 for inventory/payment/order. |
| 1:00–2:00 | 3 HLD | Funnel: CDN/WAF → gateway → waiting room → Redis gate → one atomic DB update. Reserve is sync; payment→order→shipment→notification is async via outbox + Kafka. Services stateless, database-per-service. |
| 2:00–3:00 | 4–5 Critical design | Six steps; last-unit race resolved by row lock + `WHERE available >= 1`; CHECK constraints as final guard; reservation states and TTL expiry; why not FOR UPDATE or optimistic CAS. |
| 3:00–3:45 | 6 Payment & Order | Success / failure / timeout (reconcile, same merchant_ref) / Order outage (Kafka retains, redelivery, recovery job, DLQ, compensation). |
| 3:45–4:30 | 7 LLD + SOLID + Patterns | Payment module: PaymentService → PaymentProvider interface; Factory, Adapter, Decorator + circuit breaker; State, Observer, Saga, Outbox. New provider = new adapter only. |
| 4:30–5:00 | 8–10 Scale, reliability, trade-offs | 50×: CDN absorbs, admission control caps load, DB load unchanged. DB/gateway/Redis failure paths. Trade-offs: queue wait, eventual consistency, ops complexity. |

## Answer to the final jury question
"100 units left, 10,000 clicking Buy Now: walk us through it."
1. Edge/WAF absorb page traffic and bots; gateway authenticates, rate-limits and requires an Idempotency-Key.
2. The waiting room admits a bounded flow to Inventory.
3. Duplicates (≈2%) return the stored result.
4. Redis Lua gate: first 100 get a token; ≈9,900 get `OUT_OF_STOCK` without touching the DB.
5. One DB transaction: conditional UPDATE + reservation INSERT + outbox INSERT. Zero rows updated means out of stock.
6. Winners pay (≈95 succeed): webhook → PaymentSucceeded → reservation CONFIRMED, order created (idempotent on reservation_id), then SOLD, shipment, notification.
7. ≈5 payment failures: reservation released, stock +1, units re-offered to the waitlist, so the sale finishes at exactly 100 sold, never more.
8. If Order Service is down 30 s: events wait in Kafka; paid reservations never expire; orders are created on recovery.

## Likely jury questions (short answers)
- **Where is consistency guaranteed?** The `inventory` row in the Inventory DB via an atomic conditional UPDATE plus CHECK constraints.
- **Two requests at once?** Row lock serialises; second re-checks `available >= 1`, fails, gets OUT_OF_STOCK.
- **Why sync reserve, async order?** Customer needs an immediate deterministic answer; downstream work must survive outages.
- **Payment success then order failure?** Outbox + retention + redelivery + recovery job + DLQ; refund + release only if impossible.
- **Bottleneck?** Hot inventory row; protected by funnel; stock bucketing if thousands of units.
