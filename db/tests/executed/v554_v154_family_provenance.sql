-- EXECUTED golden fixture for nestly_v554 — the v154 family exists in a rebuilt database and
-- its runtime-resolved call chain works (TRUTH-003).
--
-- WHY. Production carries five EXECUTE-granted functions no migration defines; a rebuilt
-- database differed from production by exactly that family, and nothing touching them could be
-- tested. v554 captures the live bodies verbatim (md5-verified against production at capture).
--
--   F1  all five functions exist with their production signatures
--   F2  the runtime-resolved chain executes: preview_campaign_audience_v154 (which calls
--       staff_list_customers_v154, which calls the two app helpers) returns a real payload
--       for a seeded owner — proving the family is not just present but wired
--   F3  staff_list_customers_v154's points figure equals app.client_points_balance_v409 for a
--       seeded customer — the nestly_v544 correction survived the capture
--
-- Named for v554: F1-F3 must FAIL against the frozen baseline (the family is absent there).
-- One transaction, rolled back.

\set ON_ERROR_STOP on

begin;

create temp table _fail(k text, v text) on commit drop;

do $v554$
declare
  b uuid := '00000000-0000-4000-8000-00000000f001';
  c1 uuid := '00000000-0000-4000-8000-00000000f101';
  u uuid := '00000000-0000-4000-8000-00000000f201';
  prog uuid; res jsonb; pts bigint; expected bigint; missing text;
begin
  -- F1 — existence with production signatures
  select string_agg(fn, ', ') into missing from (values
    ('app.resolve_reporting_branch_scope_v154(uuid,text,uuid[],uuid)'),
    ('app.reporting_scope_label_v154(uuid,text,uuid[],uuid)'),
    ('public.staff_list_customers_v154(uuid,text,text,text,uuid[],uuid,integer,integer)'),
    ('public.get_dashboard_summary_v154(uuid,date,date,text,uuid[],uuid)'),
    ('public.preview_campaign_audience_v154(uuid,text,text,uuid[],uuid)')
  ) v(fn) where to_regprocedure(fn) is null;
  if missing is not null then
    insert into _fail values ('F1', format('missing from the rebuilt database: %s', missing));
    return; -- nothing below can run without them
  end if;

  -- seed a business, an owner login, a customer with points
  insert into auth.users (id, email) values (u, 'zz-v554-owner@example.test');
  insert into public.businesses (id, name, slug) values (b,'ZZ v554 prov','zz-v554-prov');
  insert into public.staff (business_id, user_id, role, full_name, active)
  values (b, u, 'owner', 'Fixture Owner', true);
  -- a freshly inserted business is born 'pending'; the module gate answers 'disabled' until the
  -- workspace is approved, so approve it the way the platform would
  update public.business_workspace_controls_v94
     set approval_status='approved', decided_at=now(), decision_reason='v554 fixture approval'
   where business_id=b;
  -- v620: business_operational_v620 additionally requires a paid (or trialing) subscriptions
  -- row on top of the approved workspace above.
  insert into public.subscriptions (business_id, status, payment_status, current_period_end)
  values (b, 'active', 'paid', now() + interval '30 days')
  on conflict (business_id) do update
    set status='active', payment_status='paid', current_period_end=now() + interval '30 days';
  insert into public.clients (id, business_id, full_name) values (c1,b,'Fixture Pia');
  insert into public.sales (business_id, client_id, kind, amount_cents, occurred_at) values
    (b, c1, 'quick_sale', 1200, (current_date - 40)::timestamp at time zone 'Asia/Singapore');

  perform set_config('request.jwt.claim.sub', u::text, true);
  perform set_config('request.jwt.claims', json_build_object(
    'sub',u,'role','authenticated','aud','authenticated')::text, true);

  -- F2 — the runtime-resolved chain executes end to end
  begin
    res := public.preview_campaign_audience_v154(b, 'inactive_30_59', 'all', array[]::uuid[], null);
    if res is null or res->>'status' is distinct from 'ok' then
      insert into _fail values ('F2', format('audience preview did not answer ok: %s', left(res::text,200)));
    end if;
  exception when others then
    insert into _fail values ('F2', format('the captured chain raised %s: %s', sqlstate, left(sqlerrm,160)));
  end;

  -- F3 — the v544 correction survived: points from v154 == the canonical primitive
  begin
    res := public.staff_list_customers_v154(b, null, null, 'all', array[]::uuid[], null, 100, 0);
    select (customer->>'points')::bigint into pts
      from jsonb_array_elements(res->'customers') customer
     where customer->>'id' = c1::text;
    expected := coalesce(app.client_points_balance_v409(b, c1), 0);
    if pts is distinct from expected then
      insert into _fail values ('F3', format('v154 points=%s, canonical primitive=%s', pts, expected));
    end if;
  exception when others then
    insert into _fail values ('F3', format('staff_list_customers_v154 raised %s: %s', sqlstate, left(sqlerrm,160)));
  end;
end
$v554$;

select case when count(*)=0 then 'PASS — the v154 family is rebuilt, wired, and canonical'
            else 'FAIL' end as verdict, count(*) as failures from _fail;
select k, v from _fail order by k;

do $verdict$
declare v integer;
begin
  select count(*) into v from _fail;
  if v > 0 then raise exception 'v554: % assertion(s) failed', v; end if;
end
$verdict$;

rollback;
