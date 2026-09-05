-- nestly_v787 rollback suite — every live business is on the Pipeline.
--
-- Runs inside ONE transaction ending in ROLLBACK, so it is safe against production.
--
-- WHAT IT PROVES
--   01  the ensure function (internal) and the sync RPC (authenticated) exist; no trigger remains on
--       businesses (app.* stays internal — v720 access boundary).
--   02  after the backfill, every non-synthetic business has exactly one prospect linked through
--       converted_business_id, and no business's source_prospect_id was touched.
--   03  a brand-new business gets its record from the admin sync: Closed lane ('account_created'
--       without a subscription), ownership 'closed', company named for it, stage history and
--       source lineage written; calling ensure again returns the same id (idempotent).
--   04  a synthetic business gets no record; a business inserted WITH source_prospect_id (the CRM
--       conversion flow) gets no second record.
--   05  the Pipeline board (v785) lists the new business in the 'closed' lane with its branch count.

begin;

create temp table _v787(id int generated always as identity, check_name text, ok boolean, detail text) on commit drop;
grant all on _v787 to public;

create or replace function pg_temp.as_v787_user(p_uid uuid, p_role text default 'authenticated')
returns void language plpgsql as $$
begin
  execute format('set local role %I', p_role);
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', p_uid, 'role', p_role,
    'amr', jsonb_build_array(jsonb_build_object('method','oauth')),
    'app_metadata', jsonb_build_object('provider','google','providers',jsonb_build_array('email','google')))::text, true);
end
$$;
grant execute on function pg_temp.as_v787_user(uuid,text) to public;

insert into _v787(check_name, ok, detail)
select '01 ensure internal, sync callable, no trigger on businesses',
  exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='app' and p.proname='v787_ensure_business_prospect')
  and not exists (select 1 from pg_trigger where tgname='zz_businesses_pipeline_record_v787')
  and not has_function_privilege('authenticated','app.v787_ensure_business_prospect(uuid)','execute')
  and not has_function_privilege('anon','app.v787_ensure_business_prospect(uuid)','execute')
  and has_function_privilege('authenticated','public.platform_pipeline_sync_live_firms_v787()','execute')
  and not has_function_privilege('anon','public.platform_pipeline_sync_live_firms_v787()','execute'),
  'grants + no trigger';

insert into _v787(check_name, ok, detail)
select '02 every live business has exactly one linked prospect',
  count(*) filter (where n <> 1) = 0,
  format('%s businesses, %s without exactly one record', count(*), count(*) filter (where n <> 1))
from (select b.id, (select count(*) from public.sme_prospects p where p.converted_business_id = b.id) n
      from public.businesses b where coalesce(b.is_synthetic,false) = false) x;

insert into _v787(check_name, ok, detail)
select '02 backfill never set businesses.source_prospect_id',
  count(*) = 0, count(*)::text || ' self-serve businesses now carry source_prospect_id'
from public.businesses b
join public.sme_prospects p on p.converted_business_id = b.id
where b.source_prospect_id = p.id
  and exists (select 1 from public.sme_prospect_source_lineage l where l.prospect_id = p.id and l.source_system = 'peekaa_self_serve');

do $$
declare
  v_sa uuid := gen_random_uuid(); v_sa_email text := 'v787-sa-'||replace(gen_random_uuid()::text,'-','')||'@example.invalid';
  v_biz uuid := gen_random_uuid(); v_synth uuid := gen_random_uuid(); v_conv uuid := gen_random_uuid();
  v_company uuid := gen_random_uuid(); v_prospect_seed uuid := gen_random_uuid();
  v_prospect uuid; v_again uuid; v_out jsonb; v_row record;
begin
  insert into auth.users(id, email, instance_id, aud, role, created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
  values (v_sa, v_sa_email, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', now(), now(), '{}'::jsonb, '{}'::jsonb);
  insert into public.super_admins(user_id, email) values (v_sa, v_sa_email);

  -- 03 a brand-new self-serve business; the admin's console sync registers it
  insert into public.businesses(id, name, slug, industry) values (v_biz, 'V787 Tea First Lah', 'v787-tea-'||left(replace(v_biz::text,'-',''),8), 'fnb');
  insert into _v787(check_name, ok, detail) values ('03 no trigger: a plain insert creates nothing by itself',
    not exists (select 1 from public.sme_prospects where converted_business_id = v_biz), 'fixtures may insert their own prospect for it');
  perform pg_temp.as_v787_user(v_sa);
  v_out := public.platform_pipeline_sync_live_firms_v787();
  reset role;
  select id into v_prospect from public.sme_prospects where converted_business_id = v_biz;
  insert into _v787(check_name, ok, detail) values ('03 the sync created the record',
    v_prospect is not null and (v_out->>'registered')::int >= 1, coalesce(v_prospect::text,'<none>')||' registered='||coalesce(v_out->>'registered','?'));
  select p.*, c.trading_name into v_row from public.sme_prospects p join public.sme_companies c on c.id = p.company_id where p.id = v_prospect;
  insert into _v787(check_name, ok, detail) values ('03 closed lane, ownership closed, company named for the business',
    v_row.current_stage_key = 'account_created' and v_row.ownership_state = 'closed' and v_row.queue_key is null
      and v_row.converted_business_id = v_biz and v_row.converted_by is not null and v_row.trading_name = 'V787 Tea First Lah'
      and app.v785_lane(v_row.current_stage_key) = 'closed',
    format('stage=%s ownership=%s company=%s', v_row.current_stage_key, v_row.ownership_state, v_row.trading_name));
  insert into _v787(check_name, ok, detail) values ('03 stage history + source lineage written',
    exists (select 1 from public.sme_prospect_stage_history h where h.prospect_id = v_prospect and h.to_stage_key = 'account_created' and h.reason_code = 'self_serve_workspace')
    and exists (select 1 from public.sme_prospect_source_lineage l where l.prospect_id = v_prospect and l.source_system = 'peekaa_self_serve' and l.external_id = v_biz::text),
    'history + lineage');
  v_again := app.v787_ensure_business_prospect(v_biz);
  insert into _v787(check_name, ok, detail) values ('03 ensure is idempotent',
    v_again = v_prospect and (select count(*) from public.sme_prospects where converted_business_id = v_biz) = 1, coalesce(v_again::text,'<none>'));
  insert into _v787(check_name, ok, detail) values ('03 source_prospect_id untouched',
    (select source_prospect_id from public.businesses where id = v_biz) is null, 'v79 guard stays inert for self-serve');

  -- 04 synthetic → no record; conversion-flow insert → no second record
  insert into public.businesses(id, name, slug, industry, is_synthetic) values (v_synth, 'V787 Synthetic', 'v787-syn-'||left(replace(v_synth::text,'-',''),8), 'fnb', true);
  perform pg_temp.as_v787_user(v_sa);
  v_out := public.platform_pipeline_sync_live_firms_v787();
  reset role;
  insert into _v787(check_name, ok, detail) values ('04 synthetic business gets no record',
    not exists (select 1 from public.sme_prospects where converted_business_id = v_synth), 'skipped by the sync');
  insert into public.sme_companies(id, legal_name, trading_name) values (v_company, 'V787 CONVERTED PTE. LTD.', 'V787 Converted');
  insert into public.sme_prospects(id, company_id, current_stage_key, ownership_state, queue_key, next_action_at, next_action_type)
  values (v_prospect_seed, v_company, 'proposal', 'queued', 'triage', now() + interval '30 minutes', 'convert'); -- proposal carries an SLA; 'client' does not and the v510 guard refuses a null SLA
  perform set_config('app.v79_system_transition', 'on', true);
  insert into public.businesses(id, name, slug, industry, source_prospect_id) values (v_conv, 'V787 Converted', 'v787-conv-'||left(replace(v_conv::text,'-',''),8), 'fnb', v_prospect_seed);
  perform set_config('app.v79_system_transition', 'off', true);
  perform pg_temp.as_v787_user(v_sa);
  v_out := public.platform_pipeline_sync_live_firms_v787();
  reset role;
  insert into _v787(check_name, ok, detail) values ('04 conversion-flow business gets no second record',
    not exists (select 1 from public.sme_prospects where converted_business_id = v_conv)
      and app.v787_ensure_business_prospect(v_conv) = v_prospect_seed,
    'ensure returns the prospect the conversion flow owns');
  begin
    perform pg_temp.as_v787_user(gen_random_uuid());
    v_out := public.platform_pipeline_sync_live_firms_v787();
    v_out := jsonb_build_object('code','no error');
  exception when others then v_out := jsonb_build_object('code', sqlstate);
  end;
  reset role;
  insert into _v787(check_name, ok, detail) values ('04 a stranger cannot run the sync → 42501', v_out->>'code' = '42501', v_out::text);

  -- 05 the board shows it
  perform pg_temp.as_v787_user(v_sa);
  v_out := public.platform_pipeline_board_v785('all', null, 'V787 Tea', 100);
  reset role;
  insert into _v787(check_name, ok, detail) values ('05 board lists the live business in the closed lane',
    exists (select 1 from jsonb_array_elements(v_out->'items') x where x->>'converted_business_id' = v_biz::text
              and x->>'lane' = 'closed' and x->>'business_name' = 'V787 Tea First Lah'),
    (select x::text from jsonb_array_elements(v_out->'items') x where x->>'converted_business_id' = v_biz::text));
end $$;

select check_name, ok, detail from _v787 order by id;
select count(*) filter (where not ok) as failures, count(*) as checks from _v787;

rollback;
