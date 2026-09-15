-- nestly_v928 rollback suite — a live client's advisor changes; nothing else about it does.
--
-- Run inside a transaction against production and ROLLED BACK. Impersonates a real super admin
-- (public.super_admins) with the v625 Google-OAuth-shaped claims.
--
-- The load-bearing pair:
--   * the advisor on a CONVERTED prospect can be set, changed and cleared through the new RPC;
--   * the v79 guard still refuses every other write to that row — including a stage move made in
--     the same transaction, and including a stage move attempted while the v928 GUC is on.

\set ON_ERROR_STOP on

begin;

do $suite$
declare
  sa uuid; outsider uuid := gen_random_uuid();
  biz uuid := gen_random_uuid(); company uuid := gen_random_uuid(); prospect uuid := gen_random_uuid();
  consultant uuid; got jsonb; row_after public.sme_prospects%rowtype; before public.sme_prospects%rowtype;
  n integer := 0;
begin
  select user_id into sa from public.super_admins limit 1;
  if sa is null then raise exception 'A0 failed: no super admin to impersonate'; end if;
  select id into consultant from public.platform_consultants where active order by created_at limit 1;
  if consultant is null then raise exception 'A0 failed: no active consultant to assign'; end if;

  insert into public.businesses(id,name,slug,industry,join_enabled,enabled_modules)
  values (biz,'V928 live client fixture','v928-'||substr(biz::text,1,8),'test',true,array['dashboard','clients']);
  insert into public.sme_companies(id,legal_name) values (company,'V928 Live Client Fixture Pte Ltd');
  -- sme_prospects_conversion_shape_check: converted_business_id / converted_at / converted_by are
  -- all-or-nothing, so a converted fixture needs the whole triple.
  insert into public.sme_prospects(id,company_id,current_stage_key,converted_business_id,converted_at,
      converted_by,ownership_state,created_by)
  values (prospect,company,'activated',biz,now(),sa,'closed',sa);

  -- ------------------------------------------------------------------ the guard still bites
  n := n + 1;
  begin
    update public.sme_prospects set assigned_consultant_id=consultant where id=prospect;
    raise exception 'A% failed: a plain UPDATE changed a converted prospect''s advisor', n;
  exception when insufficient_privilege then null; end;

  n := n + 1;
  begin
    update public.sme_prospects set current_stage_key='new_lead' where id=prospect;
    raise exception 'A% failed: a plain UPDATE moved a converted prospect''s stage', n;
  exception when insufficient_privilege then null; end;

  -- The v928 GUC must not become a way to move a stage.
  n := n + 1;
  begin
    perform set_config('app.v928_advisor_change','on',true);
    update public.sme_prospects set current_stage_key='new_lead' where id=prospect;
    perform set_config('app.v928_advisor_change','off',true);
    raise exception 'A% failed: the advisor GUC allowed a stage move', n;
  exception when insufficient_privilege then
    perform set_config('app.v928_advisor_change','off',true);
  end;

  -- ...nor a way to move the advisor AND the stage together.
  n := n + 1;
  begin
    perform set_config('app.v928_advisor_change','on',true);
    update public.sme_prospects
       set assigned_consultant_id=consultant, current_stage_key='new_lead' where id=prospect;
    perform set_config('app.v928_advisor_change','off',true);
    raise exception 'A% failed: the advisor GUC allowed a combined advisor+stage write', n;
  exception when insufficient_privilege then
    perform set_config('app.v928_advisor_change','off',true);
  end;

  -- ------------------------------------------------------------------ authorisation
  perform set_config('request.jwt.claims', jsonb_build_object('sub',outsider,'role','authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', outsider::text, true);
  n := n + 1;
  begin
    perform public.platform_set_firm_advisor_v928(biz,consultant,'suite');
    raise exception 'A% failed: a non-super-admin set a live client''s advisor', n;
  exception when insufficient_privilege then null; end;

  perform set_config('request.jwt.claims', jsonb_build_object(
    'sub', sa, 'role', 'authenticated',
    'amr', jsonb_build_array(jsonb_build_object('method', 'oauth')),
    'app_metadata', jsonb_build_object('providers', jsonb_build_array('google')))::text, true);
  perform set_config('request.jwt.claim.sub', sa::text, true);

  n := n + 1;
  begin
    perform public.platform_set_firm_advisor_v928(biz,consultant,' ');
    raise exception 'A% failed: an advisor change was accepted with no reason', n;
  exception when sqlstate '22023' then null; end;

  n := n + 1;
  begin
    perform public.platform_set_firm_advisor_v928(biz,gen_random_uuid(),'suite');
    raise exception 'A% failed: an unknown consultant was accepted', n;
  exception when sqlstate '22023' then null; end;

  n := n + 1;
  begin
    perform public.platform_set_firm_advisor_v928(gen_random_uuid(),consultant,'suite');
    raise exception 'A% failed: a business with no live client record was accepted', n;
  exception when sqlstate '42704' then null; end;

  -- ------------------------------------------------------------------ the happy path
  select * into before from public.sme_prospects where id=prospect;
  got := public.platform_set_firm_advisor_v928(biz,consultant,'suite: first advisor');
  select * into row_after from public.sme_prospects where id=prospect;

  n := n + 1;
  if row_after.assigned_consultant_id is distinct from consultant then
    raise exception 'A% failed: the advisor was not set', n; end if;

  n := n + 1;
  if row_after.current_stage_key is distinct from before.current_stage_key
     or row_after.ownership_state is distinct from before.ownership_state
     or row_after.queue_key is distinct from before.queue_key
     or row_after.company_id is distinct from before.company_id
     or row_after.converted_business_id is distinct from before.converted_business_id then
    raise exception 'A% failed: setting the advisor moved something else on the record', n; end if;

  n := n + 1;
  if row_after.version <> before.version + 1 then
    raise exception 'A% failed: version went % -> %', n, before.version, row_after.version; end if;

  n := n + 1;
  if not exists(select 1 from public.sme_prospect_assignments
                 where prospect_id=prospect and consultant_id=consultant) then
    raise exception 'A% failed: no assignment history row', n; end if;

  n := n + 1;
  if not exists(select 1 from public.audit_log
                 where business_id=biz and action='firm_advisor_changed') then
    raise exception 'A% failed: no audit row for the advisor change', n; end if;

  -- the advisor now actually reaches the thing it gates
  n := n + 1;
  if not exists(select 1 from app.assigned_consultant_v94(biz)) then
    raise exception 'A% failed: app.assigned_consultant_v94 still reports no advisor', n; end if;

  -- ------------------------------------------------------------------ idempotence and unassign
  n := n + 1;
  got := public.platform_set_firm_advisor_v928(biz,consultant,'suite: same again');
  if (got->>'status') <> 'unchanged' then
    raise exception 'A% failed: re-setting the same advisor was not reported as unchanged: %', n, got; end if;

  n := n + 1;
  got := public.platform_set_firm_advisor_v928(biz,null,'suite: advisor left the company');
  select * into row_after from public.sme_prospects where id=prospect;
  if row_after.assigned_consultant_id is not null or row_after.owner_assigned_at is not null then
    raise exception 'A% failed: the advisor was not cleared', n; end if;

  n := n + 1;
  if exists(select 1 from app.assigned_consultant_v94(biz)) then
    raise exception 'A% failed: a cleared advisor still reads as assigned', n; end if;

  n := n + 1;
  if row_after.current_stage_key is distinct from before.current_stage_key then
    raise exception 'A% failed: clearing the advisor moved the stage', n; end if;

  -- ------------------------------------------------------------------ the guard is back on
  n := n + 1;
  begin
    update public.sme_prospects set assigned_consultant_id=consultant where id=prospect;
    raise exception 'A% failed: the GUC leaked past the RPC', n;
  exception when insufficient_privilege then null; end;

  raise notice 'v928 suite: % assertions passed', n;
end
$suite$;

rollback;
