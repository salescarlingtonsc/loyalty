-- NESTLY v752 — the birthday gift becomes a real benefit: same editor, same till, customer QR.
--
-- OWNER RULING (2026-09-04, confirmed in a follow-up question): "Birthday rewards must also
-- have the same function as tier membership rewards — the mechanism is wired correctly (not
-- just typing words, but real objectives like example discount for whole bill or selected
-- items)." Clarified further: ONE benefit, using the SAME editor as a tier benefit, and the
-- customer must be able to see the birthday reward in their customer app so they can let the
-- business scan the QR code.
--
-- WHAT WAS TRUE BEFORE THIS MIGRATION (v45/v182/v367/v374). birthday_program_versions already
-- carried a typed fulfillment_kind ('discount_pct' | 'free_item'), a bare discount_percent, and
-- a free-text manual_item — no product/service catalogue pick, no scope, no cap, and the
-- customer_label/description/terms were typed by the owner rather than derived. Redemption ran
-- through a wholly separate "Activate benefit" -> customer_birthday_entitlements ->
-- redeem_customer_birthday_benefit path with NO gift QR, NO Record-sale discount, and NO reuse of
-- the tier-benefit label vocabulary. A structured "10% off, capped at $20" birthday gift could
-- not be expressed, and even a plain "10% off" never actually came off a bill.
--
-- WHAT THIS MIGRATION ADDS (additive only; nothing dropped, nothing renamed).
--   1. birthday_program_versions grows the SAME structured-discount columns tier_benefits_v365
--      has (product_id, discount_scope, max_discount_cents), plus a new scope side-table
--      birthday_benefit_scope_v752 mirroring tier_benefit_scope_v656 (one row per eligible
--      product/service for an 'item'-scoped discount).
--   2. customer_label is no longer typed: a new BEFORE INSERT trigger derives it from the
--      structured fields using the SAME server label authorities the tier-benefit editor already
--      uses (app.v369_benefit_label for "Free <item>", app.v657_discount_label for "N% off[,
--      one item][, up to $x]") — one authority, not a second implementation. customer_description
--      and customer_terms remain owner-authored supplementary copy, unchanged.
--   3. app.c45_benefit_snapshot and app.c45_customer_birthday_benefit_for_context's inline
--      'display' projection are recomputed through the same v369/v657 authorities instead of the
--      old bare "X% off" / manual_item string, so every reader (customer wallet, staff card,
--      QR-intent quote) agrees with the editor.
--   4. 'birthday' becomes a fourth public.customer_gift_intents_v515 gift_kind, reusing the exact
--      QR-mint / poll / cancel / staff-scan machinery welcome, bringback, referral and tier_perk
--      already share (customer_create_gift_intent_v515, customer_get_gift_intent_v515,
--      customer_cancel_gift_intent_v515, staff_scan_gift_qr_to_till_v666,
--      staff_stage_gift_qr_v665). The gift target is the client's live
--      customer_birthday_entitlements row (status='available', inside its SG window) — the SAME
--      one-per-window latch v45/v138 already enforce; no new "have they used it" bookkeeping.
--   5. A discount_pct birthday benefit is staged onto the sale and actually taken off the bill:
--      app.ps1c_plan_checkout gains an additive p_birthday boolean (default false — every
--      existing caller keeps its old behaviour unchanged) that prices it exactly like the v656/
--      v657 hand-applied tier discount (whole bill, or the dearest eligible item from
--      birthday_benefit_scope_v752, capped in money). public.record_cart_sale, on finalising a
--      sale that carries that effect, calls the EXISTING public.redeem_customer_birthday_benefit
--      (unchanged) inside the same transaction that takes the money — the same "spend the
--      allowance where the money moves" discipline v656 uses for tier_benefit_issues_v365,
--      reusing redeem_customer_birthday_benefit's own idempotency and one-per-window lock rather
--      than inventing a parallel counter.
--   6. A free_item birthday benefit settles like a tier free_item gift (v681): the QR scan
--      answers settle_now=true and a new, deliberately thin public.
--      staff_confirm_birthday_free_item_v752 hands it over by calling the SAME
--      redeem_customer_birthday_benefit — literally the existing "Activate" era redemption
--      authority, now reachable from the counter's QR scan instead of only a standalone button.
--
-- WHAT IS DELIBERATELY UNCHANGED. fulfillment_kind stays a closed choice of exactly
-- ('discount_pct','free_item') — no 'custom' free-text option is added here, matching the owner's
-- "not just typing words" ruling and v682's narrowing of the analogous tier vocabulary in the
-- other direction. The standalone "Activate benefit" -> redeem_customer_birthday_benefit path
-- (the non-QR till button) is untouched and keeps working for a business that has not adopted
-- the new editor fields yet. Older published birthday_program_versions rows (typed
-- customer_label, no product_id/discount_scope/max_discount_cents) are read exactly as before —
-- app.c45_benefit_snapshot only recomputes 'display'; customer_label on an already-published row
-- is immutable and untouched.

begin;

-- ===============================================================================================
-- 1. Structured benefit columns on birthday_program_versions (mirrors tier_benefits_v365).
-- ===============================================================================================

alter table public.birthday_program_versions
  add column if not exists product_id uuid references public.products(id) on delete restrict,
  add column if not exists discount_scope text not null default 'bill'
    check (discount_scope in ('bill','item')),
  add column if not exists max_discount_cents integer
    check (max_discount_cents is null or max_discount_cents > 0);

comment on column public.birthday_program_versions.product_id is
  'nestly_v752: optional catalogue pick for a free_item benefit, alongside the pre-existing '
  'free-text manual_item — same product_id/item_label duality tier_benefits_v365 has.';
comment on column public.birthday_program_versions.discount_scope is
  'nestly_v752: for a discount_pct benefit, whether the percentage comes off the whole bill or '
  'one eligible item (the dearest item named in birthday_benefit_scope_v752) — same two shapes '
  'nestly_v657 gave tier benefits.';
comment on column public.birthday_program_versions.max_discount_cents is
  'nestly_v752: optional money cap on a discount_pct benefit, applied after the percentage — '
  'same field/semantics as tier_benefits_v365.max_discount_cents.';

-- The v45 fulfillment check required manual_item to carry the free_item text and forbade
-- product_id, which did not exist yet. Replace it with one that accepts EITHER a catalogue pick
-- or typed text for a free item (at least one), and leaves discount_pct's shape unconstrained on
-- scope/cap (both are optional, defaulted, and independently checked above).
alter table public.birthday_program_versions
  drop constraint if exists birthday_program_versions_fulfillment_check;
alter table public.birthday_program_versions
  add constraint birthday_program_versions_fulfillment_check check (
    (fulfillment_kind = 'discount_pct'
      and discount_percent is not null and discount_percent > 0 and discount_percent <= 100
      and manual_item is null and product_id is null)
    or
    (fulfillment_kind = 'free_item'
      and discount_percent is null
      and (product_id is not null
           or length(btrim(coalesce(manual_item, ''))) between 1 and 240))
  );

create table if not exists public.birthday_benefit_scope_v752 (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  program_version_id uuid not null
    references public.birthday_program_versions(id) on delete cascade,
  product_id uuid references public.products(id) on delete cascade,
  service_id uuid references public.services(id) on delete cascade,
  created_at timestamptz not null default now(),
  constraint birthday_benefit_scope_v752_one_kind_check
    check ((product_id is not null) <> (service_id is not null))
);
comment on table public.birthday_benefit_scope_v752 is
  'nestly_v752: the eligible-item allow-list for an item-scoped birthday discount. Mirrors '
  'tier_benefit_scope_v656 exactly; only meaningful when the owning program version has '
  'fulfillment_kind=''discount_pct'' and discount_scope=''item''. A plain single-column FK on '
  '(program_version_id) — that row is already the immutable, uniquely-identified published '
  'fact; business_id travels alongside for RLS/query convenience only, not as part of the FK.';

create index if not exists birthday_benefit_scope_v752_program_idx
  on public.birthday_benefit_scope_v752(program_version_id);

alter table public.birthday_benefit_scope_v752 enable row level security;
-- Browser-closed, exactly like birthday_program_versions and tier_benefit_scope_v656: read only
-- through the SECURITY DEFINER functions below, never directly by anon or authenticated.
revoke all privileges on table public.birthday_benefit_scope_v752 from public, anon, authenticated;

-- ===============================================================================================
-- 2. customer_label is DERIVED, not typed — the same label authorities the tier-benefit editor
--    already uses. Fires only on INSERT: published rows are immutable (v45's own guard trigger
--    forbids UPDATE/DELETE), so this purely computes the column once, at publish time.
-- ===============================================================================================

create or replace function app.v752_derive_birthday_benefit_label()
returns trigger
language plpgsql
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
begin
  if new.fulfillment_kind = 'discount_pct' then
    new.customer_label := app.v657_discount_label(new.discount_percent, new.discount_scope,
      new.max_discount_cents);
  elsif new.fulfillment_kind = 'free_item' then
    new.customer_label := app.v369_benefit_label('free_item', null, new.product_id,
      new.manual_item, new.customer_label);
  end if;
  return new;
end
$function$;
comment on function app.v752_derive_birthday_benefit_label() is
  'nestly_v752: overwrites the incoming customer_label with the SAME app.v657_discount_label / '
  'app.v369_benefit_label sentence a tier benefit would get, so the wording customers see is '
  'never hand-typed. Runs BEFORE the pre-existing c45 immutability/window guard trigger; it only '
  'sets a column and never raises, so trigger firing order does not matter.';
revoke all on function app.v752_derive_birthday_benefit_label() from public, anon, authenticated;

drop trigger if exists v752_derive_birthday_benefit_label_trg on public.birthday_program_versions;
create trigger v752_derive_birthday_benefit_label_trg
  before insert on public.birthday_program_versions
  for each row execute function app.v752_derive_birthday_benefit_label();

-- ===============================================================================================
-- 3. Every reader of a birthday benefit's 'display' text goes through the same authorities.
--    Restating both functions verbatim except the 'display'/label computation.
-- ===============================================================================================

create or replace function app.c45_benefit_snapshot(p_program public.birthday_program_versions)
returns jsonb
language sql
immutable
strict
set search_path to 'pg_catalog', 'pg_temp'
as $function$
  select jsonb_strip_nulls(jsonb_build_object(
    'label', p_program.customer_label,
    'description', p_program.customer_description,
    'terms', p_program.customer_terms,
    'kind', p_program.fulfillment_kind,
    'display', case when p_program.fulfillment_kind = 'discount_pct'
      then app.v657_discount_label(p_program.discount_percent, p_program.discount_scope,
        p_program.max_discount_cents)
      else app.v369_benefit_label('free_item', null, p_program.product_id, p_program.manual_item,
        p_program.manual_item)
    end
  ))
$function$;
revoke all on function app.c45_benefit_snapshot(public.birthday_program_versions)
  from public, anon, authenticated;

create or replace function app.c45_customer_birthday_benefit_for_context(
  p_business_id uuid, p_client_id uuid, p_identity_id uuid, p_birth_date date,
  p_as_of timestamptz)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_entitlement public.customer_birthday_entitlements%rowtype;
  v_program public.birthday_program_versions%rowtype;
  v_window record;
  v_opted_in boolean := false;
  v_display text;
begin
  select * into v_entitlement
    from public.customer_birthday_entitlements e
   where e.business_id = p_business_id and e.client_id = p_client_id
     and e.identity_id = p_identity_id and e.valid_until > p_as_of
   order by e.valid_until desc, e.activated_at desc
   limit 1;
  if found then
    return app.c45_safe_birthday_entitlement(v_entitlement, p_as_of);
  end if;
  select coalesce(p.opted_in, false) into v_opted_in
    from (select 1) one
    left join public.customer_birthday_participation p on p.identity_id = p_identity_id;
  select bpv.* into v_program
    from public.businesses b
    join public.birthday_program_versions bpv
      on bpv.config_version_id = b.active_config_version_id
     and bpv.business_id = b.id and bpv.active
   where b.id = p_business_id
     and 'loyalty' = any(coalesce(b.enabled_modules, '{}'::text[]))
   order by bpv.sort, bpv.program_id
   limit 1;
  if found then
    select * into v_window
      from app.c45_birthday_window(p_birth_date, v_program.window_days_before,
        v_program.window_days_after, p_as_of, v_program.window_mode);
    if found then
      select * into v_entitlement
        from public.customer_birthday_entitlements e
       where e.business_id = p_business_id and e.client_id = p_client_id
         and e.identity_id = p_identity_id and e.birthday_year = v_window.birthday_year
       order by e.activated_at desc
       limit 1;
      if found then return app.c45_safe_birthday_entitlement(v_entitlement, p_as_of); end if;
      if coalesce(v_opted_in, false) then
        -- nestly_v752: the same derived sentence app.c45_benefit_snapshot gives a live
        -- entitlement, computed here BEFORE one exists yet (the customer has not tapped
        -- Activate), so the pre-activation preview and the post-activation card never disagree.
        v_display := case when v_program.fulfillment_kind = 'discount_pct'
          then app.v657_discount_label(v_program.discount_percent, v_program.discount_scope,
            v_program.max_discount_cents)
          else app.v369_benefit_label('free_item', null, v_program.product_id,
            v_program.manual_item, v_program.manual_item)
        end;
        return jsonb_build_object(
          'label', v_program.customer_label,
          'description', v_program.customer_description,
          'terms', v_program.customer_terms,
          'kind', v_program.fulfillment_kind,
          'display', v_display,
          'status', 'ready_to_activate',
          'validity', jsonb_build_object('available_from', v_window.valid_from, 'available_until', v_window.valid_until),
          'cta', 'activate'
        );
      end if;
    end if;
  end if;
  select * into v_entitlement
    from public.customer_birthday_entitlements e
   where e.business_id = p_business_id and e.client_id = p_client_id
     and e.identity_id = p_identity_id
   order by e.birthday_year desc, e.valid_until desc, e.activated_at desc
   limit 1;
  if found then return app.c45_safe_birthday_entitlement(v_entitlement, p_as_of); end if;
  return null;
end
$function$;
revoke all on function app.c45_customer_birthday_benefit_for_context(uuid, uuid, uuid, date, timestamptz)
  from public, anon, authenticated;



-- ===============================================================================================
-- 3b. app.c45_safe_birthday_entitlement gains an additive 'id' key (only ever present when the
--     underlying entitlement is 'available' — never for a redeemed/expired one, since only a live
--     entitlement is ever a gift-QR target). Every existing reader ignores unknown keys, so this
--     is additive for both public.customer_get_birthday_benefit and
--     public.staff_get_customer_birthday_benefit, which are restated below unchanged except that
--     they now carry it through.
-- ===============================================================================================

create or replace function app.c45_safe_birthday_entitlement(
  p_entitlement customer_birthday_entitlements, p_as_of timestamptz, p_cta text default 'show_at_counter')
returns jsonb
language sql
stable
strict
set search_path to 'pg_catalog', 'pg_temp'
as $function$
  select jsonb_strip_nulls(jsonb_build_object(
    'id', case when p_entitlement.status = 'available' and p_entitlement.valid_until > p_as_of
      then p_entitlement.id else null end,
    'label', p_entitlement.benefit_snapshot->>'label',
    'description', p_entitlement.benefit_snapshot->>'description',
    'terms', p_entitlement.benefit_snapshot->>'terms',
    'kind', p_entitlement.benefit_snapshot->>'kind',
    'display', p_entitlement.benefit_snapshot->>'display',
    'status', case
      when p_entitlement.status = 'available' and p_entitlement.valid_until <= p_as_of then 'expired'
      else p_entitlement.status end,
    'validity', jsonb_build_object(
      'available_from', p_entitlement.valid_from,
      'available_until', p_entitlement.valid_until
    ),
    'redemption', case when p_entitlement.status = 'redeemed' then 'redeemed' else null end,
    'cta', case
      when p_entitlement.status = 'available'
       and p_entitlement.valid_from <= p_as_of
       and p_entitlement.valid_until > p_as_of then p_cta
      else null end
  ))
$function$;
revoke all on function app.c45_safe_birthday_entitlement(customer_birthday_entitlements, timestamptz, text)
  from public, anon, authenticated;

-- ===============================================================================================
-- 4. 'birthday' becomes a fourth gift_kind on the SAME QR intent used by welcome/bringback/
--    referral/tier_perk. Restated verbatim except the new v_kind='birthday' branch and its
--    resolution query.
--
-- customer_gift_intents_v515 needs three constraint changes first: benefit_id is polymorphic
-- ALREADY (grant_id has no FK at all, because it names a row in one of THREE different grant
-- tables depending on gift_kind, validated in code, not by a foreign key) — a birthday intent's
-- benefit_id names a row in customer_birthday_entitlements, a fourth table, so the existing FK to
-- tier_benefits_v365 has to go the same way grant_id's already did: application-validated, not
-- database-enforced. kind_check and shape_check both widen by exactly one arm.
-- ===============================================================================================

alter table public.customer_gift_intents_v515
  drop constraint if exists customer_gift_intents_v515_benefit_id_fkey;

alter table public.customer_gift_intents_v515
  drop constraint customer_gift_intents_v515_kind_check;
alter table public.customer_gift_intents_v515
  add constraint customer_gift_intents_v515_kind_check
  check (gift_kind = any (array['welcome'::text, 'bringback'::text, 'referral'::text, 'tier_perk'::text, 'birthday'::text]));

alter table public.customer_gift_intents_v515
  drop constraint customer_gift_intents_v515_shape_check;
alter table public.customer_gift_intents_v515
  add constraint customer_gift_intents_v515_shape_check
  check (
    ((gift_kind = any (array['welcome'::text, 'bringback'::text, 'referral'::text]))
      and grant_id is not null and benefit_id is null and quoted_period_key is null)
    or ((gift_kind = any (array['tier_perk'::text, 'birthday'::text]))
      and grant_id is null and benefit_id is not null)
  );

comment on column public.customer_gift_intents_v515.benefit_id is
  'Polymorphic: tier_benefits_v365.id when gift_kind=tier_perk, customer_birthday_entitlements.id '
  'when gift_kind=birthday (nestly_v752) — validated by the writer function, not a foreign key, '
  'the same way grant_id already names one of three different grant tables.';

create or replace function public.customer_create_gift_intent_v515(
  p_business uuid, p_gift_kind text, p_target uuid, p_idempotency_key uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_actor uuid := auth.uid();
  v_kind text := lower(btrim(coalesce(p_gift_kind,'')));
  v_identity uuid; v_client uuid;
  v_existing public.customer_gift_intents_v515%rowtype;
  v_request_hash text; v_token text; v_id uuid := gen_random_uuid();
  v_label text; v_min_spend integer := 0; v_period_key text; v_terms jsonb := '{}'::jsonb;
  v_benefit public.tier_benefits_v365%rowtype;
  v_tier public.loyalty_tiers%rowtype;
  v_used integer;
  -- nestly_v752: the customer's live birthday entitlement, standing in for v_benefit/v_tier.
  v_entitlement public.customer_birthday_entitlements%rowtype;
begin
  if v_actor is null then
    raise exception 'authenticated customer session required' using errcode='28000';
  end if;
  if p_idempotency_key is null then
    raise exception 'idempotency key is required' using errcode='22023';
  end if;
  if v_kind not in ('welcome','bringback','referral','tier_perk','birthday') then
    raise exception 'unsupported gift kind' using errcode='22023';
  end if;
  if p_target is null then
    raise exception 'gift target is required' using errcode='22023';
  end if;
  select ci.id, l.client_id into v_identity, v_client
    from public.customer_identities ci
    join public.customer_links l
      on l.identity_id = ci.id and l.auth_user_id = v_actor and l.state = 'verified'
   where ci.auth_user_id = v_actor and ci.status = 'active' and l.business_id = p_business
   limit 1;
  if v_identity is null then
    raise exception 'verified customer link required' using errcode='42501';
  end if;
  if not app.v89_business_module_enabled(p_business,'loyalty') then
    raise exception 'this business is not running a customer programme' using errcode='42501';
  end if;
  v_request_hash := app.v89_sha256(p_business::text||':'||v_kind||':'||p_target::text);
  perform pg_advisory_xact_lock(hashtextextended(
    'v515:gift-intent:'||v_identity::text||':'||p_idempotency_key::text, 0));
  perform pg_advisory_xact_lock(hashtextextended(
    'v676:gift-target:'||p_business::text||':'||v_client::text||':'||v_kind||':'||p_target::text, 0));
  select * into v_existing from public.customer_gift_intents_v515 intent
   where intent.identity_id = v_identity and intent.idempotency_key = p_idempotency_key
   for update;
  if found then
    if v_existing.request_hash <> v_request_hash then
      raise exception 'idempotency key conflicts with another gift intent' using errcode='23505';
    end if;
    return jsonb_build_object('intent_id',v_existing.id,'status',v_existing.status,
      'gift_kind',v_existing.gift_kind,'reward_label',v_existing.quoted_label,
      'min_spend_cents',v_existing.quoted_min_spend_cents,
      'qr_token',app.v89_redemption_token(v_identity,p_business,
        v_existing.gift_kind||'_v515',coalesce(v_existing.grant_id,v_existing.benefit_id),
        p_idempotency_key),
      'expires_at',v_existing.expires_at,'replayed',true);
  end if;
  update public.customer_gift_intents_v515
     set status='expired'
   where business_id=p_business and client_id=v_client and status='pending'
     and coalesce(grant_id,benefit_id)=p_target and expires_at<=now();
  select * into v_existing from public.customer_gift_intents_v515 intent
   where intent.business_id = p_business
     and intent.client_id = v_client
     and intent.gift_kind = v_kind
     and coalesce(intent.grant_id, intent.benefit_id) = p_target
     and intent.status = 'pending'
     and intent.expires_at > now()
     and intent.auth_user_id = v_actor
   for update;
  if found then
    return jsonb_build_object('intent_id',v_existing.id,'status',v_existing.status,
      'gift_kind',v_existing.gift_kind,'reward_label',v_existing.quoted_label,
      'min_spend_cents',v_existing.quoted_min_spend_cents,
      'qr_token',app.v89_redemption_token(v_existing.identity_id,p_business,
        v_existing.gift_kind||'_v515',coalesce(v_existing.grant_id,v_existing.benefit_id),
        v_existing.idempotency_key),
      'expires_at',v_existing.expires_at,'replayed',true);
  end if;
  if v_kind = 'welcome' then
    select g.reward_label, coalesce(g.min_spend_cents,0) into v_label, v_min_spend
      from public.welcome_offer_grants_v215 g
     where g.id=p_target and g.business_id=p_business and g.client_id=v_client
       and g.status='granted' and (g.expires_at is null or g.expires_at>now());
    if v_label is null then
      raise exception 'this welcome gift is not available' using errcode='22023';
    end if;
  elsif v_kind = 'bringback' then
    select g.reward_label into v_label
      from public.bringback_grants_v361 g
     where g.id=p_target and g.business_id=p_business and g.client_id=v_client
       and g.status='granted' and (g.expires_at is null or g.expires_at>now());
    if v_label is null then
      raise exception 'this bring-back voucher is not available' using errcode='22023';
    end if;
  elsif v_kind = 'referral' then
    select g.reward_label into v_label
      from public.referral_grants_v420 g
     where g.id=p_target and g.business_id=p_business and g.client_id=v_client
       and g.status='granted' and (g.expires_at is null or g.expires_at>now());
    if v_label is null then
      raise exception 'this referral gift is not available' using errcode='22023';
    end if;
  elsif v_kind = 'birthday' then
    -- nestly_v752: the target is the client's own live customer_birthday_entitlements row (the
    -- same row redeem_customer_birthday_benefit and the standalone "Activate" card use), never a
    -- program-version id directly — an entitlement is client-scoped, immutable-snapshotted, and
    -- already carries the SG window and the one-per-window status this gift QR must respect.
    select * into v_entitlement from public.customer_birthday_entitlements e
     where e.id=p_target and e.business_id=p_business and e.client_id=v_client;
    if v_entitlement.id is null then
      raise exception 'this birthday gift is not available' using errcode='22023';
    end if;
    if v_entitlement.status <> 'available'
       or v_entitlement.valid_from > now() or v_entitlement.valid_until <= now() then
      raise exception 'this birthday gift is not available' using errcode='22023';
    end if;
    v_label := v_entitlement.benefit_snapshot->>'label';
    if v_label is null then
      raise exception 'this birthday gift is not available' using errcode='22023';
    end if;
  else
    select * into v_benefit from public.tier_benefits_v365 b
     where b.id=p_target and b.business_id=p_business and b.active and b.deleted_at is null;
    if not found then
      raise exception 'this perk is not available' using errcode='22023';
    end if;
    if v_benefit.limit_count is null then
      raise exception 'this perk is applied automatically at payment' using errcode='22023';
    end if;
    select * into v_tier from public.loyalty_tiers t
     where t.id=v_benefit.tier_id and t.business_id=p_business;
    if not found or coalesce(v_tier.paused,false) or v_tier.deleted_at is not null then
      raise exception 'this perk is not available' using errcode='22023';
    end if;
    if coalesce((select ct.threshold from app.v365_client_tier(p_business, v_client) ct), -1)
       < coalesce(v_tier.threshold, 0) then
      raise exception 'this perk belongs to a tier you have not reached' using errcode='22023';
    end if;
    if v_benefit.limit_period = 'birthday_month'
       and not app.v367_in_birthday_month(v_client, now()) then
      raise exception 'this perk is only available in your birthday month' using errcode='22023';
    end if;
    v_period_key := app.v365_period_key(v_benefit.limit_period, now());
    select count(*) into v_used from public.tier_benefit_issues_v365 i
     where i.benefit_id=v_benefit.id and i.client_id=v_client and i.period_key=v_period_key
       and i.reversed_at is null;
    if v_used >= v_benefit.limit_count then
      raise exception 'you have used this perk for this period' using errcode='22023';
    end if;
    v_label := v_benefit.label;
    v_terms := jsonb_build_object('limit_count',v_benefit.limit_count,
                 'limit_period',v_benefit.limit_period,'used',v_used);
  end if;
  begin
    insert into public.customer_gift_intents_v515(
      id, business_id, identity_id, auth_user_id, client_id, gift_kind,
      grant_id, benefit_id, quoted_label, quoted_min_spend_cents, quoted_period_key,
      quoted_terms, token_hash, idempotency_key, request_hash, expires_at
    ) values (
      v_id, p_business, v_identity, v_actor, v_client, v_kind,
      case when v_kind in ('tier_perk','birthday') then null else p_target end,
      case when v_kind in ('tier_perk','birthday') then p_target else null end,
      v_label, v_min_spend, v_period_key, v_terms,
      app.v89_sha256(app.v89_redemption_token(v_identity,p_business,v_kind||'_v515',p_target,p_idempotency_key)),
      p_idempotency_key, v_request_hash, now() + interval '15 minutes'
    );
  exception when unique_violation then
    raise exception 'this gift already has a QR open at the counter — use it, or wait for it to expire'
      using errcode='22023';
  end;
  v_token := app.v89_redemption_token(v_identity,p_business,v_kind||'_v515',p_target,p_idempotency_key);
  return jsonb_build_object('intent_id',v_id,'status','pending','gift_kind',v_kind,
    'reward_label',v_label,'min_spend_cents',v_min_spend,
    'qr_token',v_token,'expires_at',now()+interval '15 minutes','replayed',false);
end
$function$;
revoke all on function public.customer_create_gift_intent_v515(uuid, text, uuid, uuid)
  from public, anon;
grant execute on function public.customer_create_gift_intent_v515(uuid, text, uuid, uuid)
  to authenticated, service_role;


-- ===============================================================================================
-- 5. The counter's QR scan and stage flow. Restated verbatim except the new birthday branches.
-- ===============================================================================================


create or replace function public.staff_scan_gift_qr_to_till_v666(p_business uuid, p_qr_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_actor uuid := auth.uid();
  v_intent public.customer_gift_intents_v515%rowtype;
  v_benefit public.tier_benefits_v365%rowtype;
  v_entitlement public.customer_birthday_entitlements%rowtype;
  v_program public.birthday_program_versions%rowtype;
  v_stageable boolean := false;
  v_settle_now boolean := false;
  v_benefit_kind text := null;
begin
  if v_actor is null then
    raise exception 'authenticated staff required' using errcode = '42501';
  end if;
  if not (app.is_salon_owner(p_business) or app.can_module_write(p_business,'till')
          or app.can_module_write(p_business,'loyalty')) then
    raise exception 'till or loyalty write authorization required' using errcode = '42501';
  end if;
  if p_qr_token is null or length(btrim(p_qr_token)) < 32 then
    return jsonb_build_object('status','invalid','message','This is not a Peekaa reward QR.');
  end if;

  select * into v_intent from public.customer_gift_intents_v515
   where business_id = p_business and token_hash = app.v89_sha256(p_qr_token);
  if not found then
    return jsonb_build_object('status','invalid','message','This reward QR is not from this business.');
  end if;
  if v_intent.status <> 'pending' or v_intent.expires_at <= now() then
    return jsonb_build_object('status','not_pending','gift_kind',v_intent.gift_kind,
      'reward_label',v_intent.quoted_label);
  end if;

  if v_intent.gift_kind = 'tier_perk' then
    select * into v_benefit from public.tier_benefits_v365
     where id = v_intent.benefit_id and business_id = p_business
       and deleted_at is null and active;
    v_stageable := found
      and v_benefit.benefit_kind = 'discount_pct'
      and coalesce(v_benefit.discount_percent,0) > 0
      and v_benefit.limit_count is not null;
    if found then
      v_benefit_kind := v_benefit.benefit_kind;
      v_settle_now := v_benefit.benefit_kind = 'free_item';
    end if;
  elsif v_intent.gift_kind = 'birthday' then
    -- nestly_v752: the same stageable/settle_now split as a tier perk, keyed off the entitlement's
    -- own published benefit row instead of tier_benefits_v365.
    -- nestly_v752: a record-typed INTO target must be the sole item in its list, so the
    -- entitlement and its owning programme row are fetched in two statements rather than one.
    select * into v_entitlement from public.customer_birthday_entitlements
     where id = v_intent.benefit_id and business_id = p_business;
    if v_entitlement.id is not null then
      select * into v_program from public.birthday_program_versions
       where id = v_entitlement.birthday_program_version_id;
    end if;
    v_stageable := v_entitlement.id is not null and v_program.id is not null
      and v_program.fulfillment_kind = 'discount_pct'
      and coalesce(v_program.discount_percent,0) > 0;
    if v_entitlement.id is not null and v_program.id is not null then
      v_benefit_kind := v_program.fulfillment_kind;
      v_settle_now := v_program.fulfillment_kind = 'free_item';
    end if;
  else
    v_settle_now := coalesce(v_intent.quoted_min_spend_cents,0) = 0;
  end if;

  return app.v666_till_customer_card(p_business, v_intent.client_id)
         || jsonb_build_object(
              'gift_kind', v_intent.gift_kind,
              'gift_label', v_intent.quoted_label,
              'benefit_id', v_intent.benefit_id,
              'benefit_kind', v_benefit_kind,
              'min_spend_cents', coalesce(v_intent.quoted_min_spend_cents,0),
              'settle_now', v_settle_now,
              'stageable', v_stageable);
end
$function$;
revoke all on function public.staff_scan_gift_qr_to_till_v666(uuid, text)
  from public, anon;
grant execute on function public.staff_scan_gift_qr_to_till_v666(uuid, text)
  to authenticated, service_role;

create or replace function public.staff_stage_gift_qr_v665(p_business uuid, p_client uuid, p_qr_token text)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_actor uuid := auth.uid();
  v_intent public.customer_gift_intents_v515%rowtype;
  v_benefit public.tier_benefits_v365%rowtype;
  v_entitlement public.customer_birthday_entitlements%rowtype;
  v_program public.birthday_program_versions%rowtype;
  v_period_now text;
  v_result jsonb;
begin
  if v_actor is null then
    raise exception 'authenticated staff required' using errcode = '42501';
  end if;
  if not (app.is_salon_owner(p_business) or app.can_module_write(p_business,'till')
          or app.can_module_write(p_business,'loyalty')) then
    raise exception 'till or loyalty write authorization required' using errcode = '42501';
  end if;
  if p_qr_token is null or length(btrim(p_qr_token)) < 32 then
    raise exception 'gift QR is invalid' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(
    'v515:scan:'||p_business::text||':'||app.v89_sha256(p_qr_token), 0));

  select * into v_intent from public.customer_gift_intents_v515
   where business_id = p_business and token_hash = app.v89_sha256(p_qr_token)
   for update;

  if not found then
    return jsonb_build_object('status','not_stageable','reason','unknown_token');
  end if;
  if v_intent.status <> 'pending' or v_intent.expires_at <= now() then
    return jsonb_build_object('status','not_stageable','reason','not_pending');
  end if;
  if v_intent.gift_kind not in ('tier_perk','birthday') then
    return jsonb_build_object('status','not_stageable','reason','not_a_tier_perk');
  end if;
  if p_client is not null and v_intent.client_id is distinct from p_client then
    return jsonb_build_object('status','wrong_customer');
  end if;

  if v_intent.gift_kind = 'tier_perk' then
    select * into v_benefit from public.tier_benefits_v365
     where id = v_intent.benefit_id and business_id = p_business
       and deleted_at is null and active;
    if not found then
      return jsonb_build_object('status','not_stageable','reason','benefit_gone');
    end if;
    if v_benefit.benefit_kind <> 'discount_pct'
       or coalesce(v_benefit.discount_percent, 0) <= 0
       or v_benefit.limit_count is null then
      return jsonb_build_object('status','not_stageable','reason','not_a_metered_discount');
    end if;

    v_period_now := app.v365_period_key(v_benefit.limit_period, now());
    if v_period_now is distinct from v_intent.quoted_period_key then
      raise exception 'this perk''s period rolled over; ask the customer for a new QR'
        using errcode = '23514';
    end if;

    v_result := jsonb_build_object('status','staged','gift_kind','tier_perk',
      'intent_id',v_intent.id,'benefit_id',v_benefit.id,'client_id',v_intent.client_id,
      'reward_label',v_intent.quoted_label,'discount_percent',v_benefit.discount_percent,
      'staged_at',now());
  else
    -- nestly_v752: birthday's discount_pct is staged exactly like a tier discount — the QR is
    -- spent here, the ALLOWANCE (the entitlement's status) is spent later by
    -- public.redeem_customer_birthday_benefit inside record_cart_sale, in the same transaction
    -- that takes the money. A sale abandoned after staging leaves the entitlement 'available' and
    -- the customer simply shows a fresh QR — the same asymmetry v665 documents for tier perks.
    select * into v_entitlement from public.customer_birthday_entitlements
     where id = v_intent.benefit_id and business_id = p_business;
    if v_entitlement.id is null then
      return jsonb_build_object('status','not_stageable','reason','benefit_gone');
    end if;
    select * into v_program from public.birthday_program_versions
     where id = v_entitlement.birthday_program_version_id;
    if v_program.fulfillment_kind <> 'discount_pct'
       or coalesce(v_program.discount_percent, 0) <= 0 then
      return jsonb_build_object('status','not_stageable','reason','not_a_metered_discount');
    end if;
    if v_entitlement.status <> 'available'
       or v_entitlement.valid_from > now() or v_entitlement.valid_until <= now() then
      raise exception 'this birthday gift''s window has closed; ask the customer for a new QR'
        using errcode = '23514';
    end if;

    v_result := jsonb_build_object('status','staged','gift_kind','birthday',
      'intent_id',v_intent.id,'benefit_id',v_entitlement.id,'client_id',v_intent.client_id,
      'reward_label',v_intent.quoted_label,'discount_percent',v_program.discount_percent,
      'staged_at',now());
  end if;

  update public.customer_gift_intents_v515
     set status='completed', completed_at=now(), completed_by=v_actor, completion_result=v_result
   where id = v_intent.id;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor,
    case when v_intent.gift_kind = 'birthday' then 'BIRTHDAY_BENEFIT_STAGED_V752'
         else 'TIER_PERK_STAGED_V665' end,
    'customer_gift_intents_v515', v_intent.id,
    jsonb_build_object('client_id',v_intent.client_id,'benefit_id',v_intent.benefit_id,
                       'label',v_intent.quoted_label));

  return v_result;
end
$function$;
revoke all on function public.staff_stage_gift_qr_v665(uuid, uuid, text)
  from public, anon;
grant execute on function public.staff_stage_gift_qr_v665(uuid, uuid, text)
  to authenticated, service_role;


-- ===============================================================================================
-- 5b. The counter's REDEEM dispatcher (welcome/bringback/referral/tier_perk/birthday). Restated
--     verbatim except the new 'birthday' branch, which reaches
--     staff_confirm_birthday_free_item_v752 (part 8 below) — a discount_pct birthday benefit never
--     arrives here at all, because staff_stage_gift_qr_v665 above already settles it by staging.
-- ===============================================================================================

CREATE OR REPLACE FUNCTION public.staff_scan_gift_qr_v515(p_business uuid, p_branch uuid, p_qr_token text, p_sale uuid, p_idempotency_key uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_actor uuid := auth.uid();
  v_intent public.customer_gift_intents_v515%rowtype;
  v_benefit public.tier_benefits_v365%rowtype;
  v_period_now text;
  v_result jsonb;
  v_customer text;
begin
  if v_actor is null then
    raise exception 'authenticated staff required' using errcode='42501';
  end if;
  if p_qr_token is null or length(btrim(p_qr_token)) < 32 then
    raise exception 'gift QR is invalid' using errcode='22023';
  end if;
  if p_idempotency_key is null then
    raise exception 'idempotency key is required' using errcode='22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(
    'v515:scan:'||p_business::text||':'||app.v89_sha256(p_qr_token), 0));

  select * into v_intent from public.customer_gift_intents_v515
   where business_id = p_business and token_hash = app.v89_sha256(p_qr_token)
   for update;
  if not found then
    raise exception 'gift QR is invalid' using errcode='22023';
  end if;

  if v_intent.status = 'completed' then
    return coalesce(v_intent.completion_result,'{}'::jsonb) || jsonb_build_object('replayed',true);
  end if;
  if v_intent.status in ('expired','cancelled') then
    return jsonb_build_object('status',v_intent.status,'gift_kind',v_intent.gift_kind,
      'reward_label',v_intent.quoted_label);
  end if;
  if v_intent.expires_at <= now() then
    update public.customer_gift_intents_v515 set status='expired' where id=v_intent.id;
    return jsonb_build_object('status','expired','gift_kind',v_intent.gift_kind,
      'reward_label',v_intent.quoted_label);
  end if;

  -- The quote re-check, the analogue of v117's `current quote is distinct from quoted_terms`.
  -- A perk QR minted at 23:58 on the 31st must not silently spend NEXT period's allowance.
  if v_intent.gift_kind = 'tier_perk' then
    select * into v_benefit from public.tier_benefits_v365 where id = v_intent.benefit_id;
    if not found then
      raise exception 'this perk no longer exists' using errcode='23514';
    end if;
    v_period_now := app.v365_period_key(v_benefit.limit_period, now());
    if v_period_now is distinct from v_intent.quoted_period_key then
      raise exception 'this perk''s period rolled over; ask the customer for a new QR'
        using errcode='23514';
    end if;
  end if;

  if v_intent.gift_kind = 'welcome' then
    v_result := public.staff_redeem_welcome_offer_v215(
      p_business, v_intent.client_id, p_branch, p_sale, 'v515:'||v_intent.id::text);
  elsif v_intent.gift_kind = 'bringback' then
    v_result := public.staff_redeem_bringback_v361(
      p_business, v_intent.client_id, p_branch, v_intent.grant_id);
  elsif v_intent.gift_kind = 'referral' then
    v_result := public.staff_redeem_referral_v420(
      p_business, v_intent.client_id, p_branch, v_intent.grant_id);
  elsif v_intent.gift_kind = 'birthday' then
    -- nestly_v752: reaches here only for a free_item birthday benefit — a discount_pct one is
    -- settled by staff_stage_gift_qr_v665 before the till ever calls this function (see its
    -- header). The intent id as the key is LOAD-BEARING, exactly as it is for a tier perk below.
    v_result := public.staff_confirm_birthday_free_item_v752(
      p_business, v_intent.client_id, p_branch, v_intent.id);
  else
    -- The intent id as the key is LOAD-BEARING: staff_issue_tier_benefit_v365 turns a NULL key
    -- into a fresh uuid, which would burn a second allowance instead of replaying.
    v_result := public.staff_issue_tier_benefit_v365(
      p_business, v_intent.client_id, v_intent.benefit_id, p_branch, v_intent.id);
  end if;

  select c.full_name into v_customer from public.clients c where c.id = v_intent.client_id;

  v_result := coalesce(v_result,'{}'::jsonb) || jsonb_build_object(
    'status','completed','gift_kind',v_intent.gift_kind,
    'reward_label',v_intent.quoted_label,'customer_name',v_customer,
    'branch_id',p_branch,'intent_id',v_intent.id);

  update public.customer_gift_intents_v515
     set status='completed', completed_at=now(), completed_by=v_actor, completion_result=v_result
   where id = v_intent.id;

  return v_result;
end
$function$;
revoke all on function public.staff_scan_gift_qr_v515(uuid, uuid, text, uuid, uuid)
  from public, anon;
grant execute on function public.staff_scan_gift_qr_v515(uuid, uuid, text, uuid, uuid)
  to authenticated, service_role;

-- ===============================================================================================
-- 6. app.ps1c_plan_checkout gains an additive p_birthday boolean (default false — every existing
--    caller is unaffected). Restated verbatim except the new parameter, the new declare block,
--    and the new birthday-discount block placed alongside the existing v656/v657 hand-applied
--    tier discount, immediately before the total is computed.
-- ===============================================================================================


CREATE OR REPLACE FUNCTION app.ps1c_plan_checkout(p_business uuid, p_branch uuid, p_client uuid, p_lines jsonb, p_config uuid, p_tier_benefit uuid DEFAULT NULL::uuid, p_birthday boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_line jsonb; v_ord int := 0; v_n int;
  v_kind text[]; v_id uuid[]; v_name text[]; v_unit int[]; v_qty int[]; v_ltot int[]; v_rem int[];
  v_entered_by uuid[]; v_lreason text[];
  v_subtotal bigint := 0; v_price jsonb; v_pstatus text; v_nm text;
  v_server jsonb := '[]'::jsonb; v_entry jsonb;
  v_payload jsonb; v_active_rules boolean := (p_config is not null);
  r record; v_eff jsonb; v_idx int; v_etype text; v_ckind text; v_cid uuid; v_level text;
  v_stackable boolean; v_cap int; v_period text;
  v_cand jsonb := '[]'::jsonb;
  v_applied jsonb := '[]'::jsonb;
  v_total_discount bigint := 0; v_any_line boolean := false; v_any_bill boolean := false;
  c jsonb; v_target int; v_base int; v_d int; v_reason text; v_suppressed boolean;
  -- V370: the automatic tier discount.
  v_nonstack_applied boolean := false;
  v_tier_benefit record; v_tier_base int; v_tier_d int;
  -- nestly_v656: the scope of the chosen discount, and whether it was chosen by hand.
  v_tier_scoped boolean := false; v_tier_used int; v_tier_names text[];
  -- nestly_v657: which of the two shapes this discount is, and the line it landed on.
  v_tier_target int; v_tier_best int;
  v_ps timestamptz; v_pe timestamptz; v_committed int; v_projected int;
  v_rule_proj jsonb := '{}'::jsonb; v_gst_reg boolean; v_gst_bps int; v_total int; v_gst int;
  j int;
  v_desc text; v_camt numeric; v_creason text; v_limit int; v_may_custom boolean;
  v_bundle jsonb; v_bline jsonb; v_bsrc uuid[]; v_bsrcqty int[];
  v_key text;
  -- nestly_v752: the hand-applied birthday discount, staged by staff_stage_gift_qr_v665
  -- exactly like the v656 hand-applied tier discount above.
  v_bday_entitlement public.customer_birthday_entitlements%rowtype;
  v_bday_program public.birthday_program_versions%rowtype;
  v_bday_scoped boolean := false; v_bday_target int; v_bday_best int;
  v_bday_base int; v_bday_d int;
begin
  if jsonb_typeof(p_lines) <> 'array' then
    return jsonb_build_object('status', 'invalid', 'reason', 'lines must be a JSON array');
  end if;
  v_n := jsonb_array_length(p_lines);
  if v_n < 1 or v_n > 50 then
    return jsonb_build_object('status', 'invalid', 'reason', 'a cart must have between 1 and 50 lines');
  end if;

  select coalesce(custom_line_limit_cents, 50000) into v_limit from public.businesses where id = p_business;
  v_limit := coalesce(v_limit, 50000);
  v_may_custom := app.is_salon_owner(p_business) or app.has_perm(p_business, 'custom_price_lines');

  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_ord := v_ord + 1;
    v_ckind := v_line->>'catalog_kind';
    if v_ckind is null or v_ckind not in ('service', 'product', 'custom', 'bundle') then
      return jsonb_build_object('status', 'bad_kind', 'line', v_ord,
        'reason', 'catalog_kind must be service, product, bundle or custom');
    end if;

    if v_ckind = 'custom' then
      for v_key in select jsonb_object_keys(v_line) loop
        if v_key not in ('catalog_kind', 'description', 'amount_cents', 'reason', 'qty') then
          return jsonb_build_object('status', 'custom_line_invalid', 'line', v_ord,
            'reason', 'custom_line_invalid: a custom line carries only catalog_kind, description, amount_cents and reason');
        end if;
      end loop;
      if not v_may_custom then
        return jsonb_build_object('status', 'custom_line_denied', 'line', v_ord,
          'reason', 'custom_line_denied: you do not have permission to enter a manual price (custom_price_lines)');
      end if;
      if v_line ? 'qty' then
        if jsonb_typeof(v_line->'qty') is distinct from 'number'
           or (v_line->>'qty')::numeric <> 1 then
          return jsonb_build_object('status', 'custom_line_invalid', 'line', v_ord,
            'reason', 'custom_line_invalid: a custom line quantity is always 1');
        end if;
      end if;
      if jsonb_typeof(v_line->'amount_cents') is distinct from 'number' then
        return jsonb_build_object('status', 'custom_line_invalid', 'line', v_ord,
          'reason', 'custom_line_invalid: a custom line requires a numeric amount_cents');
      end if;
      v_camt := (v_line->>'amount_cents')::numeric;
      if v_camt <> trunc(v_camt) or v_camt = 0 then
        return jsonb_build_object('status', 'custom_line_invalid', 'line', v_ord,
          'reason', 'custom_line_invalid: amount_cents must be a whole number of cents and cannot be zero');
      end if;
      if abs(v_camt) > v_limit then
        return jsonb_build_object('status', 'custom_line_limit', 'line', v_ord,
          'reason', 'custom_line_limit: amount_cents exceeds this business''s manual-price limit of '
                    || v_limit || ' cents');
      end if;
      v_desc := btrim(coalesce(v_line->>'description', ''));
      v_creason := btrim(coalesce(v_line->>'reason', ''));
      if length(v_desc) < 3 or length(v_desc) > 200 then
        return jsonb_build_object('status', 'custom_line_invalid', 'line', v_ord,
          'reason', 'custom_line_invalid: a custom line needs a description of 3 to 200 characters');
      end if;
      if length(v_creason) > 200 then
        return jsonb_build_object('status', 'custom_line_invalid', 'line', v_ord,
          'reason', 'custom_line_invalid: a custom line reason cannot exceed 200 characters');
      end if;
      v_kind := array_append(v_kind, 'custom');
      v_id := array_append(v_id, null::uuid);
      v_name := array_append(v_name, v_desc);
      v_unit := array_append(v_unit, v_camt::int);
      v_qty := array_append(v_qty, 1);
      v_ltot := array_append(v_ltot, v_camt::int);
      v_rem := array_append(v_rem, v_camt::int);
      v_entered_by := array_append(v_entered_by, auth.uid());
      v_lreason := array_append(v_lreason, v_creason);
      v_bsrc := array_append(v_bsrc, null::uuid);
      v_bsrcqty := array_append(v_bsrcqty, null::int);
      v_subtotal := v_subtotal + v_camt::int;
      continue;
    end if;

    if v_line ? 'unit_price_cents' or v_line ? 'price_cents' or v_line ? 'amount_cents'
       or v_line ? 'line_total_cents' or v_line ? 'unit_cents' or v_line ? 'discount' then
      return jsonb_build_object('status', 'client_priced', 'line', v_ord,
        'reason', 'checkout lines carry catalog_kind + catalog_id + qty ONLY; nothing is client-priceable');
    end if;
    if jsonb_typeof(v_line->'qty') is distinct from 'number' then
      return jsonb_build_object('status', 'bad_qty', 'line', v_ord, 'reason', 'qty must be a number');
    end if;
    if (v_line->>'qty')::numeric <> trunc((v_line->>'qty')::numeric)
       or (v_line->>'qty')::numeric < 1 or (v_line->>'qty')::numeric > 1000000 then
      return jsonb_build_object('status', 'bad_qty', 'line', v_ord, 'reason', 'qty must be a whole number 1..1000000');
    end if;
    v_cid := nullif(v_line->>'catalog_id', '')::uuid;
    if v_ckind = 'bundle' then
      v_bundle := app.ps1c_bundle_lines_v204(p_business, v_cid, (v_line->>'qty')::int);
      if v_bundle->>'status' <> 'ok' then
        return jsonb_build_object('status', 'price_error', 'line', v_ord,
          'catalog_kind', 'bundle', 'catalog_id', v_cid,
          'reason', (v_bundle->>'status') || ':' || coalesce(v_bundle->>'reason', ''));
      end if;
      for v_bline in select * from jsonb_array_elements(v_bundle->'lines') loop
        v_kind := array_append(v_kind, coalesce(v_bline->>'kind', 'service'));
        v_id := array_append(v_id, coalesce(nullif(v_bline->>'item_id',''), v_bline->>'service_id')::uuid);
        v_name := array_append(v_name, v_bline->>'name');
        v_unit := array_append(v_unit, (v_bline->>'line_cents')::int);
        v_qty := array_append(v_qty, 1);
        v_ltot := array_append(v_ltot, (v_bline->>'line_cents')::int);
        v_rem := array_append(v_rem, (v_bline->>'line_cents')::int);
        v_entered_by := array_append(v_entered_by, null::uuid);
        v_lreason := array_append(v_lreason, null::text);
        v_bsrc := array_append(v_bsrc, v_cid);
        v_bsrcqty := array_append(v_bsrcqty, (v_line->>'qty')::int);
        v_subtotal := v_subtotal + (v_bline->>'line_cents')::int;
      end loop;
      continue;
    end if;
    v_price := app.ps1b_catalog_price(p_business, v_ckind, v_cid);
    v_pstatus := v_price->>'status';
    if v_pstatus <> 'ok' then
      return jsonb_build_object('status', 'price_error', 'line', v_ord, 'catalog_kind', v_ckind,
        'catalog_id', v_cid, 'reason', v_pstatus || ':' || coalesce(v_price->>'reason', ''));
    end if;
    if v_ckind = 'service' then
      select name into v_nm from public.services where id = v_cid and business_id = p_business;
    else
      select name into v_nm from public.products where id = v_cid and business_id = p_business;
    end if;
    v_kind := array_append(v_kind, v_ckind);
    v_id := array_append(v_id, v_cid);
    v_name := array_append(v_name, coalesce(v_nm, v_ckind));
    v_unit := array_append(v_unit, (v_price->>'price_cents')::int);
    v_qty := array_append(v_qty, (v_line->>'qty')::int);
    v_ltot := array_append(v_ltot, (v_price->>'price_cents')::int * (v_line->>'qty')::int);
    v_rem := array_append(v_rem, (v_price->>'price_cents')::int * (v_line->>'qty')::int);
    v_entered_by := array_append(v_entered_by, null::uuid);
    v_lreason := array_append(v_lreason, null::text);
    v_bsrc := array_append(v_bsrc, null::uuid);
    v_bsrcqty := array_append(v_bsrcqty, null::int);
    v_subtotal := v_subtotal + ((v_price->>'price_cents')::int * (v_line->>'qty')::int);
  end loop;

  if v_subtotal <= 0 then
    return jsonb_build_object('status', 'invalid', 'reason', 'a checkout must total more than zero');
  end if;
  if v_subtotal > 2147483647 then
    return jsonb_build_object('status', 'invalid', 'reason', 'checkout subtotal exceeds the supported maximum');
  end if;

  for j in 1 .. array_length(v_kind, 1) loop
    v_entry := jsonb_build_object(
      'catalog_kind', v_kind[j], 'catalog_id', v_id[j], 'name', v_name[j],
      'unit_price_cents', v_unit[j], 'qty', v_qty[j], 'line_total_cents', v_ltot[j]);
    if v_kind[j] = 'custom' then
      v_entry := v_entry || jsonb_build_object('entered_by', v_entered_by[j], 'reason', v_lreason[j]);
    end if;
    if v_bsrc[j] is not null then
      v_entry := v_entry || jsonb_build_object('bundle_id', v_bsrc[j], 'bundle_qty', v_bsrcqty[j]);
    end if;
    v_server := v_server || jsonb_build_array(v_entry);
  end loop;

  v_payload := jsonb_build_object('amount_cents', v_subtotal, 'kind', 'cart_sale',
    'branch_id', to_jsonb(p_branch::text), 'client_id', to_jsonb(coalesce(p_client::text, '')),
    'counts_as_visit', true, 'earns_points', true);
  if v_active_rules then
    for r in select c2.rule_id, c2.compiled from public.program_rules_compiled c2
              where c2.business_id = p_business and c2.config_version_id = p_config
                and c2.when_event = 'sale.completed' and c2.active
                and not exists (select 1 from public.studio_rule_emergency_pauses ep
                                 where ep.business_id = p_business and ep.rule_id = c2.rule_id
                                   and ep.lifted_at is null)
              order by c2.rule_id loop
      if not app.ps1b_eval_conditions(v_payload, r.compiled->'if') then continue; end if;
      v_stackable := coalesce((r.compiled->'using'->>'stackable')::boolean, true);
      v_cap := nullif(r.compiled->'with'->>'budget_cap_cents', '')::int;
      v_period := coalesce(r.compiled->'with'->>'budget_period', 'monthly');
      v_idx := 0;
      for v_eff in select * from jsonb_array_elements(coalesce(r.compiled->'then', '[]'::jsonb)) loop
        v_etype := v_eff->>'effect_type';
        if v_etype in ('apply_discount_pct', 'apply_discount_amount') then
          v_ckind := nullif(v_eff->>'catalog_kind', '');
          v_cid := nullif(v_eff->>'catalog_id', '')::uuid;
          v_level := case when v_ckind is not null and v_cid is not null then 'line' else 'bill' end;
          v_cand := v_cand || jsonb_build_array(jsonb_build_object(
            'rule_id', r.rule_id, 'effect_index', v_idx, 'effect_type', v_etype, 'level', v_level,
            'catalog_kind', v_ckind, 'catalog_id', v_cid,
            'discount_pct', v_eff->>'discount_pct', 'amount_cents', v_eff->>'amount_cents',
            'stackable', v_stackable, 'cap_cents', v_cap, 'period', v_period));
        end if;
        v_idx := v_idx + 1;
      end loop;
    end loop;
  end if;

  for c in
    select e from jsonb_array_elements(v_cand) e
     order by (e->>'level') desc,
              (e->>'rule_id'), (e->>'effect_index')::int
  loop
    v_suppressed := false; v_reason := null; v_d := 0; v_target := null;
    v_stackable := (c->>'stackable')::boolean;
    v_cap := nullif(c->>'cap_cents', '')::int;
    v_period := c->>'period';

    if not v_stackable and ((c->>'level' = 'line' and v_any_line) or (c->>'level' = 'bill' and v_any_bill)) then
      v_suppressed := true; v_reason := 'stacking';
    end if;

    if not v_suppressed then
      if c->>'level' = 'line' then
        v_target := null;
        for j in 1 .. array_length(v_kind, 1) loop
          if v_kind[j] = (c->>'catalog_kind') and v_id[j] = nullif(c->>'catalog_id', '')::uuid and v_rem[j] > 0 then
            v_target := j; exit;
          end if;
        end loop;
        if v_target is null then
          v_suppressed := true; v_reason := 'no_target';
        else
          v_base := v_rem[v_target];
        end if;
      else
        v_base := (v_subtotal - v_total_discount)::int;
        if v_base <= 0 then v_suppressed := true; v_reason := 'no_target'; end if;
      end if;
    end if;

    if not v_suppressed then
      if c->>'effect_type' = 'apply_discount_pct' then
        v_d := round(v_base::numeric * (c->>'discount_pct')::numeric / 100.0)::int;
      else
        v_d := least((c->>'amount_cents')::int, v_base);
      end if;
      if v_d > v_base then v_d := v_base; end if;
      if v_d < 0 then v_d := 0; end if;
      if v_d = 0 then v_suppressed := true; v_reason := 'no_target'; end if;
    end if;

    v_ps := null; v_pe := null;
    if v_cap is not null then
      select period_start, period_end into v_ps, v_pe from app.ps1c_period_bounds(now(), v_period);
    end if;
    if not v_suppressed and v_cap is not null then
      select coalesce(committed_cents, 0) into v_committed from public.budget_periods
       where business_id = p_business and rule_id = (c->>'rule_id')::uuid and period_start = v_ps;
      v_committed := coalesce(v_committed, 0);
      v_projected := coalesce((v_rule_proj->>(c->>'rule_id'))::int, 0);
      if v_committed + v_projected + v_d > v_cap then
        v_suppressed := true; v_reason := 'budget_exhausted';
      else
        v_rule_proj := v_rule_proj || jsonb_build_object(c->>'rule_id', v_projected + v_d);
      end if;
    end if;

    if v_suppressed then
      v_applied := v_applied || jsonb_build_array(jsonb_build_object(
        'rule_id', c->>'rule_id', 'effect_index', (c->>'effect_index')::int, 'effect_type', c->>'effect_type',
        'level', c->>'level', 'target_line_index', v_target, 'amount_cents', 0,
        'suppressed', true, 'suppression_reason', v_reason,
        'capped', v_cap is not null, 'cap_cents', v_cap,
        'period_start', v_ps, 'period_end', v_pe));
    else
      if c->>'level' = 'line' then
        v_rem[v_target] := v_rem[v_target] - v_d; v_any_line := true;
      else
        v_any_bill := true;
      end if;
      v_total_discount := v_total_discount + v_d;
      if not v_stackable then v_nonstack_applied := true; end if;
      v_applied := v_applied || jsonb_build_array(jsonb_build_object(
        'rule_id', c->>'rule_id', 'effect_index', (c->>'effect_index')::int, 'effect_type', c->>'effect_type',
        'level', c->>'level', 'target_line_index', v_target, 'amount_cents', v_d,
        'suppressed', false, 'suppression_reason', null,
        'capped', v_cap is not null, 'cap_cents', v_cap,
        'period_start', v_ps, 'period_end', v_pe));
    end if;
  end loop;

  -- ===========================================================================================
  -- V370 — THE AUTOMATIC TIER DISCOUNT (owner: "for tiers it will be automatic if there is a
  -- discount % allocated to it").
  -- It is applied HERE, inside the single pricing authority, rather than by the till: a discount
  -- the browser subtracted for itself would make the sale total and this engine disagree, which
  -- is the two-sources-of-truth failure this codebase keeps paying for.
  -- Four rules, each a decision worth stating:
  --   * ONE discount, never stacked. The best (highest) percentage the customer's rung entitles
  --     them to, inherited down the ladder like every other tier benefit. Stacking Gold's 10%
  --     under Diamond's 30% would compound into a number no owner chose.
  --   * UNLIMITED benefits only. A discount carrying a per-period limit has to be COUNTED when it
  --     is used, and counting belongs to the staff-pressed Give button that already does it
  --     (staff_issue_tier_benefit_v365). Applying a limited one here would spend it silently on
  --     every bill and never record the spend.
  --   * Suppressed when a NON-STACKABLE rule effect has already applied. That rule said it does
  --     not stack; a tier discount landing on top would break the promise the owner authored.
  --   * V394: the tier lifecycle is honoured — a paused or soft-deleted tier neither sets the
  --     customer's rung (app.v365_client_tier filters both since v394) nor donates its benefit
  --     down the ladder (this SELECT filters t.paused/t.deleted_at). Owner ruling 2026-08-20:
  --     paused and deleted tiers grant nothing, matching what customers see (v393 display).
  --   * It carries rule_id null and source 'tier_benefit'. public.checkout_discount_lines is keyed
  --     on a real rule and its rule_id is NOT NULL, so record_cart_sale skips that provenance row
  --     for this effect and records the fulfilment and the signed sale_items line instead.
  -- ===========================================================================================
  if p_client is not null then
    if p_tier_benefit is not null then
      -- nestly_v656 — THE HAND-APPLIED DISCOUNT (owner: "when i 'use' the voucher it must deduct
      -- the overall amount by 10%"). A LIMITED discount could not come off a bill at all: v370
      -- deliberately excluded it here because spending an allowance has to be COUNTED, and the
      -- only thing that counted was the staff Give button, which moves no money. So staff pressed
      -- Give, Peekaa recorded that a 20%-off perk had been handed over, and then charged the
      -- customer full price.
      -- The answer is not to auto-apply it — that would spend it on every bill — but to let it be
      -- chosen, here, once, for THIS sale. The count is written by record_cart_sale in the same
      -- transaction that takes the money, so the discount and the spend can never disagree.
      -- Everything the automatic path checks is checked again: the benefit is this business's, it
      -- is a live discount on a tier the customer has actually reached, and it is in date.
      select b.id, b.tier_id, b.label, b.discount_percent, b.limit_count, b.limit_period,
             b.discount_scope, b.max_discount_cents
        into v_tier_benefit
        from public.tier_benefits_v365 b
        join public.loyalty_tiers t on t.id = b.tier_id and t.business_id = b.business_id
       where b.id = p_tier_benefit
         and b.business_id = p_business
         and b.deleted_at is null and b.active
         and b.benefit_kind = 'discount_pct'
         and coalesce(t.paused, false) = false and t.deleted_at is null
         and t.threshold <= coalesce((app.v365_client_tier(p_business, p_client)).threshold, -1)
         and (t.effective_from is null or t.effective_from <= statement_timestamp())
         and (t.expires_at is null or t.expires_at > statement_timestamp());
      if v_tier_benefit.id is null then
        return jsonb_build_object('status', 'tier_benefit_not_available',
          'reason', 'tier_benefit_not_available: that tier discount is not available to this customer');
      end if;
      -- Birthday-month perks are only live in the customer's birthday month, exactly as the
      -- Give button and the customer's own card judge them.
      if v_tier_benefit.limit_period = 'birthday_month'
         and not coalesce(app.v367_in_birthday_month(p_client, now()), false) then
        return jsonb_build_object('status', 'tier_benefit_not_available',
          'reason', 'tier_benefit_not_available: this perk is only available in the customer''s birthday month');
      end if;
      -- The allowance is checked HERE so the till can say so before the customer is charged;
      -- staff_issue_tier_benefit_v365 checks it again under a lock when the sale is finalised.
      if v_tier_benefit.limit_count is not null then
        select count(*)::int into v_tier_used
          from public.tier_benefit_issues_v365 i
         where i.benefit_id = v_tier_benefit.id and i.client_id = p_client
           and i.period_key = app.v365_period_key(v_tier_benefit.limit_period, now())
           and i.reversed_at is null;
        if v_tier_used >= v_tier_benefit.limit_count then
          return jsonb_build_object('status', 'tier_benefit_used_up',
            'reason', 'tier_benefit_used_up: this customer has already used that perk for this period');
        end if;
      end if;
    else
    select b.id, b.tier_id, b.label, b.discount_percent, b.limit_count, b.limit_period,
           b.discount_scope, b.max_discount_cents
      into v_tier_benefit
      from public.tier_benefits_v365 b
      join public.loyalty_tiers t on t.id = b.tier_id and t.business_id = b.business_id
     where b.business_id = p_business
       and b.deleted_at is null and b.active
       and b.benefit_kind = 'discount_pct'
       and b.limit_count is null
       and coalesce(t.paused, false) = false and t.deleted_at is null
       and t.threshold <= coalesce((app.v365_client_tier(p_business, p_client)).threshold, -1)
       and (t.effective_from is null or t.effective_from <= statement_timestamp())
       and (t.expires_at is null or t.expires_at > statement_timestamp())
     order by b.discount_percent desc, t.threshold desc, b.id
     limit 1;
    end if;

    if v_tier_benefit.id is not null and not v_nonstack_applied then
      -- nestly_v656 — WHAT THE PERCENTAGE COMES OFF (owner: "10% off selected products able to
      -- select the product/services ... if blanket 10% also allow that selection"). A benefit
      -- that names no item keeps v370's behaviour exactly: the whole remaining bill. A benefit
      -- that names items is worth its percentage of THOSE LINES only, and it reads them from
      -- v_rem[] — each line's remainder AFTER the Studio rules have taken their cut — so a line
      -- already discounted cannot be discounted twice off its full price.
      -- nestly_v657 — TWO SHAPES, AND ONLY TWO (owner ruling 2026-08-31, after seeing v656's
      -- tick-list discount every ticked item at once):
      --   'bill' — a percentage off the whole bill, optionally capped in money.
      --   'item' — a percentage off ONE item per transaction. The tick-list stops being "which
      --            items are discounted" and becomes "which items are ELIGIBLE"; exactly one of
      --            them is discounted, and the owner's ruling for which is the HIGHEST-PRICED
      --            eligible line on this bill — deterministic, needs no decision at the counter,
      --            and it is the line the customer would have chosen themselves.
      v_tier_scoped := coalesce(v_tier_benefit.discount_scope, 'bill') = 'item';
      v_tier_target := null;
      if v_tier_scoped then
        v_tier_best := 0;
        for j in 1 .. coalesce(array_length(v_rem, 1), 0) loop
          if v_rem[j] > v_tier_best and v_id[j] is not null and exists(
               select 1 from public.tier_benefit_scope_v656 sc
                where sc.benefit_id = v_tier_benefit.id
                  and ((v_kind[j] = 'product' and sc.product_id = v_id[j])
                    or (v_kind[j] = 'service' and sc.service_id = v_id[j]))) then
            v_tier_best := v_rem[j];
            v_tier_target := j;
          end if;
        end loop;
        -- Nothing eligible on this bill is not an error for the AUTOMATIC path — the perk simply
        -- does not apply. For a perk the counter chose by hand it IS an error, because the till
        -- quoted it and staff need to be told why it went; that refusal is raised below.
        v_tier_base := coalesce(v_tier_best, 0);
        if v_tier_base = 0 and p_tier_benefit is not null then
          return jsonb_build_object('status', 'tier_benefit_no_eligible_item',
            'reason', 'tier_benefit_no_eligible_item: nothing on this bill is covered by that perk');
        end if;
        -- A bill-level rule discount is not reflected in v_rem, so the base is capped at what is
        -- actually still payable. Without this a bill-level rule plus a tier discount could
        -- together exceed the subtotal.
        v_tier_base := least(v_tier_base, (v_subtotal - v_total_discount)::int);
      else
        v_tier_base := (v_subtotal - v_total_discount)::int;
      end if;
      if v_tier_base > 0 then
        v_tier_d := round(v_tier_base::numeric * v_tier_benefit.discount_percent / 100.0)::int;
        -- nestly_v657 (owner: "Merchant sets a maximum discount, e.g. 10% off, capped at $20").
        -- The ceiling is money, not a percentage, and it is applied AFTER the percentage so the
        -- owner's cap is what the customer's bill actually honours.
        if v_tier_benefit.max_discount_cents is not null then
          v_tier_d := least(v_tier_d, v_tier_benefit.max_discount_cents);
        end if;
        if v_tier_d > 0 then
          v_total_discount := v_total_discount + v_tier_d;
          v_applied := v_applied || jsonb_build_array(jsonb_build_object(
            'rule_id', null, 'effect_index', 0, 'effect_type', 'apply_discount_pct',
            'level', 'bill', 'target_line_index', null, 'amount_cents', v_tier_d,
            'suppressed', false, 'suppression_reason', null,
            'capped', false, 'cap_cents', null,
            'period_start', null, 'period_end', null,
            'source', 'tier_benefit', 'tier_benefit_id', v_tier_benefit.id,
            'tier_id', v_tier_benefit.tier_id, 'label', v_tier_benefit.label,
            'discount_pct', v_tier_benefit.discount_percent,
            /* nestly_v656: record_cart_sale reads these two. `limited` is what tells it to spend
               the customer's allowance when the sale is finalised; `scoped` is provenance for the
               receipt line and for anyone reading an evaluation later. */
            'tier_benefit_limited', v_tier_benefit.limit_count is not null,
            'tier_benefit_scoped', v_tier_scoped,
            /* nestly_v657: the shape, and — for a single-item discount — the line it landed on,
               so the till can name it instead of saying "(whole bill)" about one item. */
            'tier_benefit_mode', coalesce(v_tier_benefit.discount_scope, 'bill'),
            'tier_benefit_item', case when v_tier_target is null then null else v_name[v_tier_target] end,
            'tier_benefit_capped', v_tier_benefit.max_discount_cents is not null
              and v_tier_d = v_tier_benefit.max_discount_cents));
        end if;
      end if;
    end if;
  end if;


  -- ===========================================================================================
  -- NESTLY v752 — THE HAND-APPLIED BIRTHDAY DISCOUNT (owner ruling 2026-09-04: birthday gets the
  -- same mechanism as a tier benefit). Modelled exactly on the nestly_v656/v657 hand-applied tier
  -- discount immediately above: staff_stage_gift_qr_v665 has already staged this specific
  -- customer's specific entitlement onto the counter, so it is re-verified here (live, in date,
  -- unused) rather than trusted, and it is priced with the SAME whole-bill-or-one-item/cap shape.
  -- A free_item birthday benefit never reaches this function at all — it settles on scan via
  -- public.staff_confirm_birthday_free_item_v752, the same way a tier free_item does.
  -- ===========================================================================================
  if p_birthday and p_client is not null then
    select * into v_bday_entitlement
      from public.customer_birthday_entitlements e
     where e.business_id = p_business and e.client_id = p_client
       and e.status = 'available' and e.valid_from <= now() and e.valid_until > now()
     order by e.valid_until desc, e.activated_at desc
     limit 1;
    if v_bday_entitlement.id is not null then
      select * into v_bday_program from public.birthday_program_versions
       where id = v_bday_entitlement.birthday_program_version_id
         and business_id = v_bday_entitlement.business_id
         and fulfillment_kind = 'discount_pct';
    end if;
    if v_bday_entitlement.id is null or v_bday_program.id is null then
      return jsonb_build_object('status', 'birthday_benefit_not_available',
        'reason', 'birthday_benefit_not_available: this customer has no live birthday discount');
    end if;

    v_bday_scoped := coalesce(v_bday_program.discount_scope, 'bill') = 'item';
    v_bday_target := null;
    if v_bday_scoped then
      v_bday_best := 0;
      for j in 1 .. coalesce(array_length(v_rem, 1), 0) loop
        if v_rem[j] > v_bday_best and v_id[j] is not null and exists(
             select 1 from public.birthday_benefit_scope_v752 sc
              where sc.program_version_id = v_bday_program.id
                and ((v_kind[j] = 'product' and sc.product_id = v_id[j])
                  or (v_kind[j] = 'service' and sc.service_id = v_id[j]))) then
          v_bday_best := v_rem[j];
          v_bday_target := j;
        end if;
      end loop;
      v_bday_base := coalesce(v_bday_best, 0);
      if v_bday_base = 0 then
        return jsonb_build_object('status', 'birthday_benefit_no_eligible_item',
          'reason', 'birthday_benefit_no_eligible_item: nothing on this bill is covered by that birthday gift');
      end if;
      v_bday_base := least(v_bday_base, (v_subtotal - v_total_discount)::int);
    else
      v_bday_base := (v_subtotal - v_total_discount)::int;
    end if;
    if v_bday_base > 0 then
      v_bday_d := round(v_bday_base::numeric * v_bday_program.discount_percent / 100.0)::int;
      if v_bday_program.max_discount_cents is not null then
        v_bday_d := least(v_bday_d, v_bday_program.max_discount_cents);
      end if;
      if v_bday_d > 0 then
        v_total_discount := v_total_discount + v_bday_d;
        v_applied := v_applied || jsonb_build_array(jsonb_build_object(
          'rule_id', null, 'effect_index', 0, 'effect_type', 'apply_discount_pct',
          'level', 'bill', 'target_line_index', null, 'amount_cents', v_bday_d,
          'suppressed', false, 'suppression_reason', null,
          'capped', false, 'cap_cents', null,
          'period_start', null, 'period_end', null,
          'source', 'birthday_benefit', 'birthday_entitlement_id', v_bday_entitlement.id,
          'label', v_bday_entitlement.benefit_snapshot->>'label',
          'discount_pct', v_bday_program.discount_percent,
          'birthday_benefit_scoped', v_bday_scoped,
          'birthday_benefit_mode', coalesce(v_bday_program.discount_scope, 'bill'),
          'birthday_benefit_item', case when v_bday_target is null then null else v_name[v_bday_target] end,
          'birthday_benefit_capped', v_bday_program.max_discount_cents is not null
            and v_bday_d = v_bday_program.max_discount_cents));
      end if;
    end if;
  end if;

  v_total := (v_subtotal - v_total_discount)::int;

  if v_total = 0 then
    return jsonb_build_object('status', 'total_zero_not_supported',
      'reason', 'total_zero_not_supported: this checkout is fully discounted to zero and a zero-value sale is not supported; adjust the cart or the discount');
  end if;

  select gst_registered, gst_rate_bps into v_gst_reg, v_gst_bps from public.businesses where id = p_business;
  if coalesce(v_gst_reg, false) and coalesce(v_gst_bps, 0) > 0 then
    v_gst := round(v_total::numeric * v_gst_bps / (10000 + v_gst_bps))::int;
  else
    v_gst_bps := 0; v_gst := 0;
  end if;

  return jsonb_build_object(
    'status', 'ok',
    'server_lines', v_server,
    'subtotal_cents', v_subtotal::int,
    'applied_effects', v_applied,
    'discount_total_cents', v_total_discount::int,
    'total_cents', v_total,
    'gst_cents', v_gst,
    'gst_rate_bps', coalesce(v_gst_bps, 0),
    'cart_hash', app.ps1c_cart_hash(v_server));
end $function$;

revoke all on function app.ps1c_plan_checkout(uuid, uuid, uuid, jsonb, uuid, uuid, boolean)
  from public, anon, authenticated;


-- ===============================================================================================
-- 6b. public.evaluate_checkout gains the matching additive p_birthday boolean and forwards it to
--    app.ps1c_plan_checkout (part 6). Restated verbatim except the new parameter, the request
--    hash, and the forwarded call.
-- ===============================================================================================

CREATE OR REPLACE FUNCTION public.evaluate_checkout(p_business uuid, p_branch uuid, p_client uuid, p_lines jsonb, p_idempotency_key uuid, p_tier_benefit uuid DEFAULT NULL::uuid, p_birthday boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_actor uuid := auth.uid();
  v_branch uuid;
  v_config uuid;
  v_hash text;
  v_existing public.checkout_evaluation_operations%rowtype;
  v_eval public.checkout_evaluations%rowtype;
  v_plan jsonb;
  v_eval_id uuid;
  v_msg text;
begin
  if v_actor is null then
    raise exception 'authenticated staff required to evaluate a checkout' using errcode = '42501';
  end if;
  if not app.has_perm(p_business, 'create_sales')
     or not app.can_module(p_business, 'till') then
    raise exception 'you do not have permission to price a checkout in this business (create_sales)'
      using errcode = '42501';
  end if;
  if p_idempotency_key is null then
    raise exception 'a checkout evaluation idempotency key is required' using errcode = '22023';
  end if;
  v_branch := coalesce(p_branch, app.default_branch(p_business));
  if v_branch is null or not exists (
    select 1 from public.branches b where b.id = v_branch and b.business_id = p_business and b.active) then
    raise exception 'checkout branch is missing, inactive, or belongs to another business' using errcode = '22023';
  end if;
  if not app.can_see_branch(p_business, v_branch) then
    raise exception 'you are not permitted to price a checkout for this branch scope' using errcode = '42501';
  end if;
  if p_client is not null and not exists (
    select 1 from public.clients c where c.id = p_client and c.business_id = p_business) then
    raise exception 'checkout client does not belong to this business' using errcode = '22023';
  end if;

  -- nestly_v656: the hand-applied tier discount is part of what was priced, so it is part of the
  -- request identity. Two evaluations of the same cart, one with the perk and one without, are
  -- different requests and must not replay each other's answer.
  -- nestly_v752: the hand-applied birthday discount is part of what was priced too, exactly like
  -- p_tier_benefit above — it belongs in the request identity so a with-birthday and a
  -- without-birthday evaluation of the same cart cannot replay each other's answer.
  v_hash := app.ps1b_sha256(jsonb_build_object(
    'business_id', p_business, 'branch_id', v_branch, 'client_id', p_client, 'lines', p_lines,
    'tier_benefit', p_tier_benefit, 'birthday', p_birthday)::text);

  perform pg_advisory_xact_lock(hashtextextended(
    'v58:evaluate:' || p_business::text || ':' || p_idempotency_key::text, 0));

  select * into v_existing from public.checkout_evaluation_operations o
   where o.business_id = p_business and o.idempotency_key = p_idempotency_key for update;
  if found then
    if v_existing.actor is distinct from v_actor or v_existing.request_hash <> v_hash then
      raise exception 'idempotency key conflicts with a different checkout evaluation' using errcode = '22023';
    end if;
    select * into v_eval from public.checkout_evaluations where id = v_existing.evaluation_id;
    if v_eval.consumed_at is not null or v_eval.expires_at <= now() then
      raise exception 'stale: this checkout evaluation is already consumed or expired; re-evaluate' using errcode = '22023';
    end if;
    return jsonb_build_object(
      'status', 'ok', 'replayed', true, 'evaluation_id', v_eval.id, 'expires_at', v_eval.expires_at,
      'server_lines', v_eval.server_lines, 'applied_effects', v_eval.applied_effects,
      'subtotal_cents', v_eval.subtotal_cents, 'discount_total_cents', v_eval.discount_total_cents,
      'total_cents', v_eval.total_cents, 'gst_cents', v_eval.gst_cents,
      'stored_value', app.sv_evaluate_quote(p_business, v_eval.client_id, v_eval.total_cents));
  end if;

  select active_config_version_id into v_config from public.businesses where id = p_business;

  v_plan := app.ps1c_plan_checkout(p_business, v_branch, p_client, p_lines, v_config, p_tier_benefit, p_birthday);
  if v_plan->>'status' <> 'ok' then
    -- Surface the typed status as the message prefix. When the plan already provides a
    -- prefixed human sentence in 'reason' (custom_line_*, total_zero_not_supported) use
    -- it as-is; otherwise compose '<status>: <reason> (line N)'.
    if v_plan->>'reason' is not null and position((v_plan->>'status') || ':' in (v_plan->>'reason')) = 1 then
      v_msg := v_plan->>'reason';
    else
      v_msg := (v_plan->>'status') || ': ' || coalesce(v_plan->>'reason', 'checkout could not be priced')
               || case when v_plan->>'line' is not null then ' (line ' || (v_plan->>'line') || ')' else '' end;
    end if;
    raise exception '%', v_msg using errcode = '22023';
  end if;

  insert into public.checkout_evaluations(
    business_id, branch_id, client_id, server_lines, cart_hash, config_version_id, applied_effects,
    subtotal_cents, discount_total_cents, total_cents, gst_cents, gst_rate_bps, expires_at)
  values(
    p_business, v_branch, p_client, v_plan->'server_lines', v_plan->>'cart_hash', v_config,
    v_plan->'applied_effects', (v_plan->>'subtotal_cents')::int, (v_plan->>'discount_total_cents')::int,
    (v_plan->>'total_cents')::int, (v_plan->>'gst_cents')::int, (v_plan->>'gst_rate_bps')::int,
    now() + interval '10 minutes')
  returning id into v_eval_id;

  insert into public.checkout_evaluation_operations(business_id, actor, idempotency_key, request_hash, evaluation_id)
  values(p_business, v_actor, p_idempotency_key, v_hash, v_eval_id);

  return jsonb_build_object(
    'status', 'ok', 'replayed', false, 'evaluation_id', v_eval_id,
    'expires_at', now() + interval '10 minutes',
    'server_lines', v_plan->'server_lines', 'applied_effects', v_plan->'applied_effects',
    'subtotal_cents', (v_plan->>'subtotal_cents')::int, 'discount_total_cents', (v_plan->>'discount_total_cents')::int,
    'total_cents', (v_plan->>'total_cents')::int, 'gst_cents', (v_plan->>'gst_cents')::int,
    'stored_value', app.sv_evaluate_quote(p_business, p_client, (v_plan->>'total_cents')::int));
end $function$
;
revoke all on function public.evaluate_checkout(uuid, uuid, uuid, jsonb, uuid, uuid, boolean)
  from public, anon;
grant execute on function public.evaluate_checkout(uuid, uuid, uuid, jsonb, uuid, uuid, boolean)
  to authenticated, service_role;




-- ===============================================================================================
-- 7. public.record_cart_sale (the p_evaluation_id / finalise overload) spends the birthday
--    entitlement in the same transaction as the money. Restated verbatim except the three
--    touch-points marked nestly_v752 above: the fulfilment key/label, the sale_items line, and
--    the counting call (reusing the EXISTING public.redeem_customer_birthday_benefit, unchanged).
-- ===============================================================================================


CREATE OR REPLACE FUNCTION public.record_cart_sale(p_business uuid, p_client uuid, p_branch uuid, p_staff uuid, p_method text, p_idempotency_key text, p_lines jsonb, p_evaluation_id uuid, p_paid boolean DEFAULT true, p_occurred_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_redemptions jsonb DEFAULT NULL::jsonb)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_actor uuid := auth.uid();
  v_key text := nullif(btrim(p_idempotency_key), '');
  v_method text := lower(nullif(btrim(p_method), ''));
  v_paid boolean := coalesce(p_paid, true);
  v_eval public.checkout_evaluations%rowtype;
  v_line jsonb; v_ord int; v_rehash text; v_price jsonb;
  v_kind text; v_cid uuid; v_qty int; v_unit int;
  v_reproj jsonb := '[]'::jsonb;
  v257_bundle jsonb; v257_bline jsonb; v257_bid uuid; v257_bqty int;
  v257_cur_bid uuid; v257_cur_bqty int; v257_pos int := 0;
  v_retail_lines int := 0; v_stamp_product uuid; v_stamp_qty int;
  v_financial jsonb; v_sale_id uuid; v_replayed boolean;
  eff jsonb; v_ps timestamptz; v_amt int; v_ful uuid; v_key_ben text; v_rule uuid; v_rule_name text;
  bp record; v_bp_id uuid; v_committed int; v_points int := 0; v_items json;
  -- v67 stored-value tender locals
  v_tender public.checkout_sv_tenders%rowtype; v_has_sv boolean := false;
  v_sv_amount int := 0; v_sv_remainder int := 0; v_spend jsonb; v_sv_json jsonb := null;
begin
  if v_actor is null then
    raise exception 'authenticated staff required to finalise a cart sale' using errcode = '42501';
  end if;
  if not app.has_perm(p_business, 'create_sales')
     or not app.can_module(p_business, 'till') then
    raise exception 'you do not have permission to record a sale in this business (create_sales)' using errcode = '42501';
  end if;
  if v_key is null or length(v_key) < 8 then
    raise exception 'a cart-sale idempotency key of at least 8 characters is required' using errcode = '22023';
  end if;
  if v_method is null or v_method not in ('cash', 'card', 'paynow', 'other') then
    raise exception 'choose Cash, Card, PayNow or Other' using errcode = '22023';
  end if;
  if p_evaluation_id is null then
    raise exception 'the kernel finaliser requires a checkout evaluation token' using errcode = '22023';
  end if;

  -- 8.1 Lock the token. Single-use + tenant + scope validation.
  select * into v_eval from public.checkout_evaluations
   where id = p_evaluation_id and business_id = p_business for update;
  if not found then
    raise exception 'checkout evaluation not found in this business' using errcode = '42501';
  end if;
  if p_branch is not null and p_branch is distinct from v_eval.branch_id then
    raise exception 'stale_evaluation: branch does not match the evaluation token' using errcode = 'P0001';
  end if;
  if p_client is not null and p_client is distinct from v_eval.client_id then
    raise exception 'stale_evaluation: client does not match the evaluation token' using errcode = 'P0001';
  end if;

  -- 8.2 If already consumed: exact replay of THIS key, or a same-token/different-key loser
  --     (which must fail stale, never double-sell).
  if v_eval.consumed_at is not null then
    if exists (select 1 from public.financial_operations fo
                where fo.business_id = p_business and fo.sale_id = v_eval.consumed_sale_id
                  and fo.operation_type = 'quick_sale' and fo.idempotency_key = v_key) then
      select coalesce(sum(pl.points), 0) into v_points from public.points_ledger pl
       where pl.business_id = p_business and pl.sale_id = v_eval.consumed_sale_id and pl.entry_type = 'earn';
      select coalesce(json_agg(row_to_json(si) order by si.created_at, si.id), '[]'::json) into v_items
        from public.sale_items si where si.business_id = p_business and si.sale_id = v_eval.consumed_sale_id;
      return json_build_object('status', 'duplicate_ignored', 'sale_id', v_eval.consumed_sale_id,
        'business_id', p_business, 'total_cents', v_eval.total_cents, 'discount_total_cents', v_eval.discount_total_cents,
        'replayed', true, 'points_earned', 0, 'evaluation_id', v_eval.id, 'items', v_items,
        'stored_value', (select jsonb_build_object('sv_paid_cents', t.reserved_cents,
            'cash_collected_cents', t.cash_remainder_cents) from public.checkout_sv_tenders t
           where t.evaluation_id = v_eval.id and t.status = 'consumed' limit 1));
    end if;
    raise exception 'stale_evaluation: this checkout evaluation was already consumed by another sale' using errcode = 'P0001';
  end if;
  if v_eval.expires_at <= now() then
    raise exception 'stale_evaluation: the checkout evaluation has expired; re-evaluate' using errcode = 'P0001';
  end if;

  -- 8.3 Config drift: the active config version must be UNCHANGED since evaluation.
  if v_eval.config_version_id is distinct from
     (select active_config_version_id from public.businesses where id = p_business) then
    raise exception 'stale_evaluation: the active configuration changed since evaluation; re-evaluate' using errcode = 'P0001';
  end if;

  -- 8.3b Stored-value tender bound to this token? Discover + re-validate gates (TOCTOU). Any drift
  --      (reservation missing/expired/released) -> stale_evaluation so the till re-evaluates once.
  select * into v_tender from public.checkout_sv_tenders
   where business_id = p_business and evaluation_id = v_eval.id and status = 'reserved'
   for update;
  if found then
    v_has_sv := true;
    -- Gate re-validation after the lock (authority live, no synthetic on live, redeem pause, currency).
    perform app.sv_checkout_tender_gate(p_business, v_eval.client_id, v_tender.currency);
    if not exists (select 1 from public.sv_reservations r
                    where r.id = v_tender.reservation_id and r.business_id = p_business and r.status = 'active') then
      raise exception 'stale_evaluation: the stored-value hold is no longer active; re-evaluate' using errcode = 'P0001';
    end if;
    v_sv_amount := least(v_tender.reserved_cents, v_eval.total_cents);
    if v_sv_amount < 1 then
      raise exception 'stale_evaluation: the stored-value hold no longer covers this checkout; re-evaluate' using errcode = 'P0001';
    end if;
    v_sv_remainder := v_eval.total_cents - v_sv_amount;
  elsif exists (select 1 from public.checkout_sv_tenders t
                 where t.business_id = p_business and t.evaluation_id = v_eval.id and t.status = 'released') then
    -- The staff opted into stored value for this token but the hold was released (superseded by a
    -- later checkout for the same customer, or swept). Never silently downgrade to cash: fail stale
    -- so the till re-evaluates once (one winner in a two-token race; the loser gets a typed stale).
    raise exception 'stale_evaluation: the stored-value hold for this checkout was released; re-evaluate' using errcode = 'P0001';
  end if;

  -- 8.4 Price drift: re-resolve every server line and recompute the cart hash. A custom line is
  --     re-projected AS-IS from the immutable token.
  v_ord := 0;
  for v_line in select * from jsonb_array_elements(v_eval.server_lines) loop
    v_ord := v_ord + 1;
    v_kind := v_line->>'catalog_kind';
    v_cid := nullif(v_line->>'catalog_id', '')::uuid;
    v_qty := (v_line->>'qty')::int;
    if v_kind = 'custom' then
      v_unit := (v_line->>'unit_price_cents')::int;
    elsif nullif(v_line->>'bundle_id', '') is not null then
      v257_bid := (v_line->>'bundle_id')::uuid;
      v257_bqty := coalesce(nullif(v_line->>'bundle_qty', '')::int, 1);
      if v257_cur_bid is distinct from v257_bid or v257_cur_bqty is distinct from v257_bqty then
        v257_bundle := app.ps1c_bundle_lines_v204(p_business, v257_bid, v257_bqty);
        if v257_bundle->>'status' <> 'ok' then
          raise exception 'stale_evaluation: bundle on line % can no longer be priced (%); re-evaluate', v_ord, v257_bundle->>'status'
            using errcode = 'P0001';
        end if;
        v257_cur_bid := v257_bid; v257_cur_bqty := v257_bqty; v257_pos := 0;
      end if;
      v257_pos := v257_pos + 1;
      v257_bline := v257_bundle->'lines'->(v257_pos - 1);
      if v257_bline is null or nullif(v257_bline->>'service_id', '')::uuid is distinct from v_cid then
        raise exception 'stale_evaluation: the bundle on line % changed since evaluation; re-evaluate', v_ord
          using errcode = 'P0001';
      end if;
      v_unit := (v257_bline->>'line_cents')::int;
    else
      v_price := app.ps1b_catalog_price(p_business, v_kind, v_cid);
      if v_price->>'status' <> 'ok' then
        raise exception 'stale_evaluation: line % can no longer be priced (%); re-evaluate', v_ord, v_price->>'status'
          using errcode = 'P0001';
      end if;
      v_unit := (v_price->>'price_cents')::int;
      if v_kind = 'product' then v_retail_lines := v_retail_lines + 1; v_stamp_product := v_cid; v_stamp_qty := v_qty; end if;
    end if;
    v_reproj := v_reproj || jsonb_build_array(jsonb_build_object(
      'catalog_kind', v_kind, 'catalog_id', v_cid, 'name', v_line->>'name',
      'unit_price_cents', v_unit, 'qty', v_qty, 'line_total_cents', v_unit * v_qty));
  end loop;
  v_rehash := app.ps1c_cart_hash(v_reproj);
  if v_rehash is distinct from v_eval.cart_hash then
    raise exception 'stale_evaluation: catalog prices changed since evaluation; re-evaluate' using errcode = 'P0001';
  end if;

  -- 8.5 Budget re-check + COMMIT, atomically, under a deterministic
  --     (business_id, rule_id, period_start) lock order.
  for eff in select e from jsonb_array_elements(v_eval.applied_effects) e
              where (e->>'suppressed')::boolean is not true and coalesce((e->>'capped')::boolean, false) loop
    insert into public.budget_periods(business_id, rule_id, period_start, period_end, cap_cents)
    values(p_business, (eff->>'rule_id')::uuid, (eff->>'period_start')::timestamptz,
           (eff->>'period_end')::timestamptz, (eff->>'cap_cents')::int)
    on conflict (business_id, rule_id, period_start) do nothing;
  end loop;
  for bp in select (e->>'rule_id')::uuid as rule_id, (e->>'period_start')::timestamptz as ps,
                    (e->>'cap_cents')::int as cap, sum((e->>'amount_cents')::int) as amt
              from jsonb_array_elements(v_eval.applied_effects) e
             where (e->>'suppressed')::boolean is not true and coalesce((e->>'capped')::boolean, false)
             group by 1, 2, 3
             order by 1, 2 loop
    select coalesce(committed_cents, 0) into v_committed from public.budget_periods
     where business_id = p_business and rule_id = bp.rule_id and period_start = bp.ps
     for update;
    if coalesce(v_committed, 0) + bp.amt > bp.cap then
      raise exception 'stale_evaluation: rule budget was exhausted since evaluation; re-evaluate' using errcode = 'P0001';
    end if;
  end loop;

  -- 8.6 Belt-guard (contract B, v59): a zero total must NEVER create a sale, and must fail as a
  --     TYPED 22023 (not a stale P0001 that would spin a client re-evaluation loop).
  if v_eval.total_cents = 0 then
    raise exception 'total_zero_not_supported: this checkout totals zero after discounts and cannot be recorded; re-price it'
      using errcode = '22023';
  end if;

  -- 8.7 Create the parent sale for the DISCOUNTED total via the kernel candidate. When stored value
  --     tenders any portion, finalise the parent p_paid=false so the finaliser writes NO full-amount
  --     payment (the non-SV remainder is recorded below; the SV portion collects no new cash).
  perform set_config('app.cart_line_product_id',
    coalesce(case when v_retail_lines = 1 then v_stamp_product::text end, ''), true);
  perform set_config('app.cart_line_qty',
    coalesce(case when v_retail_lines = 1 then v_stamp_qty::text end, ''), true);
  perform set_config('app.cart_kernel_context','1',true);
  v_financial := public.record_quick_sale(
    p_business => p_business, p_amount_cents => v_eval.total_cents, p_method => v_method,
    p_client => v_eval.client_id, p_staff => p_staff, p_branch => v_eval.branch_id, p_note => 'cart checkout (kernel)',
    p_idempotency_key => v_key, p_occurred_at => p_occurred_at, p_paid => case when v_has_sv then false else v_paid end)::jsonb;
  perform set_config('app.cart_line_product_id', '', true);
  perform set_config('app.cart_line_qty', '', true);

  v_sale_id := nullif(v_financial #>> '{sale,id}', '')::uuid;
  v_replayed := coalesce((v_financial->>'replayed')::boolean, false);
  if v_sale_id is null then
    raise exception 'kernel finaliser did not produce a parent sale row' using errcode = 'XX001';
  end if;
  if v_replayed then
    raise exception 'stale_evaluation: this idempotency key already produced a sale for a different token' using errcode = 'P0001';
  end if;
  -- v630: DIRECT redemption→sale provenance, witnessed by this finaliser.
  if p_redemptions is not null then
    perform app.stamp_direct_redemptions_v630(p_business, v_eval.client_id, v_sale_id, p_redemptions);
  end if;

  -- 8.8 Write server-line sale_items (positive; custom -> item_type 'custom') then one signed
  --     studio_discount line per applied effect (negative).
  insert into public.sale_items(sale_id, business_id, item_type, ref_id, description, qty, unit_cents, line_cents, product_id)
  select v_sale_id, p_business,
         case e->>'catalog_kind' when 'service' then 'service' when 'product' then 'retail' else 'custom' end,
         nullif(e->>'catalog_id', '')::uuid, e->>'name', (e->>'qty')::int, (e->>'unit_price_cents')::int,
         (e->>'unit_price_cents')::int * (e->>'qty')::int,
         case when e->>'catalog_kind' = 'product' then nullif(e->>'catalog_id', '')::uuid end
    from jsonb_array_elements(v_eval.server_lines) e;

  -- 8.8b One CUSTOM_PRICE_LINE audit row per custom line.
  for eff in select e from jsonb_array_elements(v_eval.server_lines) e where e->>'catalog_kind' = 'custom' loop
    insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
    values(p_business, v_actor, 'CUSTOM_PRICE_LINE', 'sale_items', v_sale_id,
      jsonb_build_object(
        'description', eff->>'name',
        'amount_cents', (eff->>'unit_price_cents')::int,
        'reason', eff->>'reason',
        'entered_by', eff->>'entered_by'));
  end loop;

  -- 8.9 Per applied (non-suppressed) discount: fulfilment registry row, provenance line, signed
  --     sale_items line, and (if capped) a committed budget reservation.
  for eff in select e from jsonb_array_elements(v_eval.applied_effects) e
              where (e->>'suppressed')::boolean is not true and (e->>'amount_cents')::int > 0
              order by (e->>'rule_id'), (e->>'effect_index')::int loop
    v_rule := (eff->>'rule_id')::uuid;
    v_amt := (eff->>'amount_cents')::int;
    -- V370: an effect with NO rule is the automatic tier discount (app.ps1c_plan_checkout). It is
    -- named by the benefit it came from, and its fulfilment key is keyed on that benefit — the
    -- rule-keyed key would collapse to null and collide with itself.
    if v_rule is null and nullif(eff->>'birthday_entitlement_id','') is not null then
      -- nestly_v752: the hand-applied birthday discount, provenanced the same way v370's
      -- automatic/hand-applied tier discount is, just keyed on the entitlement instead of a
      -- tier_benefits_v365 row.
      v_rule_name := coalesce(nullif(btrim(coalesce(eff->>'label','')),''), 'Birthday gift');
      v_key_ben := 'birthdaydiscount:' || v_sale_id::text || ':' || coalesce(eff->>'birthday_entitlement_id','');
    elsif v_rule is null then
      v_rule_name := coalesce(nullif(btrim(coalesce(eff->>'label','')),''), 'Tier discount');
      v_key_ben := 'tierdiscount:' || v_sale_id::text || ':' || coalesce(eff->>'tier_benefit_id','');
    else
      select name into v_rule_name from public.program_rules
        where rule_id = v_rule and config_version_id = v_eval.config_version_id and business_id = p_business;
      v_rule_name := coalesce(v_rule_name, 'Studio discount');
      v_key_ben := 'discount:' || v_sale_id::text || ':' || v_rule::text || ':' || (eff->>'effect_index');
    end if;
    insert into public.benefit_fulfilments(
      business_id, canonical_benefit_key, source_engine, fulfilment_kind, client_id, detail_ref,
      face_value_cents, estimated_cost_cents, cost_basis, cost_confidence, config_version_id, occurred_at)
    values(p_business, v_key_ben, 'checkout', 'checkout_discount', v_eval.client_id, v_sale_id,
      v_amt, v_amt, 'discount_face', 'high', v_eval.config_version_id, now())
    returning id into v_ful;

    -- V370: public.checkout_discount_lines is Studio provenance — rule_id is NOT NULL, its unique
    -- key is (sale_id, rule_id, effect_index), and both reverse_sale and
    -- get_checkout_discount_report key off it. A tier discount has no rule, so it gets no row
    -- there rather than a fabricated one; its money is still fully recorded, by the fulfilment
    -- above and the signed sale_items line below, and it is inside the sale total either way.
    if v_rule is not null then
      insert into public.checkout_discount_lines(
        business_id, sale_id, evaluation_id, rule_id, effect_index, effect_type, level, target_line_index,
        amount_cents, benefit_fulfilment_id, config_version_id)
      values(p_business, v_sale_id, v_eval.id, v_rule, (eff->>'effect_index')::int, eff->>'effect_type',
        eff->>'level', nullif(eff->>'target_line_index', '')::int, v_amt, v_ful, v_eval.config_version_id);
    end if;

    insert into public.sale_items(sale_id, business_id, item_type, ref_id, description, qty, unit_cents, line_cents)
    values(v_sale_id, p_business, 'studio_discount',
      coalesce(v_rule, nullif(eff->>'tier_benefit_id','')::uuid, nullif(eff->>'birthday_entitlement_id','')::uuid),
      left(case when v_rule is null then
        case when nullif(eff->>'birthday_entitlement_id','') is not null then 'Birthday gift: ' else 'Tier benefit: ' end
      else 'Discount: ' end || v_rule_name, 200),
      1, -v_amt, -v_amt);

    -- nestly_v656 — SPENDING THE ALLOWANCE IN THE SAME TRANSACTION AS THE MONEY.
    -- A LIMITED tier discount (10% off, 1 per month) never used to reach a bill at all: v370
    -- excluded it from the automatic path because using one has to be COUNTED, and the only thing
    -- that counted was the staff Give button, which moves no money. So the perk was recorded as
    -- handed over and the customer was charged in full.
    -- Now the till can apply it, and the count is written HERE — inside the one transaction that
    -- also creates the sale. staff_issue_tier_benefit_v365 re-checks the tier, the birthday month
    -- and the allowance under its own advisory lock and RAISES if the allowance has gone since the
    -- price was quoted; that abort is deliberate and is the safe direction, because the
    -- alternative is charging a discounted total for a perk nobody recorded as spent.
    -- The sale id is the idempotency key, so a replayed finalise of the same sale re-uses the same
    -- issue row rather than spending a second allowance.
    if v_rule is null and coalesce((eff->>'tier_benefit_limited')::boolean, false)
       and v_eval.client_id is not null and nullif(eff->>'tier_benefit_id','') is not null then
      perform public.staff_issue_tier_benefit_v365(
        p_business, v_eval.client_id, (eff->>'tier_benefit_id')::uuid, v_eval.branch_id, v_sale_id);
    end if;
    -- nestly_v752: spend the birthday entitlement in the SAME transaction that takes the money,
    -- via the EXISTING public.redeem_customer_birthday_benefit — the sale id is the idempotency
    -- key, so a replayed finalise of the same sale re-uses the same redemption row rather than
    -- spending a second one.
    if v_rule is null and v_eval.client_id is not null
       and nullif(eff->>'birthday_entitlement_id','') is not null then
      perform public.redeem_customer_birthday_benefit(
        p_business, v_eval.client_id, v_eval.branch_id, v_sale_id);
    end if;

    if coalesce((eff->>'capped')::boolean, false) then
      v_ps := (eff->>'period_start')::timestamptz;
      select id into v_bp_id from public.budget_periods
        where business_id = p_business and rule_id = v_rule and period_start = v_ps;
      insert into public.budget_reservations(business_id, budget_period_id, discount_fulfilment_id, amount_cents)
      values(p_business, v_bp_id, v_ful, v_amt);
      update public.budget_periods set committed_cents = committed_cents + v_amt, updated_at = now()
       where id = v_bp_id;
    end if;
  end loop;

  -- 8.9b Stored-value tender consumption (v67). Release the token hold, then spend the SV portion
  --      via the v63 engine (paid/bonus split per PS-0), record tender evidence, and record only the
  --      non-SV remainder as a payment. All within this atomic transaction with the sale.
  if v_has_sv then
    perform app.sv_release_core(p_business, v_tender.reservation_id, gen_random_uuid());
    v_spend := app.sv_spend_core(p_business, v_tender.account_id, v_sv_amount, gen_random_uuid());
    update public.checkout_sv_tenders
       set status = 'consumed', spend_operation_id = (v_spend->>'operation_id')::uuid, sale_id = v_sale_id,
           sv_paid_cents = (v_spend->>'paid_draw_cents')::int, sv_bonus_cents = (v_spend->>'bonus_draw_cents')::int,
           cash_remainder_cents = v_sv_remainder, updated_at = now()
     where id = v_tender.id;
    if v_sv_remainder > 0 and v_paid then
      perform public.record_payment(
        p_business => p_business, p_method => v_method, p_amount_cents => v_sv_remainder, p_sale => v_sale_id,
        p_client => v_eval.client_id, p_staff => p_staff, p_branch => v_eval.branch_id,
        p_idempotency_key => left(v_key || '-svrem', 255));
    end if;
    insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
    values(p_business, v_actor, 'SV_CHECKOUT_TENDER_SPENT', 'checkout_sv_tenders', v_tender.id, jsonb_build_object(
      'evaluation_id', v_eval.id, 'sale_id', v_sale_id, 'spend_operation_id', (v_spend->>'operation_id')::uuid,
      'sv_spend_cents', v_sv_amount, 'sv_paid_cents', (v_spend->>'paid_draw_cents')::int,
      'sv_bonus_cents', (v_spend->>'bonus_draw_cents')::int, 'cash_remainder_cents', v_sv_remainder));
    v_sv_json := jsonb_build_object(
      'sv_spend_cents', v_sv_amount, 'sv_paid_cents', (v_spend->>'paid_draw_cents')::int,
      'sv_bonus_cents', (v_spend->>'bonus_draw_cents')::int, 'cash_collected_cents', v_sv_remainder,
      'spend_operation_id', (v_spend->>'operation_id')::uuid);
  end if;

  -- 8.10 Consume the token (single-use).
  update public.checkout_evaluations set consumed_at = now(), consumed_sale_id = v_sale_id
   where id = v_eval.id and consumed_at is null;
  if not found then
    raise exception 'stale_evaluation: token consumed concurrently; re-evaluate' using errcode = 'P0001';
  end if;

  if v_eval.client_id is not null then
    select coalesce(sum(pl.points), 0) into v_points from public.points_ledger pl
     where pl.business_id = p_business and pl.client_id = v_eval.client_id and pl.sale_id = v_sale_id and pl.entry_type = 'earn';
  end if;
  select coalesce(json_agg(row_to_json(si) order by si.created_at, si.id), '[]'::json) into v_items
    from public.sale_items si where si.business_id = p_business and si.sale_id = v_sale_id;

  return json_build_object(
    'status', 'ok', 'sale_id', v_sale_id, 'business_id', p_business,
    'subtotal_cents', v_eval.subtotal_cents, 'discount_total_cents', v_eval.discount_total_cents,
    'total_cents', v_eval.total_cents, 'gst_cents', v_eval.gst_cents,
    'replayed', false, 'points_earned', v_points, 'evaluation_id', v_eval.id,
    'sale', v_financial->'sale', 'items', v_items, 'stored_value', v_sv_json);
end $function$;
revoke all on function public.record_cart_sale(uuid, uuid, uuid, uuid, text, text, jsonb, uuid, boolean, timestamptz, jsonb)
  from public, anon, authenticated;
grant execute on function public.record_cart_sale(uuid, uuid, uuid, uuid, text, text, jsonb, uuid, boolean, timestamptz, jsonb)
  to authenticated, service_role;

-- ===============================================================================================
-- 8. A free_item birthday benefit settles like a tier free_item gift (v681): the counter's QR
--    scan already answers settle_now=true (part 5 above); this is the confirm action staff press.
--    Deliberately thin — it IS public.redeem_customer_birthday_benefit, reached from the QR scan
--    instead of only the pre-existing standalone "Activate" card button, with one extra guard so
--    it can never be used to redeem a discount_pct benefit for free.
-- ===============================================================================================

create or replace function public.staff_confirm_birthday_free_item_v752(
  p_business uuid, p_client uuid, p_branch uuid, p_idempotency_key uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_entitlement public.customer_birthday_entitlements%rowtype;
  v_program public.birthday_program_versions%rowtype;
begin
  select * into v_entitlement from public.customer_birthday_entitlements e
   where e.business_id = p_business and e.client_id = p_client
   order by e.valid_until desc, e.activated_at desc limit 1;
  if v_entitlement.id is null then
    raise exception 'birthday benefit unavailable' using errcode = '42501';
  end if;
  select * into v_program from public.birthday_program_versions
   where id = v_entitlement.birthday_program_version_id;
  if v_program.fulfillment_kind is distinct from 'free_item' then
    raise exception 'birthday benefit unavailable' using errcode = '42501';
  end if;
  return public.redeem_customer_birthday_benefit(p_business, p_client, p_branch, p_idempotency_key);
end
$function$;
comment on function public.staff_confirm_birthday_free_item_v752(uuid, uuid, uuid, uuid) is
  'nestly_v752: hands over a free-item birthday benefit scanned at the counter. A thin, guarded '
  'wrapper around the pre-existing public.redeem_customer_birthday_benefit — no new redemption '
  'authority, just a QR-reachable entry point restricted to fulfillment_kind=''free_item''.';
revoke all on function public.staff_confirm_birthday_free_item_v752(uuid, uuid, uuid, uuid)
  from public, anon;
grant execute on function public.staff_confirm_birthday_free_item_v752(uuid, uuid, uuid, uuid)
  to authenticated, service_role;


-- ===============================================================================================
-- 10. The OWNER-FACING WRITE PATH: public.save_birthday_program_draft and
--     public.business_save_birthday_program_v424 both accept the new structured-benefit fields
--     (parts 1/2 above added the columns and the derive-label trigger; this is what actually lets
--     the editor SEND them). Restated verbatim except the widened field whitelist, the structured
--     validation block (mirrors business_set_tier_benefits_v365 / nestly_v657 clause for clause),
--     and writing birthday_benefit_scope_v752. customer_label itself is NOT computed here — the
--     BEFORE INSERT trigger from part 2 is the one authority for that wording; this function keeps
--     its pre-existing v_label fallback purely to satisfy its own NOT NULL pre-check, and whatever
--     value it computes is overwritten by the trigger before the row is ever read back.
-- ===============================================================================================

CREATE OR REPLACE FUNCTION public.save_birthday_program_draft(p_config_version uuid, p_program_id uuid, p_program jsonb, p_expected_snapshot_hash text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_header public.firm_config_versions%rowtype;
  v_existing public.birthday_program_versions%rowtype;
  v_hash text;
  v_request_hash text;
  v_replay public.birthday_program_draft_operations%rowtype;
  v_active boolean;
  v_label text;
  v_description text;
  v_terms text;
  v_kind text;
  v_discount numeric(5,2);
  v_item text;
  v_before integer;
  v_after integer;
  v_sort integer;
  v_mode text;
  -- nestly_v752: the structured-benefit fields, mirroring tier_benefits_v365 / nestly_v657 so a
  -- birthday discount or free item is a real, priced benefit — not typed words — same as a tier
  -- benefit. customer_label itself is NOT computed here: the v752_derive_birthday_benefit_label_trg
  -- BEFORE INSERT trigger derives it from whichever of these fields end up on the row, the one
  -- authority for that wording, same as app.c45_benefit_snapshot reads for every other display.
  v_disc_scope text;
  v_max_cents integer;
  v_product uuid;
  v_scope_given boolean;
  v_scope_products uuid[];
  v_scope_services uuid[];
  v_bad uuid;
  v_id uuid;
begin
  if p_program_id is null or p_program is null or jsonb_typeof(p_program) <> 'object'
     or p_expected_snapshot_hash is null or length(p_expected_snapshot_hash) <> 32 then
    raise exception 'birthday draft request is invalid' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_object_keys(p_program) k where k not in (
    'active','customer_label','customer_description','customer_terms','fulfillment_kind',
    'discount_percent','manual_item','window_days_before','window_days_after','sort','window_mode',
    /* nestly_v752 */
    'discount_scope','max_discount_cents','product_id','scope_product_ids','scope_service_ids'
  )) then
    raise exception 'birthday program contains unsupported fields' using errcode = '22023';
  end if;
  v_request_hash := app.c45_hash(jsonb_build_object('program_id',p_program_id,'program',p_program)::text);
  select * into v_header from public.firm_config_versions where id = p_config_version for update;
  if not found or not app.c45_owner_loyalty_write(v_header.business_id) then
    raise exception 'owner loyalty configuration access required' using errcode = '42501';
  end if;
  if v_header.status <> 'draft' then raise exception 'only a draft birthday program may be edited' using errcode = '42501'; end if;
  select * into v_replay from public.birthday_program_draft_operations
   where config_version_id=p_config_version and actor=auth.uid() and program_id=p_program_id
     and expected_snapshot_hash=p_expected_snapshot_hash for share;
  if found then
    if v_replay.request_hash is distinct from v_request_hash then
      raise exception 'birthday draft request conflicts with an existing operation' using errcode = '40001';
    end if;
    return jsonb_build_object('status','draft','snapshot_hash',v_replay.result_snapshot_hash,'replayed',true);
  end if;
  if v_header.snapshot_hash is distinct from p_expected_snapshot_hash then
    raise exception 'draft configuration changed; reload before saving' using errcode = '40001';
  end if;
  select * into v_existing from public.birthday_program_versions
   where config_version_id=p_config_version and business_id=v_header.business_id and program_id=p_program_id for update;
  if v_existing.id is null and exists (
    select 1 from public.birthday_program_versions p
     where p.config_version_id=p_config_version and p.business_id=v_header.business_id
  ) then
    raise exception 'only one birthday program may exist in a configuration version' using errcode='22023';
  end if;
  if v_existing.id is null then
    if exists (select 1 from public.birthday_programs where id=p_program_id and business_id<>v_header.business_id) then
      raise exception 'birthday program does not belong to this business' using errcode = '42501';
    end if;
    insert into public.birthday_programs(id,business_id) values(p_program_id,v_header.business_id)
      on conflict (id) do nothing;
  end if;
  v_active := case when p_program ? 'active' then (p_program->>'active')::boolean else coalesce(v_existing.active,true) end;
  v_label := coalesce(nullif(btrim(p_program->>'customer_label'),''),v_existing.customer_label);
  v_description := coalesce(nullif(btrim(p_program->>'customer_description'),''),v_existing.customer_description);
  v_terms := coalesce(nullif(btrim(p_program->>'customer_terms'),''),v_existing.customer_terms);
  v_kind := coalesce(nullif(btrim(p_program->>'fulfillment_kind'),''),v_existing.fulfillment_kind);
  v_discount := case when p_program ? 'discount_percent' then nullif(p_program->>'discount_percent','')::numeric
                     when v_kind = 'discount_pct' then v_existing.discount_percent
                     else null end;
  v_item := case when p_program ? 'manual_item' then nullif(btrim(p_program->>'manual_item'),'')
                 when v_kind = 'free_item' then v_existing.manual_item
                 else null end;
  v_before := case when p_program ? 'window_days_before' then (p_program->>'window_days_before')::integer else coalesce(v_existing.window_days_before,0) end;
  v_after := case when p_program ? 'window_days_after' then (p_program->>'window_days_after')::integer else coalesce(v_existing.window_days_after,0) end;
  v_sort := case when p_program ? 'sort' then (p_program->>'sort')::integer else coalesce(v_existing.sort,0) end;
  v_mode := case when p_program ? 'window_mode' then nullif(btrim(p_program->>'window_mode'),'')
                 else coalesce(v_existing.window_mode,'days') end;

  -- nestly_v752 — the structured fields, validated the same way business_set_tier_benefits_v365
  -- validates them for a tier benefit (nestly_v656/v657): a product/service must belong to this
  -- business, an item-scoped discount must name at least one eligible item, and a cap is money on
  -- a whole-bill discount only.
  v_disc_scope := lower(coalesce(nullif(btrim(coalesce(p_program->>'discount_scope','')),''),
                          coalesce(v_existing.discount_scope,'bill')));
  v_max_cents := case when p_program ? 'max_discount_cents' then nullif(p_program->>'max_discount_cents','')::integer
                       else v_existing.max_discount_cents end;
  v_product := case when p_program ? 'product_id' then nullif(p_program->>'product_id','')::uuid
                     else v_existing.product_id end;
  v_scope_given := (p_program ? 'scope_product_ids') or (p_program ? 'scope_service_ids');
  v_scope_products := coalesce((select array_agg(value::uuid)
    from jsonb_array_elements_text(case when jsonb_typeof(p_program->'scope_product_ids')='array'
      then p_program->'scope_product_ids' else '[]'::jsonb end)), '{}'::uuid[]);
  v_scope_services := coalesce((select array_agg(value::uuid)
    from jsonb_array_elements_text(case when jsonb_typeof(p_program->'scope_service_ids')='array'
      then p_program->'scope_service_ids' else '[]'::jsonb end)), '{}'::uuid[]);

  if v_kind = 'discount_pct' then
    v_product := null;
    select p into v_bad from unnest(v_scope_products) p
     where not exists(select 1 from public.products x where x.id=p and x.business_id=v_header.business_id) limit 1;
    if v_bad is not null then
      raise exception 'that product does not belong to this business' using errcode='42704';
    end if;
    select s into v_bad from unnest(v_scope_services) s
     where not exists(select 1 from public.services x where x.id=s and x.business_id=v_header.business_id) limit 1;
    if v_bad is not null then
      raise exception 'that service does not belong to this business' using errcode='42704';
    end if;
    if v_disc_scope not in ('bill','item') then
      raise exception 'a discount is either off the whole bill or off one chosen item' using errcode='22023';
    end if;
    if v_disc_scope='item' and cardinality(v_scope_products)+cardinality(v_scope_services)=0 then
      raise exception 'choose at least one product or service the discount can come off' using errcode='22023';
    end if;
    if v_disc_scope='bill' then
      v_scope_products := '{}'::uuid[]; v_scope_services := '{}'::uuid[];
      if v_max_cents is not null and (v_max_cents < 1 or v_max_cents > 100000000) then
        raise exception 'a maximum discount must be a positive amount' using errcode='22023';
      end if;
    else
      v_max_cents := null;
    end if;
  elsif v_kind = 'free_item' then
    v_disc_scope := 'bill'; v_max_cents := null; v_scope_products := '{}'::uuid[]; v_scope_services := '{}'::uuid[];
    if v_product is not null then
      perform 1 from public.products where id=v_product and business_id=v_header.business_id;
      if not found then
        raise exception 'that product does not belong to this business' using errcode='42704';
      end if;
      v_item := null;
    end if;
  else
    v_disc_scope := 'bill'; v_max_cents := null; v_product := null;
    v_scope_products := '{}'::uuid[]; v_scope_services := '{}'::uuid[];
  end if;

  if v_label is null or v_description is null or v_terms is null or v_kind not in ('discount_pct','free_item')
     or v_before not between 0 and 182 or v_after not between 0 and 182 or v_before+v_after+1 > 365
     or v_sort not between 0 and 10000 or v_mode not in ('days','month')
     or (v_kind='discount_pct' and (v_discount is null or v_discount<=0 or v_discount>100 or v_item is not null))
     or (v_kind='free_item' and (v_discount is not null or (v_item is null and v_product is null))) then
    raise exception 'birthday programme values are invalid' using errcode = '22023';
  end if;
  insert into public.birthday_program_versions(
    program_id,config_version_id,business_id,active,customer_label,customer_description,
    customer_terms,fulfillment_kind,discount_percent,manual_item,window_days_before,window_days_after,sort,window_mode,
    discount_scope,max_discount_cents,product_id
  ) values(
    p_program_id,p_config_version,v_header.business_id,v_active,v_label,v_description,
    v_terms,v_kind,v_discount,v_item,v_before,v_after,v_sort,v_mode,
    v_disc_scope,v_max_cents,v_product
  ) on conflict(program_id,config_version_id) do update set
    active=excluded.active, customer_label=excluded.customer_label,
    customer_description=excluded.customer_description, customer_terms=excluded.customer_terms,
    fulfillment_kind=excluded.fulfillment_kind, discount_percent=excluded.discount_percent,
    manual_item=excluded.manual_item, window_mode=excluded.window_mode, window_days_before=excluded.window_days_before,
    window_days_after=excluded.window_days_after, sort=excluded.sort,
    discount_scope=excluded.discount_scope, max_discount_cents=excluded.max_discount_cents,
    product_id=excluded.product_id
  returning id into v_id;
  -- The scope is replaced wholesale, and only when the payload spoke about it — mirrors
  -- business_set_tier_benefits_v365's identical rule so an older client that sends neither key
  -- cannot silently widen a single-item discount back to the whole bill.
  if v_scope_given then
    delete from public.birthday_benefit_scope_v752 where program_version_id = v_id;
    insert into public.birthday_benefit_scope_v752(business_id, program_version_id, product_id, service_id)
    select v_header.business_id, v_id, p, null from unnest(v_scope_products) p
    union all
    select v_header.business_id, v_id, null, s from unnest(v_scope_services) s
    on conflict do nothing;
  end if;
  perform app.refresh_loyalty_config_snapshot(p_config_version);
  select snapshot_hash into v_hash from public.firm_config_versions where id=p_config_version;
  insert into public.birthday_program_draft_operations(
    config_version_id,business_id,actor,program_id,expected_snapshot_hash,request_hash,result_snapshot_hash
  ) values(p_config_version,v_header.business_id,auth.uid(),p_program_id,p_expected_snapshot_hash,v_request_hash,v_hash);
  return jsonb_build_object('status','draft','snapshot_hash',v_hash,'replayed',false);
end $function$
;
revoke all on function public.save_birthday_program_draft(uuid, uuid, jsonb, text) from public;
revoke all on function public.save_birthday_program_draft(uuid, uuid, jsonb, text) from anon;
grant execute on function public.save_birthday_program_draft(uuid, uuid, jsonb, text)
  to authenticated, service_role;

CREATE OR REPLACE FUNCTION public.business_save_birthday_program_v424(p_business uuid, p_payload jsonb, p_idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_actor       uuid := auth.uid();
  v_key         text := btrim(coalesce(p_idempotency_key,''));
  v_program     jsonb;
  v_program_id  uuid;
  v_request     text;
  v_replay      public.birthday_program_save_operations_v424%rowtype;
  v_version     uuid;
  v_hash        text;
  v_result      jsonb;
begin
  if p_business is null or p_payload is null or jsonb_typeof(p_payload) <> 'object'
     or length(v_key) not between 8 and 200 then
    raise exception 'birthday save request is invalid' using errcode = '22023';
  end if;
  -- The same gate save_birthday_program_draft and publish_loyalty_config apply, applied once and
  -- up front so an unauthorised caller never reaches the point of creating a draft version.
  if v_actor is null or not app.c45_owner_loyalty_write(p_business) then
    raise exception 'owner loyalty configuration access required' using errcode = '42501';
  end if;

  -- program_id travels BESIDE the programme fields, never inside them: save_birthday_program_draft
  -- rejects any key outside its own whitelist, and that whitelist is the contract this payload
  -- must match exactly. Everything else is forwarded untouched and validated by that function.
  v_program := p_payload - 'program_id';
  if exists (select 1 from jsonb_object_keys(v_program) k where k not in (
    'active','customer_label','customer_description','customer_terms','fulfillment_kind',
    'discount_percent','manual_item','window_days_before','window_days_after','sort','window_mode',
    /* nestly_v752 */
    'discount_scope','max_discount_cents','product_id','scope_product_ids','scope_service_ids'
  )) then
    raise exception 'birthday program contains unsupported fields' using errcode = '22023';
  end if;

  -- Serialise concurrent saves for this firm before reading the receipt, so the second caller
  -- takes a fresh snapshot after the first has committed and replays instead of publishing twice.
  -- publish_loyalty_config takes the same lock; re-taking it inside one transaction is free.
  perform 1 from public.businesses where id = p_business for update;

  v_request := app.c45_hash(jsonb_build_object('business',p_business,'payload',p_payload)::text);
  select * into v_replay from public.birthday_program_save_operations_v424
   where business_id = p_business and idempotency_key = v_key;
  if found then
    -- Same key, different edit: the caller reused a key it must not reuse. Refusing is the only
    -- honest answer — publishing would silently discard one of the two edits.
    if v_replay.request_hash is distinct from v_request then
      raise exception 'birthday save conflicts with an existing operation' using errcode = '40001';
    end if;
    return coalesce(v_replay.result,'{}'::jsonb) || jsonb_build_object('replayed', true);
  end if;

  -- Which programme is being edited. A caller may name it; otherwise the firm's live birthday
  -- programme is resolved server-side, and only a firm that has never had one gets a new id.
  -- The browser inventing a uuid on every save is how a second birthday programme gets created.
  v_program_id := coalesce(
    nullif(p_payload->>'program_id','')::uuid,
    (select bpv.program_id
       from public.birthday_program_versions bpv
       join public.businesses b
         on b.id = bpv.business_id and b.active_config_version_id = bpv.config_version_id
      where bpv.business_id = p_business
      order by bpv.sort, bpv.program_id
      limit 1),
    (select bp.id from public.birthday_programs bp
      where bp.business_id = p_business order by bp.created_at, bp.id limit 1),
    gen_random_uuid());

  v_version := (public.create_loyalty_config_draft(
    p_business, null, 'birthday_editor_v424')::jsonb->>'version_id')::uuid;
  if v_version is null then
    raise exception 'birthday save could not open a draft' using errcode = '55000';
  end if;
  -- Read the hash back rather than assuming one: create_loyalty_config_draft writes a hash and
  -- then app.refresh_loyalty_config_snapshot rewrites it, so no value known before this is current.
  select snapshot_hash into v_hash from public.firm_config_versions where id = v_version;
  perform public.save_birthday_program_draft(v_version, v_program_id, v_program, v_hash);
  perform public.publish_loyalty_config(v_version);

  v_result := jsonb_build_object(
    'status','published','version_id',v_version,'program_id',v_program_id);
  insert into public.birthday_program_save_operations_v424(
    business_id,actor,idempotency_key,request_hash,program_id,config_version_id,result)
  values (p_business,v_actor,v_key,v_request,v_program_id,v_version,v_result);
  return v_result || jsonb_build_object('replayed', false);
end $function$
;
revoke all on function public.business_save_birthday_program_v424(uuid, jsonb, text) from public;
revoke all on function public.business_save_birthday_program_v424(uuid, jsonb, text) from anon;
grant execute on function public.business_save_birthday_program_v424(uuid, jsonb, text)
  to authenticated, service_role;



-- ===============================================================================================
-- 11. public.get_active_birthday_program (the business-side reader that feeds the owner's editor)
--     gains the structured-benefit fields, so opening "Edit benefit" on a published discount or
--     free item reads back exactly what was chosen — the product/service ids and the scope, not
--     only the rendered sentence. Restated verbatim except the four new jsonb_build_object keys.
-- ===============================================================================================

CREATE OR REPLACE FUNCTION public.get_active_birthday_program(p_business_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_version uuid;
  v_as_of timestamptz:=statement_timestamp();
begin
  if auth.uid() is null
     or not app.can_module_read(p_business_id, 'loyalty') then
    raise exception 'loyalty read access required' using errcode = '42501';
  end if;

  select business.active_config_version_id into v_version
    from public.businesses business
   where business.id = p_business_id;

  if v_version is null then
    return jsonb_build_object(
      'status','unavailable','as_of',v_as_of,'programs','[]'::jsonb
    );
  end if;

  return jsonb_build_object(
    'status','published',
    'as_of',v_as_of,
    'programs',coalesce((
      select jsonb_agg(jsonb_build_object(
        'program_id',program.program_id,
        'active',program.active,
        'customer_label',program.customer_label,
        'customer_description',program.customer_description,
        'customer_terms',program.customer_terms,
        'fulfillment_kind',program.fulfillment_kind,
        'discount_percent',program.discount_percent,
        'manual_item',program.manual_item,
        'window_mode',program.window_mode,'window_days_before',program.window_days_before,
        'window_days_after',program.window_days_after,
        'sort',program.sort,
        -- nestly_v752: the structured-benefit fields, so the editor's "Edit benefit" dialog can
        -- read back exactly what it wrote — a business/product name plus the raw ids the
        -- eligible-item checkboxes need, not just the rendered sentence.
        'discount_scope',program.discount_scope,'max_discount_cents',program.max_discount_cents,
        'product_id',program.product_id,
        'product_name',(select pr.name from public.products pr where pr.id=program.product_id),
        'scope_product_ids',coalesce((select jsonb_agg(sc.product_id) from public.birthday_benefit_scope_v752 sc
          where sc.program_version_id=program.id and sc.product_id is not null),'[]'::jsonb),
        'scope_service_ids',coalesce((select jsonb_agg(sc.service_id) from public.birthday_benefit_scope_v752 sc
          where sc.program_version_id=program.id and sc.service_id is not null),'[]'::jsonb)
      ) order by program.sort,program.program_id)
        from public.birthday_program_versions program
       where program.business_id = p_business_id
         and program.config_version_id = v_version
    ),'[]'::jsonb)
  );
end
$function$;

revoke all on function public.get_active_birthday_program(uuid) from public, anon;
grant execute on function public.get_active_birthday_program(uuid) to authenticated, service_role;


commit;
