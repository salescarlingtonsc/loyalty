-- NESTLY v644 — Phase B, B1: one contactability authority.
-- Owner-approved Phase B design (2026-08-30). Consent lives in three systems with different
-- scopes and defaults: the per-business append-only `consents` ledger (purpose×channel,
-- doc-pinned — the ONLY sufficient authority for proactive marketing, per the v572 "nobody
-- is grandfathered" ruling), the identity-scoped v263 preference matrix (deviation rows,
-- absence = ON by owner ruling; zero rows in production today), and the platform-level
-- opt-in event stream. Only the v551 WhatsApp chain composes them correctly, inline.
--
-- app.can_contact_v1 is the composition LAW: a read-only function every future send path,
-- audience sizing and CI surface asks instead of re-deriving the rules. The v551 chain is
-- deliberately NOT refactored here — it stays live and correct; swapping it onto this
-- function is Phase G work, gated on the shadow agreement the rollback suite asserts.
--
-- clients.marketing_consent remains a till-side prefilter only; it is never sufficient.
-- 'booking_updates' (transactional) is refused as a category rather than answered — v263
-- structurally excludes it and this function must not become a transactional gate.
begin;

create or replace function app.can_contact_v1(
  p_business uuid, p_client uuid, p_category text, p_channel text)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_client public.clients%rowtype;
  v_prov jsonb := '[]'::jsonb;
  v_identity uuid;
  v_latest_consent text;
  v_pref boolean;
  v_platform boolean;
begin
  if p_category not in ('business_offers','rewards_and_points','peekaa_updates') then
    raise exception 'unsupported contact category % (transactional traffic is not gated here)', p_category
      using errcode = '22023';
  end if;
  if p_channel not in ('whatsapp','sms','email','push','in_app','call') then
    raise exception 'unsupported contact channel %', p_channel using errcode = '22023';
  end if;

  select * into v_client from public.clients
   where id = p_client and business_id = p_business;
  if not found then
    raise exception 'client not found' using errcode = '22023';
  end if;

  -- 1. Hard stops.
  if exists (select 1 from public.client_erasures_v290 e
              where e.business_id = p_business and e.client_id = p_client) then
    return jsonb_build_object('allowed', false, 'reason', 'erased',
      'provenance', v_prov || jsonb_build_array(jsonb_build_object('step','erasure','outcome','deny')));
  end if;
  v_prov := v_prov || jsonb_build_array(jsonb_build_object('step','erasure','outcome','pass'));
  if coalesce(v_client.is_synthetic, false) then
    return jsonb_build_object('allowed', false, 'reason', 'synthetic_client',
      'provenance', v_prov || jsonb_build_array(jsonb_build_object('step','synthetic','outcome','deny')));
  end if;
  if not app.analytics_business_included_v1(p_business) then
    v_prov := v_prov || jsonb_build_array(jsonb_build_object('step','business_scope','outcome','deny'));
    return jsonb_build_object('allowed', false, 'reason', 'excluded_business', 'provenance', v_prov);
  end if;

  -- 2. Reachability.
  select cl.identity_id into v_identity
    from public.customer_links cl
   where cl.business_id = p_business and cl.client_id = p_client and cl.state = 'verified'
   limit 1;
  if p_channel in ('whatsapp','sms','call') and nullif(v_client.phone_norm,'') is null then
    return jsonb_build_object('allowed', false, 'reason', 'unreachable_no_phone',
      'provenance', v_prov || jsonb_build_array(jsonb_build_object('step','reachability','outcome','deny','detail','no phone')));
  end if;
  if p_channel = 'email' and nullif(btrim(coalesce(v_client.email,'')),'') is null then
    return jsonb_build_object('allowed', false, 'reason', 'unreachable_no_email',
      'provenance', v_prov || jsonb_build_array(jsonb_build_object('step','reachability','outcome','deny','detail','no email')));
  end if;
  if p_channel in ('push','in_app') and v_identity is null then
    return jsonb_build_object('allowed', false, 'reason', 'unreachable_no_verified_link',
      'provenance', v_prov || jsonb_build_array(jsonb_build_object('step','reachability','outcome','deny','detail','no verified link')));
  end if;
  v_prov := v_prov || jsonb_build_array(jsonb_build_object('step','reachability','outcome','pass'));

  -- 3. Category authority.
  if p_category = 'peekaa_updates' then
    if v_identity is null then
      return jsonb_build_object('allowed', false, 'reason', 'no_platform_relationship',
        'provenance', v_prov || jsonb_build_array(jsonb_build_object('step','platform_optin','outcome','deny')));
    end if;
    select e.opted_in into v_platform
      from public.customer_platform_marketing_consent_events e
     where e.identity_id = v_identity
     order by e.occurred_at desc limit 1;
    if not coalesce(v_platform, false) then
      return jsonb_build_object('allowed', false, 'reason', 'platform_consent_missing',
        'provenance', v_prov || jsonb_build_array(jsonb_build_object('step','platform_optin','outcome','deny')));
    end if;
    v_prov := v_prov || jsonb_build_array(jsonb_build_object('step','platform_optin','outcome','pass'));
  else
    -- Proactive marketing to a business's customer requires an affirmative,
    -- doc-pinned, business-scoped consent row for THIS channel. Nobody is
    -- grandfathered; clients.marketing_consent alone never suffices.
    select c.action into v_latest_consent
      from public.consents c
     where c.business_id = p_business and c.client_id = p_client
       and c.purpose = 'marketing' and c.channel = p_channel
     order by c.created_at desc limit 1;
    if v_latest_consent is distinct from 'granted' then
      return jsonb_build_object('allowed', false, 'reason', 'consent_missing',
        'provenance', v_prov || jsonb_build_array(jsonb_build_object(
          'step','business_consent','outcome','deny',
          'detail', coalesce('latest action: '||v_latest_consent, 'no consent row'))));
    end if;
    v_prov := v_prov || jsonb_build_array(jsonb_build_object('step','business_consent','outcome','pass'));
  end if;

  -- 4. Identity-level preference (absence = ON, per the standing owner ruling).
  if v_identity is not null then
    select p.enabled into v_pref
      from public.customer_communication_preferences_v263 p
     where p.identity_id = v_identity and p.category = p_category and p.channel = p_channel;
    if v_pref is false then
      return jsonb_build_object('allowed', false, 'reason', 'preference_opt_out',
        'provenance', v_prov || jsonb_build_array(jsonb_build_object('step','identity_preference','outcome','deny')));
    end if;
  end if;
  v_prov := v_prov || jsonb_build_array(jsonb_build_object('step','identity_preference','outcome','pass'));

  return jsonb_build_object('allowed', true, 'reason', 'ok', 'provenance', v_prov);
end;
$$;
revoke all on function app.can_contact_v1(uuid,uuid,text,text) from public, anon, authenticated;
grant execute on function app.can_contact_v1(uuid,uuid,text,text) to service_role;

-- Batch companion for the CI card and Best-Action audience sizing.
create or replace function app.contactable_counts_v1(p_business uuid, p_category text)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_channel text;
  v_client record;
  v_total integer := 0;
  v_result jsonb := '{}'::jsonb;
  v_allowed integer;
begin
  select count(*) into v_total
    from public.clients c
   where c.business_id = p_business
     and not coalesce(c.is_synthetic, false)
     and not exists (select 1 from public.client_erasures_v290 e
                      where e.business_id = p_business and e.client_id = c.id);
  foreach v_channel in array array['whatsapp','sms','email','push','in_app','call'] loop
    v_allowed := 0;
    for v_client in
      select c.id from public.clients c
       where c.business_id = p_business and not coalesce(c.is_synthetic, false)
    loop
      if (app.can_contact_v1(p_business, v_client.id, p_category, v_channel)->>'allowed')::boolean then
        v_allowed := v_allowed + 1;
      end if;
    end loop;
    v_result := v_result || jsonb_build_object(v_channel, v_allowed);
  end loop;
  return jsonb_build_object('category', p_category, 'customers', v_total, 'allowed_by_channel', v_result);
end;
$$;
revoke all on function app.contactable_counts_v1(uuid,text) from public, anon, authenticated;
grant execute on function app.contactable_counts_v1(uuid,text) to service_role;

commit;
