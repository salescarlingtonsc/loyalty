-- ============================================================================
-- nestly_v583 — THE OWNER CAN SEE, AND SWITCH OFF, EVERY AUTOMATIC MESSAGE
--
-- Peekaa cannot charge a shop for automation the shopkeeper can neither see
-- nor stop. Today four lanes send on a business's behalf — booking
-- confirmation, the day-before reminder, the short-notice reminder (v581) and
-- the bring-back voucher (v551) — and the ONLY controls over any of them are
-- the platform kill switch and the superadmin-written capability grant. Both
-- are Peekaa's controls. The owner has none.
--
-- This migration gives the owner four switches on their own row, and wires
-- each one into the gate that already exists for that lane.
--
-- ===========================================================================
-- 1. WHY FLAT COLUMNS, AND WHY THESE DEFAULTS
-- ===========================================================================
-- Flat boolean columns on public.businesses, because that is what every other
-- business setting in this schema already is: join_enabled, notify_new_bookings,
-- booking_auto_confirm, gift_card_sales_enabled, quick_earn_catalogue_enabled.
-- There is no settings jsonb bag to join; inventing one for four booleans would
-- make this the only setting the UI reads differently from all the others.
--
-- Three default TRUE, one default FALSE, and the split is not arbitrary:
--
--   * A business that has been GRANTED the capability should get the behaviour
--     the capability implies. The grant is the deliberate act — someone at
--     Peekaa turned this firm's messaging on, and in most cases sold it to them.
--     Defaulting the owner switch to false would mean every newly-granted firm
--     silently sends nothing until it discovers a switch it was never told about,
--     and the first symptom is a customer who never got their confirmation.
--     So: wa_confirmation_enabled, wa_reminder_24h_enabled, wa_bringback_enabled
--     all default true. They subtract from a grant; they do not gate it.
--
--   * wa_reminder_short_enabled defaults FALSE, because its template is still
--     draft (v581 shipped that lane inert on purpose). A switch showing "on" for
--     a lane that provably cannot send is a lie told to the owner — they would
--     read "on", see nothing arrive, and open a support ticket. It ships off, and
--     it becomes the owner's own decision to turn on once the message is live.
--     This is the one place where honesty to the owner outranks convenience.
--
-- ===========================================================================
-- 2. THE TOGGLE CAN ONLY EVER SUBTRACT
-- ===========================================================================
-- Both gates already run an ordered chain of refusals. The new condition is
-- inserted INTO that chain, downstream of every safety gate, so no ordering of
-- inputs exists in which the owner switch causes a send that would otherwise
-- have been refused. Ordering, after this migration:
--
--   appointment lane (app.whatsapp_enqueue_appointment_notice_v557)
--     1 kind is one of the four known kinds
--     2 appointment exists and is still 'booked'
--     3 platform kill switch      app.platform_feature_enabled('whatsapp_outbound')
--     4 business eligibility/hold app.business_may_initiate_comms_v572(...)
--     5 template exists AND status = 'approved'
--     6 capability grant          app.capability_state_v518(...)
--     7 >>> NEW: the owner's switch for THIS kind <<<   automation_off_for_business
--     8 client exists / not synthetic / has a phone
--     9 insert (idempotent)
--    10 quota consumption; a refusal here fails the row
--
--   bring-back lane (app.v551_enqueue_bringback_send)
--     1 platform kill switch  whatsapp_outbound
--     2 platform kill switch  whatsapp_retention_sends
--     3 business eligibility  app.business_may_initiate_comms_v572(... 'marketing')
--     4 platform hold         app.retention_platform_hold_v574(...)
--     5 capability grant      app.capability_state_v518(... 'whatsapp_retention')
--     6 synthetic client
--     7 >>> NEW: wa_bringback_enabled <<<               automation_off_for_business
--     8 marketing consent, then WhatsApp marketing consent
--     9 customer's own channel preference
--    10 phone on file
--    11 cooldown
--
-- The proof that the switch cannot bypass anything is structural, not a matter
-- of care: the chain is an if/elsif ladder, and a later branch is only reached
-- when every earlier branch was false. Turning the switch ON adds no branch and
-- removes none — it makes the NEW branch false, restoring the exact pre-v583
-- behaviour, which then continues into consent, cooldown and quota unchanged.
-- Turning it OFF short-circuits to a refusal. A boolean placed at position 7
-- cannot be evaluated before positions 1-6, so it cannot overrule them.
--
-- ===========================================================================
-- 3. KIND -> SWITCH, AND WHY appointment_updated SITS WITH CONFIRMATIONS
-- ===========================================================================
--   appointment_confirmation     -> wa_confirmation_enabled
--   appointment_reminder         -> wa_reminder_24h_enabled
--   appointment_reminder_short   -> wa_reminder_short_enabled
--   appointment_updated          -> wa_confirmation_enabled
--
-- The last one is a judgement, stated rather than hidden. A change-of-time
-- notice is the same speech act as a confirmation: it tells the customer when
-- to turn up, and it is sent because the business itself just changed that
-- answer. An owner who wants confirmations wants their customers told when the
-- time moves; an owner who has switched confirmations off has decided they tell
-- customers themselves, and would be surprised to find Peekaa still messaging
-- after a reschedule. It is deliberately NOT tied to the reminder switches — a
-- reminder is about a time the customer already knows.
--
-- A lane whose column is unknown fails closed (see the helper's else branch),
-- so adding a fifth kind without adding its switch makes that kind refuse, not
-- send unattended.
--
-- ===========================================================================
-- 4. WHO MAY WRITE THESE
-- ===========================================================================
-- Nothing new. public.businesses already has exactly one UPDATE policy,
-- salons_update / app.is_salon_owner(id), so these four columns are writable by
-- the firm's own owner and by nobody else — not staff, not another tenant, and
-- not a superadmin (whose 46 policies are SELECT-only). That is the intended
-- shape: the capability is Peekaa's ceiling, the toggle is the owner's floor.
-- ============================================================================

begin;

-- ---------------------------------------------------------------- columns
alter table public.businesses
  add column if not exists wa_confirmation_enabled   boolean not null default true,
  add column if not exists wa_reminder_24h_enabled   boolean not null default true,
  add column if not exists wa_reminder_short_enabled boolean not null default false,
  add column if not exists wa_bringback_enabled      boolean not null default true;

comment on column public.businesses.wa_confirmation_enabled is
  'nestly_v583 — owner switch: send a booking confirmation, and a change-of-time notice, on WhatsApp. Subtracts from the capability grant; never grants.';
comment on column public.businesses.wa_reminder_24h_enabled is
  'nestly_v583 — owner switch: send the day-before appointment reminder.';
comment on column public.businesses.wa_reminder_short_enabled is
  'nestly_v583 — owner switch: send the short-notice (~2h) reminder. Ships FALSE because its template is still draft; an "on" switch for a lane that cannot send is a lie to the owner.';
comment on column public.businesses.wa_bringback_enabled is
  'nestly_v583 — owner switch: send the bring-back voucher to quiet customers.';

-- --------------------------------------------------------------- the helper
-- One mapping, read by both gates, so the two lanes cannot drift apart. STABLE
-- and SECURITY DEFINER because both callers are themselves definer functions
-- running with search_path pinned; it reads one row of public.businesses and
-- returns a boolean. Fail-closed on every unknown: unknown lane -> false,
-- missing business -> false.
create or replace function app.business_automation_enabled_v583(
  p_business uuid, p_lane text)
returns boolean
language sql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $fn$
  select coalesce((
    select case p_lane
             when 'appointment_confirmation'   then b.wa_confirmation_enabled
             when 'appointment_updated'        then b.wa_confirmation_enabled
             when 'appointment_reminder'       then b.wa_reminder_24h_enabled
             when 'appointment_reminder_short' then b.wa_reminder_short_enabled
             when 'bringback'                  then b.wa_bringback_enabled
             else false
           end
      from public.businesses b
     where b.id = p_business
  ), false);
$fn$;

revoke all on function app.business_automation_enabled_v583(uuid, text)
  from public, anon, authenticated;
grant execute on function app.business_automation_enabled_v583(uuid, text)
  to service_role;

-- The owner's card reads the capability ceiling through the existing v518
-- business-scoped probe. The grant already exists in prod; it is restated here
-- because v21's allowlist test only looks at v21 itself plus the migrations
-- still pending in the canonical plan, and this is the migration that makes the
-- browser call it for the first time.
revoke all on function public.business_get_capability_v518(uuid, text)
  from public, anon;
grant execute on function public.business_get_capability_v518(uuid, text)
  to authenticated, service_role;

-- ============================================================================
-- THE APPOINTMENT LANE
-- Transcribed from the live v581 definition with ONE inserted block, marked
-- v583 below. Nothing else on this path changed.
-- ============================================================================
create or replace function app.whatsapp_enqueue_appointment_notice_v557(
  p_business uuid, p_appointment uuid, p_kind text)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_appt public.appointments%rowtype;
  v_client public.clients%rowtype;
  v_tpl public.whatsapp_template_registry_v551%rowtype;
  v_state jsonb;
  v_quota jsonb;
  v_biz jsonb;
  v_biz_name text;
  v_service_name text;
  v_idem text;
  v_when text;
  v_id uuid;
begin
  if p_kind is null or p_kind not in ('appointment_confirmation','appointment_reminder',
                                      'appointment_reminder_short','appointment_updated') then
    return jsonb_build_object('status','refused','reason','unknown_kind');
  end if;

  select * into v_appt from public.appointments
   where id = p_appointment and business_id = p_business;
  if not found then
    return jsonb_build_object('status','refused','reason','appointment_not_found');
  end if;
  if v_appt.status <> 'booked' then
    return jsonb_build_object('status','refused','reason','appointment_not_booked');
  end if;

  if not app.platform_feature_enabled('whatsapp_outbound') then
    return jsonb_build_object('status','refused','reason','outbound_not_enabled');
  end if;

  v_biz := app.business_may_initiate_comms_v572(p_business, 'whatsapp', 'transactional');
  if not coalesce((v_biz->>'allowed')::boolean, false) then
    return jsonb_build_object('status','refused',
      'reason', coalesce(v_biz->>'reason', 'business_not_eligible'));
  end if;

  -- v581: the template must exist AND be approved. This is what keeps a newly
  -- added kind inert until Meta has actually said yes.
  select * into v_tpl from public.whatsapp_template_registry_v551
   where template_key = p_kind;
  if not found then
    return jsonb_build_object('status','refused','reason','template_unknown');
  end if;
  if v_tpl.status <> 'approved' then
    return jsonb_build_object('status','refused','reason','template_not_approved',
      'template_status', v_tpl.status);
  end if;

  v_state := app.capability_state_v518(p_business, 'whatsapp_appointment_notification');
  if (v_state->>'allowed') is distinct from 'true' then
    return jsonb_build_object('status','refused',
      'reason', coalesce(v_state->>'reason','capability_refused')) || v_state;
  end if;

  -- v583: the owner's own switch, LAST of the eligibility gates and therefore
  -- incapable of overruling any of them. Everything above has already said yes;
  -- this is the shopkeeper's chance to say no.
  if not app.business_automation_enabled_v583(p_business, p_kind) then
    return jsonb_build_object('status','refused','reason','automation_off_for_business',
      'kind', p_kind);
  end if;

  select * into v_client from public.clients
   where id = v_appt.client_id and business_id = p_business;
  if not found then
    return jsonb_build_object('status','refused','reason','client_not_found');
  end if;
  if coalesce(v_client.is_synthetic, false) then
    return jsonb_build_object('status','refused','reason','synthetic_client');
  end if;
  if v_client.phone_norm is null then
    return jsonb_build_object('status','refused','reason','no_phone');
  end if;

  select b.name into v_biz_name from public.businesses b where b.id = p_business;
  select s.name into v_service_name from public.services s where s.id = v_appt.service_id;

  -- A reminder names only a time because its template already says which day.
  -- A confirmation or a change of time must name the date, because the customer
  -- is being told something they do not already know.
  v_when := case
    when p_kind in ('appointment_reminder','appointment_reminder_short')
      then to_char(v_appt.starts_at at time zone 'Asia/Singapore', 'HH12:MI AM')
    else to_char(v_appt.starts_at at time zone 'Asia/Singapore', 'Dy DD Mon, HH12:MI AM')
  end;

  v_idem := p_kind || ':' || p_appointment::text || ':'
            || to_char(v_appt.starts_at at time zone 'UTC', 'YYYYMMDD"T"HH24MISS');

  insert into public.whatsapp_template_sends_v557(
    business_id, appointment_id, kind, recipient_phone_norm,
    template_name, language_code, parameters, idempotency_key,
    status, status_rank, attempt_count, queued_at, next_attempt_at)
  values (
    p_business, p_appointment, p_kind, v_client.phone_norm,
    v_tpl.meta_name, v_tpl.language_code,
    jsonb_build_array(
      jsonb_build_object('type','text','text', coalesce(nullif(btrim(v_biz_name),''),'Peekaa')),
      jsonb_build_object('type','text','text', coalesce(nullif(btrim(v_service_name),''),'your appointment')),
      jsonb_build_object('type','text','text', v_when)),
    v_idem, 'queued', app.support_status_rank_v535('queued'), 0, now(), now())
  on conflict (business_id, idempotency_key) do nothing
  returning id into v_id;

  if v_id is null then
    return jsonb_build_object('status','ok','duplicate',true,'reason','already_queued');
  end if;

  v_quota := app.capability_consume_v518(
    p_business, 'whatsapp_appointment_notification', v_idem,
    jsonb_build_object('appointment_id', p_appointment, 'kind', p_kind));

  if (v_quota->>'consumed') is distinct from 'true' then
    update public.whatsapp_template_sends_v557
       set status = 'failed',
           status_rank = greatest(status_rank, app.support_status_rank_v535('failed')),
           last_error_code = left(coalesce(v_quota->>'reason','capability_refused'), 64),
           next_attempt_at = null
     where id = v_id;
    return jsonb_build_object('status','refused',
      'reason', coalesce(v_quota->>'reason','capability_refused'),
      'send_id', v_id);
  end if;

  return jsonb_build_object(
    'status','ok','duplicate',false,'send_id',v_id,'kind',p_kind,
    'template_name',v_tpl.meta_name,'idempotency_key',v_idem,
    'remaining', v_quota->'remaining');
end
$function$;

-- Restated verbatim from the live proacl ({postgres=X/postgres,service_role=X/postgres}).
revoke all on function app.whatsapp_enqueue_appointment_notice_v557(uuid, uuid, text)
  from public, anon, authenticated;
grant execute on function app.whatsapp_enqueue_appointment_notice_v557(uuid, uuid, text)
  to service_role;

-- ============================================================================
-- THE BRING-BACK LANE
-- Transcribed from the live definition with ONE inserted elsif, marked v583.
-- It sits after the platform switches, the business eligibility check, the
-- platform hold, the capability grant and the synthetic-client guard, and
-- BEFORE consent: a business's own switch is cheaper to evaluate than the two
-- consent lookups and the cooldown scan, and refusing on the owner's decision
-- first tells the owner something true and actionable. It is placed after the
-- synthetic-client guard on purpose — "this is a demo customer" is a stronger,
-- more surprising fact than "you turned this off", and should keep its name in
-- the suppression report.
-- ============================================================================
create or replace function app.v551_enqueue_bringback_send()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_client public.clients%rowtype;
  v_biz_name text;
  v_first text;
  v_identity uuid;
  v_reason text := null;
  v_biz jsonb;
  v_hold jsonb;
  v_consent jsonb;
begin
  select * into v_client from public.clients
   where id = new.client_id and business_id = new.business_id;
  if not found then return new; end if;

  select b.name into v_biz_name from public.businesses b where b.id = new.business_id;

  if not app.platform_feature_enabled('whatsapp_outbound') then
    v_reason := 'outbound_off';
  elsif not app.platform_feature_enabled('whatsapp_retention_sends') then
    v_reason := 'retention_sends_off';
  else
    v_biz := app.business_may_initiate_comms_v572(new.business_id, 'whatsapp', 'marketing');
    if not coalesce((v_biz->>'allowed')::boolean, false) then
      v_reason := coalesce(v_biz->>'reason', 'business_not_eligible');
    else
      v_hold := app.retention_platform_hold_v574(new.business_id, new.campaign_id);
      if coalesce((v_hold->>'held')::boolean, false) then
        v_reason := 'platform_hold';
      elsif not coalesce((app.capability_state_v518(new.business_id, 'whatsapp_retention')->>'allowed')::boolean, false) then
        v_reason := 'capability_disabled';
      elsif coalesce(v_client.is_synthetic, false) then
        v_reason := 'synthetic_client';
      elsif not app.business_automation_enabled_v583(new.business_id, 'bringback') then
        -- v583: the owner switched this lane off. Downstream of every platform
        -- and capability gate above, upstream of consent below, so it can only
        -- ever remove a send.
        v_reason := 'automation_off_for_business';
      elsif not coalesce(v_client.marketing_consent, false) then
        v_reason := 'consent_missing';
      else
        v_consent := app.whatsapp_marketing_consent_v572(new.business_id, new.client_id);
        if not coalesce((v_consent->>'allowed')::boolean, false) then
          v_reason := coalesce(v_consent->>'reason', 'whatsapp_consent_absent');
        else
          select l.identity_id into v_identity
            from public.customer_links l
           where l.business_id = new.business_id and l.client_id = new.client_id
             and l.state = 'verified'
           limit 1;
          if v_identity is not null
             and not app.customer_communication_allows_v263(v_identity, 'business_offers', 'whatsapp') then
            v_reason := 'preference_opt_out';
          elsif v_client.phone_norm is null then
            v_reason := 'no_phone';
          elsif app.retention_in_cooldown_v572(new.business_id, new.client_id) then
            v_reason := 'cooldown_active';
          end if;
        end if;
      end if;
    end if;
  end if;

  v_first := nullif(split_part(btrim(coalesce(v_client.full_name, '')), ' ', 1), '');

  insert into public.retention_sends_v551(
    business_id, client_id, grant_id, template_key, variables,
    recipient_phone_norm, status, status_rank, suppressed_reason)
  values (
    new.business_id, new.client_id, new.id, 'bring_back_v1',
    jsonb_build_object(
      'customer_first_name', coalesce(v_first, 'there'),
      'business_name', coalesce(v_biz_name, 'us'),
      'reward_label', new.reward_label),
    v_client.phone_norm,
    case when v_reason is null then 'queued' else 'suppressed' end,
    case when v_reason is null then 0 else app.v551_retention_status_rank('suppressed') end,
    v_reason)
  on conflict (grant_id) do nothing;

  return new;
exception when others then
  return new;
end
$function$;

-- Restated verbatim from the live proacl ({postgres=X/postgres}) — a trigger
-- function no role calls directly.
revoke all on function app.v551_enqueue_bringback_send()
  from public, anon, authenticated;

commit;
