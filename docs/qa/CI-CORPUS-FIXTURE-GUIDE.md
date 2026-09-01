# Executed-fixture guide for the Customer Intelligence acceptance corpus

Written 2026-09-01 while building `db/tests/executed/v667_ci_access_boundaries.sql`. Every trap
below cost a red-herring debugging cycle; three of them produce a **test that passes for the
wrong reason**, which is worse than a failing one.

## The harness

`npm run test:db` → `scripts/db-tests/run.mjs`. It boots a throwaway Postgres 17, builds a
BASELINE from `tests/fixtures/db-schema-snapshot.sql` (watermark **v422**), runs every
`db/tests/executed/*.sql` against it, then applies migrations newer than the watermark and runs
them all again. Only files in `db/tests/executed/` are ever run. Anything under `db/tests/`
without `executed/` is read by nobody.

Name a file for the version whose behaviour it proves:

- **at or below v422** (e.g. `v106_…`) — must pass in BOTH phases. This is a regression floor.
- **above v422** (e.g. `v651_…`) — reported `n/a` in the baseline, gated on the migrated run.

Useful flags: `--filter=<substr>`, `--migrated-only`, `--keep`.

## Skeleton

```sql
\set ON_ERROR_STOP on
begin;
create temp table _fail(k text, v text) on commit drop;

do $vNNN$
declare
  biz uuid := '00000000-0000-4000-8000-0000000NNN01';
begin
  -- fixture, then assertions that INSERT INTO _fail on violation
end
$vNNN$;

select case when count(*)=0 then 'PASS — <what held>' else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'vNNN: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

rollback;
```

Two details that matter: the harness surfaces the **raised message**, not the `select` above, so
the failure detail has to travel with the exception. And qualify columns inside that block
(`f.k`, `f.v`) — a bare `v` collides with a PL/pgSQL variable and raises "column reference is
ambiguous".

## Impersonation

`auth.uid()` reads `request.jwt.claim.sub`, falling back to `request.jwt.claims->>'sub'`:

```sql
perform set_config('request.jwt.claims',
  json_build_object('sub', u_owner, 'role','authenticated')::text, true);
```

**A platform session needs more.** `nestly_v625` rewrote `app.is_super_admin()` to require a
Google SSO session, so a `super_admins` row alone is not enough:

```sql
perform set_config('request.jwt.claims', json_build_object(
    'sub', u_sa, 'role','authenticated',
    'amr', json_build_array(json_build_object('method','oauth')),
    'app_metadata', json_build_object('providers', json_build_array('google'))
  )::text, true);
```

Omit those claims and every platform-authority assertion fails for a **fixture** reason while
looking exactly like a product defect. This is the likely cause of most of the 15 failures in
`docs/qa/audit-artifacts/v667-suite-delta-2026-09-01.md`.

## Making a business genuinely operational

`app.is_salon_member` (v207) requires an **active, approved** staff row AND an open workspace,
and `app.business_operational_v620` resolves "open" through three separate tables. Miss any one
and every gate refuses for a billing or approval reason rather than the thing under test.

```sql
insert into public.businesses (id, name, slug, enabled_modules)
values (biz, 'ZZ fixture', 'zz-fixture', array['dashboard','clients','sales','reports']);

insert into public.staff (business_id, user_id, role, full_name, active, access_state)
values (biz, u_owner, 'owner', 'ZZ owner', true, 'approved');   -- access_state is required

insert into public.business_workspace_controls_v94
  (business_id, approval_status, decided_at, decision_reason)
values (biz, 'approved', now(), 'fixture')
  on conflict (business_id) do update set approval_status='approved';

insert into public.business_subscription_lifecycle_v94 (business_id, state, workspace_paused)
values (biz, 'current', false)
  on conflict (business_id) do update set state='current', workspace_paused=false;

insert into public.subscriptions (business_id, status, payment_status, current_period_end)
values (biz, 'active', 'paid', now() + interval '30 days')
  on conflict (business_id) do update set payment_status='paid';
```

`enabled_modules` must actually list the module a gate asks for — the v246 resolver reads it.

## Assigning a consultant

There is no column on `businesses`. `app.assigned_consultant_v94` reads through `sme_prospects`:

```sql
insert into public.platform_consultants (id, user_id, display_name, tier, employment_started_on, active)
values (cons, u_cons, 'ZZ consultant', 'senior', current_date - 400, true);
insert into public.sme_companies (id, legal_name, trading_name) values (co, 'ZZ Pte Ltd', 'ZZ');
insert into public.sme_prospects (company_id, legacy_stage_raw, assigned_consultant_id,
                                  ownership_state, queue_key,
                                  converted_business_id, converted_at, converted_by)
values (co, 'zz-fixture', cons, 'owned', null, biz, clock_timestamp(), u_sa);
```

Two check constraints bite: `sme_prospects_v510_ownership_shape` demands
`ownership_state='owned'` with a consultant and a NULL `queue_key`; and the conversion-shape
check demands all three `converted_*` fields together or none.

## Catalogue rows

`public.service_canonical_map` needs `version_no` (1) and a `method` from
`('suggested_confirmed','owner_chosen','console_corrected')`. Node keys must exist in
`public.taxonomy_nodes` at `version_no = 1`; select them rather than hardcoding.

## Write-guard GUCs

Several tables refuse a direct insert unless the writer identifies itself through a session
setting, so the guard trigger can tell an authorised route from an arbitrary one. Read the guard
trigger's source to find the setting name, then `set_config(..., true)` before the insert.

Known so far:

| Table | Setting |
|---|---|
| `public.clients` (acquisition path) | `app.first_acquired_via` |
| `public.customer_profiles` | `app.c42_profile_identity` |
| `public.customer_links` | `app.customer_link_insert_id` |

Add to this table when you find another, rather than working around the guard.

## The rule that matters most

**Assert your preconditions.** Before asserting that a role is refused, assert that the role
genuinely holds the access the refusal is supposed to be about:

```sql
if not app.can_module(biz,'reports') then
  insert into _fail values ('B1-pre','fixture owner lacks reports; the refusal proves nothing');
end if;
```

The v667 fixture passed its authorization assertion three times in a row while the fixture user
was not a member of the business at all. Only the precondition check revealed it. Every corpus
fixture that asserts a denial must also assert that the denial was earned.

## Predetermined truth tables

Write the expected numbers into a comment **before** running anything, and assert exact equality,
never `> 0`. The v667 fixture states its table inline:

```
Branch A1: 5 x 5000 = 25000.  Branch A2: 1 x 9000 = 9000.  Firm-wide 34000.
```

An assertion of `revenue > 0` would have passed against a branch filter that did nothing at all.
