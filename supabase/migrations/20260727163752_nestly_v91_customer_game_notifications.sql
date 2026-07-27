-- Nestly v91 customer experience: only surface the two urgent expiry moments
-- requested by the customer journey (3 days and 1 day). C46 remains the
-- customer-safe, consent-aware inbox authority; this changes presentation
-- timing without adding a second notification ledger.

begin;

create or replace function app.c46_customer_safe_inbox_candidates(p_card jsonb)
returns table (
  source_kind text, topic text, title text, body text,
  source_fingerprint text, deadline_at timestamptz
)
language sql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select 'c44_actionable_wallet', 'value_expiry',
         case
           when (nullif(p_card#>>'{expiry,next_expiry_at}','')::timestamptz-now())<=interval '1 day'
             then case when p_card#>>'{loyalty,unit}'='stamps' then 'Stamps expire tomorrow' else 'Points expire tomorrow' end
           else case when p_card#>>'{loyalty,unit}'='stamps' then 'Stamps expire within 3 days' else 'Points expire within 3 days' end
         end,
         case when p_card#>>'{loyalty,unit}'='stamps'
           then 'Open this programme now to review your expiring stamps.'
           else 'Open this programme now to review your expiring points.' end,
         app.c46_sha256_hex(jsonb_build_object(
           'source','c44-expiry-urgent',
           'window',case when (nullif(p_card#>>'{expiry,next_expiry_at}','')::timestamptz-now())<=interval '1 day' then 'one_day' else 'three_days' end,
           'deadline',p_card#>>'{expiry,next_expiry_at}',
           'unit',p_card#>>'{loyalty,unit}'
         )::text),
         nullif(p_card#>>'{expiry,next_expiry_at}','')::timestamptz
   where p_card#>>'{loyalty,unit}' in ('points','stamps')
     and coalesce((p_card#>>'{expiry,expiring_units}')::integer, 0)>0
     and nullif(p_card#>>'{expiry,next_expiry_at}','') is not null
     and nullif(p_card#>>'{expiry,next_expiry_at}','')::timestamptz>now()
     and nullif(p_card#>>'{expiry,next_expiry_at}','')::timestamptz<=now()+interval '3 days'
  union all
  select 'c44_actionable_wallet', 'reward_ready', 'Reward unlocked!',
         'Open this programme to view and redeem your reward.',
         app.c46_sha256_hex(jsonb_build_object(
           'source','c44-reward','name',p_card#>>'{next_eligible_reward,name}',
           'cost',p_card#>>'{next_eligible_reward,cost_units}'
         )::text), null
   where coalesce((p_card#>>'{next_eligible_reward,available_now}')::boolean, false)
  union all
  select 'c44_actionable_wallet', 'visit_progress', 'Quest almost complete',
         'One qualifying visit remains before your next reward.',
         app.c46_sha256_hex(jsonb_build_object(
           'source','c44-visit','period_end',p_card#>>'{visit_progress,period_ends_at}',
           'goal',p_card#>>'{visit_progress,goal_visits}'
         )::text), nullif(p_card#>>'{visit_progress,period_ends_at}','')::timestamptz
   where coalesce((p_card#>>'{visits_remaining}')::integer, -1)=1
  union all
  select 'c45_birthday_benefit', 'birthday_benefit', 'Birthday surprise unlocked',
         'Open this programme to view your birthday benefit.',
         app.c46_sha256_hex(jsonb_build_object(
           'source','c45-birthday','status',p_card#>>'{birthday_benefit,status}',
           'until',p_card#>>'{birthday_benefit,validity,available_until}'
         )::text), nullif(p_card#>>'{birthday_benefit,validity,available_until}','')::timestamptz
   where p_card#>>'{birthday_benefit,status}' in ('ready_to_activate','available')
$$;

revoke all on function app.c46_customer_safe_inbox_candidates(jsonb)
  from public, anon, authenticated;
grant execute on function app.c46_customer_safe_inbox_candidates(jsonb)
  to service_role;

create or replace function public.business_get_customer_join_qr_status_v91(p_business uuid)
returns jsonb
language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_count integer;v_expires_at timestamptz;
begin
  if not (app.is_salon_owner(p_business) or app.is_super_admin()) then
    raise exception 'business owner access is required' using errcode='42501';
  end if;
  select count(*)::integer,max(q.expires_at) into v_count,v_expires_at
  from public.business_customer_join_qr_v89 q
  where q.business_id=p_business and q.status='active' and q.expires_at>now();
  return jsonb_build_object('active_count',v_count,'latest_expires_at',v_expires_at);
end
$$;

revoke all on function public.business_get_customer_join_qr_status_v91(uuid)
  from public, anon, authenticated;
grant execute on function public.business_get_customer_join_qr_status_v91(uuid)
  to authenticated;

create or replace function public.business_ensure_customer_join_qr_v91(
  p_business uuid,p_expires_at timestamptz default now()+interval '365 days'
)
returns jsonb
language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_existing record;v_created jsonb;
begin
  if not (app.is_salon_owner(p_business) or app.is_super_admin()) then
    raise exception 'business owner access is required' using errcode='42501';
  end if;
  if p_expires_at<=now()+interval '5 minutes'
     or p_expires_at>now()+interval '370 days' then
    raise exception 'join QR expiry must be between 5 minutes and 370 days'
      using errcode='22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(
    'v90:join-qr:'||p_business::text,0
  ));
  select q.id,q.expires_at into v_existing
  from public.business_customer_join_qr_v89 q
  where q.business_id=p_business and q.status='active' and q.expires_at>now()
  order by q.expires_at desc,q.id desc
  limit 1;
  if found then
    return jsonb_build_object(
      'business_id',p_business,'created',false,'qr_id',v_existing.id,
      'expires_at',v_existing.expires_at
    );
  end if;

  v_created:=public.business_create_customer_join_qr_v89(
    p_business,p_expires_at
  );
  return v_created||jsonb_build_object('business_id',p_business,'created',true);
end
$$;

revoke all on function public.business_ensure_customer_join_qr_v91(uuid,timestamptz)
  from public, anon, authenticated;
grant execute on function public.business_ensure_customer_join_qr_v91(uuid,timestamptz)
  to authenticated;

commit;
