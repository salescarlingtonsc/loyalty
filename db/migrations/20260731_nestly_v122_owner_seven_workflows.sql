-- Nestly v122 — owner-requested counter, profitability, feedback, and
-- consent-aware promotion workflow contracts.

begin;

-- Real product cost is an authorised inventory input. Existing rows remain
-- explicit unknowns instead of being silently treated as zero-cost.
alter table public.products
  add column cost_cents bigint,
  add constraint products_cost_cents_check
    check (cost_cents is null or cost_cents between 0 and 2147483647);
comment on column public.products.cost_cents is
  'Authorised unit product cost in business currency cents. NULL means unknown; it is never inferred from retail price.';

-- Inventory is deliberately platform-disabled in v94. Reward economics still
-- needs a narrow owner-only product-cost boundary, so Grow never reopens the
-- wider inventory module or relies on its RLS policies.
create or replace function public.owner_list_reward_profitability_products_v122(
  p_business uuid
)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  if auth.uid() is null then
    raise exception 'authenticated_session_required' using errcode='28000';
  end if;
  if p_business is null
     or not exists(
       select 1 from public.staff staff_row
       where staff_row.business_id=p_business
         and staff_row.user_id=auth.uid()
         and staff_row.active
         and staff_row.role='owner'
     )
     or not app.can_module_write(p_business,'loyalty')
  then
    raise exception 'owner_loyalty_write_required' using errcode='42501';
  end if;
  return jsonb_build_object('items',coalesce((
    select jsonb_agg(jsonb_build_object(
      'id',product.id,'name',product.name,
      'retail_price_cents',product.retail_price_cents,
      'cost_cents',product.cost_cents
    ) order by product.name,product.id)
    from public.products product
    where product.business_id=p_business and product.active
  ),'[]'::jsonb));
end
$$;

create or replace function public.owner_set_product_cost_v122(
  p_business uuid,
  p_product uuid,
  p_cost_cents bigint,
  p_expected_cost_cents bigint
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_product public.products%rowtype;
begin
  if auth.uid() is null then
    raise exception 'authenticated_session_required' using errcode='28000';
  end if;
  if p_business is null or p_product is null
     or p_cost_cents is null
     or p_cost_cents not between 0 and 2147483647
  then
    raise exception 'valid_product_cost_required' using errcode='22023';
  end if;
  if not exists(
       select 1 from public.staff staff_row
       where staff_row.business_id=p_business
         and staff_row.user_id=auth.uid()
         and staff_row.active
         and staff_row.role='owner'
     )
     or not app.can_module_write(p_business,'loyalty')
  then
    raise exception 'owner_loyalty_write_required' using errcode='42501';
  end if;
  select * into v_product
  from public.products product
  where product.id=p_product and product.business_id=p_business and product.active
  for update;
  if not found then
    raise exception 'active_product_not_found' using errcode='P0002';
  end if;
  -- A replay after a lost response is harmless; a genuinely stale editor
  -- refuses instead of silently overwriting another owner.
  if v_product.cost_cents is not distinct from p_cost_cents then
    return jsonb_build_object(
      'id',v_product.id,'cost_cents',v_product.cost_cents,'replayed',true
    );
  end if;
  if v_product.cost_cents is distinct from p_expected_cost_cents then
    raise exception 'product_cost_changed_refresh_required' using errcode='40001';
  end if;
  update public.products
  set cost_cents=p_cost_cents
  where id=v_product.id
  returning * into v_product;
  return jsonb_build_object(
    'id',v_product.id,'cost_cents',v_product.cost_cents,'replayed',false
  );
end
$$;

revoke all on function public.owner_list_reward_profitability_products_v122(uuid)
  from public,anon,authenticated;
revoke all on function public.owner_set_product_cost_v122(uuid,uuid,bigint,bigint)
  from public,anon,authenticated;
grant execute on function public.owner_list_reward_profitability_products_v122(uuid)
  to authenticated;
grant execute on function public.owner_set_product_cost_v122(uuid,uuid,bigint,bigint)
  to authenticated;

-- Feedback already persists through the v53 RPC. Add a durable staff
-- notification so the existing authenticated Realtime channel refreshes the
-- queue in other sessions without granting browsers direct table access.
alter table public.notifications
  drop constraint notifications_kind_check,
  add constraint notifications_kind_check check(kind in(
    'booking_new','booking_waitlisted','change_request','booking_expired',
    'waitlist_ready','subscription_payment_due','feedback_new'
  ));

create or replace function app.visit_feedback_v122_notify_staff()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  insert into public.notifications(
    business_id,kind,title,body,ref_table,ref_id
  ) values (
    new.business_id,'feedback_new','New customer feedback',
    case when new.recovery_status='open'
      then 'A customer response needs follow-up.'
      else 'A customer shared visit feedback.'
    end,
    'visit_feedback',new.id
  );
  return new;
end
$$;
revoke all on function app.visit_feedback_v122_notify_staff()
  from public,anon,authenticated;

create trigger visit_feedback_v122_notify_staff
after insert on public.visit_feedback
for each row execute function app.visit_feedback_v122_notify_staff();

-- Promotion alerts are their own explicit consent topic. They do not inherit
-- an old generic marketing or loyalty preference.
alter table public.customer_notification_preferences
  drop constraint customer_notification_preferences_topic_check,
  add constraint customer_notification_preferences_topic_check check (topic in (
    'marketing','loyalty_updates','value_expiry','reward_ready','visit_progress',
    'birthday_benefit','booking_updates','promotion_alerts'
  ));
alter table public.customer_preference_audit
  drop constraint customer_preference_audit_topic_check,
  add constraint customer_preference_audit_topic_check check (topic in (
    'marketing','loyalty_updates','value_expiry','reward_ready','visit_progress',
    'birthday_benefit','booking_updates','promotion_alerts'
  ));

create or replace function app.c46_in_app_topic_allowed(p_topic text)
returns boolean language sql immutable
set search_path to 'pg_catalog','pg_temp'
as $$
  select $1 = any(array[
    'value_expiry','reward_ready','visit_progress','birthday_benefit',
    'booking_updates','promotion_alerts'
  ]::text[])
$$;

alter table public.customer_in_app_inbox_events
  drop constraint customer_in_app_inbox_events_source_kind_check,
  add constraint customer_in_app_inbox_events_source_kind_check check(source_kind in(
    'c44_actionable_wallet','c45_birthday_benefit','v33_booking_action',
    'v48_appointment_reschedule','v122_promotion_new','v122_promotion_expiry'
  )),
  drop constraint customer_in_app_inbox_events_topic_check,
  add constraint customer_in_app_inbox_events_topic_check check(topic in(
    'value_expiry','reward_ready','visit_progress','birthday_benefit',
    'booking_updates','promotion_alerts'
  )),
  drop constraint customer_in_app_inbox_events_title_check,
  add constraint customer_in_app_inbox_events_title_check check(title in(
    'Points expire soon','Stamps expire soon','A reward is ready','One visit to go',
    'Birthday benefit ready','Appointment request received','Appointment time changed',
    'Points expire tomorrow','Stamps expire tomorrow','Points expire within 3 days',
    'Stamps expire within 3 days','Reward unlocked!','Quest almost complete',
    'Birthday surprise unlocked','New promotion available','Promotion ending soon'
  )),
  drop constraint customer_in_app_inbox_events_body_check,
  add constraint customer_in_app_inbox_events_body_check check(body in(
    'Open this business wallet to review your points.',
    'Open this business wallet to review your stamps.',
    'Open this business wallet to view the available reward.',
    'One qualifying visit remains before your next reward.',
    'Open this business wallet to view your birthday benefit.',
    'Open this business wallet to review your appointment request.',
    'Open this business wallet to review your updated appointment.',
    'Open this programme now to review your expiring points.',
    'Open this programme now to review your expiring stamps.',
    'Open this programme to view and redeem your reward.',
    'Open this programme to view your birthday benefit.',
    'Open this programme to view the latest promotion.',
    'Open this programme before the current promotion ends.'
  ));

create or replace function app.c46_inbox_source_available(
  p_source_kind text,p_actionable_wallet_enabled boolean
)
returns boolean language sql immutable
set search_path to 'pg_catalog','pg_temp'
as $$
  select $1 in (
    'v33_booking_action','v48_appointment_reschedule',
    'v122_promotion_new','v122_promotion_expiry'
  ) or (
    coalesce($2,false)
    and $1 in ('c44_actionable_wallet','c45_birthday_benefit')
  )
$$;

create or replace function public.customer_get_in_app_inbox_preferences(
  p_business_slug text
)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_context record;
begin
  if not app.platform_feature_enabled('customer_in_app_inbox') then
    raise exception 'customer in-app inbox is not enabled' using errcode='0A000';
  end if;
  select * into v_context from app.c46_customer_inbox_context(p_business_slug);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'topic',topics.topic,'opted_in',coalesce(preference.opted_in,false),
      'quiet_hours_timezone',preference.quiet_hours_timezone,
      'quiet_hours_start',preference.quiet_hours_start,
      'quiet_hours_end',preference.quiet_hours_end
    ) order by topics.ordinal)
    from (values
      (1,'value_expiry'::text),(2,'reward_ready'::text),
      (3,'visit_progress'::text),(4,'birthday_benefit'::text),
      (5,'booking_updates'::text),(6,'promotion_alerts'::text)
    ) topics(ordinal,topic)
    left join public.customer_notification_preferences preference
      on preference.business_id=v_context.business_id
     and preference.identity_id=v_context.identity_id
     and preference.link_id=v_context.link_id
     and preference.channel='in_app'
     and preference.topic=topics.topic
  ),'[]'::jsonb);
end
$$;
revoke all on function public.customer_get_in_app_inbox_preferences(text)
  from public,anon,authenticated;
grant execute on function public.customer_get_in_app_inbox_preferences(text)
  to authenticated;

create or replace function app.customer_push_event_eligible_v95(
  p_source_kind text,p_topic text
)
returns boolean language sql immutable
set search_path to 'pg_catalog','pg_temp'
as $$
  select (p_source_kind,p_topic) in (
    ('c44_actionable_wallet','value_expiry'),
    ('c44_actionable_wallet','reward_ready'),
    ('c44_actionable_wallet','visit_progress'),
    ('c45_birthday_benefit','birthday_benefit'),
    ('v33_booking_action','booking_updates'),
    ('v48_appointment_reschedule','booking_updates'),
    ('v122_promotion_new','promotion_alerts'),
    ('v122_promotion_expiry','promotion_alerts')
  )
$$;

-- One durable campaign watermark prevents the scheduler from re-running a
-- customer-wide fanout after that exact activation/expiry version succeeded.
create table public.promotion_alert_runs_v122(
  promotion_id uuid not null
    references public.business_customer_content_v95(id) on delete restrict,
  source_kind text not null check(
    source_kind in('v122_promotion_new','v122_promotion_expiry')
  ),
  source_version text not null check(length(source_version) between 1 and 200),
  processed_at timestamptz not null default now(),
  primary key(promotion_id,source_kind,source_version)
);
alter table public.promotion_alert_runs_v122 enable row level security;
revoke all privileges on table public.promotion_alert_runs_v122
  from public,anon,authenticated;

-- One insert path for both publication and the daily expiry sweep. The
-- customer/link tuple and opted-in preference are server-derived; the
-- deterministic fingerprint/dedupe pair prevents repeat popup/push events.
create or replace function app.enqueue_promotion_alert_v122(
  p_promotion uuid,p_source_kind text
)
returns integer language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_content public.business_customer_content_v95%rowtype;
  v_source_version text;
  v_inserted integer:=0;
begin
  if p_source_kind not in ('v122_promotion_new','v122_promotion_expiry') then
    raise exception 'unsupported promotion alert kind' using errcode='22023';
  end if;
  select * into v_content
  from public.business_customer_content_v95 content
  where content.id=p_promotion
    and content.content_type='offer'
    and content.metadata->>'schema'='nestly.promotion.v104'
    and content.active
    and content.branch_id is null
    and (content.starts_at is null or content.starts_at<=now())
    and content.ends_at>now();
  if not found then return 0; end if;
  if not exists(
    select 1 from public.business_media_assets_v95 asset
    where asset.business_id=v_content.business_id
      and asset.asset_kind='offer'
      and asset.entity_id=v_content.id
      and asset.customer_visible
      and asset.branch_id is null
  ) then
    return 0;
  end if;
  v_source_version:=case when p_source_kind='v122_promotion_new'
    then coalesce(v_content.metadata->>'published_once_at','missing')
    else coalesce(v_content.metadata->>'published_once_at','missing')
      ||':'||v_content.ends_at::text end;
  insert into public.promotion_alert_runs_v122(
    promotion_id,source_kind,source_version
  ) values(
    v_content.id,p_source_kind,v_source_version
  ) on conflict do nothing;
  if not found then return 0; end if;

  insert into public.customer_in_app_inbox_events(
    business_id,identity_id,auth_user_id,link_id,client_id,
    source_kind,topic,route_key,source_fingerprint,dedupe_key,
    title,body,deadline_at
  )
  select
    link.business_id,link.identity_id,link.auth_user_id,link.id,link.client_id,
    p_source_kind,'promotion_alerts','wallet_business',
    app.c46_sha256_hex((jsonb_build_object(
      'promotion_id',v_content.id,'source_kind',p_source_kind,
      'published_once_at',v_content.metadata->>'published_once_at'
    ) || case when p_source_kind='v122_promotion_expiry'
      then jsonb_build_object('ends_at',v_content.ends_at)
      else '{}'::jsonb end)::text),
    app.c46_sha256_hex((jsonb_build_object(
      'business_id',link.business_id,'identity_id',link.identity_id,
      'promotion_id',v_content.id,'source_kind',p_source_kind,
      'published_once_at',v_content.metadata->>'published_once_at'
    ) || case when p_source_kind='v122_promotion_expiry'
      then jsonb_build_object('ends_at',v_content.ends_at)
      else '{}'::jsonb end)::text),
    case when p_source_kind='v122_promotion_new'
      then 'New promotion available' else 'Promotion ending soon' end,
    case when p_source_kind='v122_promotion_new'
      then 'Open this programme to view the latest promotion.'
      else 'Open this programme before the current promotion ends.' end,
    v_content.ends_at
  from public.customer_links link
  join public.customer_notification_preferences preference
    on preference.business_id=link.business_id
   and preference.identity_id=link.identity_id
   and preference.auth_user_id=link.auth_user_id
   and preference.link_id=link.id
   and preference.channel='in_app'
   and preference.topic='promotion_alerts'
   and preference.opted_in
  where link.business_id=v_content.business_id
    and link.state='verified'
  on conflict(identity_id,dedupe_key) do nothing;
  get diagnostics v_inserted=row_count;
  return v_inserted;
end
$$;
revoke all on function app.enqueue_promotion_alert_v122(uuid,text)
  from public,anon,authenticated;
grant execute on function app.enqueue_promotion_alert_v122(uuid,text)
  to service_role;

create or replace function app.promotion_publication_v122_alert()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  if new.content_type='offer'
     and new.metadata->>'schema'='nestly.promotion.v104'
     and new.active
     and not old.active
  then
    perform app.enqueue_promotion_alert_v122(new.id,'v122_promotion_new');
  end if;
  return new;
end
$$;
revoke all on function app.promotion_publication_v122_alert()
  from public,anon,authenticated;

create trigger business_promotion_v122_alert
after update of active on public.business_customer_content_v95
for each row execute function app.promotion_publication_v122_alert();

-- The same visibility sweep activates scheduled promotions once they are
-- actually customer-visible and emits the separate expiry event near deadline.
-- Deterministic event keys make the 15-minute sweep replay-safe.
create or replace function app.enqueue_due_promotion_alerts_v122()
returns integer language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_item record;v_total integer:=0;
begin
  for v_item in
    select content.id,'v122_promotion_new'::text source_kind
    from public.business_customer_content_v95 content
    where content.content_type='offer'
      and content.metadata->>'schema'='nestly.promotion.v104'
      and content.active
      and content.branch_id is null
      and (content.starts_at is null or content.starts_at<=now())
      and content.ends_at>now()
      and exists(
        select 1 from public.business_media_assets_v95 asset
        where asset.business_id=content.business_id
          and asset.asset_kind='offer'
          and asset.entity_id=content.id
          and asset.customer_visible
          and asset.branch_id is null
      )
      and not exists(
        select 1 from public.promotion_alert_runs_v122 run
        where run.promotion_id=content.id
          and run.source_kind='v122_promotion_new'
          and run.source_version=coalesce(
            content.metadata->>'published_once_at','missing'
          )
      )
    union all
    select content.id,'v122_promotion_expiry'::text source_kind
    from public.business_customer_content_v95 content
    where content.content_type='offer'
      and content.metadata->>'schema'='nestly.promotion.v104'
      and content.active
      and content.branch_id is null
      and (content.starts_at is null or content.starts_at<=now())
      and content.ends_at>now()
      and content.ends_at<=now()+interval '3 days'
      and exists(
        select 1 from public.business_media_assets_v95 asset
        where asset.business_id=content.business_id
          and asset.asset_kind='offer'
          and asset.entity_id=content.id
          and asset.customer_visible
          and asset.branch_id is null
      )
      and not exists(
        select 1 from public.promotion_alert_runs_v122 run
        where run.promotion_id=content.id
          and run.source_kind='v122_promotion_expiry'
          and run.source_version=coalesce(
            content.metadata->>'published_once_at','missing'
          )||':'||content.ends_at::text
      )
  loop
    v_total:=v_total+app.enqueue_promotion_alert_v122(
      v_item.id,v_item.source_kind
    );
  end loop;
  return v_total;
end
$$;
revoke all on function app.enqueue_due_promotion_alerts_v122()
  from public,anon,authenticated;
grant execute on function app.enqueue_due_promotion_alerts_v122()
  to service_role;

-- Popup reads are event-first: only an unread, undismissed, customer-owned
-- event can expose its exact still-visible promotion. The content join repeats
-- the enqueue fingerprint, so a generic offer can never masquerade as the
-- event that caused the prompt.
create or replace function public.customer_get_pending_promotion_prompt_v122(
  p_business_slug text
)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_context record;v_prompt jsonb;
begin
  if not app.platform_feature_enabled('customer_in_app_inbox') then
    raise exception 'customer in-app inbox is not enabled' using errcode='0A000';
  end if;
  select * into v_context from app.c46_customer_inbox_context(p_business_slug);
  select jsonb_build_object(
    'event_id',event.id,'source_kind',event.source_kind,
    'title',event.title,'body',event.body,'deadline_at',event.deadline_at,
    'promotion_id',content.id
  ) into v_prompt
  from public.customer_in_app_inbox_events event
  left join public.customer_in_app_inbox_state state on state.event_id=event.id
  join public.business_customer_content_v95 content
    on content.business_id=event.business_id
   and content.content_type='offer'
   and content.metadata->>'schema'='nestly.promotion.v104'
   and content.active
   and content.branch_id is null
   and (content.starts_at is null or content.starts_at<=now())
   and content.ends_at>now()
   and event.source_fingerprint=app.c46_sha256_hex((jsonb_build_object(
      'promotion_id',content.id,'source_kind',event.source_kind,
      'published_once_at',content.metadata->>'published_once_at'
   ) || case when event.source_kind='v122_promotion_expiry'
      then jsonb_build_object('ends_at',content.ends_at)
      else '{}'::jsonb end)::text)
  where event.business_id=v_context.business_id
    and event.identity_id=v_context.identity_id
    and event.link_id=v_context.link_id
    and event.client_id=v_context.client_id
    and event.topic='promotion_alerts'
    and event.source_kind in('v122_promotion_new','v122_promotion_expiry')
    and state.read_at is null and state.dismissed_at is null
    and exists(
      select 1 from public.customer_notification_preferences preference
      where preference.business_id=event.business_id
        and preference.identity_id=event.identity_id
        and preference.auth_user_id=event.auth_user_id
        and preference.link_id=event.link_id
        and preference.channel='in_app'
        and preference.topic='promotion_alerts'
        and preference.opted_in
    )
    and not exists(
      select 1 from public.customer_in_app_inbox_resolutions resolution
      where resolution.event_id=event.id
    )
    and exists(
      select 1 from public.business_media_assets_v95 asset
      where asset.business_id=content.business_id
        and asset.asset_kind='offer'
        and asset.entity_id=content.id
        and asset.customer_visible
        and asset.branch_id is null
    )
  order by event.created_at desc,event.id desc
  limit 1;
  return v_prompt;
end
$$;
revoke all on function public.customer_get_pending_promotion_prompt_v122(text)
  from public,anon,authenticated;
grant execute on function public.customer_get_pending_promotion_prompt_v122(text)
  to authenticated;

-- C46's generic sync knows only its original candidate sources and would
-- otherwise resolve every V122 promotion event as "no longer current".
-- Preserve only events whose exact promotion is still customer-visible;
-- once it is future, expired, inactive, branch-scoped, media-less, or changed,
-- the normal C46 resolution insert proceeds.
create or replace function app.preserve_current_promotion_event_v122()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  if exists(
    select 1
    from public.customer_in_app_inbox_events event
    join public.business_customer_content_v95 content
      on content.business_id=event.business_id
     and content.content_type='offer'
     and content.metadata->>'schema'='nestly.promotion.v104'
     and content.active
     and content.branch_id is null
     and (content.starts_at is null or content.starts_at<=now())
     and content.ends_at>now()
     and event.source_fingerprint=app.c46_sha256_hex((jsonb_build_object(
       'promotion_id',content.id,'source_kind',event.source_kind,
       'published_once_at',content.metadata->>'published_once_at'
     ) || case when event.source_kind='v122_promotion_expiry'
       then jsonb_build_object('ends_at',content.ends_at)
       else '{}'::jsonb end)::text)
    where event.id=new.event_id
      and event.source_kind in('v122_promotion_new','v122_promotion_expiry')
      and exists(
        select 1 from public.business_media_assets_v95 asset
        where asset.business_id=content.business_id
          and asset.asset_kind='offer'
          and asset.entity_id=content.id
          and asset.customer_visible
          and asset.branch_id is null
      )
  ) then
    return null;
  end if;
  return new;
end
$$;
revoke all on function app.preserve_current_promotion_event_v122()
  from public,anon,authenticated;
create trigger a_v122_preserve_current_promotion_event
before insert on public.customer_in_app_inbox_resolutions
for each row execute function app.preserve_current_promotion_event_v122();

do $v122_cron$
declare v_job bigint;
begin
  select jobid into v_job from cron.job
  where jobname='nestly-v122-promotion-alerts';
  if v_job is not null then perform cron.unschedule(v_job); end if;
  perform cron.schedule(
    'nestly-v122-promotion-alerts',
    '*/15 * * * *',
    'select app.enqueue_due_promotion_alerts_v122()'
  );
end
$v122_cron$;

commit;
