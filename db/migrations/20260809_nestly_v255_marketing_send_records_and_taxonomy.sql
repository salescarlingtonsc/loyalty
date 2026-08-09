-- NESTLY v255 - MARKETING SEND RECORDS, WATERMARK ORDERING, EVENT TAXONOMY
--
-- Three decision-independent repairs from the 2026-08-09 marketing/telemetry
-- audit. Nothing here is merchant-visible and nothing introduces a quota, a
-- price, or a provider integration.
--
-- 1. app.enqueue_promotion_alert_v122 burned its watermark BEFORE the recipient
--    fan-out (audit finding 1.5). A promotion published while nobody had opted
--    in wrote a promotion_alert_runs_v122 row against zero recipients and could
--    then never alert again. The watermark now lands only when recipients were
--    actually enqueued, serialized by an advisory lock so the publish trigger
--    and the */15 catch-up cron cannot double-send.
--    The three already-burned watermark rows are DELIBERATELY LEFT IN PLACE:
--    clearing them would re-alert customers about promotions published days ago,
--    which is an owner decision (O2), not an implementation detail.
--
-- 2. public.campaign_send_records_v255 is the immutable, business-attributed,
--    timestamped send record the audit found missing (finding 1.17). It is
--    written in the SAME statement as each existing fan-out. campaign_ref_id is
--    deliberately NOT a foreign key and campaign_label is a denormalized
--    snapshot: a send record must survive business_delete_promotion_v183.
--
-- 3. Eight new client event names join the v100 taxonomy, and the v100 client
--    context allowlist gains surface_key, promotion_id and query_shape. Search
--    capture is SHAPE-ONLY - a normalized token-count/length bucket, never the
--    typed text (audit 5e). record_product_interaction_v100 additionally stops
--    demanding a verified customer link when the event carries no business
--    scope at all, which is what a directory search legitimately is.

begin;

create table public.campaign_send_records_v255 (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null
    references public.businesses(id) on delete restrict,
  campaign_kind text not null
    check (campaign_kind in ('promotion','retention','growth')),
  -- Not a foreign key on purpose. The promotion this points at is a mutable,
  -- deletable business_customer_content_v95 row; the evidence that a message
  -- went out must outlive it.
  campaign_ref_id uuid not null,
  send_kind text not null
    check (char_length(send_kind) between 1 and 60),
  campaign_label text not null
    check (char_length(campaign_label) between 1 and 200),
  -- 'none' records an audience that was frozen without any delivery channel.
  -- Retention campaign activation is exactly that today (audit finding 1.14);
  -- calling it a send would be a lie the console would then report as one.
  channel text not null
    check (channel in ('in_app','web_push','none')),
  inbox_event_id uuid,
  identity_id uuid,
  link_id uuid,
  client_id uuid not null,
  recipient_key uuid not null
    generated always as (coalesce(identity_id,client_id)) stored,
  occurred_at timestamptz not null default now(),
  retention_until timestamptz not null default (now()+interval '400 days'),
  constraint campaign_send_records_v255_in_app_shape_check check (
    channel<>'in_app'
    or (
      identity_id is not null
      and link_id is not null
      and inbox_event_id is not null
    )
  ),
  constraint campaign_send_records_v255_retention_check check (
    retention_until>=occurred_at+interval '399 days'
    and retention_until<=occurred_at+interval '401 days'
  )
);
-- A promotion raises both a 'new' and an 'expiry' alert against the same
-- campaign_ref_id, so send_kind has to participate in the identity or the
-- second alert would silently collapse into the first.
create unique index campaign_send_records_v255_recipient_uk
  on public.campaign_send_records_v255(
    campaign_kind,campaign_ref_id,send_kind,recipient_key,channel
  );
create index campaign_send_records_v255_business_time_idx
  on public.campaign_send_records_v255(business_id,occurred_at desc);
create index campaign_send_records_v255_campaign_idx
  on public.campaign_send_records_v255(
    business_id,campaign_kind,campaign_ref_id
  );
create index campaign_send_records_v255_retention_idx
  on public.campaign_send_records_v255(retention_until);
create index campaign_send_records_v255_inbox_idx
  on public.campaign_send_records_v255(inbox_event_id)
  where inbox_event_id is not null;

alter table public.campaign_send_records_v255 enable row level security;
revoke all privileges on table public.campaign_send_records_v255
  from public,anon,authenticated,service_role;

create or replace function app.v255_campaign_send_immutable_guard()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
begin
  if tg_op='DELETE'
     and coalesce(
       pg_catalog.current_setting('app.v255_retention_purge',true),''
     )='on'
     and old.retention_until<clock_timestamp() then
    return old;
  end if;
  raise exception 'v255 campaign send records are append-only'
    using errcode='restrict_violation';
end
$$;
revoke all privileges on function app.v255_campaign_send_immutable_guard()
  from public,anon,authenticated,service_role;
create trigger campaign_send_records_v255_immutable
  before update or delete on public.campaign_send_records_v255
  for each row execute function app.v255_campaign_send_immutable_guard();

create or replace function public.purge_campaign_send_records_v255(
  p_limit integer default 5000
)
returns integer
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_deleted integer:=0;
begin
  if p_limit not between 1 and 10000 then
    raise exception 'purge limit must be 1..10000' using errcode='22023';
  end if;
  perform pg_catalog.set_config('app.v255_retention_purge','on',true);
  with expired as(
    select send_row.id
    from public.campaign_send_records_v255 send_row
    where send_row.retention_until<clock_timestamp()
    order by send_row.retention_until,send_row.id
    limit p_limit
    for update skip locked
  )
  delete from public.campaign_send_records_v255 send_row
  using expired
  where send_row.id=expired.id;
  get diagnostics v_deleted=row_count;
  perform pg_catalog.set_config('app.v255_retention_purge','',true);
  return v_deleted;
end
$$;
revoke all privileges on function public.purge_campaign_send_records_v255(
  integer
) from public,anon,authenticated,service_role;
grant execute on function public.purge_campaign_send_records_v255(integer)
  to service_role;

do $cron$
begin
  if to_regnamespace('cron') is not null
     and to_regprocedure('cron.schedule(text,text,text)') is not null then
    if exists(
      select 1 from cron.job
      where jobname='nestly-v255-campaign-send-retention-daily'
    ) then
      perform cron.unschedule('nestly-v255-campaign-send-retention-daily');
    end if;
    perform cron.schedule(
      'nestly-v255-campaign-send-retention-daily',
      '50 19 * * *',
      $command$select public.purge_campaign_send_records_v255(5000)$command$
    );
  else
    raise notice
      'v255: pg_cron is absent; campaign send retention is not scheduled';
  end if;
end
$cron$;

insert into public.product_adoption_event_taxonomy_v100(
  event_name,source_authority,actor_scope,required_module,required_mode,
  business_scope_required,economic_event,description
) values
  ('customer.session_started','client','customer',null,null,true,false,
    'Verified customer began an application session on a linked programme.'),
  ('customer.surface_viewed','client','customer',null,null,true,false,
    'Verified customer opened a customer application surface.'),
  ('merchant.surface_viewed','client','merchant',null,null,true,false,
    'Authenticated merchant opened a workspace surface.'),
  ('customer.promotion_viewed','client','customer',null,null,true,false,
    'Verified customer saw a promotion in a linked programme.'),
  ('customer.promotion_opened','client','customer',null,null,true,false,
    'Verified customer opened a promotion detail view.'),
  ('customer.reward_viewed','client','customer',null,null,true,false,
    'Verified customer opened a reward in a linked programme.'),
  ('customer.notification_opened','client','customer',null,null,true,false,
    'Verified customer opened an in-app notification.'),
  ('customer.explore_searched','client','customer',null,null,false,false,
    'Customer ran a discovery search. Only the query shape is recorded.')
on conflict (event_name) do nothing;

-- Rewritten in full rather than spliced: a pg_get_functiondef splice cannot be
-- shown comment-free here, and the context allowlist is a literal list inside
-- the body.
create or replace function public.record_product_interaction_v100(
  p_event_name text,
  p_business uuid,
  p_branch uuid,
  p_session_id uuid,
  p_idempotency_key text,
  p_occurred_at timestamptz default now(),
  p_context jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_actor uuid:=auth.uid();
  v_taxonomy public.product_adoption_event_taxonomy_v100%rowtype;
  v_context jsonb:=coalesce(p_context,'{}'::jsonb);
  v_key text:=btrim(coalesce(p_idempotency_key,''));
  v_hash text;
  v_existing public.product_adoption_events_v100%rowtype;
  v_id uuid:=gen_random_uuid();
begin
  if v_actor is null then
    raise exception 'authenticated interaction session is required'
      using errcode='28000';
  end if;
  select taxonomy.* into v_taxonomy
  from public.product_adoption_event_taxonomy_v100 taxonomy
  where taxonomy.event_name=p_event_name
    and taxonomy.source_authority='client';
  if not found then
    raise exception 'event is not in the client interaction allowlist'
      using errcode='22023';
  end if;
  if char_length(v_key) not between 8 and 200 then
    raise exception 'idempotency key must contain 8..200 characters'
      using errcode='22023';
  end if;
  if p_occurred_at is null
     or p_occurred_at<clock_timestamp()-interval '24 hours'
     or p_occurred_at>clock_timestamp()+interval '5 minutes' then
    raise exception 'interaction time is outside the accepted window'
      using errcode='22023';
  end if;
  if v_taxonomy.business_scope_required and p_business is null then
    raise exception 'interaction requires a business scope'
      using errcode='22023';
  end if;
  if jsonb_typeof(v_context)<>'object'
     or octet_length(v_context::text)>2048
     or exists(
       select 1
       from pg_catalog.jsonb_object_keys(v_context) as context_key(key)
       where context_key.key not in (
         'action_key','entry_point','locale','device_class','install_mode',
         'surface_version','outcome','surface_key','promotion_id','query_shape'
       )
     )
     or exists(
       select 1
       from pg_catalog.jsonb_each(v_context) as context_item(key,value)
       where pg_catalog.jsonb_typeof(context_item.value)
               not in ('string','number','boolean','null')
          or (
            pg_catalog.jsonb_typeof(context_item.value)='string'
            and char_length(context_item.value#>>'{}')>80
          )
     ) then
    raise exception
      'context may contain only short privacy-safe allowlisted dimensions'
      using errcode='22023';
  end if;

  if v_taxonomy.actor_scope='customer' then
    if p_business is not null and not exists(
      select 1
      from public.customer_links customer_link
      where customer_link.business_id=p_business
        and customer_link.auth_user_id=v_actor
        and customer_link.state='verified'
    ) then
      raise exception 'verified customer relationship is required'
        using errcode='42501';
    end if;
    if p_branch is not null and not exists(
      select 1
      from public.branches branch
      where branch.id=p_branch and branch.business_id=p_business
    ) then
      raise exception 'branch does not belong to this business'
        using errcode='42501';
    end if;
  elsif v_taxonomy.actor_scope='merchant' then
    if not app.is_salon_member(p_business) then
      raise exception 'active merchant membership is required'
        using errcode='42501';
    end if;
    if v_taxonomy.required_module is not null
       and (
         (
           v_taxonomy.required_mode='r'
           and not app.can_module_read(
             p_business,v_taxonomy.required_module
           )
         )
         or (
           v_taxonomy.required_mode='rw'
           and not app.can_module_write(
             p_business,v_taxonomy.required_module
           )
         )
       ) then
      raise exception 'module access does not permit this interaction'
        using errcode='42501';
    end if;
    if p_branch is not null
       and not app.can_see_branch(p_business,p_branch) then
      raise exception 'branch is outside the merchant scope'
        using errcode='42501';
    end if;
  else
    raise exception 'unsupported client actor scope' using errcode='22023';
  end if;

  v_hash:=pg_catalog.encode(
    extensions.digest(
      pg_catalog.convert_to(
        pg_catalog.concat_ws(
          '|','v100.client-interaction',p_event_name,
          coalesce(p_business::text,''),coalesce(p_branch::text,''),
          coalesce(p_session_id::text,''),p_occurred_at::text,v_context::text
        ),
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'v100:interaction:'||v_actor::text||':'||v_key,0
    )
  );
  select event_row.* into v_existing
  from public.product_adoption_events_v100 event_row
  where event_row.actor_user_id=v_actor
    and event_row.idempotency_key=v_key;
  if found then
    if v_existing.request_hash<>v_hash then
      raise exception 'idempotency key conflicts with another interaction'
        using errcode='23505';
    end if;
    return pg_catalog.jsonb_build_object(
      'event_id',v_existing.id,'event_name',v_existing.event_name,
      'recording_status','accepted_interaction_only',
      'business_outcome_asserted',false,'replayed',true
    );
  end if;
  insert into public.product_adoption_events_v100(
    id,event_name,source_authority,actor_scope,actor_user_id,
    business_id,branch_id,session_id,event_context,idempotency_key,
    request_hash,occurred_at
  ) values(
    v_id,p_event_name,'client',v_taxonomy.actor_scope,v_actor,
    p_business,p_branch,p_session_id,v_context,v_key,v_hash,p_occurred_at
  );
  return pg_catalog.jsonb_build_object(
    'event_id',v_id,'event_name',p_event_name,
    'recording_status','accepted_interaction_only',
    'business_outcome_asserted',false,'replayed',false
  );
end
$$;
revoke all privileges on function public.record_product_interaction_v100(
  text,uuid,uuid,uuid,text,timestamptz,jsonb
) from public,anon,authenticated,service_role;
grant execute on function public.record_product_interaction_v100(
  text,uuid,uuid,uuid,text,timestamptz,jsonb
) to authenticated;

create or replace function app.enqueue_promotion_alert_v122(
  p_promotion uuid,
  p_source_kind text
)
returns integer
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_content public.business_customer_content_v95%rowtype;
  v_source_version text;
  v_label text;
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

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'v122:promotion-alert:'||v_content.id::text||':'||p_source_kind,0
    )
  );
  if exists(
    select 1 from public.promotion_alert_runs_v122 run
    where run.promotion_id=v_content.id
      and run.source_kind=p_source_kind
      and run.source_version=v_source_version
  ) then
    return 0;
  end if;

  select coalesce(
    (
      select nullif(btrim(left(copy_row.name,200)),'')
      from public.business_localized_copy_v95 copy_row
      where copy_row.business_id=v_content.business_id
        and copy_row.entity_type='offer'
        and copy_row.entity_id=v_content.id
      order by (copy_row.locale='en') desc,copy_row.locale
      limit 1
    ),
    'Promotion'
  ) into v_label;

  with recipients as(
    select
      link.business_id,link.identity_id,link.auth_user_id,
      link.id as link_id,link.client_id
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
  ),
  enqueued as(
    insert into public.customer_in_app_inbox_events(
      business_id,identity_id,auth_user_id,link_id,client_id,
      source_kind,topic,route_key,source_fingerprint,dedupe_key,
      title,body,deadline_at
    )
    select
      recipient.business_id,recipient.identity_id,recipient.auth_user_id,
      recipient.link_id,recipient.client_id,
      p_source_kind,'promotion_alerts','wallet_business',
      app.c46_sha256_hex((jsonb_build_object(
        'promotion_id',v_content.id,'source_kind',p_source_kind,
        'published_once_at',v_content.metadata->>'published_once_at'
      ) || case when p_source_kind='v122_promotion_expiry'
        then jsonb_build_object('ends_at',v_content.ends_at)
        else '{}'::jsonb end)::text),
      app.c46_sha256_hex((jsonb_build_object(
        'business_id',recipient.business_id,'identity_id',recipient.identity_id,
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
    from recipients recipient
    on conflict(identity_id,dedupe_key) do nothing
    returning id,business_id,identity_id,link_id,client_id
  ),
  recorded as(
    insert into public.campaign_send_records_v255(
      business_id,campaign_kind,campaign_ref_id,send_kind,campaign_label,
      channel,inbox_event_id,identity_id,link_id,client_id
    )
    select
      enqueued.business_id,'promotion',v_content.id,p_source_kind,v_label,
      'in_app',enqueued.id,enqueued.identity_id,enqueued.link_id,
      enqueued.client_id
    from enqueued
    on conflict do nothing
    returning 1
  )
  select count(*)::integer into v_inserted from enqueued;

  if v_inserted>0 then
    insert into public.promotion_alert_runs_v122(
      promotion_id,source_kind,source_version
    ) values(
      v_content.id,p_source_kind,v_source_version
    ) on conflict do nothing;
  end if;
  return v_inserted;
end
$$;
revoke all privileges on function app.enqueue_promotion_alert_v122(uuid,text)
  from public,anon,authenticated,service_role;

create or replace function public.activate_retention_campaign(
  p_business uuid,
  p_campaign uuid,
  p_client_ids uuid[],
  p_idempotency_key text
)
returns json
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_campaign public.retention_campaigns%rowtype;
  v_requested integer;
  v_inserted integer;
  v_treatment integer;
  v_holdout integer;
begin
  if not app.is_salon_owner(p_business) then
    raise exception 'owner only' using errcode = '42501';
  end if;
  if p_idempotency_key is null or length(btrim(p_idempotency_key)) < 8 then
    raise exception 'idempotency key must contain at least 8 characters' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('v50:activate:' || p_campaign::text, 0));
  select * into v_campaign from public.retention_campaigns
   where id = p_campaign and business_id = p_business for update;
  if not found then raise exception 'campaign not found in this business'; end if;

  if v_campaign.status = 'active' then
    select count(*) filter (where assignment = 'treatment'),
           count(*) filter (where assignment = 'holdout')
      into v_treatment, v_holdout
      from public.retention_campaign_members
     where campaign_id = p_campaign and business_id = p_business;
    return json_build_object('campaign_id', p_campaign, 'status', 'active',
      'audience_size', v_campaign.audience_size, 'treatment', v_treatment, 'holdout', v_holdout,
      'replayed', true);
  end if;
  if v_campaign.status <> 'draft' then
    raise exception 'only a draft campaign can be activated' using errcode = '42501';
  end if;
  if p_client_ids is null or array_length(p_client_ids, 1) is null then
    raise exception 'a non-empty audience is required to activate a campaign' using errcode = '22023';
  end if;
  select count(*) into v_requested from (select distinct unnest(p_client_ids) cid) u where u.cid is not null;
  if v_requested = 0 then
    raise exception 'a non-empty audience is required to activate a campaign' using errcode = '22023';
  end if;
  if v_requested > 50000 then
    raise exception 'campaign audience is limited to 50000 members' using errcode = '22023';
  end if;

  -- The membership fan-out and its immutable send record are one statement.
  -- channel='none' is the honest value: activation freezes an audience and no
  -- delivery channel exists for retention campaigns (audit finding 1.14).
  with members as(
    insert into public.retention_campaign_members(
      campaign_id, business_id, client_id, assignment, assignment_bucket
    )
    select p_campaign, p_business, c.id,
           case when app.campaign_holdout_bucket(p_campaign, c.id) < v_campaign.holdout_percent
                then 'holdout' else 'treatment' end,
           app.campaign_holdout_bucket(p_campaign, c.id)
      from (select distinct unnest(p_client_ids) cid) u
      join public.clients c on c.id = u.cid and c.business_id = p_business
    returning business_id, client_id, assignment
  ),
  recorded as(
    insert into public.campaign_send_records_v255(
      business_id,campaign_kind,campaign_ref_id,send_kind,campaign_label,
      channel,client_id
    )
    select
      member.business_id,'retention',p_campaign,'v50_campaign_activated',
      coalesce(nullif(btrim(left(v_campaign.name,200)),''),'Bring-back campaign'),
      'none',member.client_id
    from members member
    where member.assignment='treatment'
    on conflict do nothing
    returning 1
  )
  select count(*)::integer into v_inserted from members;
  if v_inserted <> v_requested then
    raise exception 'some audience clients do not belong to this business' using errcode = '42501';
  end if;

  select count(*) filter (where assignment = 'treatment'),
         count(*) filter (where assignment = 'holdout')
    into v_treatment, v_holdout
    from public.retention_campaign_members
   where campaign_id = p_campaign and business_id = p_business;

  update public.retention_campaigns
     set status = 'active', activated_at = now(), audience_size = v_inserted
   where id = p_campaign and business_id = p_business;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'ACTIVATE_RETENTION_CAMPAIGN', 'retention_campaigns', p_campaign,
    jsonb_build_object('audience_size', v_inserted, 'treatment', v_treatment, 'holdout', v_holdout));
  return json_build_object('campaign_id', p_campaign, 'status', 'active',
    'audience_size', v_inserted, 'treatment', v_treatment, 'holdout', v_holdout, 'replayed', false);
end
$$;
revoke all privileges on function public.activate_retention_campaign(
  uuid,uuid,uuid[],text
) from public,anon,authenticated,service_role;
grant execute on function public.activate_retention_campaign(
  uuid,uuid,uuid[],text
) to authenticated,service_role;

comment on table public.campaign_send_records_v255 is
  'Append-only marketing send evidence. campaign_ref_id is intentionally not a foreign key and campaign_label is a snapshot so a record survives campaign deletion.';
comment on function app.enqueue_promotion_alert_v122(uuid,text) is
  'Fans out promotion alerts and only then burns the watermark, so a run against zero opted-in recipients stays repeatable.';

commit;
