-- FRENLY v4 — atomic onboarding. Fixes RLS chicken-and-egg on first business:
-- INSERT..RETURNING requires SELECT policy (member-only), impossible pre-membership.
create or replace function public.create_business(
  p_name text, p_slug text, p_industry text, p_modules text[])
returns json language plpgsql security definer set search_path = public as $$
declare v_uid uuid; rec businesses;
begin
  v_uid := auth.uid();
  if v_uid is null then raise exception 'sign in required'; end if;
  if p_name is null or length(trim(p_name)) < 2 then raise exception 'business name required'; end if;
  insert into businesses (name, slug, industry, enabled_modules)
  values (trim(p_name), p_slug, coalesce(p_industry,'other'),
          coalesce(p_modules, array['dashboard','clients','sales','loyalty','retention','referrals']))
  returning * into rec;
  insert into staff (business_id, user_id, role, full_name)
  values (rec.id, v_uid, 'owner', coalesce(auth.jwt()->>'email','Owner'));
  insert into loyalty_programs (business_id, kind, earn_points_per_dollar,
                                redeem_points, reward_credit_cents, active)
  values (rec.id, 'points', 1, 800, 2000, true);
  insert into audit_log (business_id, actor, action, entity, entity_id, detail)
  values (rec.id, v_uid, 'ONBOARD', 'businesses', rec.id,
          json_build_object('name', rec.name, 'industry', rec.industry)::jsonb);
  return row_to_json(rec);
end $$;
revoke execute on function public.create_business(text, text, text, text[]) from public, anon;
grant execute on function public.create_business(text, text, text, text[]) to authenticated;