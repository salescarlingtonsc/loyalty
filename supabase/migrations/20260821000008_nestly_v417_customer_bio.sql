-- nestly_v417 — the company bio reaches the customer.
--
-- OWNER, 2026-08-21 (photo 7): "(shown on your portal)" struck off the Company bio label, and an
-- arrow drawn from the field itself to the line under the business name in the customer app —
-- "show here as bio".
--
-- businesses.bio has existed since v325 and the Business Profile page has always written it, but
-- NO customer-facing read has ever returned it: customer_get_business_summary carries name,
-- industry, industry_label, currency, logo and review_url, and stopped there. So every word a
-- firm typed into "Company bio" was visible only to the firm that typed it, under a label that
-- promised it was on their portal. That is the whole defect; the parenthetical was removed in the
-- same batch because it was describing a place the bio never appeared.
--
-- One key added to one jsonb payload, the same shape v385 used for industry_label — a scalar
-- subquery off public.businesses, so app.v32_customer_wallet_context keeps the exact shape every
-- other caller of it depends on. The body below was EXTRACTED from production and patched
-- programmatically, then diffed: 7 added lines, 6 of them this comment.

begin;

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
      -- nestly_v417 (owner, photo 7: an arrow from the workspace's "Company bio" field to the line
      -- under the business name in the customer app, "show here as bio"). The column has existed
      -- since v325 and the workspace has always edited it; no customer read ever returned it, so
      -- everything a firm wrote there was only ever visible to the firm. Same shape as
      -- industry_label above: a scalar subquery off the row, leaving v32_customer_wallet_context
      -- untouched for every other caller.
      'bio', (select b.bio from public.businesses b where b.id = v_context.business_id),
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
