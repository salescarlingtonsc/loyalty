-- NESTLY v640 — Phase A follow-up to v637: the public edge gateway holds a slug or a join
-- token, not a business id. Two service-role resolvers let it record funnel hits without a
-- second lookup round-trip. Fire-and-forget semantics preserved: unresolvable input is a
-- silent no-op; the public surface must never fail because of telemetry.
begin;

create or replace function public.internal_public_funnel_hit_by_slug_v640(
  p_slug text, p_surface text, p_step text)
returns void
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_business uuid;
begin
  select b.id into v_business from public.businesses b where b.slug = p_slug;
  if v_business is null then return; end if;
  perform public.internal_public_funnel_hit_v637(v_business, p_surface, p_step);
end;
$$;

create or replace function public.internal_public_funnel_hit_by_join_token_v640(
  p_join_token text, p_surface text, p_step text)
returns void
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_business uuid;
begin
  if length(coalesce(p_join_token, '')) < 32 then return; end if;
  select qr.business_id into v_business
    from public.business_customer_join_qr_v89 qr
   where qr.token_hash = app.v89_sha256(p_join_token);
  if v_business is null then return; end if;
  perform public.internal_public_funnel_hit_v637(v_business, p_surface, p_step);
end;
$$;

revoke all on function public.internal_public_funnel_hit_by_slug_v640(text,text,text) from public, anon, authenticated;
revoke all on function public.internal_public_funnel_hit_by_join_token_v640(text,text,text) from public, anon, authenticated;
grant execute on function public.internal_public_funnel_hit_by_slug_v640(text,text,text) to service_role;
grant execute on function public.internal_public_funnel_hit_by_join_token_v640(text,text,text) to service_role;

commit;
