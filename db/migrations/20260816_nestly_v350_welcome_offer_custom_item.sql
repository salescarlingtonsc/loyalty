-- V350: welcome offer "Free item" no longer has to be a catalogued service/product.
--
-- Owner, photo 3 annotation 2026-08-16: "Free item does not need to be owner's own products, can
-- be anything else." reward_catalog_kind was hard-CHECK'd to ('service','product') and
-- reward_catalog_id was NOT NULL on both business_welcome_offers_v215 and
-- welcome_offer_grants_v215 — a business with no services/products configured yet couldn't set a
-- welcome offer at all (openWelcomeOfferEditorV215 toasts "Add a service or product first").
--
-- Adds a third kind, 'custom', backed by a new nullable business_welcome_offers_v215.custom_label
-- column (the grants table needs no equivalent column — reward_label already freezes the exact
-- text at grant time, same as it always has for a catalog item's name).
--
-- Redemption (staff_redeem_welcome_offer_v215) needs NO change: it never looks up
-- reward_catalog_id for price or inventory — the free item is unconditionally a $0 sale, and its
-- kind-branch is `case when reward_catalog_kind='service' then 'service' else 'retail' end`,
-- which already routes 'custom' to 'retail' correctly. issue_welcome_offer_v215 (the join-time
-- "still exists and active" catalogue guard) and business_get_welcome_offer_v215 (the owner-facing
-- "item_available" flag) both need a 'custom' bypass — a custom item never withers when a service
-- is deleted, because there is no catalogue row backing it to delete.
--
-- APPLIED 2026-08-16 to gadpooereceldfpfxsod (rolled-back dry run covering all 5 checks below,
-- then applied for real and re-confirmed only one business_set_welcome_offer_v215 signature).

alter table public.business_welcome_offers_v215
  alter column reward_catalog_id drop not null,
  add column if not exists custom_label text;

alter table public.business_welcome_offers_v215
  drop constraint if exists business_welcome_offers_v215_kind_check;
alter table public.business_welcome_offers_v215
  add constraint business_welcome_offers_v215_kind_check
    check (reward_catalog_kind in ('service','product','custom'));
alter table public.business_welcome_offers_v215
  add constraint business_welcome_offers_v215_catalog_shape_check
    check (
      (reward_catalog_kind in ('service','product') and reward_catalog_id is not null and custom_label is null)
      or
      (reward_catalog_kind = 'custom' and reward_catalog_id is null and custom_label is not null
       and length(btrim(custom_label)) between 1 and 120)
    );

alter table public.welcome_offer_grants_v215
  alter column reward_catalog_id drop not null;
alter table public.welcome_offer_grants_v215
  drop constraint if exists welcome_offer_grants_v215_kind_check;
alter table public.welcome_offer_grants_v215
  add constraint welcome_offer_grants_v215_kind_check
    check (reward_catalog_kind in ('service','product','custom'));

create or replace function app.issue_welcome_offer_v215(p_business uuid, p_client uuid)
returns uuid language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_offer public.business_welcome_offers_v215%rowtype;
  v_ok boolean;
  v_grant uuid;
begin
  if p_business is null or p_client is null then return null; end if;

  select * into v_offer
  from public.business_welcome_offers_v215
  where business_id = p_business;
  if not found or not v_offer.active then return null; end if;

  if v_offer.reward_catalog_kind = 'custom' then
    v_ok := true;
  elsif v_offer.reward_catalog_kind = 'service' then
    select true into v_ok from public.services
    where id = v_offer.reward_catalog_id and business_id = p_business and active;
  else
    select true into v_ok from public.products
    where id = v_offer.reward_catalog_id and business_id = p_business and active;
  end if;
  if not coalesce(v_ok, false) then return null; end if;

  if exists(
    select 1 from public.sales
    where business_id = p_business and client_id = p_client and reversal_of is null
  ) then
    return null;
  end if;

  insert into public.welcome_offer_grants_v215(
    business_id, client_id, min_spend_cents,
    reward_catalog_kind, reward_catalog_id, reward_label, expires_at
  ) values (
    p_business, p_client, v_offer.min_spend_cents,
    v_offer.reward_catalog_kind, v_offer.reward_catalog_id, v_offer.reward_label,
    case when v_offer.expiry_days is null then null
         else now() + make_interval(days => v_offer.expiry_days) end
  )
  on conflict (business_id, client_id) do nothing
  returning id into v_grant;

  return v_grant;
end
$$;

create or replace function public.business_get_welcome_offer_v215(p_business uuid)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_row public.business_welcome_offers_v215%rowtype;
  v_granted int; v_redeemed int; v_item_ok boolean;
begin
  if auth.uid() is null then
    raise exception 'authenticated staff required' using errcode='42501';
  end if;
  if not (app.is_salon_owner(p_business)
          or app.can_module_read(p_business,'loyalty')
          or app.can_module_read(p_business,'till')) then
    raise exception 'welcome offer authorization required' using errcode='42501';
  end if;

  select count(*) filter (where status='granted'), count(*) filter (where status='redeemed')
    into v_granted, v_redeemed
  from public.welcome_offer_grants_v215 where business_id = p_business;

  select * into v_row from public.business_welcome_offers_v215 where business_id = p_business;
  if v_row.business_id is null then
    return jsonb_build_object('status','ok','configured',false,'active',false,
      'granted_count',coalesce(v_granted,0),'redeemed_count',coalesce(v_redeemed,0));
  end if;

  if v_row.reward_catalog_kind = 'custom' then
    v_item_ok := true;
  elsif v_row.reward_catalog_kind = 'service' then
    select true into v_item_ok from public.services
    where id = v_row.reward_catalog_id and business_id = p_business and active;
  else
    select true into v_item_ok from public.products
    where id = v_row.reward_catalog_id and business_id = p_business and active;
  end if;

  return jsonb_build_object(
    'status','ok','configured',true,'active',v_row.active,
    'min_spend_cents',v_row.min_spend_cents,
    'reward_catalog_kind',v_row.reward_catalog_kind,
    'reward_catalog_id',v_row.reward_catalog_id,
    'custom_label',v_row.custom_label,
    'reward_label',v_row.reward_label,'expiry_days',v_row.expiry_days,
    'version',v_row.version,
    'item_available',coalesce(v_item_ok,false),
    'granted_count',coalesce(v_granted,0),'redeemed_count',coalesce(v_redeemed,0));
end
$$;

-- A new parameter changes the signature, so CREATE OR REPLACE would leave the OLD 6-arg function
-- sitting alongside this one as an ambiguous overload (the same trap v343/v345's own migrations
-- called out and hit) — drop it explicitly first.
drop function if exists public.business_set_welcome_offer_v215(uuid,boolean,integer,text,uuid,integer);
create or replace function public.business_set_welcome_offer_v215(
  p_business uuid, p_active boolean, p_min_spend_cents integer,
  p_reward_catalog_kind text, p_reward_catalog_id uuid, p_expiry_days integer default null,
  p_custom_label text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_label text;
  v_custom text := nullif(btrim(coalesce(p_custom_label,'')),'');
  v_row public.business_welcome_offers_v215%rowtype;
begin
  if v_actor is null then
    raise exception 'authenticated staff required' using errcode='42501';
  end if;
  if not (app.is_salon_owner(p_business) or app.can_module_write(p_business,'loyalty')) then
    raise exception 'welcome offer authorization required' using errcode='42501';
  end if;
  if p_reward_catalog_kind is null or p_reward_catalog_kind not in ('service','product','custom') then
    raise exception 'reward_catalog_kind must be service, product or custom' using errcode='22023';
  end if;
  if coalesce(p_min_spend_cents,0) < 0 or coalesce(p_min_spend_cents,0) > 100000000 then
    raise exception 'min_spend_cents out of range' using errcode='22023';
  end if;
  if p_expiry_days is not null and (p_expiry_days < 1 or p_expiry_days > 3650) then
    raise exception 'expiry_days must be between 1 and 3650' using errcode='22023';
  end if;

  if p_reward_catalog_kind = 'custom' then
    if v_custom is null or char_length(v_custom) > 120 then
      raise exception 'welcome_offer_custom_label_required' using errcode='22023';
    end if;
    v_label := v_custom;
  else
    if p_reward_catalog_kind = 'service' then
      select name into v_label from public.services
      where id = p_reward_catalog_id and business_id = p_business and active;
    else
      select name into v_label from public.products
      where id = p_reward_catalog_id and business_id = p_business and active;
    end if;
    if v_label is null then
      raise exception 'welcome_offer_item_unavailable' using errcode='22023';
    end if;
  end if;

  insert into public.business_welcome_offers_v215 as offer(
    business_id, active, min_spend_cents, reward_catalog_kind,
    reward_catalog_id, custom_label, reward_label, expiry_days, updated_by, updated_at
  ) values (
    p_business, coalesce(p_active,false), coalesce(p_min_spend_cents,0),
    p_reward_catalog_kind, case when p_reward_catalog_kind='custom' then null else p_reward_catalog_id end,
    v_custom, v_label, p_expiry_days, v_actor, now()
  )
  on conflict (business_id) do update set
    active = excluded.active,
    min_spend_cents = excluded.min_spend_cents,
    reward_catalog_kind = excluded.reward_catalog_kind,
    reward_catalog_id = excluded.reward_catalog_id,
    custom_label = excluded.custom_label,
    reward_label = excluded.reward_label,
    expiry_days = excluded.expiry_days,
    version = offer.version + 1,
    updated_by = excluded.updated_by,
    updated_at = now()
  returning * into v_row;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'WELCOME_OFFER_SET_V215',
          'business_welcome_offers_v215', p_business, jsonb_build_object(
    'active', v_row.active, 'min_spend_cents', v_row.min_spend_cents,
    'reward_catalog_kind', v_row.reward_catalog_kind,
    'reward_catalog_id', v_row.reward_catalog_id,
    'reward_label', v_row.reward_label, 'expiry_days', v_row.expiry_days,
    'version', v_row.version));

  return jsonb_build_object(
    'status','ok','active',v_row.active,'min_spend_cents',v_row.min_spend_cents,
    'reward_catalog_kind',v_row.reward_catalog_kind,
    'reward_catalog_id',v_row.reward_catalog_id,
    'custom_label',v_row.custom_label,
    'reward_label',v_row.reward_label,'expiry_days',v_row.expiry_days,
    'version',v_row.version);
end
$$;

revoke all on function public.business_set_welcome_offer_v215(uuid,boolean,integer,text,uuid,integer,text) from public, anon;
grant execute on function public.business_set_welcome_offer_v215(uuid,boolean,integer,text,uuid,integer,text) to authenticated;

-- ============================================================================================
-- VERIFICATION (rolled-back transaction against production before applying for real)
-- ============================================================================================
-- Verified 2026-08-16 inside a rolled-back transaction against gadpooereceldfpfxsod, using Cubbly:
--   1. after the explicit drop, only ONE business_set_welcome_offer_v215 signature (7-arg) exists
--      — no ambiguous overload.
--   2. set with kind='custom', custom_label='Free thank-you card', no catalog id -> saved,
--      reward_label='Free thank-you card', reward_catalog_id null.
--   3. business_get_welcome_offer_v215 on that row -> item_available=true (no catalog dependency).
--   4. set with kind='custom' and blank custom_label -> refused 22023.
--   5. set with kind='service' (a real active service, p_custom_label omitted) -> still succeeds,
--      reward_catalog_id set, custom_label null — the catalog path is unaffected.
