-- Rollback-only acceptance for v375 — points buy gifts, never store credit.
--   supabase db query --linked -f db/tests/v375_points_are_not_credit.sql
-- Any row whose result starts with FAIL is a failure. Nothing is committed.
--
-- The tenant here is shaped exactly like the one in the owner's screenshot: loyalty_model
-- 'classic', 150 points, reward_credit_cents 150. On the pre-v375 reader that business's customer
-- profile offered a synthesized "SGD 1.50 credit" and, because the catalogue arm of the same CTE
-- excluded 'classic' outright, showed NONE of the gifts the business had actually published.
begin;

create temp table _r(k text, v text) on commit drop;
create temp table _c(biz uuid, br uuid, owner uuid, slug text, draft uuid, prog uuid, cli uuid, rw uuid) on commit drop;
grant select,insert,update,delete on _r,_c to authenticated;
insert into _c(slug,prog) values ('zz-v375-'||substr(md5(random()::text),1,8), gen_random_uuid());

with i as (insert into public.businesses(name,slug,enabled_modules)
  select 'ZZ V375',slug,array['loyalty'] from _c returning id)
update _c set biz=(select id from i);
with i as (insert into public.branches(business_id,name) select biz,'Main' from _c returning id)
update _c set br=(select id from i);
with i as (insert into auth.users(id,instance_id,aud,role,email,encrypted_password,
    email_confirmed_at,created_at,updated_at)
  values (gen_random_uuid(),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
    'zz-v375-'||substr(md5(random()::text),1,8)||'@example.test','x',now(),now(),now()) returning id)
update _c set owner=(select id from i);
insert into public.staff(business_id,user_id,role,active,access_state,full_name)
  select biz,owner,'owner',true,'approved','ZZ V375 Owner' from _c;
-- the owner write gate needs an approved, unpaused workspace (a trigger seeds both rows)
insert into public.business_workspace_controls_v94(business_id,approval_status,decided_by,decided_at,decision_reason)
select biz,'approved',owner,now(),'v375 fixture' from _c
on conflict (business_id) do update set approval_status='approved',
  decided_by=excluded.decided_by, decided_at=excluded.decided_at, decision_reason=excluded.decision_reason;
insert into public.business_subscription_lifecycle_v94(business_id,workspace_paused)
select biz,false from _c on conflict (business_id) do update set workspace_paused=false;

-- A minimum published loyalty configuration for the draft to be based on.
insert into public.firm_config_versions(id,business_id,version_no,status,source,snapshot_hash,created_by)
select cfg,biz,1,'draft','manual',md5('v375-base'),owner from (select *, gen_random_uuid() as cfg from _c) x;
update _c set draft=(select id from public.firm_config_versions where business_id=(select biz from _c));
select set_config('request.jwt.claims',
  json_build_object('sub',(select owner from _c),'role','authenticated')::text,true);
insert into public.loyalty_program_versions(config_version_id,business_id,kind,loyalty_model,active,
  earn_points_per_dollar,redeem_points,reward_credit_cents,tier_basis,expiry_mode)
select draft,biz,'points','classic',true,1,150,150,'points_earned','none' from _c;
select set_config('request.jwt.claims','{}',true);
update public.firm_config_versions set status='published',published_at=now()
 where id=(select draft from _c);
-- a trigger already created this row on business insert, so the fixture UPDATES it into the
-- owner's exact live shape: classic, 150 points, SGD 1.50 of credit.
insert into public.loyalty_programs(business_id,kind,active,loyalty_model,configuration_status,current_config_version_id)
select biz,'points',true,'classic','published',draft from _c
on conflict (business_id) do update set kind='points',active=true,loyalty_model='classic',
  configuration_status='published',current_config_version_id=excluded.current_config_version_id;
update public.loyalty_programs set redeem_points=150,reward_credit_cents=150,earn_points_per_dollar=1
 where business_id=(select biz from _c);
select set_config('app.v79_system_transition','on',true);
update public.businesses set active_config_version_id=(select draft from _c) where id=(select biz from _c);
select set_config('app.v79_system_transition','off',true);


-- A customer, and a real published gift for them to be offered.
with i as (insert into public.clients(business_id,full_name,phone) select biz,'ZZ V375 Customer','8'||substr((random()*90000000+10000000)::bigint::text,1,7) from _c returning id)
update _c set cli=(select id from i);
with i as (insert into public.loyalty_rewards(business_id,name,internal_name,customer_name,cost_points,credit_cents,estimated_cost_cents,fulfillment_kind,active,sort,current_config_version_id)
  select biz,'Free Facial cream','Free Facial cream','Free Facial cream',1000,0,0,'manual_item',true,0,draft from _c returning id)
update _c set rw=(select id from i);
select set_config('request.jwt.claims',
  json_build_object('sub',(select owner from _c),'role','authenticated')::text,true);
insert into public.loyalty_reward_versions(reward_id,config_version_id,business_id,internal_name,customer_name,
  cost_points,credit_cents,estimated_cost_cents,fulfillment_kind,active,sort,terms)
select rw,draft,biz,'Free Facial cream','Free Facial cream',1000,0,0,'manual_item',true,0,'Synthetic acceptance only' from _c;
select set_config('request.jwt.claims','{}',true);

create or replace function pg_temp.try_redeem_v375() returns text language plpgsql security definer as $$
begin
  perform public.redeem_points((select biz from _c),(select cli from _c),'v375-acceptance-key');
  return 'ok (no refusal)';
exception when others then return sqlstate||' '||sqlerrm;
end $$;
grant execute on function pg_temp.try_redeem_v375() to authenticated;

create or replace function pg_temp.rewards_v375() returns jsonb language sql security definer as $$
  select coalesce(public.staff_get_customer_actionable_loyalty_v145(
    (select biz from _c),(select cli from _c),null),'{}'::jsonb)
$$;
grant execute on function pg_temp.rewards_v375() to authenticated;

select set_config('request.jwt.claims',
  json_build_object('sub',(select owner from _c),'role','authenticated')::text,true);
set local role authenticated;

-- 01/02 — the defect, on whatever definition is live right now.
insert into _r select '01 pre-fix offers store credit',
  case when pg_temp.rewards_v375()::text ilike '%credit%' and pg_temp.rewards_v375()::text ilike '%SGD 1.50%'
    then 'PASS (a classic tenant was offered SGD 1.50 credit)'
    else 'INFO already retired' end;
insert into _r select '02 pre-fix hides the real gift',
  case when pg_temp.rewards_v375()::text not ilike '%Free Facial cream%'
    then 'PASS (the published gift was withheld from a classic tenant)'
    else 'INFO already retired' end;

reset role;
CREATE OR REPLACE FUNCTION public.staff_get_customer_actionable_loyalty_v145(p_business uuid, p_client uuid, p_branch uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_as_of timestamptz := statement_timestamp();
  v_result jsonb;
begin
  perform public.require_module_scope_v145(
    p_business, p_branch, 'clients'
  );
  perform public.require_module_scope_v145(
    p_business, p_branch, 'loyalty'
  );
  if not exists (
    select 1
      from public.clients client
     where client.id = p_client
       and client.business_id = p_business
  ) then
    raise exception 'customer not found in business'
      using errcode = '22023';
  end if;

  with program as (
    select
      loyalty.id,
      loyalty.kind,
      loyalty.loyalty_model,
      loyalty.earn_points_per_dollar,
      loyalty.redeem_points,
      loyalty.reward_credit_cents,
      loyalty.stamp_per_cents,
      loyalty.expiry_mode,
      loyalty.configuration_status,
      coalesce(loyalty.active, false)
        and loyalty.configuration_status = 'published' as enabled,
      business.active_config_version_id
    from public.businesses business
    left join public.loyalty_programs loyalty
      on loyalty.business_id = business.id
    where business.id = p_business
  ), ledger_balance as (
    select greatest(coalesce(sum(ledger.points), 0), 0)::integer as units
      from public.points_ledger ledger
     where ledger.business_id = p_business
       and ledger.client_id = p_client
  ), unexpired_batches as (
    select
      batch.id,
      batch.remaining,
      batch.earned_at,
      batch.expires_at,
      sum(batch.remaining) over (
        order by batch.expires_at nulls last, batch.earned_at, batch.id
        rows between unbounded preceding and current row
      )::bigint as cumulative_remaining
      from public.points_batches batch
     where batch.business_id = p_business
       and batch.client_id = p_client
       and batch.remaining > 0
       and (batch.expires_at is null or batch.expires_at > v_as_of)
  ), batch_balance as (
    select coalesce(sum(batch.remaining), 0)::integer as units
      from unexpired_batches batch
  ), loyalty_balance as (
    select case when program.enabled
      then greatest(least(ledger_balance.units, batch_balance.units), 0)
      else 0 end::integer as units
      from program cross join ledger_balance cross join batch_balance
  ), actionable_batches as (
    select
      batch.expires_at,
      least(
        batch.remaining::bigint,
        greatest(
          loyalty_balance.units::bigint
            - (batch.cumulative_remaining - batch.remaining::bigint),
          0
        )
      )::integer as actionable_remaining
      from unexpired_batches batch
      cross join loyalty_balance
     where loyalty_balance.units > 0
       and batch.cumulative_remaining - batch.remaining::bigint
           < loyalty_balance.units::bigint
  ), next_expiry as (
    select batch.expires_at,
           sum(batch.actionable_remaining)::integer as units
      from actionable_batches batch
     where batch.expires_at is not null
       and batch.actionable_remaining > 0
     group by batch.expires_at
     order by batch.expires_at
     limit 1
  ), credit_balance as (
    select greatest(coalesce(sum(ledger.amount_cents), 0), 0)::integer
      as balance_cents
      from public.credit_ledger ledger
     where ledger.business_id = p_business
       and ledger.client_id = p_client
  ), redemption_capability as (
    select (
      program.enabled
      and app.platform_feature_enabled('customer_qr_redemption')
      and coalesce(capability.redemption_enabled, false)
    ) as enabled
    from program
    left join public.business_customer_capabilities_v89 capability
      on capability.business_id = p_business
  ), candidate_rewards as (
    select
      'catalog'::text as source,
      reward_version.reward_id,
      reward_version.customer_name as name,
      reward_version.cost_points::integer as cost_units,
      reward_version.credit_cents::integer,
      reward_version.fulfillment_kind,
      reward_version.sort::integer as sort_order,
      greatest(reward_version.cost_points - loyalty_balance.units, 0)::integer
        as remaining_units,
      (redemption_capability.enabled
        and loyalty_balance.units >= reward_version.cost_points) as available_now
    from program
    cross join loyalty_balance
    cross join redemption_capability
    join public.loyalty_reward_versions reward_version
      on reward_version.business_id = p_business
     and reward_version.config_version_id = program.active_config_version_id
     and reward_version.active
    join public.loyalty_rewards reward
      on reward.id = reward_version.reward_id
     and reward.business_id = reward_version.business_id
     and reward.active
     and not reward.paused
    left join lateral (
      select count(*)::integer as used_count
        from public.loyalty_redemptions redemption
       where redemption.business_id = p_business
         and redemption.client_id = p_client
         and redemption.reward_id = reward_version.reward_id
    ) usage on true
    where program.enabled
      and (reward_version.claim_available_from is null
        or reward_version.claim_available_from <= v_as_of)
      and (reward_version.claim_available_until is null
        or reward_version.claim_available_until > v_as_of)
      and (reward_version.usage_limit is null
        or usage.used_count < reward_version.usage_limit)
      and not exists (
        select 1 from public.loyalty_reward_branches restriction
         where restriction.reward_version_id = reward_version.id
      )
      and not exists (
        select 1 from public.loyalty_reward_services restriction
         where restriction.reward_version_id = reward_version.id
      )
      and not exists (
        select 1 from public.loyalty_reward_products restriction
         where restriction.reward_version_id = reward_version.id
      )
  ), reward_list as (
    select coalesce(jsonb_agg(jsonb_build_object(
      'source', candidate.source,
      'reward_id', candidate.reward_id,
      'name', candidate.name,
      'cost_units', candidate.cost_units,
      'credit_cents', candidate.credit_cents,
      'fulfillment_kind', candidate.fulfillment_kind,
      'remaining_units', candidate.remaining_units,
      'available_now', candidate.available_now
    ) order by candidate.remaining_units, candidate.sort_order,
      lower(candidate.name), candidate.reward_id nulls first), '[]'::jsonb)
      as rewards
      from candidate_rewards candidate
  ), next_reward as (
    select jsonb_build_object(
      'source', candidate.source,
      'reward_id', candidate.reward_id,
      'name', candidate.name,
      'cost_units', candidate.cost_units,
      'credit_cents', candidate.credit_cents,
      'fulfillment_kind', candidate.fulfillment_kind,
      'remaining_units', candidate.remaining_units,
      'available_now', candidate.available_now
    ) as reward
    from candidate_rewards candidate
    order by candidate.remaining_units, candidate.sort_order,
      lower(candidate.name), candidate.reward_id nulls first
    limit 1
  )
  select jsonb_build_object(
    'as_of', v_as_of,
    'program', case when program.id is null then null else jsonb_build_object(
      'id', program.id,
      'active', program.enabled,
      'kind', program.kind,
      'model', program.loyalty_model,
      'unit', case when program.loyalty_model = 'stamps'
        then 'stamps' else 'points' end,
      'earn_points_per_dollar', program.earn_points_per_dollar,
      'stamp_per_cents', program.stamp_per_cents,
      'redeem_points', program.redeem_points,
      'reward_credit_cents', program.reward_credit_cents,
      'expiry_mode', program.expiry_mode,
      'configuration_status', program.configuration_status
    ) end,
    'points_balance', loyalty_balance.units,
    'credit_balance_cents', credit_balance.balance_cents,
    'expiry', case
      when not program.enabled or program.expiry_mode = 'none'
        or next_expiry.expires_at is null then null
      else jsonb_build_object(
        'expires_at', next_expiry.expires_at,
        'units', next_expiry.units
      ) end,
    'redemption_enabled', redemption_capability.enabled,
    'rewards', reward_list.rewards,
    'next_reward', next_reward.reward
  ) into v_result
  from program
  cross join loyalty_balance
  cross join credit_balance
  cross join redemption_capability
  cross join reward_list
  left join next_expiry on true
  left join next_reward on true;

  return v_result;
end;
$function$;
CREATE OR REPLACE FUNCTION app.redeem_points_v40_internal(p_business uuid, p_client uuid, p_idempotency_key text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  lp public.loyalty_programs%rowtype;
  bal integer;
  v_batch_balance integer;
  v_remaining integer;
  v_take integer;
  v_batch record;
  v_actor uuid := auth.uid();
  v_staff uuid;
  v_points_id uuid := gen_random_uuid();
  v_credit_id uuid := gen_random_uuid();
  v_operation_id uuid := gen_random_uuid();
  v_payload jsonb;
  v_operation public.loyalty_operations%rowtype;
  v_rows integer;
  v_result json;
  v_points_programme uuid;
begin
  -- v375: points are points, never store credit. This is the only route that ever converted a
  -- points balance into credit_ledger, and it is refused outright rather than left reachable.
  raise exception 'points are redeemed for gifts, not for store credit'
    using errcode = '22023';
  if p_idempotency_key is null or length(btrim(p_idempotency_key)) < 8 then
    raise exception 'idempotency key must contain at least 8 characters' using errcode = '22023';
  end if;
  p_idempotency_key := btrim(p_idempotency_key);
  if not app.has_perm(p_business, 'create_sales') then
    raise exception 'you do not have permission to redeem points in this business (create_sales)'
      using errcode = '42501';
  end if;
  perform 1 from public.businesses where id = p_business for share;

  select s.id into v_staff
    from public.staff s
   where s.business_id = p_business and s.user_id = v_actor and s.active
     and 'create_sales' = any (app.role_perms(s.role))
   order by case s.role when 'owner' then 0 when 'manager' then 1 else 2 end, s.created_at
   limit 1 for update;
  if not found or not app.has_perm(p_business, 'create_sales') then
    raise exception 'active staff authorization changed while redeeming points'
      using errcode = '42501';
  end if;

  perform 1 from public.clients c
   where c.id = p_client and c.business_id = p_business for update;
  if not found then raise exception 'client does not belong to this business'; end if;

  v_payload := jsonb_build_object('business_id', p_business, 'client_id', p_client);
  perform set_config('app.loyalty_operation_insert_id', v_operation_id::text, true);
  insert into public.loyalty_operations
    (id, business_id, client_id, operation_type, actor, idempotency_key,
     request_payload, request_hash)
  values
    (v_operation_id, p_business, p_client, 'redeem_points', v_actor,
     p_idempotency_key, v_payload, md5(v_payload::text))
  on conflict (business_id, operation_type, idempotency_key) do nothing;
  get diagnostics v_rows = row_count;
  perform set_config('app.loyalty_operation_insert_id', '', true);

  if v_rows = 0 then
    select * into v_operation from public.loyalty_operations
     where business_id = p_business and operation_type = 'redeem_points'
       and idempotency_key = p_idempotency_key
     for update;
    if v_operation.actor is distinct from v_actor
       or v_operation.request_payload is distinct from v_payload then
      raise exception 'idempotency key was already used for another redemption request'
        using errcode = '22023';
    end if;
    if v_operation.status = 'completed' then return v_operation.result::json; end if;
    raise exception 'matching redemption is still reserved; retry shortly' using errcode = '40001';
  end if;

  select * into lp from public.loyalty_programs
   where business_id = p_business and active and kind = 'points'
     and redeem_points > 0 and reward_credit_cents > 0 limit 1;
  if not found then
    raise exception 'no active redeemable points program with positive points and credit values';
  end if;
  if lp.loyalty_model is distinct from 'classic' then
    raise exception 'this business redeems points through its reward catalog; use redeem_reward';
  end if;

  select coalesce(sum(pl.points), 0)::integer into bal from public.points_ledger pl
   where pl.business_id = p_business and pl.client_id = p_client;
  if bal < lp.redeem_points then
    raise exception 'insufficient points: % < %', bal, lp.redeem_points;
  end if;
  v_points_programme := app.resolve_ledger_programme_v309(p_business);
  if v_points_programme is null then
    raise exception 'redemption programme is not resolvable for this business'
      using errcode = 'XX001';
  end if;
  select coalesce(sum(pb.remaining), 0)::integer into v_batch_balance
    from public.points_batches pb
   where pb.business_id = p_business and pb.client_id = p_client and pb.remaining > 0
     and pb.programme_id = v_points_programme;
  if v_batch_balance < lp.redeem_points then
    raise exception 'points batches % cannot prove redemption %', v_batch_balance, lp.redeem_points
      using errcode = 'check_violation';
  end if;

  v_remaining := lp.redeem_points;
  for v_batch in
    select pb.id, pb.remaining from public.points_batches pb
     where pb.business_id = p_business and pb.client_id = p_client and pb.remaining > 0
       and pb.programme_id = v_points_programme
     order by pb.expires_at nulls last, pb.earned_at, pb.id for update
  loop
    exit when v_remaining = 0;
    v_take := least(v_batch.remaining, v_remaining);
    update public.points_batches set remaining = remaining - v_take where id = v_batch.id;
    v_remaining := v_remaining - v_take;
  end loop;

  perform set_config('app.points_ledger_insert_id', v_points_id::text, true);
  perform set_config('app.points_ledger_write_scope', 'redeem_points', true);
  insert into public.points_ledger
    (id, business_id, client_id, entry_type, points, reference, actor, programme_id)
  values
    (v_points_id, p_business, p_client, 'redeem', -lp.redeem_points,
     'redeemed to credit', v_actor, v_points_programme);
  perform set_config('app.points_ledger_insert_id', '', true);
  perform set_config('app.points_ledger_write_scope', '', true);

  perform set_config('app.credit_ledger_insert_id', v_credit_id::text, true);
  perform set_config('app.credit_ledger_write_scope', 'redeem_points', true);
  insert into public.credit_ledger
    (id, business_id, client_id, entry_type, amount_cents, reference, actor)
  values
    (v_credit_id, p_business, p_client, 'loyalty_earn', lp.reward_credit_cents,
     'points redemption', v_actor);
  perform set_config('app.credit_ledger_insert_id', '', true);
  perform set_config('app.credit_ledger_write_scope', '', true);

  v_result := json_build_object(
    'points_spent', lp.redeem_points,
    'credit_cents', lp.reward_credit_cents
  );
  perform set_config('app.loyalty_operation_complete_id', v_operation_id::text, true);
  update public.loyalty_operations
     set status = 'completed', result = v_result::jsonb, completed_at = now()
   where id = v_operation_id;
  perform set_config('app.loyalty_operation_complete_id', '', true);
  return v_result;
end $function$;
select set_config('request.jwt.claims',
  json_build_object('sub',(select owner from _c),'role','authenticated')::text,true);
set local role authenticated;

-- 03 — no customer is ever promised store credit again.
insert into _r select '03 no store credit is offered',
  case when pg_temp.rewards_v375()::text not ilike '%SGD 1.50 credit%'
  then 'PASS' else 'FAIL store credit is still offered: '||pg_temp.rewards_v375()::text end;

-- 04 — and the gift the business actually published is what the customer is shown instead.
insert into _r select '04 the published gift is offered',
  case when pg_temp.rewards_v375()::text ilike '%Free Facial cream%'
  then 'PASS' else 'FAIL the published gift is still withheld: '||pg_temp.rewards_v375()::text end;

-- 05 — the only route that ever minted credit from points refuses.
insert into _r select '05 redeeming points for credit is refused',
  case when pg_temp.try_redeem_v375() like '22023%' and pg_temp.try_redeem_v375() ilike '%not for store credit%'
  then 'PASS' else 'FAIL redeem_points did not refuse: '||pg_temp.try_redeem_v375() end;

reset role;
select k as check, v as result from _r order by k;

rollback;
