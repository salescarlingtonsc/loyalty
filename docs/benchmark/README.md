# Avocado — Benchmark Discovery (Flowesce)

This folder is the point-in-time discovery record from benchmarking **Flowesce**
(`app.flowesce.com`) to inform **Avocado**, our Singapore-first loyalty platform.

> Naming note: the product has been referred to as both **Frenly** (marketing site)
> and **Avocado** (the loyalty app/product). These docs use **Avocado = the loyalty
> product** (Supabase backend `kyzovonwnscrzmkvocid`) and **Frenly = the marketing
> site**. Confirm/rename — see `OPEN_QUESTIONS.md`.

## What Flowesce actually is (read this first)
Flowesce is **not** a standalone loyalty platform. It is a full **salon operating
system** (booking, calendar, inventory, POS, memberships, reports) in which
**loyalty is one module** under a "Catalog" group. We are benchmarking its
**retention pillar** — Loyalty, Memberships, Referrals, Reviews — and the shared
**in-store credit ledger** that unifies them. Avocado is a *dedicated, multi-tenant,
multi-industry loyalty platform*, so we reuse Flowesce's **loyalty logic and
automations**, not its salon-specific surface area.

## Reading order
1. `EXECUTIVE_SUMMARY.md` — management summary + top-10 priorities/opportunities/risks
2. `REVIEW_LOG.md` — how the review was done, what was reachable vs locked
3. `MODULE_INVENTORY.md` — every module, purpose, I/O, dependencies
4. `PAGE_INVENTORY.md` — routes/pages observed
5. `MODULE_RELATIONSHIP_MAP.md` — relationship table + Mermaid flow
6. `DATA_ENTITY_MAP.md` — entities + mapping to our Supabase schema
7. `EFFICIENCY_AUTOMATION_AUDIT.md` — the automations to reproduce (the real value)
8. `ROLE_PERMISSION_MATRIX.md` — roles observed + Avocado target RBAC
9. `AVOCADO_GAP_ANALYSIS.md` — Flowesce vs Avocado, gaps classified
10. `AVOCADO_REUSE_MATRIX.md` — reuse/refactor/build decisions
11. `SINGAPORE_PRODUCT_STRATEGY.md` — beachhead, pricing, GTM
12. `IMPLEMENTATION_ROADMAP.md` — phased plan
13. `OPEN_QUESTIONS.md` — unresolved items and things needing your input

## Evidence base
- **Live console walk** of `app.flowesce.com` (own trial tenant, Singapore, empty of data; loyalty/memberships/team modules gated behind the paid "Growth" tier).
- **Public feature pages** (`flowesce.com/features/*`) — primary source for loyalty, membership, referral mechanics (the paid config screens were not opened, to avoid changing billing).
- **Prior marketing-site audit** (`Flowesce_Product_Audit.docx`, in the loyalty folder).

## Status
Phase 0 (discovery) — core evidence-based docs complete. Strategy/roadmap docs are
first-draft and need your business input (pricing intent, target vertical, funding
model). No Avocado application code has been changed based on this yet.
