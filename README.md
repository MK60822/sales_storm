# SALESTORM – System Design Submission (SYSCRAFTERS 2026)

**Challenge:** 10,000 concurrent purchase requests for 100 units, no overselling, reliable payment and order processing.
**Approach:** design-first blueprint. Contention is controlled at one point (atomic conditional UPDATE on the inventory row), shielded by CDN/WAF, rate limiting, a waiting room and a Redis stock gate. Everything after payment is asynchronous (transactional outbox + Kafka + idempotent consumers) with reconciliation as a safety net.

## Folder Map (mapped to the 21 deliverables)
| # | Deliverable | File |
|---|-------------|------|
| 1 | Requirements & Assumptions | `01_Requirements/Requirements_and_Assumptions.md` |
| 2 | System Context Diagram | `02_HLD/01_System_Context_Diagram.md` |
| 3 | HLD Architecture | `02_HLD/02_HLD_Architecture.md` |
| 4 | Container Diagram | `02_HLD/03_Container_Diagram.md` |
| 5 | Component Diagram | `02_HLD/04_Component_Diagram.md` |
| 6 | Deployment Diagram | `02_HLD/05_Deployment_Diagram.md` |
| 7 | Database / ER Diagram | `04_Database/01_ER_Diagram.md`, `03_schema.sql`; concurrency in `02_Concurrency_and_Transactions.md` |
| 8 | Class Diagram | `03_LLD/01_Class_Diagram.md` |
| 9 | Purchase / Reservation Sequence | `03_LLD/02_Sequence_Purchase_Reservation.md` |
| 10 | Payment Sequence | `03_LLD/03_Sequence_Payment.md` |
| 11 | Order Sequence (+ recovery) | `03_LLD/04_Sequence_Order_and_Recovery.md` |
| 12 | Order / Reservation State Diagram | `03_LLD/05_State_Diagrams.md` |
| 13 | SOLID Mapping | `06_SOLID/SOLID_Mapping.md` |
| 14 | Design Pattern Mapping | `07_Design_Patterns/Design_Pattern_Mapping.md` |
| 15 | API Specification (+ events) | `05_API/01_API_Specification.md`, `02_Event_Design.md` |
| 16 | Scalability & Reliability | `08_Scalability_Reliability/Scalability_and_Reliability_Design.md` |
| 17 | Security & Observability | `09_Security_Observability/Security_and_Observability_Design.md` |
| 18 | ADR | `10_ADR/Architecture_Decision_Records.md` |
| 21 | Final Presentation | `12_Presentation/SALESTORM_Pitch.pptx`, `Pitch_Script_5min.md` |

Optional items (AI-assisted prototype/simulation, folder `11_AI_Assisted_Validation`) were intentionally not included.

## How to view the diagrams
All diagrams are Mermaid code blocks inside the Markdown files. They render on GitHub/GitLab, in VS Code (Markdown Preview Mermaid Support), or by pasting into https://mermaid.live. Export to PNG/SVG if the jury needs images.

## Key Design Decisions (one line each)
1. SQL as inventory source of truth; atomic `UPDATE ... WHERE available_quantity >= q` plus CHECK constraints.
2. Redis Lua stock gate and a waiting room reduce DB contention to ≈100 writes; Redis is never authoritative.
3. Reservation with TTL (RESERVED → PAYMENT_PENDING → CONFIRMED → SOLD, or RELEASED); paid reservations never expire.
4. Idempotency at every boundary (client key, DB unique constraints, gateway merchant_ref, consumer dedupe).
5. Saga + transactional outbox; payment timeout = unknown state resolved by reconciliation.
6. Circuit breaker, retries, DLQ, reconciliation jobs for failure recovery.

## Assumptions to confirm before the pitch
- Reservation TTL 10 minutes; one unit per customer per sale; refund-by-default for payments arriving after release (ADR-013).
- Team name, tool/vendor names (Razorpay/Stripe, Kafka, PostgreSQL, Redis) are examples; the design is vendor-neutral.
- Throughput numbers (e.g. admission 1,000–2,000 req/s, breaker thresholds) are reasoned starting values, not measured results.

## AI Usage Note
Claude (Anthropic) was used to draft the documents, diagrams and slide deck from the hackathon brief. No code was generated or executed as validation evidence; the SQL schema is a reference design and has not been run against a database. The team must review, understand and be able to defend every artefact (per the brief's ownership rule).
