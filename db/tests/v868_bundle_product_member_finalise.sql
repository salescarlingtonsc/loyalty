-- nestly_v868 rollback suite — a bundle containing a product can actually be sold.
--
-- Asserts every claim nestly_v868 makes, against an applied database, inside a transaction that
-- is ROLLED BACK. Nothing is left behind, and nothing is written: the guard under test is a pure
-- predicate, so the suite lifts it OUT of the shipped record_cart_sale/11 body and evaluates that
-- exact text over app.ps1c_bundle_lines_v204's real output. It tests what shipped, not a retyped
-- copy of it — a no-op guard would fail section B, and a guard that never fires would fail C.
--
--   supabase db query --linked -f db/tests/v837_bundle_product_member_finalise.sql
--
-- Run with the migration prepended and its trailing `commit;` stripped (and this file's leading
-- `begin;` stripped) to prove the assertions PASS after; run alone against the pre-v868 database
-- to prove they FAIL before — A4 answers "raises stale_evaluation" for member 5 of AhXiang's
-- bundle (SK-II Facial Treatment Clear Lotion, 14,862c of a 500,000c bundle) with nothing
-- drifted at all. That is the whole defect: the till could price that bundle and never record it.
-- The behavioural assertions deliberately come first, so the pre-v868 failure is a behaviour,
-- not a missing comment.
--
-- The tenant is AhXiang (33773caa-6d51-4cf2-9ad6-b83f015759e6), read ONLY — the suite selects
-- their live bundle and never writes a row anywhere.

begin;

-- Lift the bundle drift-guard condition out of the shipped finaliser and answer: would this
-- member, at this position, raise stale_evaluation? Lives in pg_temp so the rollback takes it.
create function pg_temp.v837_guard_raises(p_bline jsonb, p_cid uuid, p_kind text)
returns boolean
language plpgsql
as $f$
declare
  v_src text;
  v_cond text;
  v_expr text;
  v_raises boolean;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'record_cart_sale' and p.pronargs = 11;
  if position('if v257_bline is null' in v_src) = 0 then
    raise exception 'v868 suite: the bundle drift guard is not where this suite expects it';
  end if;
  v_cond := substring(v_src from position('if v257_bline is null' in v_src) + 3);
  v_cond := left(v_cond, position(' then' in v_cond) - 1);
  -- Bind the three finaliser locals the condition reads, as literals.
  v_expr := v_cond;
  v_expr := replace(v_expr, 'v257_bline', coalesce(quote_literal(p_bline::text) || '::jsonb', 'null::jsonb'));
  v_expr := replace(v_expr, 'v_cid',      coalesce(quote_literal(p_cid::text)   || '::uuid',  'null::uuid'));
  v_expr := replace(v_expr, 'v_kind',     coalesce(quote_literal(p_kind)        || '::text',  'null::text'));
  execute 'select (' || v_expr || ')' into v_raises;
  return v_raises;
end
$f$;

do $suite$
declare
  c_biz    constant uuid := '33773caa-6d51-4cf2-9ad6-b83f015759e6';  -- AhXiang
  c_bundle constant uuid := '9d0646d1-f669-4db0-9709-c5d0482b926d';  -- Package x5 facial + treatment
  c_prod   constant uuid := 'c85f5479-f35e-49a9-84cc-7de018978aa2';  -- SK-II Facial Treatment Clear Lotion
  v_src    text;
  v_j      jsonb;
  v_bline  jsonb;
  v_cid    uuid;
  v_kind   text;
  v_int    integer;
  v_txt    text;
  v_bool   boolean;
  v_acl    text;
  r        record;
  n        integer := 0;

begin
  ---------------------------------------------------------------- A. the AhXiang defect
  -- app.ps1c_bundle_lines_v204 is NOT changed by v868: it already emits a product member as
  -- kind='product' / item_id=<product id> / service_id=null. Prove that first, then prove the
  -- finaliser's guard now agrees with it.
  v_j := app.ps1c_bundle_lines_v204(c_biz, c_bundle, 1);

  n := n + 1;
  if v_j->>'status' is distinct from 'ok' then
    raise exception 'A%: AhXiang''s bundle no longer prices (%) — the fixture is gone', n, v_j->>'status';
  end if;

  n := n + 1;
  select count(*)::int into v_int from jsonb_array_elements(v_j->'lines') e where e->>'kind' = 'product';
  if v_int <> 1 then
    raise exception 'A%: the bundle expands to % product members, expected exactly 1', n, v_int;
  end if;

  n := n + 1;   -- the allocation is exhaustive: the members sum to the bundle price
  select sum((e->>'line_cents')::int)::int into v_int from jsonb_array_elements(v_j->'lines') e;
  if v_int is distinct from (v_j->>'total_cents')::int or v_int is distinct from 500000 then
    raise exception 'A%: the members sum to %c, expected the 500000c bundle total', n, v_int;
  end if;

  n := n + 1;   -- EVERY member, in its own position, must now finalise
  for r in
    select ordinality as pos, e from jsonb_array_elements(v_j->'lines') with ordinality t(e, ordinality)
    order by ordinality
  loop
    -- exactly what app.ps1c_plan_checkout wrote into checkout_evaluations.server_lines
    v_kind  := coalesce(r.e->>'kind', 'service');
    v_cid   := coalesce(nullif(r.e->>'item_id', ''), r.e->>'service_id')::uuid;
    v_bline := v_j->'lines'->(r.pos::int - 1);
    if pg_temp.v837_guard_raises(v_bline, v_cid, v_kind) then
      raise exception 'A%: member % (% %) raises stale_evaluation with nothing drifted — the bundle cannot be sold',
        n, r.pos, v_kind, coalesce(r.e->>'name', '?');
    end if;
  end loop;

  n := n + 1;   -- and name the defect: the old one-field predicate raised on that product member
  select e into v_bline from jsonb_array_elements(v_j->'lines') e where e->>'item_id' = c_prod::text;
  if v_bline is null then
    raise exception 'A%: the SK-II product member is no longer in AhXiang''s bundle', n;
  end if;
  if not (nullif(v_bline->>'service_id', '')::uuid is distinct from c_prod) then
    raise exception 'A%: the pre-v868 predicate no longer reproduces — service_id is populated for a product member', n;
  end if;
  if (v_bline->>'line_cents')::int <> 14862 then
    raise exception 'A%: the SK-II member allocates %c, expected 14862c', n, (v_bline->>'line_cents')::int;
  end if;

  ---------------------------------------------------------------- B. drift must STILL raise
  -- Same real member, perturbed the way genuine drift would perturb it. The guard is the shipped
  -- one, lifted out of the function body — a guard relaxed into a no-op fails every one of these.
  n := n + 1;   -- a swapped member
  if not pg_temp.v837_guard_raises(v_bline, '00000000-0000-0000-0000-0000000000ff'::uuid, 'product') then
    raise exception 'B%: a swapped bundle member no longer raises stale_evaluation', n;
  end if;

  n := n + 1;   -- a kind flip at the same position (the old check could only catch this by luck)
  if not pg_temp.v837_guard_raises(v_bline, c_prod, 'service') then
    raise exception 'B%: a bundle member whose kind changed no longer raises stale_evaluation', n;
  end if;

  n := n + 1;   -- a removed member: the position no longer exists
  if not pg_temp.v837_guard_raises(v_j->'lines'->99, c_prod, 'product') then
    raise exception 'B%: a removed bundle member no longer raises stale_evaluation', n;
  end if;

  n := n + 1;   -- a re-ordered bundle: member 1 now sits where the token expects member 5
  if not pg_temp.v837_guard_raises(v_j->'lines'->0, c_prod, 'product') then
    raise exception 'B%: a re-ordered bundle no longer raises stale_evaluation', n;
  end if;

  ---------------------------------------------------------------- C. price drift stays hashed
  -- v868 does not touch the cart re-hash, and must not: that is where a moved price is caught.
  n := n + 1;
  select app.ps1c_cart_hash(jsonb_agg(jsonb_build_object(
           'catalog_kind', coalesce(e->>'kind', 'service'),
           'catalog_id', coalesce(nullif(e->>'item_id', ''), e->>'service_id'),
           'qty', 1, 'unit_price_cents', (e->>'line_cents')::int,
           'line_total_cents', (e->>'line_cents')::int) order by ord))
       is distinct from
       app.ps1c_cart_hash(jsonb_agg(jsonb_build_object(
           'catalog_kind', coalesce(e->>'kind', 'service'),
           'catalog_id', coalesce(nullif(e->>'item_id', ''), e->>'service_id'),
           'qty', 1, 'unit_price_cents', (e->>'line_cents')::int + case when ord = 5 then 100 else 0 end,
           'line_total_cents', (e->>'line_cents')::int + case when ord = 5 then 100 else 0 end) order by ord))
    into v_bool
    from jsonb_array_elements(v_j->'lines') with ordinality t(e, ord);
  if not coalesce(v_bool, false) then
    raise exception 'C%: a moved bundle-member price no longer changes the cart hash', n;
  end if;

  ---------------------------------------------------------------- D. the service-only bundles
  n := n + 1;   -- nothing that worked before v868 may have changed
  for r in
    select b.id, b.business_id, b.name from public.bundles b
     where b.active
       and not exists (select 1 from public.bundle_items bi
                        where bi.bundle_id = b.id and bi.product_id is not null)
  loop
    v_j := app.ps1c_bundle_lines_v204(r.business_id, r.id, 1);
    if v_j->>'status' <> 'ok' then continue; end if;
    for v_bline in select e from jsonb_array_elements(v_j->'lines') e loop
      if pg_temp.v837_guard_raises(v_bline,
           coalesce(nullif(v_bline->>'item_id', ''), v_bline->>'service_id')::uuid,
           coalesce(v_bline->>'kind', 'service')) then
        raise exception 'D%: service-only bundle "%" now raises stale_evaluation; v868 regressed it', n, r.name;
      end if;
    end loop;
  end loop;

  ---------------------------------------------------------------- E. shape
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname = 'record_cart_sale' and p.pronargs = 11;

  n := n + 1;
  if position('nestly_v868' in v_src) = 0 then
    raise exception 'E%: record_cart_sale/11 does not carry the v868 bundle member-identity guard', n;
  end if;

  n := n + 1;
  if position('nullif(v257_bline->>''service_id'', '''')::uuid is distinct from v_cid' in v_src) > 0 then
    raise exception 'E%: the service_id-only bundle guard is still present in record_cart_sale/11', n;
  end if;

  n := n + 1;   -- the guard must stay position-sensitive, and price drift must stay hashed
  if position('v257_pos := v257_pos + 1;' in v_src) = 0
     or position('v_rehash := app.ps1c_cart_hash(v_reproj);' in v_src) = 0 then
    raise exception 'E%: the position cursor or the cart re-hash went missing from record_cart_sale/11', n;
  end if;

  n := n + 1;   -- the unit price still comes from the FRESHLY priced bundle line, never the token
  if position('v_unit := (v257_bline->>''line_cents'')::int;' in v_src) = 0 then
    raise exception 'E%: record_cart_sale/11 no longer re-prices a bundle member from line_cents', n;
  end if;

  n := n + 1;   -- the 7-arg overload is the pre-kernel path: no token, no bundles, no defect
  select pg_get_functiondef(p.oid) into v_txt
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname = 'record_cart_sale' and p.pronargs = 7;
  if v_txt is null then
    raise exception 'E%: record_cart_sale/7 not found', n;
  end if;
  if position('bundle' in v_txt) > 0 then
    raise exception 'E%: record_cart_sale/7 now handles bundles and was not carried through v868', n;
  end if;

  ---------------------------------------------------------------- F. the grant is unchanged
  n := n + 1;
  select p.proacl::text into v_acl from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname = 'record_cart_sale' and p.pronargs = 11;
  if v_acl not like '%authenticated=X%' or v_acl not like '%service_role=X%' or v_acl like '%anon=X%' then
    raise exception 'F%: record_cart_sale/11 now grants %, expected authenticated + service_role only', n, v_acl;
  end if;

  raise notice 'nestly_v868: % / % assertions passed', n, n;
end
$suite$;

rollback;
