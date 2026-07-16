# Frenly — loyalty & retention SaaS for any business

Multi-tenant SaaS: each business signs up, picks an industry (F&B, salon, facial,
massage, fitness, retail...), gets the right modules auto-selected, and runs
loyalty points, visit-frequency retention promos, bookings, and analytics.
Rewards are real spendable in-store credit — not vanity points.

- `app/` — the web app (static SPA, Supabase-backed, deployed on Vercel)
- `db/` — Supabase schema migrations + notes
- `docs/benchmark/` — Flowesce benchmark discovery (Phase 0)
- `CLAUDE.md` — project memory / instructions

Tenancy: one database, hard tenant isolation via Postgres RLS on every table.
