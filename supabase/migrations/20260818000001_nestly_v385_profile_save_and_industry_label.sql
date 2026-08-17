-- Nestly v385 — the Business Profile save, and the firm's own words for what it does.
--
-- Two owner findings from the 2026-08-17 screenshot review, one of them a live outage.
--
-- 1. NOBODY COULD SAVE THEIR BUSINESS PROFILE.
--    v313 installed a statement trigger on public.businesses that fires after an update of
--    place_id, postal_code, legal_name or name, and calls app.v311_match_merchants(). Neither
--    function is SECURITY DEFINER and neither is executable by `authenticated` (proacl is
--    {postgres=X/postgres} on both). PostgreSQL checks EXECUTE on a trigger function at
--    CREATE TRIGGER time, not when it fires, so the trigger itself ran — and then died on the
--    inner call. Every owner pressing Save on Business Profile got
--        42501  permission denied for function v311_match_merchants
--    which the app prints as "You don't have access to do that. Ask an owner to check your
--    permissions." Reproduced against production as the Cubbly owner and rolled back.
--
--    The fix is on the TRIGGER function, not on the matcher. Making the trigger SECURITY
--    DEFINER lets its inner call run as the definer, exactly as v313's own bootstrap
--    `select app.v311_match_merchants(null)` did when it ran as postgres. The matcher stays
--    revoked from anon and authenticated: it sweeps every tenant's prospect rows and no
--    end user has any business calling it directly. Granting EXECUTE instead would have fixed
--    the same symptom by opening that door, which is the worse trade.
--
-- 2. businesses.industry_label — the line a customer reads under the business name.
--    The workspace Industry select is Peekaa's sector taxonomy; it shapes defaults elsewhere,
--    so it stays a fixed list. It is also, until now, the only thing the customer app could
--    print there, and "Facial / Spa" is Peekaa's word for a sector rather than a given firm's
--    word for itself (owner: "might be facial and not spa"). This column is that firm's own
--    wording. NULL means "use the sector", so every existing firm keeps today's behaviour and
--    no backfill is needed.
--
-- Safety: additive and reversible. The column is nullable with no default, so the ADD COLUMN
-- takes no table rewrite. No row is read or written by this migration.

begin;

-- ---------------------------------------------------------------------------
-- 1. The Business Profile save
-- ---------------------------------------------------------------------------
create or replace function app.v311_on_business_merchant_link()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
begin
  perform app.v311_match_merchants(null);
  return null;
end $function$;

-- Restated verbatim from the live proacl of both functions ({postgres=X/postgres}): neither is
-- callable by any client role, and this migration must not quietly widen that.
revoke all on function app.v311_on_business_merchant_link() from public, anon, authenticated;
revoke all on function app.v311_match_merchants(uuid) from public, anon, authenticated;

comment on function app.v311_on_business_merchant_link() is
  'v385: SECURITY DEFINER so the prospect matcher it calls runs as the definer. Without it every
   owner UPDATE of businesses.name or legal_name raised 42501 and the Business Profile could not
   be saved by anyone.';

-- ---------------------------------------------------------------------------
-- 2. The customer-facing industry wording
-- ---------------------------------------------------------------------------
alter table public.businesses
  add column if not exists industry_label text;

do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.businesses'::regclass
       and conname = 'businesses_industry_label_len'
  ) then
    alter table public.businesses
      add constraint businesses_industry_label_len
      check (industry_label is null or char_length(btrim(industry_label)) between 1 and 60);
  end if;
end $$;

comment on column public.businesses.industry_label is
  'v385: the firm''s own wording for what it does, shown under its name in the customer app.
   NULL = fall back to the industry sector label.';

-- UPDATE on public.businesses is granted column by column on this database, so a new column is
-- not writable until it is named. SELECT is table-level and already covers it.
grant update (industry_label) on public.businesses to authenticated;

-- ---------------------------------------------------------------------------
-- 3. The customer read
-- ---------------------------------------------------------------------------
-- Replaced from the live definition with one key added, so nothing else about this function's
-- behaviour moves.
CREATE OR REPLACE FUNCTION public.customer_get_business_summary(p_business_slug text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_actor uuid := auth.uid();
  v_context record;
  v_summary jsonb;
begin
  if v_actor is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;
  if not app.platform_feature_enabled('customer_wallet') then
    raise exception 'customer wallet is not enabled' using errcode = '0A000';
  end if;

  select identity_id, business_id, client_id, business_name, business_slug,
         business_industry, business_currency, enabled_modules into v_context
    from app.v32_customer_wallet_context(p_business_slug)
   limit 1;
  if not found then
    raise exception 'verified customer link required' using errcode = '42501';
  end if;

  select jsonb_build_object(
    'business', jsonb_build_object(
      'id', v_context.business_id,
      'slug', v_context.business_slug,
      'name', v_context.business_name,
      'industry', v_context.business_industry,
      -- V385: the firm's OWN wording for what it does, shown under the business name in the
      -- customer app. Read straight off the row rather than added to the wallet context, so the
      -- context view keeps the shape every other caller of it already depends on.
      'industry_label', (select b.industry_label from public.businesses b where b.id = v_context.business_id),
      'currency', v_context.business_currency,
      'logo_url', app.v267_business_logo_url(v_context.business_id),
      'review_url', (select b.review_url from public.businesses b where b.id = v_context.business_id)
    ),
    'loyalty', app.customer_live_loyalty_v384(
      v_context.business_id, v_context.client_id, v_context.enabled_modules, now()
    ),
    'packages', jsonb_build_object(
      'enabled', 'packages' = any(v_context.enabled_modules),
      'active_count', case when 'packages' = any(v_context.enabled_modules) then coalesce((
        select count(*)::integer
          from public.client_packages cp
         where cp.business_id = v_context.business_id
           and cp.client_id = v_context.client_id
           and cp.status = 'active'
           and cp.remaining > 0
      ), 0) else 0 end,
      'sessions_remaining', case when 'packages' = any(v_context.enabled_modules) then coalesce((
        select sum(cp.remaining)::integer
          from public.client_packages cp
         where cp.business_id = v_context.business_id
           and cp.client_id = v_context.client_id
           and cp.status = 'active'
           and cp.remaining > 0
      ), 0) else 0 end
    ),
    'membership', jsonb_build_object(
      'enabled', 'memberships' = any(v_context.enabled_modules),
      'active', case when 'memberships' = any(v_context.enabled_modules) then exists (
        select 1 from public.memberships m
         where m.business_id = v_context.business_id
           and m.client_id = v_context.client_id
           and m.status in ('active', 'paused', 'cancel_at_period_end')
      ) else false end,
      'current_period_ends_at', case when 'memberships' = any(v_context.enabled_modules) then (
        select min(m.current_period_end)
          from public.memberships m
         where m.business_id = v_context.business_id
           and m.client_id = v_context.client_id
           and m.status in ('active', 'paused', 'cancel_at_period_end')
      ) end
    ),
    'upcoming_appointments', jsonb_build_object(
      'enabled', 'appointments' = any(v_context.enabled_modules),
      'count', case when 'appointments' = any(v_context.enabled_modules) then (
        select count(*)::integer
          from public.appointments a
         where a.business_id = v_context.business_id
           and a.client_id = v_context.client_id
           and a.status = 'booked'
           and a.starts_at >= now()
      ) else 0 end
    )
  ) into v_summary;

  return v_summary;
end;
$function$;


revoke all on function public.customer_get_business_summary(text) from public, anon;
grant execute on function public.customer_get_business_summary(text) to authenticated, service_role;

commit;
