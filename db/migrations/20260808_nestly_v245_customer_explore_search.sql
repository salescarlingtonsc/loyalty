-- Nestly v245 — Explore: search the Peekaa ecosystem the way you'd search Google.
--
-- Numbering: filed as v245 because a concurrent session claimed v244 twice on main while this
-- was in flight. The FUNCTION keeps the name it was applied to production with,
-- customer_explore_businesses_v244 — the client already calls it, and a rename would be churn.
--
-- Owner (nav revamp, Grab-style reference): "explore = search for nearby peekaa businessess
-- (can type example food near me, chicken rice, dessert shop etc) - then will pop up relevant
-- business based on search - like google search)".
--
-- v242 already lists every join-enabled business with the caller's own joined/balance state.
-- What it cannot do is answer "chicken rice" — the thing a customer types is usually WHAT THEY
-- WANT, not the shop's name, and only the server knows which businesses sell chicken rice. This
-- function is the v242 projection plus:
--   * token search: the query is split into words, filler dropped ("near", "me", "shop"…), and
--     every remaining word must match the business name, industry, an active service name or an
--     active product name. AND semantics — "chicken rice" finds sellers of chicken rice, not
--     every business with "chicken" plus every business with "rice".
--   * a match_note naming the first service/product that matched, so the result can say WHY it
--     appeared ("Sells: Chicken Rice") instead of looking arbitrary;
--   * logo_url, and the default branch's address and phone — an explore result the customer may
--     travel to needs a place, which the join page for that business already shows;
--   * booking_enabled, so a result can offer Book only when the business actually takes bookings.
--
-- Isolation mirrors v242 exactly: an unjoined row can never carry a balance, the caller's link
-- is the only link consulted, and nothing crosses business_id. Anonymous has no EXECUTE.
-- No trigram/FTS index at this scale (tens of businesses); ilike over the join is measured in
-- microseconds, and the shape can move to pg_trgm without a contract change if the directory
-- ever grows to thousands.

begin;

create or replace function public.customer_explore_businesses_v244(p_query text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $function$
declare
  v_actor uuid := auth.uid();
  v_tokens text[];
  v_result jsonb;
begin
  if v_actor is null then
    raise exception 'authenticated customer required' using errcode='28000';
  end if;

  select coalesce(array_agg(word), '{}')
    into v_tokens
  from (
    select lower(word) as word
    from regexp_split_to_table(coalesce(p_query,''), '[^[:alnum:]]+') word
    where length(word) between 2 and 40
      and lower(word) not in ('near','me','nearby','the','shop','shops','store','stores','place','places','in','at','for','a','an')
    limit 6
  ) cleaned;

  select coalesce(jsonb_agg(entry order by (entry->>'joined') desc, entry->>'name'), '[]'::jsonb)
    into v_result
  from (
    select jsonb_build_object(
      'business_id', b.id,
      'name', b.name,
      'slug', b.slug,
      'brand_color', b.brand_color,
      'industry', b.industry,
      'logo_url', app.v95_public_media_url(logo.object_path),
      'joined', (cl.id is not null),
      'points_balance', case when cl.id is null then null else coalesce((
        select sum(pl.points) from public.points_ledger pl
         where pl.business_id = b.id and pl.client_id = cl.client_id), 0) end,
      'earn_points_per_dollar', lp.earn_points_per_dollar,
      'loyalty_model', lp.loyalty_model,
      'points_mode', b.points_mode,
      'address', branch.address,
      'phone', branch.phone,
      'booking_enabled', coalesce(b.booking_policy is not null and exists(
        select 1 from public.services s where s.business_id=b.id and s.active), false),
      'match_note', matched.note
    ) as entry
    from public.businesses b
    left join public.customer_links cl
      on cl.business_id = b.id and cl.auth_user_id = v_actor
     and cl.state = 'verified' and cl.unlinked_at is null
    left join public.loyalty_programs lp
      on lp.business_id = b.id and lp.active
    left join public.business_brand_presentation_v95 brand
      on brand.business_id = b.id
    left join public.business_media_assets_v95 logo
      on logo.id = brand.logo_asset_id and logo.business_id = b.id
     and logo.asset_kind = 'logo' and logo.customer_visible
    left join lateral (
      select br.address, br.phone from public.branches br
      where br.business_id = b.id and coalesce(br.active,true)
      order by br.is_default desc, br.created_at, br.id limit 1
    ) branch on true
    left join lateral (
      -- the first catalogue item any token matched, so the card can say why it is here
      select min(item.name) as note
      from (
        select s.name from public.services s where s.business_id=b.id and s.active
        union all
        select p.name from public.products p where p.business_id=b.id and coalesce(p.active,true)
      ) item
      where cardinality(v_tokens) > 0
        and exists(select 1 from unnest(v_tokens) t where item.name ilike '%'||t||'%')
    ) matched on true
    where b.join_enabled
      and (
        cardinality(v_tokens) = 0
        or not exists (
          select 1 from unnest(v_tokens) t
          where not (
            b.name ilike '%'||t||'%'
            or coalesce(b.industry,'') ilike '%'||t||'%'
            or exists(select 1 from public.services s
                       where s.business_id=b.id and s.active and s.name ilike '%'||t||'%')
            or exists(select 1 from public.products p
                       where p.business_id=b.id and coalesce(p.active,true) and p.name ilike '%'||t||'%')
          )
        )
      )
  ) listed;

  return v_result;
end
$function$;

comment on function public.customer_explore_businesses_v244(text) is
  'v244: Explore search over the join-enabled directory. Tokenised AND match on business name, '
  'industry, active service and product names; unjoined rows never carry a balance; the match_note '
  'names the first catalogue item a token hit so results can explain themselves.';

revoke all on function public.customer_explore_businesses_v244(text) from public, anon;
grant execute on function public.customer_explore_businesses_v244(text) to authenticated;

commit;
