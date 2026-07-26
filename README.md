# Nestly — customer growth and operations SaaS

Multi-tenant SaaS: each business signs up, picks an industry (F&B, salon, facial,
massage, fitness, retail...), gets the right modules auto-selected, and runs
Nestly connects business operations, customer relationships, loyalty, bookings,
billing, and growth intelligence in one installable web app.
Rewards are real spendable in-store credit — not vanity points.

- `app/` — the web app (static SPA, Supabase-backed, deployed on Vercel)
- `db/` — Supabase schema migrations + notes
- `docs/benchmark/` — Flowesce benchmark discovery (Phase 0)
- `CLAUDE.md` — project memory / instructions

Tenancy: one database, hard tenant isolation via Postgres RLS on every table.
