-- nestly_v875 — the customer's "Loyalty activity" reads the same pot as their balance.
--
-- WHAT WAS LIVE, AND WHY IT IS WRONG. public.customer_get_loyalty_details prints the
-- customer's balance through app.client_points_balance_v409 — scoped to the live programme
-- pot (v312/v381) — and then lists "activity" from public.points_ledger with NO pot predicate,
-- and computes "expiring soon" from public.points_batches with no pot predicate either. So the
-- feed under a 1,150-point balance listed rows from a switched-off stamps programme, and the
-- internal pot-transfer bookkeeping the platform writes when the owner flips a programme
-- (+75,877 / -75,877 pairs on Cubbly SPA customer 268cb96d, four times in 28 minutes on
-- 2026-08-16) as if it were customer activity. The numbers on one screen described two
-- different pots.
--
-- THE FIX. The ledger arm and both batch subqueries carry the same predicate the balance uses
-- (scope read into locals once — v370: a resolver inlined into a WHERE is re-evaluated per row).
-- The net-zero 'programme pot transfer' pairs are bookkeeping, not activity, and are hidden.
-- A conversion row ('stamp conversion: points spent' / 'stamps issued') IS something that
-- happened to the customer's balance and stays visible, titled for what it was. Everything
-- else — redemptions, grants, paging, the payload shape — is unchanged.

begin;

create or replace function public.customer_get_loyalty_details(p_business_slug text, p_cursor jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_context record;
  v_program public.loyalty_programs%rowtype;
  v_cursor jsonb:=coalesce(p_cursor,'{}'::jsonb);
  v_limit integer:=20;
  v_before_at timestamptz;
  v_before_id uuid;
  v_result jsonb;
  -- nestly_v875: the pot the balance is scoped to, resolved once.
  v_scope text;
  v_live uuid;
begin
  if auth.uid() is null then
    raise exception 'authenticated customer session required'
      using errcode='28000';
  end if;
  if pg_catalog.jsonb_typeof(v_cursor)<>'object'
     or exists(
       select 1
       from pg_catalog.jsonb_object_keys(v_cursor) as keys(key)
       where keys.key not in ('limit','before_at','before_id')
     ) then
    raise exception 'invalid loyalty activity cursor' using errcode='22023';
  end if;
  begin
    v_limit:=least(
      greatest(coalesce((v_cursor->>'limit')::integer,20),1),50
    );
    v_before_at:=nullif(v_cursor->>'before_at','')::timestamptz;
    v_before_id:=nullif(v_cursor->>'before_id','')::uuid;
  exception when others then
    raise exception 'invalid loyalty activity cursor' using errcode='22023';
  end;
  if (v_before_at is null)<>(v_before_id is null) then
    raise exception 'loyalty activity cursor is incomplete'
      using errcode='22023';
  end if;

  select * into v_context
  from app.v32_customer_wallet_context(p_business_slug)
  limit 1;
  if not found then
    raise exception 'verified customer link required' using errcode='42501';
  end if;
  if not ('loyalty'=any(v_context.enabled_modules)) then
    raise exception 'loyalty module is unavailable for this business'
      using errcode='42501';
  end if;
  select * into v_program
  from public.loyalty_programs program
  where program.business_id=v_context.business_id
    and program.active
  limit 1;
  if not found then
    raise exception 'loyalty module is unavailable for this business'
      using errcode='42501';
  end if;

  v_scope := app.programme_balance_scope_v312(v_context.business_id);
  v_live  := app.live_balance_programme_v381(v_context.business_id);

  with activity as (
    select
      ledger.id,
      ledger.created_at as event_at,
      ledger.entry_type as event_type,
      ledger.points::integer as points_delta,
      case
        when ledger.reference like 'stamp conversion:%' then 'Programme switched'
        when ledger.entry_type='earn' then 'Points earned'
        when ledger.entry_type='expire' then 'Points expired'
        when ledger.entry_type='adjust' then 'Balance adjustment'
        else 'Loyalty activity'
      end as title,
      case when ledger.reference like 'stamp conversion:%' then ledger.reference else null end::text as detail,
      null::text as status,
      null::timestamptz as entitlement_expires_at,
      false as is_campaign_entitlement,
      null::text as entitlement_status,
      null::text as fulfillment_status,
      null::text as redemption_mode,
      null::boolean as economic_value_posted,
      null::text as fulfillment_kind,
      null::text as reward_label,
      false as reward_value_hidden,
      null::text as display_label,
      null::bigint as display_amount_cents
    from public.points_ledger ledger
    where ledger.business_id=v_context.business_id
      and ledger.client_id=v_context.client_id
      and ledger.entry_type in ('earn','expire','adjust')
      -- nestly_v875: the same pot the balance above is summed from.
      and (v_scope <> 'programme_pot' or ledger.programme_id is not distinct from v_live)
      -- nestly_v875: pot-transfer pairs are platform bookkeeping (net zero), not activity.
      and coalesce(ledger.reference,'') not like 'programme pot transfer %'
    union all
    select
      redemption.id,
      redemption.redeemed_at,
      'reward_claimed',
      -redemption.points_spent,
      redemption.reward_name,
      null::text,
      case when reversal.id is null then 'claimed' else 'reversed' end,
      redemption.entitlement_expires_at,
      false,null::text,null::text,null::text,null::boolean,
      null::text,redemption.reward_name,false,redemption.reward_name,
      null::bigint
    from public.loyalty_redemptions redemption
    left join public.loyalty_redemption_reversals reversal
      on reversal.business_id=redemption.business_id
     and reversal.redemption_id=redemption.id
    where redemption.business_id=v_context.business_id
      and redemption.client_id=v_context.client_id
    union all
    select
      reward.id,
      reward.granted_at,
      case when reward.campaign_id is not null
        then 'campaign_offer_entitlement'
        else 'retention_reward'
      end,
      0,
      case when reward.campaign_id is not null
        then 'Offer awaiting merchant fulfilment'
        else coalesce(
          nullif(btrim(reward.reward_label),''),'Reward earned'
        )
      end,
      case when reward.campaign_id is not null
        then 'No wallet value has been posted. Ask the business to fulfil this offer.'
        else null::text
      end,
      case
        when reward.campaign_id is not null and reward.status='expired'
          then 'expired_unfulfilled'
        when reward.campaign_id is not null
          then 'merchant_fulfilment_pending'
        else reward.status
      end,
      null::timestamptz,
      reward.campaign_id is not null,
      reward.status,
      case
        when reward.campaign_id is not null and reward.status='expired'
          then 'expired_unfulfilled'
        when reward.campaign_id is not null
          then 'merchant_fulfilment_pending'
        else reward.status
      end,
      case when reward.campaign_id is not null
        then 'merchant_fulfilment_pending'
        else null::text
      end,
      case when reward.campaign_id is not null then false else null::boolean end,
      reward.fulfillment_kind,
      reward.reward_label,
      reward.campaign_id is not null,
      case when reward.campaign_id is not null
        then 'Offer awaiting merchant fulfilment'
        else coalesce(nullif(btrim(reward.reward_label),''),'Reward')
      end,
      case
        when reward.campaign_id is null
         and reward.fulfillment_kind='credit'
          then reward.reward_value::bigint
        else null::bigint
      end
    from public.reward_grants reward
    where reward.business_id=v_context.business_id
      and reward.client_id=v_context.client_id
  ), eligible as (
    select *
    from activity
    where v_before_at is null
       or (event_at,id)<(v_before_at,v_before_id)
    order by event_at desc,id desc
    limit v_limit+1
  ), visible as (
    select * from eligible order by event_at desc,id desc limit v_limit
  )
  select pg_catalog.jsonb_build_object(
    'model',v_program.loyalty_model,
    'unit',case when v_program.loyalty_model='stamps'
      then 'stamps' else 'points' end,
    'programme',pg_catalog.jsonb_build_object(
      'kind',case when v_program.loyalty_model='stamps' then 'stamps' else 'points' end,
      'active',coalesce((
        select spine.active from public.business_programmes spine
         where spine.business_id=v_context.business_id
           and spine.kind=case when v_program.loyalty_model='stamps'
                               then 'stamps' else 'points' end),false),
      'balance_scope',v_scope),
    'balance',app.client_points_balance_v409(v_context.business_id,v_context.client_id),
    'expiry',pg_catalog.jsonb_build_object(
      'expiring_next_30_days',coalesce((
        select sum(batch.remaining)::integer
        from public.points_batches batch
        where batch.business_id=v_context.business_id
          and batch.client_id=v_context.client_id
          and batch.remaining>0
          and (v_scope <> 'programme_pot' or batch.programme_id is not distinct from v_live)
          and batch.expires_at>now()
          and batch.expires_at<=now()+interval '30 days'
      ),0),
      'next_expiry_at',(
        select min(batch.expires_at)
        from public.points_batches batch
        where batch.business_id=v_context.business_id
          and batch.client_id=v_context.client_id
          and batch.remaining>0
          and (v_scope <> 'programme_pot' or batch.programme_id is not distinct from v_live)
          and batch.expires_at>now()
      )
    ),
    'items',coalesce((
      select pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'event_at',event_at,
          'event_type',event_type,
          'points_delta',points_delta,
          'title',title,
          'detail',detail,
          'status',status,
          'entitlement_expires_at',entitlement_expires_at,
          'is_campaign_entitlement',is_campaign_entitlement,
          'entitlement_status',entitlement_status,
          'fulfillment_status',fulfillment_status,
          'redemption_mode',redemption_mode,
          'economic_value_posted',economic_value_posted,
          'fulfillment_kind',fulfillment_kind,
          'reward_label',reward_label,
          'reward_value_hidden',reward_value_hidden,
          'display_label',display_label,
          'display_amount_cents',display_amount_cents
        )
        order by event_at desc,id desc
      )
      from visible
    ),'[]'::jsonb),
    'next_cursor',case
      when (select count(*) from eligible)>v_limit then (
        select pg_catalog.jsonb_build_object(
          'before_at',event_at,'before_id',id,'limit',v_limit
        )
        from visible order by event_at,id limit 1
      )
      else null
    end
  ) into v_result;
  return v_result;
end
$function$;

-- ACL restated verbatim from prod (nestly_v875).
revoke all on function public.customer_get_loyalty_details(text,jsonb) from public, anon;
grant execute on function public.customer_get_loyalty_details(text,jsonb) to authenticated;

do $verify$
declare v_def text := pg_get_functiondef('public.customer_get_loyalty_details(text,jsonb)'::regprocedure);
begin
  if position('ledger.programme_id is not distinct from v_live' in v_def) = 0
     or position('batch.programme_id is not distinct from v_live' in v_def) = 0
     or position('programme pot transfer %' in v_def) = 0 then
    raise exception 'nestly_v875: customer loyalty activity is not pot-scoped' using errcode = 'XX001';
  end if;
end
$verify$;

commit;
