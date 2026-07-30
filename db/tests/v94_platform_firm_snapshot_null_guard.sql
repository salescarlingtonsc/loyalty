-- Rollback-only v94 acceptance: a fresh, unattended prospect with no next
-- action must not abort the super-admin firm directory snapshot.
begin;

create or replace function pg_temp.as_v94_user(p_uid uuid)
returns void language plpgsql as $$
begin
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub',p_uid::text,true);
  perform set_config('request.jwt.claims',
    json_build_object('sub',p_uid,'role','authenticated')::text,true);
end
$$;
grant execute on function pg_temp.as_v94_user(uuid) to public;

do $v94$
declare
  v_sa uuid:=gen_random_uuid();
  v_company uuid:=gen_random_uuid();
  v_prospect uuid:=gen_random_uuid();
  v_snapshot_at timestamptz:=date_trunc('second',clock_timestamp());
  v_raw_attention boolean;
  v_result jsonb;
  v_item jsonb;
begin
  if to_regprocedure(
    'app.ensure_platform_firm_snapshot_v88(uuid,timestamp with time zone,boolean)'
  ) is null then
    raise exception 'v94 repaired snapshot writer is missing';
  end if;

  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,
    email_confirmed_at,created_at,updated_at
  ) values(
    '00000000-0000-0000-0000-000000000000',v_sa,
    'authenticated','authenticated',
    'v94-sa-'||substr(v_sa::text,1,8)||'@example.test','',
    now(),now(),now()
  );
  insert into public.super_admins(user_id,email,note)
  values(
    v_sa,'v94-sa-'||substr(v_sa::text,1,8)||'@example.test',
    'v94 rollback fixture'
  );
  insert into public.sme_companies(
    id,legal_name,trading_name,registration_number,industry,
    created_at,updated_at
  ) values(
    v_company,'V94 Fresh Pte Ltd','V94 Fresh','V94-UEN-FRESH','retail',
    v_snapshot_at-interval '1 day',v_snapshot_at-interval '1 day'
  );
  insert into public.sme_prospects(
    id,company_id,current_stage_key,next_action_at,stage_entered_at,
    created_at,updated_at
  ) values(
    v_prospect,v_company,'new_lead',null,v_snapshot_at-interval '1 day',
    v_snapshot_at-interval '1 day',v_snapshot_at-interval '1 day'
  );

  select firm.attention_due into v_raw_attention
  from app.platform_firm_rows_v88(v_snapshot_at) firm
  where firm.prospect_id=v_prospect;
  if v_raw_attention is not null then
    raise exception 'v94 fixture no longer reproduces the v88 nullable predicate';
  end if;

  perform pg_temp.as_v94_user(v_sa);
  v_result:=public.platform_list_firm_onboarding_v88(
    '{"search":"V94 Fresh"}',null,100,null,null
  );
  reset role;

  if (v_result->>'total_count')::integer<>1
     or jsonb_array_length(v_result->'items')<>1 then
    raise exception 'v94 repaired snapshot omitted or duplicated the firm: %',v_result;
  end if;
  v_item:=v_result->'items'->0;
  if v_item->>'prospect_id'<>v_prospect::text
     or v_item->>'attention_due'<>'false' then
    raise exception 'v94 frozen payload did not fail-close attention_due: %',v_item;
  end if;
  if not exists(
    select 1
    from app.platform_firm_snapshot_rows_v88 snapshot
    where snapshot.actor_id=v_sa
      and snapshot.snapshot_at=(v_result->>'snapshot_at')::timestamptz
      and snapshot.row_id=v_prospect
      and snapshot.attention_due=false
      and snapshot.payload->>'attention_due'='false'
  ) then
    raise exception 'v94 indexed snapshot and payload do not agree';
  end if;
  if has_function_privilege(
      'authenticated',
      'app.ensure_platform_firm_snapshot_v88(uuid,timestamp with time zone,boolean)',
      'execute'
    )
     or has_function_privilege(
      'anon',
      'app.ensure_platform_firm_snapshot_v88(uuid,timestamp with time zone,boolean)',
      'execute'
    ) then
    raise exception 'v94 widened the private snapshot writer';
  end if;
end
$v94$;

select 'V94 SUITE PASS' as result;
rollback;
