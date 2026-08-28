-- nestly_v571 — referral attribution from the customer app, and inbox provenance.
--
-- Three things, all additive and backward compatible.
--
-- 1. REFERRAL ATTRIBUTION (owner, scan-sheet photo: the join pop-up should carry a referral
--    code field). Until now exactly one thing in the whole product created a referrals row:
--    public.staff_create_client, when a member of staff typed a code into the customer form.
--    A customer joining from a QR had no way to say who sent them. These two functions give
--    them one WITHOUT inventing a second referral system — the write below is the same insert
--    staff_create_client performs, into the same table, with the same 'pending' status and the
--    same guards, so qualification and payout continue to be owned entirely by the existing
--    referral engine. Nothing here grants points, credit or a reward: a referral becomes
--    payable only when the referred customer's own first qualifying sale says so.
--
--    The check function exists so an invalid code is reported BEFORE the customer confirms,
--    and joining is never blocked by one. It is deliberately keyed on the join TOKEN rather
--    than a business slug: the caller must physically hold an active counter QR, which keeps
--    the function from becoming an oracle for "is CODE a customer of this business" to anyone
--    who merely knows a slug.
--
-- 2. INBOX BUSINESS LOGO (owner, Messages photo: "company logo"). The two list readers return
--    the business as {name, slug}; the wallet has shown logos for a long time through
--    app.v95_public_media_url over business_media_assets_v95. This adds the same expression to
--    the same two readers and nothing else — no new endpoint, no new column, no new grant.
--
-- 3. INBOX OFFER TITLE (owner, Messages photo: "state offer title"). A promotion alert says
--    'New promotion available' because that literal is all the row has ever carried: the
--    promotion's id was hashed into source_fingerprint and dedupe_key and was therefore
--    unrecoverable. Historical rows CANNOT be repaired and this migration does not pretend
--    otherwise — it adds a nullable source_ref_id, has the generator record it from now on,
--    and lets the readers print the offer's own name only when that reference is present.
--    Rows without it, and every non-promotion message, are returned exactly as before.
--
-- Rollback suite: db/tests/v571_referral_attribution_and_inbox_provenance.sql

begin;

-- ---------------------------------------------------------------- 1. inbox provenance column
alter table public.customer_in_app_inbox_events
  add column if not exists source_ref_id uuid;

comment on column public.customer_in_app_inbox_events.source_ref_id is
  'nestly_v571 — the domain row this event is about (today: the promotion for v122_promotion_* '
  'events). Null on every row created before v571 and on every source kind that has no such row; '
  'readers must treat null as "no reference" and fall back to the stored title.';

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
    left join public.customer_notification_preferences preference
      on preference.business_id=link.business_id
     and preference.identity_id=link.identity_id
     and preference.auth_user_id=link.auth_user_id
     and preference.link_id=link.id
     and preference.channel='in_app'
     and preference.topic='promotion_alerts'
    where link.business_id=v_content.business_id
      and link.state='verified'
      and coalesce(preference.opted_in,true)
      and app.customer_communication_allows_v263(
        link.identity_id,'business_offers','in_app'
      )
  ),
  enqueued as(
    insert into public.customer_in_app_inbox_events(
      business_id,identity_id,auth_user_id,link_id,client_id,
      source_kind,topic,route_key,source_fingerprint,dedupe_key,
      title,body,deadline_at,source_ref_id
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
      v_content.ends_at,
      /* nestly_v571: the promotion this alert is ABOUT, kept as an explicit reference.
         Everything identifying it was previously hashed into source_fingerprint and
         dedupe_key, so a row could never be traced back to its offer and the reader had
         nothing to print but the generic title above. Historical rows keep a null here and
         are rendered exactly as before. */
      v_content.id
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
$$;-- ------------------------------------------------- 2+3. inbox readers: logo and offer title
create or replace function public.customer_list_in_app_inbox(
  p_business_slug text,
  p_cursor jsonb default '{}'::jsonb
)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_context record; v_limit integer := 20; v_cursor_at timestamptz; v_cursor_id uuid;
  v_has_cursor boolean := false; v_count integer := 0; v_has_more boolean := false;
  v_items jsonb := '[]'::jsonb; v_row record; v_last_at timestamptz; v_last_id uuid;
  v_quiet boolean; v_filter text; v_actionable_source_available boolean;
begin
  if not app.platform_feature_enabled('customer_in_app_inbox') then
    raise exception 'customer in-app inbox is not enabled' using errcode='0A000';
  end if;
  select * into v_context from app.c46_customer_inbox_context(p_business_slug);
  v_actionable_source_available:=app.platform_feature_enabled('customer_actionable_wallet');
  if p_cursor is null then p_cursor:='{}'::jsonb; end if;
  if jsonb_typeof(p_cursor) <> 'object' or p_cursor - 'limit' - 'filter' - 'created_at' - 'event_id' <> '{}'::jsonb then
    raise exception 'invalid inbox cursor' using errcode='22023';
  end if;
  v_filter:=lower(coalesce(p_cursor->>'filter','all'));
  if v_filter not in ('all','unread') then raise exception 'invalid inbox filter' using errcode='22023'; end if;
  if p_cursor ? 'limit' then
    if (p_cursor->>'limit') !~ '^[0-9]{1,2}$' then raise exception 'invalid inbox cursor' using errcode='22023'; end if;
    v_limit:=least(greatest((p_cursor->>'limit')::integer,1),50);
  end if;
  if (p_cursor ? 'created_at') <> (p_cursor ? 'event_id') then
    raise exception 'invalid inbox cursor' using errcode='22023';
  end if;
  if p_cursor ? 'created_at' then
    begin
      v_cursor_at:=(p_cursor->>'created_at')::timestamptz;
      v_cursor_id:=(p_cursor->>'event_id')::uuid;
    exception when others then
      raise exception 'invalid inbox cursor' using errcode='22023';
    end;
    v_has_cursor:=true;
  end if;
  for v_row in
    select e.id,e.title,e.body,e.route_key,e.created_at,e.deadline_at,e.topic,e.source_kind,s.read_at,r.id as resolution_id,
           app.v95_public_media_url(logo.object_path) as logo_url,
           /* nestly_v571: the offer's own name, and only when the event actually references
              one. left join + null source_ref_id means historical rows and non-promotion
              sources return null here and the reader keeps the stored title. */
           (select nullif(btrim(left(copy_row.name,200)),'')
              from public.business_localized_copy_v95 copy_row
             where copy_row.business_id=e.business_id
               and copy_row.entity_type='offer'
               and copy_row.entity_id=e.source_ref_id
             order by (copy_row.locale='en') desc,copy_row.locale
             limit 1) as offer_title,
           app.c46_inbox_source_available(e.source_kind,v_actionable_source_available) as source_available
      from public.customer_in_app_inbox_events e
      left join public.business_brand_presentation_v95 brand on brand.business_id=e.business_id
      left join public.business_media_assets_v95 logo
        on logo.id=brand.logo_asset_id and logo.business_id=e.business_id
       and logo.asset_kind='logo' and logo.customer_visible
      left join public.customer_in_app_inbox_state s on s.event_id=e.id
      left join public.customer_in_app_inbox_resolutions r on r.event_id=e.id
     where e.business_id=v_context.business_id and e.identity_id=v_context.identity_id
       and e.link_id=v_context.link_id and s.dismissed_at is null
       and (v_filter='all' or (
         r.id is null
         and app.c46_inbox_source_available(e.source_kind,v_actionable_source_available)
         and s.read_at is null
       ))
       and (not v_has_cursor or (e.created_at,e.id) < (v_cursor_at,v_cursor_id))
     order by e.created_at desc,e.id desc
     limit v_limit+1
  loop
    v_count:=v_count+1;
    if v_count > v_limit then v_has_more:=true; exit; end if;
    v_items:=v_items || jsonb_build_array(jsonb_build_object(
      'event_id',v_row.id,'title',v_row.title,'body',v_row.body,
      'offer_title',v_row.offer_title,'business',jsonb_build_object('logo_url',v_row.logo_url),
      'route_key',case when v_row.resolution_id is null and v_row.source_available then v_row.route_key else null end,
      'action_available',v_row.resolution_id is null and v_row.source_available,
      'created_at',v_row.created_at,'deadline_at',v_row.deadline_at,'topic',v_row.topic,
      'source',v_row.source_kind,'state',case when v_row.resolution_id is not null then 'resolved'
        when not v_row.source_available then 'source_unavailable'
        when v_row.read_at is null then 'unread' else 'read' end
    ));
    v_last_at:=v_row.created_at; v_last_id:=v_row.id;
  end loop;
  select exists (
    select 1 from (values ('value_expiry'::text),('reward_ready'::text),('visit_progress'::text),
                         ('birthday_benefit'::text),('booking_updates'::text)) topics(topic)
    join lateral app.c46_in_app_preference_for_context(
      v_context.business_id,v_context.identity_id,v_context.link_id,topics.topic
    ) p on true
    where p.opted_in and (v_actionable_source_available or topics.topic='booking_updates')
      and app.c46_in_quiet_hours(
      p.quiet_hours_timezone,p.quiet_hours_start,p.quiet_hours_end,statement_timestamp()
    )
  ) into v_quiet;
  return jsonb_build_object('items',v_items,'next_cursor',case when v_has_more then
    jsonb_build_object('limit',v_limit,'filter',v_filter,'created_at',v_last_at,'event_id',v_last_id) else null end,
    'filter',v_filter,'quiet_hours_active',v_quiet,
    'actionable_source_available',v_actionable_source_available);
end;
$$;
create or replace function public.customer_list_in_app_inbox_global(
  p_cursor jsonb default '{}'::jsonb
)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_context record; v_limit integer:=20; v_filter text; v_cursor_at timestamptz; v_cursor_id uuid;
  v_has_cursor boolean:=false; v_count integer:=0; v_has_more boolean:=false;
  v_items jsonb:='[]'::jsonb; v_row record; v_last_at timestamptz; v_last_id uuid;
  v_actionable_source_available boolean;
begin
  if not app.platform_feature_enabled('customer_in_app_inbox') then
    raise exception 'customer in-app inbox is not enabled' using errcode='0A000';
  end if;
  select * into v_context from app.c46_customer_inbox_global_context();
  v_actionable_source_available:=app.platform_feature_enabled('customer_actionable_wallet');
  if p_cursor is null then p_cursor:='{}'::jsonb; end if;
  if jsonb_typeof(p_cursor)<>'object'
     or p_cursor-'limit'-'filter'-'created_at'-'event_id'<>'{}'::jsonb then
    raise exception 'invalid inbox cursor' using errcode='22023';
  end if;
  v_filter:=lower(coalesce(p_cursor->>'filter','all'));
  if v_filter not in ('all','unread') then raise exception 'invalid inbox filter' using errcode='22023'; end if;
  if p_cursor ? 'limit' then
    if (p_cursor->>'limit') !~ '^[0-9]{1,2}$' then raise exception 'invalid inbox cursor' using errcode='22023'; end if;
    v_limit:=least(greatest((p_cursor->>'limit')::integer,1),50);
  end if;
  if (p_cursor?'created_at')<>(p_cursor?'event_id') then raise exception 'invalid inbox cursor' using errcode='22023'; end if;
  if p_cursor?'created_at' then
    begin
      v_cursor_at:=(p_cursor->>'created_at')::timestamptz; v_cursor_id:=(p_cursor->>'event_id')::uuid;
    exception when others then raise exception 'invalid inbox cursor' using errcode='22023';
    end;
    v_has_cursor:=true;
  end if;
  for v_row in
    select e.id,e.title,e.body,e.route_key,e.created_at,e.deadline_at,e.topic,e.source_kind,
           b.name as business_name,b.slug as business_slug,s.read_at,r.id as resolution_id,
           app.v95_public_media_url(logo.object_path) as logo_url,
           /* nestly_v571: the offer's own name, and only when the event actually references
              one. left join + null source_ref_id means historical rows and non-promotion
              sources return null here and the reader keeps the stored title. */
           (select nullif(btrim(left(copy_row.name,200)),'')
              from public.business_localized_copy_v95 copy_row
             where copy_row.business_id=e.business_id
               and copy_row.entity_type='offer'
               and copy_row.entity_id=e.source_ref_id
             order by (copy_row.locale='en') desc,copy_row.locale
             limit 1) as offer_title,
           app.c46_inbox_source_available(e.source_kind,v_actionable_source_available) as source_available
      from public.customer_in_app_inbox_events e
      join public.customer_links cl on cl.id=e.link_id and cl.business_id=e.business_id
        and cl.client_id=e.client_id and cl.identity_id=e.identity_id and cl.auth_user_id=v_context.auth_user_id
        and cl.state='verified'
      join public.businesses b on b.id=e.business_id
      left join public.business_brand_presentation_v95 brand on brand.business_id=e.business_id
      left join public.business_media_assets_v95 logo
        on logo.id=brand.logo_asset_id and logo.business_id=e.business_id
       and logo.asset_kind='logo' and logo.customer_visible
      left join public.customer_in_app_inbox_state s on s.event_id=e.id
      left join public.customer_in_app_inbox_resolutions r on r.event_id=e.id
     where e.identity_id=v_context.identity_id and e.auth_user_id=v_context.auth_user_id
       and s.dismissed_at is null and (v_filter='all' or (
         r.id is null
         and app.c46_inbox_source_available(e.source_kind,v_actionable_source_available)
         and s.read_at is null
       ))
       and (not v_has_cursor or (e.created_at,e.id)<(v_cursor_at,v_cursor_id))
     order by e.created_at desc,e.id desc limit v_limit+1
  loop
    v_count:=v_count+1; if v_count>v_limit then v_has_more:=true; exit; end if;
    v_items:=v_items||jsonb_build_array(jsonb_build_object(
      'event_id',v_row.id,'business',jsonb_build_object('name',v_row.business_name,'slug',v_row.business_slug,'logo_url',v_row.logo_url),
      'offer_title',v_row.offer_title,
      'route_key',case when v_row.resolution_id is null and v_row.source_available then v_row.route_key else null end,
      'action_available',v_row.resolution_id is null and v_row.source_available,
      'title',v_row.title,'body',v_row.body,'topic',v_row.topic,
      'source',v_row.source_kind,'deadline_at',v_row.deadline_at,'created_at',v_row.created_at,
      'state',case when v_row.resolution_id is not null then 'resolved'
        when not v_row.source_available then 'source_unavailable'
        when v_row.read_at is null then 'unread' else 'read' end
    ));
    v_last_at:=v_row.created_at; v_last_id:=v_row.id;
  end loop;
  return jsonb_build_object('items',v_items,'filter',v_filter,
    'actionable_source_available',v_actionable_source_available,'next_cursor',case when v_has_more then
    jsonb_build_object('limit',v_limit,'filter',v_filter,'created_at',v_last_at,'event_id',v_last_id)
    else null end);
end;
$$;
-- ------------------------------------------------------------------ 4. referral attribution

/* Read-only. Answers "would this code work?" so the customer is told BEFORE they confirm, and
   a bad code never becomes a failed join. Keyed on the join TOKEN, not a slug: the caller must
   be holding an active counter QR, so this cannot be used to test codes against a business you
   merely know the name of. It never reveals who the code belongs to. */
create or replace function public.customer_check_referral_code_v571(
  p_join_token text,
  p_code text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_business uuid;
  v_code text := nullif(upper(btrim(coalesce(p_code, ''))), '');
  v_referrer uuid;
  v_self uuid;
  v_enabled boolean;
begin
  if v_actor is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;
  -- An empty box is not an error. The code is optional and always was.
  if v_code is null then
    return jsonb_build_object('ok', true, 'reason', 'empty');
  end if;
  if char_length(v_code) > 32 then
    return jsonb_build_object('ok', false, 'reason', 'unknown_code');
  end if;

  select qr.business_id into v_business
    from public.business_customer_join_qr_v89 qr
    join public.businesses business on business.id = qr.business_id
   where qr.token_hash = app.v89_sha256(p_join_token)
     and qr.status = 'active'
     and qr.expires_at > now()
     and business.join_enabled;
  if v_business is null then
    return jsonb_build_object('ok', false, 'reason', 'unknown_business');
  end if;

  select rp.enabled into v_enabled
    from public.referral_programs rp
   where rp.business_id = v_business;
  if not coalesce(v_enabled, false) then
    return jsonb_build_object('ok', false, 'reason', 'referrals_off');
  end if;

  select c.id into v_referrer
    from public.clients c
   where c.business_id = v_business
     and c.referral_code = v_code
   limit 1;
  if v_referrer is null then
    return jsonb_build_object('ok', false, 'reason', 'unknown_code');
  end if;

  /* Somebody re-scanning a counter they already belong to can be told the two things that
     would refuse them, before they press anything. A brand-new customer has no link yet, so
     these are re-checked for real by the apply function once the join has happened. */
  select cl.client_id into v_self
    from public.customer_links cl
   where cl.business_id = v_business
     and cl.auth_user_id = v_actor
     and cl.state = 'verified'
   limit 1;
  if v_self is not null and v_self = v_referrer then
    return jsonb_build_object('ok', false, 'reason', 'self_referral');
  end if;
  if v_self is not null and exists(
    select 1 from public.referrals r where r.referred_client_id = v_self
  ) then
    return jsonb_build_object('ok', false, 'reason', 'already_referred');
  end if;

  return jsonb_build_object('ok', true, 'reason', 'ok');
end;
$$;

/* Writes the attribution, after the join. Deliberately the SAME insert public.staff_create_client
   performs — same table, same 'pending' status, no reward columns touched — so qualification and
   payout stay entirely with the existing referral engine. This function never grants anything.

   Idempotency is the database's, not a bookkeeping table's: one_referral_per_referred is a unique
   index on referred_client_id, so a duplicate submit or a retried join cannot produce a second
   row. Re-sending the SAME code is reported as success; sending a DIFFERENT one afterwards is
   refused, because the first attribution stands. */
create or replace function public.customer_apply_referral_code_v571(
  p_business_slug text,
  p_code text,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_context record;
  v_code text := nullif(upper(btrim(coalesce(p_code, ''))), '');
  v_referrer uuid;
  v_existing_referrer uuid;
  v_referral uuid;
  v_enabled boolean;
begin
  if v_actor is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;
  if p_idempotency_key is null then
    raise exception 'invalid referral request' using errcode = '22023';
  end if;
  if v_code is null then
    return jsonb_build_object('applied', false, 'reason', 'empty');
  end if;
  if char_length(v_code) > 32 then
    return jsonb_build_object('applied', false, 'reason', 'unknown_code');
  end if;

  select context.identity_id, context.business_id, context.client_id
    into v_context
    from app.v32_customer_wallet_context(p_business_slug) context
   limit 1;
  if not found then
    raise exception 'verified customer link required' using errcode = '42501';
  end if;

  select rp.enabled into v_enabled
    from public.referral_programs rp
   where rp.business_id = v_context.business_id;
  if not coalesce(v_enabled, false) then
    return jsonb_build_object('applied', false, 'reason', 'referrals_off');
  end if;

  select c.id into v_referrer
    from public.clients c
   where c.business_id = v_context.business_id
     and c.referral_code = v_code
   limit 1
   for share;
  -- Cross-business codes land here: the lookup is scoped to this business and finds nothing.
  if v_referrer is null then
    return jsonb_build_object('applied', false, 'reason', 'unknown_code');
  end if;
  if v_referrer = v_context.client_id then
    return jsonb_build_object('applied', false, 'reason', 'self_referral');
  end if;

  insert into public.referrals (
    business_id, referrer_client_id, referred_client_id, status
  ) values (
    v_context.business_id, v_referrer, v_context.client_id, 'pending'
  )
  on conflict (referred_client_id) where referred_client_id is not null do nothing
  returning id into v_referral;

  if v_referral is null then
    select r.id, r.referrer_client_id
      into v_referral, v_existing_referrer
      from public.referrals r
     where r.referred_client_id = v_context.client_id;
    if v_existing_referrer = v_referrer then
      return jsonb_build_object('applied', true, 'reason', 'already_applied',
                                'referral_id', v_referral);
    end if;
    return jsonb_build_object('applied', false, 'reason', 'already_referred',
                              'referral_id', v_referral);
  end if;

  return jsonb_build_object('applied', true, 'reason', 'ok', 'referral_id', v_referral);
end;
$$;

-- ------------------------------------------------------------------------------------ grants
revoke all on function public.customer_check_referral_code_v571(text, text) from public, anon;
grant execute on function public.customer_check_referral_code_v571(text, text) to authenticated;

revoke all on function public.customer_apply_referral_code_v571(text, text, uuid) from public, anon;
grant execute on function public.customer_apply_referral_code_v571(text, text, uuid) to authenticated;

-- Restated verbatim from the live proacl of the functions this migration replaces.
revoke all on function public.customer_list_in_app_inbox(text, jsonb) from public, anon;
grant execute on function public.customer_list_in_app_inbox(text, jsonb) to authenticated, service_role;

revoke all on function public.customer_list_in_app_inbox_global(jsonb) from public, anon;
grant execute on function public.customer_list_in_app_inbox_global(jsonb) to authenticated, service_role;

revoke all on function app.enqueue_promotion_alert_v122(uuid, text) from public, anon, authenticated;

commit;
