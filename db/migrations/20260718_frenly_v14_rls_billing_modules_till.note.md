# v14 — super admin RLS · seat billing · module permissions · customer sign-up · phone till

Applied + verified 2260718. Authoritative SQL lives in `supabase_migrations.schema_migrations`
(project `kyzovonwnscrzmkvocid`) under these four names, applied in this order:

| # | migration | what |
|---|-----------|------|
| a | `frenly_v14a_superadmin_roles_phone` | super admin, role unification, phone normalisation |
| b | `frenly_v14b_billing_module_perms`   | subscriptions/seats, per-staff module permissions |
| c | `frenly_v14c_customer_signup_phone_till` | public join RPC, till lookup/confirm RPCs |
| d | `frenly_v14d_harden_search_path`     | pin `search_path` on the two v14 IMMUTABLE helpers |

---

## 1. Super admin — read-all, write-platform-only

Owner ruling 2026-07-18: super admin = **`leechuanseng.biz@gmail.com`**, scope =
**read every tenant, write only platform tables**.

- `public.super_admins (user_id PK → auth.users, email, note, created_at)`.
- `app.is_super_admin()` — SECURITY DEFINER, stable.
- **`super_admins` has a SELECT policy and NO write policy at all.** The table is
  unwritable through PostgREST by anybody, including a super admin. Promotion requires
  the service role / direct SQL. Deliberate: a stolen owner session must never be able
  to self-promote.
- 46 `<table>_sa_read` SELECT-only policies were generated across every table carrying a
  `business_id`, plus `businesses` (keys on `id`) and the 4 child tables that inherit
  tenancy through a parent (`appointment_services`, `bundle_items`, `service_products`,
  `stock_batches`).

**Why SELECT-only policies instead of widening `app.is_salon_member()`:** most tenant
tables use one `FOR ALL` policy whose `WITH CHECK` is `is_salon_member`. Adding a
separate *permissive* SELECT policy ORs in read access while leaving that `WITH CHECK`
untouched — which is `false` for a super admin who isn't staff. Hence read-all,
write-nothing, with no change to the existing policy surface.

> ⚖️ PDPA note: read-all across tenants is a real disclosure surface. It is defensible for
> platform support/billing, but access should be logged and justified. Not legal advice.

## 2. Role vocabulary — BUG FIX

`staff_invites.role` allowed `manager|receptionist|bookkeeper|staff` while `staff.role`
allowed `owner|manager|stylist|frontdesk`. `accept_invite()` inserts the invite's role
straight into `staff`, so **every invite except `manager` threw a check violation** —
employee onboarding was broken for 3 of the 4 offered roles and had been since v7.

Canonical set is now exactly: **`owner | manager | staff | frontdesk | bookkeeper`**.
`stylist` (salon-only — wrong for an industry-agnostic product with an F&B beachhead) and
`receptionist` are gone; rows were backfilled `stylist→staff`, `receptionist→frontdesk`.
`owner` is deliberately **not** invitable — ownership transfer must be explicit.
`app.role_perms()` keeps a legacy branch for both dead names so a stray row still resolves
sanely rather than silently losing all permissions.

## 3. Phone normalisation — the loyalty lookup key

`app.norm_phone(text)` → bare 8-digit SG number, else NULL. Accepts `81863833`,
`+6581863833`, `+65 8186 3833`, `65-8186-3833`. Prefixes `8`/`9` mobile, `6` fixed,
`3` VoIP. `clients.phone_norm` is a **STORED GENERATED** column over it, with a partial
unique index `(business_id, phone_norm) WHERE phone_norm IS NOT NULL` — one customer per
number per firm, while still allowing many phone-less walk-ins/CSV imports.

> Lock-in: `norm_phone` backs a generated column, so its signature/volatility can't change
> without dropping the column first. Body may be replaced (v14d did exactly that).

## 4. Seat billing — $25 firm + $10/employee SGD

`public.subscriptions` (business_id PK, status, currency, `base_price_cents=2500`,
`included_seats=1`, `per_seat_price_cents=1000`, trial/period stamps).
`public.v_business_billing` (security_invoker) computes `monthly_total_cents`.

**A seat = a staff row that can actually log in (`user_id IS NOT NULL`) and is `active`.**
v11a rota-only staff (roster entry, no account) consume no login and are **free**.
Deactivating a staff member frees the seat immediately.

RLS: members READ their own; **only a super admin can WRITE** — a firm must never be able
to set its own price. Verified: owner `UPDATE subscriptions SET base_price_cents=1` → 0 rows.

**No payment rail.** Stripe SG auto-charge stays deferred per CLAUDE.md. Billing is
computed and displayed, not collected, and there is deliberately **no hard seat cap**:
blocking an 11th invite when there is no way to pay would brick the pilot.

## 5. Module permissions — a real DB boundary, not UI hiding

- `staff.modules text[]` — `NULL` = inherit (sees everything the firm enabled);
  an array = explicit allowlist. **Owners always bypass.**
- `public.module_templates (business_id, name, modules[])`, unique per `(business_id,name)`.
- `app.can_module(business, module)` / `app.staff_modules(business)` / RPC `get_my_modules`.
- RPCs: `set_staff_modules`, `save_module_template`, `apply_module_template` (owner-gated;
  `set_staff_modules` refuses to restrict an owner).

**Enforced in RLS**, not just the nav, on the person-scoped tables: `clients`,
`appointments`, `products`, `stock_batches`. So an inventory-only employee calling
`/rest/v1/clients` directly gets **zero rows**, not the customer list. `can_module()`
implies staff membership + `active`, so it strictly subsumes the `is_salon_member()` test
it replaced (and additionally cuts off deactivated staff, which is correct).

`can_module()` deliberately does **not** test `businesses.enabled_modules`: that is a
packaging/nav concept, and switching a module off in Settings must never strand the
underlying rows. Firm-level gating = nav; person-level gating = `can_module`.

Modules NOT yet RLS-gated (UI-level only): sales, loyalty, retention, referrals,
memberships, giftcards, packages, reports, finance. `sales`/`payments`/finance already
have their own `has_perm()` role gates, which are the stronger control there.

## 6. Customer self-sign-up (QR + link)

- `businesses.join_enabled boolean default true`.
- `public.get_join_page(slug)` → `{name, brand_color, slug}` — name + colour only, nothing
  scrapeable.
- `public.join_program(slug, name, phone, email, consent)` — **granted to `anon`**.
  Writes a `consents` row (`granted`/`withdrawn`, source `self_signup`) + an audit row.

**Returns a uniform `{status:'ok'}` whether the number was new or already a member.**
Any difference would turn the form into an oracle for "is 8xxxxxxx a customer of this
shop" — the exact PDPA leak we must not ship. Dedup is handled by the partial unique
index via `ON CONFLICT DO NOTHING`.

Public page: `app/join.html?s=<slug>`.

> ⚖️ Residual risk: `join_program` is unauthenticated with **no rate limiting**. A script
> could mass-insert junk customers into any firm with a known slug. Mitigate before scale
> with a captcha/Turnstile or an edge rate limit. Owner can kill it via `join_enabled`.

## 7. Phone till — "type 8 digits, press Confirm"

- `public.lookup_client_by_phone(business, phone)` → `found` (name, points, credit, visits,
  `can_redeem`, `points_to_next`) / `not_found` / `invalid`. Gated on `create_sales`.
- `public.record_sale_by_phone(business, phone, amount_cents, kind, note, staff, idem)`.
- `public.quick_add_client(business, phone, name, consent)` — gated on the `clients` module.

`sales.idem_key` + partial unique `(business_id, idem_key)`. Replaying a key returns the
original sale as `duplicate_ignored` and earns nothing further — satisfies CLAUDE.md's
"idempotency on earn; prevent double earn". Correctly covers the nasty case: a network
timeout where the server committed but the client saw an error — retry with the same key
returns the original instead of double-earning.

`record_sale_by_phone` inserts exactly one `sales` row and **touches no ledger itself** —
the v10 policy triggers decide revenue/visit/points and `on_sale_recorded` does the
earning. This preserves CLAUDE.md's first principle: completion is the signal, modules
subscribe, none writes the ledger directly.

## Verification (rolled-back chain tests, run by Fable)

25 assertions across 3 transactions, all rolled back. **All pass.**

Super admin: reads 3/3 businesses, 7/7 clients, 9/9 sales · INSERT into another tenant's
`clients` → 42501 · UPDATE another tenant's clients → 0 rows · INSERT another tenant's
`credit_ledger` → 42501 · UPDATE `subscriptions` → 1 row ✅ · self-promote → 42501.
Isolation: normal owner sees 0 other-tenant clients, 1 business, cannot set own price.
Modules: inventory-only staff → 0 customers / products visible / customer INSERT 42501;
dashboard+customers staff → 4 customers / 0 products; owner bypasses.
Billing: $25 → $45 (2 employees) → rota staff free → $35 on deactivate.
Invites: `staff` invite created + **accepted** (previously threw) + auto-tagged.
Sign-up: anon joins, dedupes to 1 row, rejects bad number + unknown slug; anon reads 0 rows
from every table.
Till: `81863833` and `+65 8186 3833` both resolve to Lee Chuan Seng; $5 → 5 points;
double-tap → `duplicate_ignored`, +1 sale only; outsider → denied.

Supabase security advisor after v14: **0 ERROR**. The two `function_search_path_mutable`
WARNs v14 introduced were fixed in v14d.

## Pre-existing issues surfaced, NOT fixed (need an owner call)

1. **`businesses.salons_insert` is `WITH CHECK (true)`** — any authenticated user can
   INSERT a business row directly, bypassing `create_business()` (so: no owner staff row,
   no branch, no loyalty program, no subscription). Orphan-tenant + billing-evasion vector.
2. **Leaked-password protection is disabled** in Supabase Auth. One toggle in the
   dashboard; enable it.
3. `subscriptions_select` allows any *member* (not just owner) to read the firm's billing.
   Minor; flag if staff shouldn't see what the boss pays.
4. `sell_package` still books revenue upfront + earns points on the full package price
   (v10 killed only the phantom 11th visit). Unchanged — still an open owner decision.
