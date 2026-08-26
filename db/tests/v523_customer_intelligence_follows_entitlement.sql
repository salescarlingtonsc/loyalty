-- Rollback-only acceptance for nestly_v523 — Customer intelligence resolves through entitlement
-- like every other module, and stays finance-gated on the server.
-- Run: supabase db query --linked -f db/tests/v523_customer_intelligence_follows_entitlement.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
-- app.staff_module_perms_at_v115 carried `case when module_keys.module_key='customerintel' then
-- 'disabled'` ahead of the override/entitlement resolution, so the module was unreachable for every
-- tenant and every role including the owner, no matter what enabled_modules said. v523 removes that
-- clause and, in the same change, adds customerintel to the view_finance filter so the server agrees
-- with the client gate nestly_v522 added — otherwise a frontdesk user would be handed an entitlement
-- that both Customer Intelligence RPCs immediately refuse with 42501.
--
--   01  an OWNER of an entitled business now resolves customerintel
--   02  ...at 'rw', the same mode any other entitled module resolves to
--   03  a FRONTDESK user does NOT resolve it — the server matches the client's finance gate
--   04  ...and is refused by the RPC itself, so the gate is not cosmetic
--   05  a business that is NOT entitled still does not get it — this is entitlement, not a grant
--   06  the other modules' resolution is unchanged by the edit
--   07  expenses/pnl stay finance-gated exactly as before
--
-- Fixtures are created here and rolled back; no production row is written.

begin;

create temp table _r(k text, v text) on commit drop;

create or replace function pg_temp.as_v523_user(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
end
$$;
grant execute on function pg_temp.as_v523_user(uuid) to public;

do $v523$
declare
  v_entitled   uuid := '00000000-0000-4000-8000-00000000c523';
  v_bare       uuid := '00000000-0000-4000-8000-00000000c524';
  v_owner      uuid := '00000000-0000-4000-8000-00000000c525';
  v_frontdesk  uuid := '00000000-0000-4000-8000-00000000c526';
  v_bareowner  uuid := '00000000-0000-4000-8000-00000000c527';
  v_perms      jsonb;
  v_msg        text;
begin
  insert into auth.users (id, email) values
    (v_owner,'v523-owner@example.test'),
    (v_frontdesk,'v523-frontdesk@example.test'),
    (v_bareowner,'v523-bare-owner@example.test')
  on conflict (id) do nothing;

  /* An entitled business: customerintel present in enabled_modules, exactly as v171 left every
     tenant carrying a published bundle with 'reports'. */
  insert into public.businesses (id, name, slug, enabled_modules) values
    (v_entitled,'ZZ v523 entitled','zz-v523-entitled',
     array['dashboard','clients','sales','reports','customerintel','expenses','pnl']);
  /* A business entitled to reports but NOT to customerintel. */
  insert into public.businesses (id, name, slug, enabled_modules) values
    (v_bare,'ZZ v523 bare','zz-v523-bare',
     array['dashboard','clients','sales','reports']);

  /* Creating a business already mints these two rows in the PENDING shape from its own trigger,
     and app.has_perm refuses every permission until the workspace is open — so these promote the
     rows rather than create them. approval_status='approved' additionally requires decided_at and
     a 3..1000 character decision_reason (business_workspace_controls_v94_decision_shape). */
  insert into public.business_workspace_controls_v94 (business_id, approval_status, decided_at, decision_reason)
  values (v_entitled,'approved',now(),'v523 rollback suite'),
         (v_bare,'approved',now(),'v523 rollback suite')
  on conflict (business_id) do update
    set approval_status='approved', decided_at=now(), decision_reason='v523 rollback suite';
  insert into public.business_subscription_lifecycle_v94 (business_id, state, workspace_paused)
  values (v_entitled,'current',false),(v_bare,'current',false)
  on conflict (business_id) do update set state='current', workspace_paused=false;

  insert into public.staff (business_id, user_id, role, active) values
    (v_entitled, v_owner,     'owner',     true),
    (v_entitled, v_frontdesk, 'frontdesk', true),
    (v_bare,     v_bareowner, 'owner',     true);

  -- 01/02 owner of an entitled business
  perform pg_temp.as_v523_user(v_owner);
  v_perms := app.staff_module_perms_at_v115(v_entitled, null);
  insert into _r values ('01 owner resolves customerintel',
    case when v_perms ? 'customerintel' then 'PASS'
         else 'FAIL — owner of an entitled business still cannot reach it: '||v_perms::text end);
  insert into _r values ('02 owner resolves it at rw',
    case when v_perms->>'customerintel' = 'rw' then 'PASS'
         else 'FAIL — expected rw, got '||coalesce(v_perms->>'customerintel','<absent>') end);

  -- 06 the rest of the resolution is unchanged
  insert into _r values ('06 other modules unchanged for the owner',
    case when v_perms->>'clients'='rw' and v_perms->>'sales'='rw' and v_perms->>'reports'='rw'
         then 'PASS' else 'FAIL — unrelated modules moved: '||v_perms::text end);
  -- 07 expenses/pnl remain finance-gated (owner holds view_finance, so present here)
  insert into _r values ('07 expenses and pnl still resolve for a finance role',
    case when v_perms->>'expenses'='rw' and v_perms->>'pnl'='rw'
         then 'PASS' else 'FAIL — finance modules regressed: '||v_perms::text end);

  -- 03 frontdesk must NOT resolve it
  perform pg_temp.as_v523_user(v_frontdesk);
  v_perms := app.staff_module_perms_at_v115(v_entitled, null);
  insert into _r values ('03 frontdesk does not resolve customerintel',
    case when not (v_perms ? 'customerintel') then 'PASS'
         else 'FAIL — frontdesk was handed an entitlement both RPCs refuse: '||v_perms::text end);
  insert into _r values ('03b frontdesk keeps its non-finance modules',
    case when v_perms->>'clients'='rw' then 'PASS'
         else 'FAIL — the finance gate took unrelated modules too: '||v_perms::text end);

  -- 04 and the RPC itself refuses, so the gate is not cosmetic
  begin
    perform public.get_customer_intelligence_v83(
      v_entitled, null, (now()-interval '30 days')::date, now()::date, 10, null, null, null);
    insert into _r values ('04 the RPC refuses a frontdesk caller',
      'FAIL — get_customer_intelligence_v83 answered a frontdesk user');
  exception when others then
    get stacked diagnostics v_msg = message_text;
    insert into _r values ('04 the RPC refuses a frontdesk caller',
      case when v_msg ilike '%view_finance%' then 'PASS'
           else 'FAIL — refused for the wrong reason: '||v_msg end);
  end;

  -- 05 entitlement still governs
  perform pg_temp.as_v523_user(v_bareowner);
  v_perms := app.staff_module_perms_at_v115(v_bare, null);
  insert into _r values ('05 an unentitled business still does not get it',
    case when not (v_perms ? 'customerintel') then 'PASS'
         else 'FAIL — removing the override granted the module to a business without it: '||v_perms::text end);
end
$v523$;

select k, v from _r order by k;

rollback;
