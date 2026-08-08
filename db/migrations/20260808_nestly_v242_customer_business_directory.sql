-- V242 — the customer sees every business in the ecosystem, joined or not.
--
-- Owner: "for customer end i need customer to view all businesses - within the ecosystem -
-- then show (not set up) for businesses that they yet to scan QRcode. and they able to see
-- each customised points (existing infrastructure). the rewards are customised to each
-- company and not shared."
--
-- One reader, authenticated customers only. Joined = a verified, un-unlinked customer link
-- for the caller; those rows carry that business's OWN points balance and earn rate. An
-- unjoined business exposes only what its public join page already shows (name, slug,
-- brand colour, sector, earn rate) — no balances, no customer data, and deliberately no
-- signal about anyone else. Rewards stay per-business by construction: every reward,
-- ledger row and link is keyed by business_id, and this function never crosses that key.
begin;
create or replace function public.customer_list_business_directory_v242()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_actor uuid := auth.uid();
  v_result jsonb;
begin
  if v_actor is null then
    raise exception 'authenticated customer required' using errcode='28000';
  end if;
  select coalesce(jsonb_agg(entry order by (entry->>'joined') desc, entry->>'name'), '[]'::jsonb)
    into v_result
  from (
    select jsonb_build_object(
      'business_id', b.id,
      'name', b.name,
      'slug', b.slug,
      'brand_color', b.brand_color,
      'industry', b.industry,
      'joined', (cl.id is not null),
      'points_balance', case when cl.id is null then null else coalesce((
        select sum(pl.points) from public.points_ledger pl
         where pl.business_id = b.id and pl.client_id = cl.client_id), 0) end,
      'earn_points_per_dollar', lp.earn_points_per_dollar,
      'loyalty_model', lp.loyalty_model,
      'points_mode', b.points_mode
    ) as entry
    from public.businesses b
    left join public.customer_links cl
      on cl.business_id = b.id and cl.auth_user_id = v_actor
     and cl.state = 'verified' and cl.unlinked_at is null
    left join public.loyalty_programs lp
      on lp.business_id = b.id and lp.active
    where b.join_enabled
  ) listed;
  return v_result;
end
$function$;

revoke all on function public.customer_list_business_directory_v242() from public, anon;
grant execute on function public.customer_list_business_directory_v242() to authenticated;
commit;
