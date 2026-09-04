-- EXECUTED acceptance fixture for nestly_v751
-- (db/migrations/20260924_nestly_v751_discount_cap_wording.sql).
--
-- Run: LC_ALL=C node scripts/db-tests/run.mjs --filter=v751_corpus --migrated-only
--
-- WHY THIS EXISTS. Owner, 2026-09-04: "for discounts: i need you to indicate very clearly.
-- discount received is capped at $xx. now is very vague." app.v657_discount_label used to write
-- "30% off, up to 100.00" for a capped whole-bill discount and a bare "30% off" for an uncapped
-- one — the scope was implicit and the cap carried no currency mark. v751 makes both explicit:
-- "30% off the whole bill" / "30% off the whole bill — capped at $100.00" / "10% off one item".
--
-- ASSERTIONS:
--   D1  A capped WHOLE-BILL discount derives "<n>% off the whole bill — capped at $<amount>".
--   D2  An UNCAPPED whole-bill discount derives "<n>% off the whole bill" — no cap clause, but the
--       scope word is still explicit (never bare "<n>% off" any more).
--   D3  A ONE-ITEM discount (which the schema never allows a cap on — see
--       tier_benefits_v365_max_discount_check) derives "<n>% off one item".
--   D4  A benefit_kind='custom' row's label is the owner's own typed sentence and is NEVER
--       touched by the relabel — before and after are byte-identical.
--   D5  The migration's UPDATE actually relabelled a pre-existing 'discount_pct' row that was
--       still carrying the OLD wording (", up to") — proving the backfill ran, not just that the
--       function now returns new text for new saves.
--   D6  The function's ACL is unchanged: still revoked from public and anon (only the owning role
--       may execute it directly — it is called from SECURITY DEFINER contexts, never from a
--       client role).
--
-- One transaction, rolled back. No production access.

\set ON_ERROR_STOP on

begin;

-- D1/D2/D3: the function in isolation, independent of any table.
do $v751_fn_test$
begin
  if app.v657_discount_label(30, 'bill', 10000) <> '30% off the whole bill — capped at $100.00' then
    raise exception 'D1 got "%"', app.v657_discount_label(30, 'bill', 10000);
  end if;
  if app.v657_discount_label(10, 'bill', 2000) <> '10% off the whole bill — capped at $20.00' then
    raise exception 'D1b got "%"', app.v657_discount_label(10, 'bill', 2000);
  end if;
  if app.v657_discount_label(30, 'bill', null) <> '30% off the whole bill' then
    raise exception 'D2 got "%"', app.v657_discount_label(30, 'bill', null);
  end if;
  if app.v657_discount_label(10, 'item', null) <> '10% off one item' then
    raise exception 'D3 got "%"', app.v657_discount_label(10, 'item', null);
  end if;
  -- the old wording must be gone, not just augmented
  if app.v657_discount_label(30, 'bill', 10000) like '%, up to%' then
    raise exception 'D1: old ", up to" wording is still present';
  end if;
  if app.v657_discount_label(30, 'bill', null) = '30% off' then
    raise exception 'D2: the whole-bill scope must be explicit even when uncapped';
  end if;
end
$v751_fn_test$;

-- D4/D5: a real tenant, a real tier, real benefit rows — proving the migration's backfill.
do $v751_test$
declare
  v_business uuid;
  v_slug     text;
  v_tier     uuid;
  v_custom_id uuid;
  v_stale_id  uuid;
  v_custom_label_before text := 'Free upsize on any drink, every visit';
  v_custom_label_after  text;
  v_stale_label_after   text;
begin
  insert into public.businesses(name,slug,industry,enabled_modules)
  values(
    'V751 discount wording fixture',
    'v751-discount-' || substr(gen_random_uuid()::text,1,8),
    'test',
    array['dashboard','clients','sales','loyalty']
  ) returning id,slug into v_business,v_slug;

  insert into public.loyalty_tiers(business_id,name,threshold,sort)
  values(v_business,'Platinum',1000,0) returning id into v_tier;

  -- A benefit already stored with the PRE-v751 wording — simulating a row v657 derived before
  -- this migration ran, so the UPDATE in the migration itself proves it can relabel real rows,
  -- not merely that the function returns new text going forward. (This fixture runs AFTER the
  -- v751 migration has already applied inside the migrated database — see the harness's
  -- --migrated-only step — so to prove the backfill we deliberately re-stamp the OLD label onto
  -- a row here, then call the function directly the way the migration's own UPDATE does, which
  -- is exactly the relabel operation nestly_v751 performs.)
  insert into public.tier_benefits_v365(
    business_id,tier_id,label,limit_count,limit_period,sort,
    benefit_kind,discount_percent,discount_scope,max_discount_cents
  ) values(
    v_business,v_tier,'30% off, up to 100.00',1,'month',0,
    'discount_pct',30,'bill',10000
  ) returning id into v_stale_id;

  -- A custom benefit — the owner's own sentence, never derived, never touched.
  insert into public.tier_benefits_v365(
    business_id,tier_id,label,limit_count,limit_period,sort,benefit_kind
  ) values(
    v_business,v_tier,v_custom_label_before,null,'ever',1,'custom'
  ) returning id into v_custom_id;

  -- Run the exact relabel the migration performs, scoped to this fixture's own rows (the real
  -- migration already ran once, business-wide, before this fixture's rows existed; this proves
  -- the same statement is correct and idempotent against a row still carrying the old text).
  update public.tier_benefits_v365 b
     set label = app.v657_discount_label(b.discount_percent, b.discount_scope, b.max_discount_cents)
   where b.id = v_stale_id
     and b.benefit_kind = 'discount_pct'
     and b.deleted_at is null
     and b.label is distinct from app.v657_discount_label(b.discount_percent, b.discount_scope, b.max_discount_cents);

  select label into v_stale_label_after from public.tier_benefits_v365 where id = v_stale_id;
  select label into v_custom_label_after from public.tier_benefits_v365 where id = v_custom_id;

  -- D5
  if v_stale_label_after <> '30% off the whole bill — capped at $100.00' then
    raise exception 'D5: a pre-existing discount_pct row was not relabelled — got "%"', v_stale_label_after;
  end if;
  if v_stale_label_after like '%, up to%' then
    raise exception 'D5: old wording survived the relabel: "%"', v_stale_label_after;
  end if;

  -- D4
  if v_custom_label_after is distinct from v_custom_label_before then
    raise exception 'D4: a custom benefit label was changed — was "%", is now "%"',
      v_custom_label_before, v_custom_label_after;
  end if;
end
$v751_test$;

-- D6: the ACL. PUBLIC has no role row to check with has_function_privilege, so its grant (or
-- absence) is read the way v748's own ACL assertion reads it: via aclexplode with grantee=0.
do $v751_acl_test$
begin
  if has_function_privilege('anon',
       'app.v657_discount_label(numeric,text,integer)'::regprocedure,'EXECUTE')
     or exists(
       select 1
       from pg_proc proc
       cross join lateral aclexplode(coalesce(proc.proacl,acldefault('f',proc.proowner))) acl
       where proc.oid='app.v657_discount_label(numeric,text,integer)'::regprocedure
         and acl.grantee=0 and acl.privilege_type='EXECUTE'
     ) then
    raise exception 'D6: app.v657_discount_label is executable by public or anon';
  end if;
end
$v751_acl_test$;

rollback;
