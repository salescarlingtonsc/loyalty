-- Rollback-only v666 acceptance suite (owner photo 2026-09-01: "when press create branch > leads
-- to that customer tier error").
--
--   T1  business_add_branch_v202 no longer derives a capacity from the retired block model.
--   T2  A business with no terms row and a handful of customers creates a branch successfully —
--       the branch exists, unpaid and switched off, and a billing command was minted.
--   T3  The capacity the command carries is a PUBLISHED TIER, which is the thing
--       request_billing_command_v124 refuses if it is anything else.
--   T4  A pre-v664 terms row with a block-model capacity (3,000) is rounded UP to the tier that
--       covers it rather than being refused.
--
-- Runs as the branch's real owner. Rolled back.
begin;
create temporary table v666_evidence(test text, detail text) on commit drop;

create temporary table v666_fixture on commit drop as
select b.id as business_id,
       (select s.user_id from public.staff s
         where s.business_id=b.id and s.role='owner' and s.active and s.user_id is not null
         order by s.created_at limit 1) as owner_user
  from public.businesses b
 where exists (select 1 from public.subscriptions sub where sub.business_id=b.id)
   and exists (select 1 from public.staff s where s.business_id=b.id and s.role='owner'
                 and s.active and s.user_id is not null)
   and not exists (select 1 from public.billing_subscription_terms_v124 t where t.business_id=b.id)
 order by b.created_at
 limit 1;

do $t$
declare
  f record; v_added jsonb; v_command record; v_branch public.branches%rowtype; v_def text;
begin
  select * into f from v666_fixture;
  if f.business_id is null then raise exception 'V666 FIXTURE: no owner-led business without terms'; end if;

  v_def := pg_get_functiondef('public.business_add_branch_v202(uuid,text,text,text,text,uuid,uuid)'::regprocedure);
  if v_def like '%ceil(count(*)::numeric/1000)::integer*1000%' then
    raise exception 'T1: the block-model capacity derivation is still there';
  end if;
  if v_def not like '%billing_tier_for_capacity_v664%' then
    raise exception 'T1: the tier ladder is not consulted';
  end if;
  insert into v666_evidence values('T1','the capacity comes from the tier ladder, not blocks');

  perform set_config('request.jwt.claims',
    json_build_object('sub',f.owner_user::text,'role','authenticated')::text, true);

  v_added := public.business_add_branch_v202(
    f.business_id,'v666 probe branch',null,null,null,null,gen_random_uuid());
  if coalesce(v_added->>'status','') <> 'ok' then
    raise exception 'T2: adding a branch returned %', v_added->>'status';
  end if;
  select * into v_branch from public.branches where id=(v_added->>'branch_id')::uuid;
  if v_branch.billing_state <> 'pending_payment' or v_branch.active then
    raise exception 'T2: the new branch is %/active=%', v_branch.billing_state, v_branch.active;
  end if;
  if v_added->>'command_id' is null then
    raise exception 'T2: no billing command was minted for the new branch';
  end if;
  insert into v666_evidence values('T2','a branch is created, unpaid and switched off, with a billing command');

  select * into v_command from public.billing_commands where id=(v_added->>'command_id')::uuid;
  if not exists (
    select 1 from public.billing_capacity_tier_catalog_v664 tier
     where tier.active and tier.cadence = v_command.requested_cadence
       and tier.capacity_ceiling = v_command.requested_customer_capacity
  ) then
    raise exception 'T3: the command asks for capacity %, which is not a published % tier',
      v_command.requested_customer_capacity, v_command.requested_cadence;
  end if;
  insert into v666_evidence values('T3','the branch command carries a published tier');
end
$t$;

do $t4$
declare
  f record; v_added jsonb; v_command record; v_capacity integer;
begin
  select * into f from v666_fixture;
  -- a pre-v664 terms row: 3,000 profiles under the retired block model
  insert into public.billing_subscription_terms_v124(
    business_id,provider_subscription_id,pricing_model,cadence,customer_capacity,capacity_blocks,
    provider_base_price_id,provider_event_created_at,last_event_id)
  values (f.business_id,'sub_v666_probe','v124_customer_capacity','annual',3000,3,
          'price_v666_probe',now(),'evt_v666_probe')
  on conflict (business_id) do update set customer_capacity=3000, capacity_blocks=3;

  perform set_config('request.jwt.claims',
    json_build_object('sub',f.owner_user::text,'role','authenticated')::text, true);
  v_added := public.business_add_branch_v202(
    f.business_id,'v666 probe branch two',null,null,null,null,gen_random_uuid());
  select * into v_command from public.billing_commands where id=(v_added->>'command_id')::uuid;
  v_capacity := v_command.requested_customer_capacity;
  if v_capacity is null or v_capacity < 3000 then
    raise exception 'T4: a 3,000-profile legacy tenant was quoted %', v_capacity;
  end if;
  if not exists (
    select 1 from public.billing_capacity_tier_catalog_v664 tier
     where tier.active and tier.cadence='annual' and tier.capacity_ceiling = v_capacity
  ) then
    raise exception 'T4: legacy capacity 3,000 mapped to %, which is not a tier', v_capacity;
  end if;
  insert into v666_evidence values('T4','a legacy block capacity is rounded up to the covering tier');
end
$t4$;

select test, detail from v666_evidence order by test;
rollback;
