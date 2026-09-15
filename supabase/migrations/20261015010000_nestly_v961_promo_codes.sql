-- nestly_v961 — a promo code takes money off a merchant's first payment.
--
-- OWNER, 2026-09-15: "can i add a promo code to reduce the selling price of the business owner.
-- example 20% off or $200 off. (assuming vouchers given to abc cafe, the voucher code will be
-- unique to abc cafe (abc_cafe_20%_off)". Nothing promo-code-shaped existed anywhere in the
-- platform: no code table, no redemption, no expiry. The only discount that existed was a flat
-- "Discount (SGD)" typed onto a prospect quotation (platform_crm_commercial_v156), which has never
-- been used (0 rows) and is a per-deal number, not a code you can hand out.
--
-- OWNER RULINGS, 2026-09-15, recorded so they are not re-litigated:
--   A. THE MERCHANT REDEEMS IT. You create the code here and give it to the merchant; they type it
--      into their own Billing page. A super admin may also apply one on their behalf — same RPC,
--      same rules, so there is one redemption path and not two.
--   B. MANUAL FIRMS NOW. A stripe/razorpay subscription is charged BY THE PROVIDER; a discount
--      that only exists in our table would show a reduced price while the provider kept charging
--      full. Redemption is refused for those with promo_provider_billed, and the provider-coupon
--      work is written up separately for its own approval.
--   C. FIRST PAYMENT ONLY. A code comes off exactly one payment. A business therefore holds at
--      most ONE pending redemption (partial unique index), and once a redemption is consumed that
--      business has had its promo — a second code is refused. A super admin can remove a pending
--      redemption to swap one code for another before the payment happens.
--
-- WHAT THE DISCOUNT IS COMPUTED AGAINST, and why it is not computed here. The price a merchant
-- pays comes from public.billing_plan_catalog_v124 through get_business_billing_v758
-- (pricing_model 'v124_customer_capacity': a cadence base plus capacity blocks). Re-deriving that
-- here to pre-compute "20% of what?" would create a SECOND price authority that could disagree
-- with the page the merchant is reading. So it is not re-derived: app.promo_discount_cents_v961 is
-- pure arithmetic that takes the list amount as an argument, an AMOUNT code needs no list amount
-- at all, and a PERCENT code resolves against the amount actually being charged at the moment it
-- is charged. The redemption row carries the code's terms; the payment row carries the money.
--
-- HOW IT REACHES THE MONEY. A manual firm has no automatic charge — a human records the payment
-- (platform_record_subscription_payment_v664, which takes the amount as an argument). This
-- migration does NOT silently rewrite that amount: forcing a number under the person typing it is
-- how double-discounts happen. Instead the pending promo is visible to BOTH sides (the merchant's
-- billing page and the firm record in the console), and recording a payment consumes the pending
-- redemption, stamping it with that payment's reference and amount and auditing the arithmetic.
--
-- PDPA/enumeration note: the code table has NO select policy for ordinary users. A merchant can
-- never list codes, only present one. A wrong code and a code restricted to another firm return
-- the SAME 'promo_code_not_found', so the redemption box cannot be used to discover which codes
-- exist or who they belong to.
--
-- Rollback suite: db/tests/v961_promo_codes.sql

begin;

-- ---------------------------------------------------------------------------------------------
-- 1. The codes.
-- ---------------------------------------------------------------------------------------------
create table if not exists public.platform_promo_codes_v961 (
  id uuid primary key default gen_random_uuid(),
  code text not null,
  -- The merchant types whatever they like; matching is on the normalised form, so
  -- "abc_cafe_20_off", "ABC_Cafe_20_Off" and "  abc_cafe_20_off " are one code.
  code_norm text generated always as (upper(btrim(code))) stored,
  discount_kind text not null,
  percent_bps integer,
  amount_cents integer,
  currency text not null default 'SGD',
  -- The owner's example is a voucher for ONE firm. NULL means any (manual) firm may redeem it.
  restricted_business_id uuid references public.businesses(id) on delete cascade,
  max_redemptions integer,
  redeemed_count integer not null default 0,
  expires_on date,
  active boolean not null default true,
  note text,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_by uuid,
  updated_at timestamptz not null default now(),
  constraint promo_code_shape_v961 check (
    (discount_kind = 'percent' and percent_bps between 1 and 10000 and amount_cents is null)
    or (discount_kind = 'amount' and amount_cents >= 1 and percent_bps is null)),
  constraint promo_code_text_v961 check (btrim(code) <> '' and length(btrim(code)) between 3 and 64),
  constraint promo_code_max_redemptions_v961 check (max_redemptions is null or max_redemptions >= 1),
  constraint promo_code_currency_v961 check (currency = upper(currency) and length(currency) = 3)
);

create unique index if not exists platform_promo_codes_code_norm_v961
  on public.platform_promo_codes_v961 (code_norm);
create index if not exists platform_promo_codes_restricted_v961
  on public.platform_promo_codes_v961 (restricted_business_id)
  where restricted_business_id is not null;

comment on table public.platform_promo_codes_v961 is
  'nestly_v961: platform promo codes that take money off a merchant''s FIRST subscription payment. Percent or fixed amount; optionally locked to one business. No select policy for ordinary users — redemption goes through business_redeem_promo_code_v961.';

-- ---------------------------------------------------------------------------------------------
-- 2. The redemptions.
-- ---------------------------------------------------------------------------------------------
create table if not exists public.platform_promo_redemptions_v961 (
  id uuid primary key default gen_random_uuid(),
  promo_id uuid not null references public.platform_promo_codes_v961(id) on delete cascade,
  business_id uuid not null references public.businesses(id) on delete cascade,
  redeemed_by uuid,
  redeemed_by_super_admin boolean not null default false,
  redeemed_at timestamptz not null default now(),
  -- The code's terms, snapshotted: editing or deactivating a code later must not silently change
  -- what an already-redeemed merchant was promised.
  discount_kind text not null,
  percent_bps integer,
  amount_cents integer,
  currency text not null default 'SGD',
  consumed_at timestamptz,
  consumed_payment_reference text,
  consumed_list_cents integer,
  consumed_discount_cents integer,
  removed_at timestamptz,
  removed_by uuid,
  removed_reason text,
  constraint promo_redemption_shape_v961 check (
    (discount_kind = 'percent' and percent_bps between 1 and 10000 and amount_cents is null)
    or (discount_kind = 'amount' and amount_cents >= 1 and percent_bps is null)),
  constraint promo_redemption_consumed_shape_v961 check (
    (consumed_at is null and consumed_list_cents is null and consumed_discount_cents is null)
    or (consumed_at is not null and consumed_discount_cents >= 0))
);

-- One business, one use of a given code.
create unique index if not exists platform_promo_redemptions_once_v961
  on public.platform_promo_redemptions_v961 (promo_id, business_id)
  where removed_at is null;
-- RULING C, enforced rather than trusted: at most one LIVE redemption per business at a time.
create unique index if not exists platform_promo_redemptions_one_live_v961
  on public.platform_promo_redemptions_v961 (business_id)
  where removed_at is null;
create index if not exists platform_promo_redemptions_pending_v961
  on public.platform_promo_redemptions_v961 (business_id)
  where consumed_at is null and removed_at is null;

comment on table public.platform_promo_redemptions_v961 is
  'nestly_v961: one row per code a business has redeemed, carrying the code''s terms as they stood at redemption. At most one live row per business (first-payment-only); consumed when a payment is recorded.';

-- ---------------------------------------------------------------------------------------------
-- 3. RLS. No write policy anywhere — every write goes through the definer RPCs below. Codes are
--    invisible to merchants entirely (enumeration); a merchant sees only their OWN redemption.
-- ---------------------------------------------------------------------------------------------
alter table public.platform_promo_codes_v961 enable row level security;
alter table public.platform_promo_redemptions_v961 enable row level security;

drop policy if exists platform_promo_codes_sa_read_v961 on public.platform_promo_codes_v961;
create policy platform_promo_codes_sa_read_v961 on public.platform_promo_codes_v961
  for select to authenticated using (app.is_super_admin());

drop policy if exists platform_promo_redemptions_sa_read_v961 on public.platform_promo_redemptions_v961;
create policy platform_promo_redemptions_sa_read_v961 on public.platform_promo_redemptions_v961
  for select to authenticated using (app.is_super_admin());

drop policy if exists platform_promo_redemptions_member_read_v961 on public.platform_promo_redemptions_v961;
create policy platform_promo_redemptions_member_read_v961 on public.platform_promo_redemptions_v961
  for select to authenticated using (app.is_salon_member(business_id));

/* The table ACL, stated rather than inherited. A policy without a grant is inert — the role never
   reaches the table to be filtered — and a grant without a policy is a leak, so both are written
   here together. SELECT only for the browser roles: every write goes through a SECURITY DEFINER
   RPC above, which runs as the owner and needs no client privilege at all. anon reaches neither
   table; a promo is a merchant's billing fact, never public. */
revoke all on table public.platform_promo_codes_v961 from public, anon, authenticated;
grant select on table public.platform_promo_codes_v961 to authenticated;

revoke all on table public.platform_promo_redemptions_v961 from public, anon, authenticated;
grant select on table public.platform_promo_redemptions_v961 to authenticated;

-- ---------------------------------------------------------------------------------------------
-- 4. The one piece of arithmetic, so every caller rounds the same way.
--    Bankers' rounding is deliberately NOT used: round() on numeric rounds half away from zero,
--    which is what a merchant checking "20% of $148.00 is $29.60" will do on their own phone.
-- ---------------------------------------------------------------------------------------------
create or replace function app.promo_discount_cents_v961(
  p_kind text, p_percent_bps integer, p_amount_cents integer, p_list_cents integer
)
returns integer
language sql
immutable
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select case
    when p_list_cents is null or p_list_cents <= 0 then null
    when p_kind = 'amount' then least(coalesce(p_amount_cents, 0), p_list_cents)
    when p_kind = 'percent' then least(
      round(p_list_cents::numeric * coalesce(p_percent_bps, 0)::numeric / 10000)::integer,
      p_list_cents)
    else null end
$$;

comment on function app.promo_discount_cents_v961(text, integer, integer, integer) is
  'nestly_v961: the only promo arithmetic. Returns the cents a code takes off a given list amount, never more than the amount itself; NULL when there is no list amount to work from (an amount code still states its own face value).';

-- ---------------------------------------------------------------------------------------------
-- 5. Creating and retiring codes (super admin).
-- ---------------------------------------------------------------------------------------------
create or replace function public.platform_create_promo_code_v961(
  p_code text,
  p_discount_kind text,
  p_percent_bps integer,
  p_amount_cents integer,
  p_business uuid,
  p_max_redemptions integer,
  p_expires_on date,
  p_note text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_code text := upper(btrim(coalesce(p_code, '')));
  v_row public.platform_promo_codes_v961%rowtype;
begin
  if v_actor is null or not app.is_super_admin() then
    raise exception 'super_admin_required' using errcode = '42501';
  end if;
  if length(v_code) not between 3 and 64 then
    raise exception 'promo_code_length' using errcode = '22023';
  end if;
  -- A code is typed by a human off a voucher, so keep it to characters that survive that trip.
  if v_code !~ '^[A-Z0-9_-]+$' then
    raise exception 'promo_code_charset' using errcode = '22023';
  end if;
  if p_discount_kind not in ('percent', 'amount') then
    raise exception 'promo_discount_kind_invalid' using errcode = '22023';
  end if;
  if p_discount_kind = 'percent' and coalesce(p_percent_bps, 0) not between 1 and 10000 then
    raise exception 'promo_percent_out_of_range' using errcode = '22023';
  end if;
  if p_discount_kind = 'amount' and coalesce(p_amount_cents, 0) < 1 then
    raise exception 'promo_amount_out_of_range' using errcode = '22023';
  end if;
  if p_business is not null
     and not exists (select 1 from public.businesses b where b.id = p_business) then
    raise exception 'business_not_found' using errcode = '22023';
  end if;
  if p_expires_on is not null and p_expires_on < app.sg_today() then
    raise exception 'promo_expiry_in_the_past' using errcode = '22023';
  end if;
  if exists (select 1 from public.platform_promo_codes_v961 c where c.code_norm = v_code) then
    raise exception 'promo_code_already_exists' using errcode = '23505';
  end if;

  insert into public.platform_promo_codes_v961(
    code, discount_kind, percent_bps, amount_cents, restricted_business_id,
    max_redemptions, expires_on, note, created_by, updated_by)
  values (
    v_code, p_discount_kind,
    case when p_discount_kind = 'percent' then p_percent_bps end,
    case when p_discount_kind = 'amount' then p_amount_cents end,
    p_business, p_max_redemptions, p_expires_on,
    left(nullif(btrim(coalesce(p_note, '')), ''), 1000), v_actor, v_actor)
  returning * into v_row;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'promo_code_created', 'platform_promo_codes_v961', v_row.id,
    jsonb_build_object('source', 'platform_console_v961', 'code', v_row.code_norm,
      'discount_kind', v_row.discount_kind, 'percent_bps', v_row.percent_bps,
      'amount_cents', v_row.amount_cents, 'restricted_business_id', v_row.restricted_business_id,
      'max_redemptions', v_row.max_redemptions, 'expires_on', v_row.expires_on));

  return to_jsonb(v_row);
end
$$;

comment on function public.platform_create_promo_code_v961(text, text, integer, integer, uuid, integer, date, text) is
  'nestly_v961: super-admin creates a promo code — percent or fixed amount, optionally locked to one business, optionally capped and dated.';

create or replace function public.platform_set_promo_code_active_v961(
  p_promo uuid, p_active boolean, p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_row public.platform_promo_codes_v961%rowtype;
begin
  if v_actor is null or not app.is_super_admin() then
    raise exception 'super_admin_required' using errcode = '42501';
  end if;
  if length(btrim(coalesce(p_reason, ''))) not between 3 and 1000 then
    raise exception 'promo_reason_required' using errcode = '22023';
  end if;
  update public.platform_promo_codes_v961
     set active = coalesce(p_active, false), updated_by = v_actor, updated_at = now()
   where id = p_promo
  returning * into v_row;
  if v_row.id is null then
    raise exception 'promo_code_not_found' using errcode = '42704';
  end if;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (v_row.restricted_business_id, v_actor,
    case when v_row.active then 'promo_code_reactivated' else 'promo_code_deactivated' end,
    'platform_promo_codes_v961', v_row.id,
    jsonb_build_object('source', 'platform_console_v961', 'code', v_row.code_norm,
      'reason', btrim(p_reason)));
  -- Deactivating retires the code for FUTURE redemptions. Redemptions already made keep the terms
  -- they snapshotted: a merchant who was promised 20% is not quietly un-promised it.
  return to_jsonb(v_row);
end
$$;

comment on function public.platform_set_promo_code_active_v961(uuid, boolean, text) is
  'nestly_v961: super-admin retires or revives a promo code. Never alters redemptions already made — those carry their own snapshotted terms.';

create or replace function public.platform_list_promo_codes_v961()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_items jsonb;
begin
  if auth.uid() is null or not app.is_super_admin() then
    raise exception 'super_admin_required' using errcode = '42501';
  end if;
  select coalesce(jsonb_agg(item order by item->>'created_at' desc), '[]'::jsonb) into v_items
  from (
    select to_jsonb(c) || jsonb_build_object(
      'business_name', b.name,
      'live_redemptions', (select count(*) from public.platform_promo_redemptions_v961 r
                            where r.promo_id = c.id and r.removed_at is null),
      'consumed_redemptions', (select count(*) from public.platform_promo_redemptions_v961 r
                                where r.promo_id = c.id and r.removed_at is null and r.consumed_at is not null),
      'expired', (c.expires_on is not null and c.expires_on < app.sg_today())
    ) as item
    from public.platform_promo_codes_v961 c
    left join public.businesses b on b.id = c.restricted_business_id
  ) rows;
  return jsonb_build_object('items', v_items, 'as_of', now());
end
$$;

comment on function public.platform_list_promo_codes_v961() is
  'nestly_v961: super-admin list of every promo code with its redemption counts and whether it has expired.';

-- ---------------------------------------------------------------------------------------------
-- 6. Redemption — the merchant's own owner, or a super admin acting for them. One path, one set
--    of rules, so "applied by the console" and "typed by the merchant" can never diverge.
-- ---------------------------------------------------------------------------------------------
create or replace function public.business_redeem_promo_code_v961(
  p_business uuid, p_code text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_is_sa boolean;
  v_code text := upper(btrim(coalesce(p_code, '')));
  v_promo public.platform_promo_codes_v961%rowtype;
  v_existing public.platform_promo_redemptions_v961%rowtype;
  v_row public.platform_promo_redemptions_v961%rowtype;
  v_provider text;
begin
  if v_actor is null then
    raise exception 'authenticated account required' using errcode = '28000';
  end if;
  v_is_sa := app.is_super_admin();
  if not v_is_sa and not exists (
    select 1 from public.staff s
     where s.business_id = p_business and s.user_id = v_actor and s.role = 'owner' and s.active
  ) then
    raise exception 'active owner of this business required' using errcode = '42501';
  end if;

  select billing_provider into v_provider from public.subscriptions where business_id = p_business;
  if v_provider is null then
    raise exception 'no subscription exists for this business' using errcode = '42704';
  end if;
  -- RULING B. The provider owns what it charges; a code here would not reach it.
  if v_provider <> 'manual' then
    raise exception 'promo_provider_billed' using errcode = '22023';
  end if;

  -- RULING C. One promo per business, ever — the first payment happens once.
  select * into v_existing from public.platform_promo_redemptions_v961
   where business_id = p_business and removed_at is null for update;
  if v_existing.id is not null then
    if v_existing.consumed_at is not null then
      raise exception 'promo_already_used' using errcode = '22023';
    end if;
    if v_existing.promo_id = (select id from public.platform_promo_codes_v961 where code_norm = v_code) then
      return jsonb_build_object('status', 'already_redeemed', 'redemption_id', v_existing.id,
        'discount_kind', v_existing.discount_kind, 'percent_bps', v_existing.percent_bps,
        'amount_cents', v_existing.amount_cents);
    end if;
    raise exception 'promo_already_held' using errcode = '22023';
  end if;

  select * into v_promo from public.platform_promo_codes_v961 where code_norm = v_code for update;
  -- A wrong code, a retired code, an expired code, a used-up code and a code belonging to ANOTHER
  -- firm all answer identically. Anything else turns this box into an oracle for which codes exist
  -- and who holds them.
  if v_promo.id is null
     or not v_promo.active
     or (v_promo.expires_on is not null and v_promo.expires_on < app.sg_today())
     or (v_promo.restricted_business_id is not null and v_promo.restricted_business_id <> p_business)
     or (v_promo.max_redemptions is not null and v_promo.redeemed_count >= v_promo.max_redemptions)
  then
    raise exception 'promo_code_not_found' using errcode = '22023';
  end if;

  insert into public.platform_promo_redemptions_v961(
    promo_id, business_id, redeemed_by, redeemed_by_super_admin,
    discount_kind, percent_bps, amount_cents, currency)
  values (v_promo.id, p_business, v_actor, v_is_sa,
    v_promo.discount_kind, v_promo.percent_bps, v_promo.amount_cents, v_promo.currency)
  returning * into v_row;

  update public.platform_promo_codes_v961
     set redeemed_count = redeemed_count + 1, updated_at = now()
   where id = v_promo.id;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'promo_code_redeemed', 'platform_promo_redemptions_v961', v_row.id,
    jsonb_build_object('source', case when v_is_sa then 'platform_console_v961' else 'business_billing_v961' end,
      'code', v_promo.code_norm, 'discount_kind', v_row.discount_kind,
      'percent_bps', v_row.percent_bps, 'amount_cents', v_row.amount_cents));

  return jsonb_build_object('status', 'ok', 'redemption_id', v_row.id, 'code', v_promo.code_norm,
    'discount_kind', v_row.discount_kind, 'percent_bps', v_row.percent_bps,
    'amount_cents', v_row.amount_cents, 'currency', v_row.currency);
end
$$;

comment on function public.business_redeem_promo_code_v961(uuid, text) is
  'nestly_v961: a business owner (or a super admin acting for them) redeems a promo code against their FIRST payment. Manual billing only. Every rejection answers promo_code_not_found so the box cannot enumerate codes.';

-- ---------------------------------------------------------------------------------------------
-- 7. What the two surfaces read.
-- ---------------------------------------------------------------------------------------------
create or replace function public.business_get_promo_state_v961(p_business uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_row public.platform_promo_redemptions_v961%rowtype;
  v_code text;
  v_provider text;
begin
  if v_actor is null then
    raise exception 'authenticated account required' using errcode = '28000';
  end if;
  /* The SAME gate as redemption, deliberately: whoever may redeem it may see it. app.is_salon_member
     was the first draft and was wrong here — it requires app.business_operational_v620, so a firm
     that is trialing and awaiting its very first payment fails it, and that is precisely the firm a
     first-payment promo belongs to. The owner would have redeemed a code and then been unable to
     read it back. */
  if not app.is_super_admin() and not exists (
    select 1 from public.staff s
     where s.business_id = p_business and s.user_id = v_actor and s.role = 'owner' and s.active
  ) then
    raise exception 'active owner of this business required' using errcode = '42501';
  end if;

  select billing_provider into v_provider from public.subscriptions where business_id = p_business;
  select * into v_row from public.platform_promo_redemptions_v961
   where business_id = p_business and removed_at is null;
  if v_row.id is null then
    return jsonb_build_object('business_id', p_business, 'has_promo', false,
      'can_redeem', coalesce(v_provider, '') = 'manual', 'provider', v_provider);
  end if;
  select code_norm into v_code from public.platform_promo_codes_v961 where id = v_row.promo_id;
  return jsonb_build_object(
    'business_id', p_business, 'has_promo', true, 'can_redeem', false, 'provider', v_provider,
    'code', v_code,
    'discount_kind', v_row.discount_kind, 'percent_bps', v_row.percent_bps,
    'amount_cents', v_row.amount_cents, 'currency', v_row.currency,
    'redeemed_at', v_row.redeemed_at,
    'consumed_at', v_row.consumed_at,
    'consumed_list_cents', v_row.consumed_list_cents,
    'consumed_discount_cents', v_row.consumed_discount_cents,
    'consumed_payment_reference', v_row.consumed_payment_reference);
end
$$;

comment on function public.business_get_promo_state_v961(uuid) is
  'nestly_v961: the pending or consumed promo for one business, readable by that business''s members and by a super admin. The merchant billing page and the console firm record both read THIS, so neither can show a different promo from the other.';

-- ---------------------------------------------------------------------------------------------
-- 8. Removing a pending redemption (super admin) — swapping one voucher for another before the
--    payment happens. A CONSUMED redemption is history and is never removed.
-- ---------------------------------------------------------------------------------------------
create or replace function public.platform_remove_promo_redemption_v961(
  p_business uuid, p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_row public.platform_promo_redemptions_v961%rowtype;
begin
  if v_actor is null or not app.is_super_admin() then
    raise exception 'super_admin_required' using errcode = '42501';
  end if;
  if length(btrim(coalesce(p_reason, ''))) not between 3 and 1000 then
    raise exception 'promo_reason_required' using errcode = '22023';
  end if;
  select * into v_row from public.platform_promo_redemptions_v961
   where business_id = p_business and removed_at is null for update;
  if v_row.id is null then
    raise exception 'no_promo_to_remove' using errcode = '42704';
  end if;
  if v_row.consumed_at is not null then
    raise exception 'promo_already_used' using errcode = '22023';
  end if;

  update public.platform_promo_redemptions_v961
     set removed_at = now(), removed_by = v_actor, removed_reason = btrim(p_reason)
   where id = v_row.id;
  -- The code gets its allowance back, so a mistaken application does not burn a capped voucher.
  update public.platform_promo_codes_v961
     set redeemed_count = greatest(redeemed_count - 1, 0), updated_at = now()
   where id = v_row.promo_id;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'promo_redemption_removed', 'platform_promo_redemptions_v961',
    v_row.id, jsonb_build_object('source', 'platform_console_v961', 'reason', btrim(p_reason),
      'promo_id', v_row.promo_id));

  return jsonb_build_object('status', 'ok', 'business_id', p_business);
end
$$;

comment on function public.platform_remove_promo_redemption_v961(uuid, text) is
  'nestly_v961: super-admin removes a PENDING promo redemption and returns the allowance to the code. A consumed redemption is history and is refused.';

-- ---------------------------------------------------------------------------------------------
-- 9. Consuming it. Recording a payment is what spends a first-payment promo.
--    app.promo_consume_v961 is called from platform_record_subscription_payment_v664 (patched in
--    the same migration, by extract-and-diff, so the recorder keeps every other behaviour it has).
-- ---------------------------------------------------------------------------------------------
create or replace function app.promo_consume_v961(
  p_business uuid, p_amount_cents integer, p_payment_reference text
)
returns void
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_row public.platform_promo_redemptions_v961%rowtype;
  v_discount integer;
begin
  select * into v_row from public.platform_promo_redemptions_v961
   where business_id = p_business and removed_at is null and consumed_at is null
   for update skip locked;
  if v_row.id is null then
    return;
  end if;
  -- The amount recorded is the amount collected. The discount is stated against it for the record;
  -- nothing here rewrites the money a human just typed.
  v_discount := app.promo_discount_cents_v961(
    v_row.discount_kind, v_row.percent_bps, v_row.amount_cents, p_amount_cents);

  update public.platform_promo_redemptions_v961
     set consumed_at = now(),
         consumed_payment_reference = p_payment_reference,
         consumed_list_cents = p_amount_cents,
         consumed_discount_cents = coalesce(v_discount, 0)
   where id = v_row.id;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, auth.uid(), 'promo_code_consumed', 'platform_promo_redemptions_v961',
    v_row.id, jsonb_build_object('source', 'app.promo_consume_v961',
      'discount_kind', v_row.discount_kind, 'percent_bps', v_row.percent_bps,
      'amount_cents', v_row.amount_cents,
      'recorded_payment_cents', p_amount_cents,
      'stated_discount_cents', coalesce(v_discount, 0),
      'payment_reference', p_payment_reference));
end
$$;

comment on function app.promo_consume_v961(uuid, integer, text) is
  'nestly_v961: marks a business''s pending promo redemption spent against a recorded payment. Never changes the recorded amount — the person recording it owns that number.';

-- ---------------------------------------------------------------------------------------------
-- 9b. The recorder now spends the promo. Restated in full rather than text-patched: the whole
--     function is fifteen lines of validation around one delegate call, so restating it is easier
--     to read and to review than an extract-and-diff, and every line below is byte-identical to
--     the live body except the two marked ones. The delegate keeps its own idempotency (v_key), and
--     app.promo_consume_v961 is a no-op once the redemption is consumed, so a replayed call with
--     the same key spends nothing twice.
-- ---------------------------------------------------------------------------------------------
create or replace function public.platform_record_subscription_payment_v664(
  p_business uuid,
  p_reason text,
  p_period_end timestamptz,
  p_cadence text default null,
  p_paid_at timestamptz default null,
  p_amount_cents integer default null,
  p_payment_reference text default null,
  p_idempotency_key uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_paid_at timestamptz := coalesce(p_paid_at, now());
  v_key text := 'v664-manual-payment:'||coalesce(p_idempotency_key::text,'');
  v_result jsonb;                                            -- nestly_v961
begin
  if v_actor is null or not app.is_super_admin() then
    raise exception 'super_admin_required' using errcode = '42501';
  end if;
  if length(coalesce(btrim(p_reason),'')) < 8 then
    raise exception 'a reason of at least 8 characters is required' using errcode = '22023';
  end if;
  if p_idempotency_key is null then
    raise exception 'an idempotency key is required' using errcode = '22023';
  end if;
  if p_period_end is null or p_period_end <= v_paid_at then
    raise exception 'the paid-through date must be after the payment date' using errcode = '22023';
  end if;
  if p_period_end > now() + interval '400 days' then
    raise exception 'a paid-through date more than 400 days out is not recordable here'
      using errcode = '22023';
  end if;
  if p_cadence is not null and p_cadence not in ('monthly','annual') then
    raise exception 'cadence must be monthly or annual' using errcode = '22023';
  end if;
  v_result := app.v680_apply_paid_period(
    p_business, p_period_end, v_key, btrim(p_reason), v_actor, 'platform_rpc_v664',
    null, null, null, p_cadence, v_paid_at, p_amount_cents, p_payment_reference);
  perform app.promo_consume_v961(p_business, p_amount_cents, p_payment_reference); -- nestly_v961
  return v_result;
end
$$;

comment on function public.platform_record_subscription_payment_v664(uuid, text, timestamptz, text, timestamptz, integer, text, uuid) is
  'nestly_v664 + v961: super-admin records a manual subscription payment. v961: recording it also spends any pending first-payment promo redemption, stating the discount against the amount recorded without altering it.';

-- ---------------------------------------------------------------------------------------------
-- 10. Grants. Codes are super-admin only; redemption and state are reachable by a signed-in
--     merchant owner (the function itself decides which business they may touch).
-- ---------------------------------------------------------------------------------------------
revoke all on function public.platform_record_subscription_payment_v664(uuid, text, timestamptz, text, timestamptz, integer, text, uuid) from public, anon;
grant execute on function public.platform_record_subscription_payment_v664(uuid, text, timestamptz, text, timestamptz, integer, text, uuid) to authenticated, service_role;

/* NOT granted to authenticated. It is only ever called from inside the SECURITY DEFINER RPCs
   above, which run as the owner and already have execute; a browser grant would widen the app
   schema's exposed surface for nothing, and db/tests/executed/v720_corpus_evidence_pack_grants.sql
   is right to refuse any app.* function reaching anon/authenticated without a stated reason. */
revoke all on function app.promo_discount_cents_v961(text, integer, integer, integer) from public, anon, authenticated;
grant execute on function app.promo_discount_cents_v961(text, integer, integer, integer) to service_role;

revoke all on function app.promo_consume_v961(uuid, integer, text) from public, anon, authenticated;
grant execute on function app.promo_consume_v961(uuid, integer, text) to service_role;

revoke all on function public.platform_create_promo_code_v961(text, text, integer, integer, uuid, integer, date, text) from public, anon;
grant execute on function public.platform_create_promo_code_v961(text, text, integer, integer, uuid, integer, date, text) to authenticated, service_role;

revoke all on function public.platform_set_promo_code_active_v961(uuid, boolean, text) from public, anon;
grant execute on function public.platform_set_promo_code_active_v961(uuid, boolean, text) to authenticated, service_role;

revoke all on function public.platform_list_promo_codes_v961() from public, anon;
grant execute on function public.platform_list_promo_codes_v961() to authenticated, service_role;

revoke all on function public.business_redeem_promo_code_v961(uuid, text) from public, anon;
grant execute on function public.business_redeem_promo_code_v961(uuid, text) to authenticated, service_role;

revoke all on function public.business_get_promo_state_v961(uuid) from public, anon;
grant execute on function public.business_get_promo_state_v961(uuid) to authenticated, service_role;

revoke all on function public.platform_remove_promo_redemption_v961(uuid, text) from public, anon;
grant execute on function public.platform_remove_promo_redemption_v961(uuid, text) to authenticated, service_role;

commit;
