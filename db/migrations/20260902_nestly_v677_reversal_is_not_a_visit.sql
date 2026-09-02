-- NESTLY v677 — a reversed sale is not a visit.
--
-- THE DEFECT (audit F061). `app.on_sale_policy_snapshot` copies the original's policy
-- flags onto the compensating row a reversal writes, so every reversal sale carries
-- counts_as_visit = true (prod: 9 of 9). The original is immutable and keeps its own
-- true. Four readers counted visits as a bare
--
--     select count(*) from public.sales
--      where business_id = ... and client_id = ... and counts_as_visit
--
-- with no netting, so REVERSING a sale ADDED a visit instead of taking one away:
-- original + reversal = 2 where the truth is 0.
--
--   * app.tier_resolve_v426                         — the canonical tier resolver, and
--     therefore app.loyalty_tier_for's points multiplier inside app.on_sale_recorded,
--     public.customer_get_effective_tier_v143, and app.tier_observe_v1 (which fires on
--     the reversal row itself through zzz_tier_observe_sale_v633).
--   * public.lookup_client_by_phone                 — the till's phone lookup.
--   * app.v666_till_customer_card                   — the till's customer card.
--   * public.customer_get_business_presentation_v95 — the customer's own app.
--
-- Every other visit reader in the estate (~40: dashboards, customer lists, cadence,
-- campaigns, retention audiences) already nets reversals, and so does the client's own
-- validVisitSales(). The four above were the only disagreement — confirmed against
-- production by listing every function and view whose body mentions counts_as_visit
-- and does not mention reversal_of. That list is exactly:
--
--     app.tier_resolve_v426                         <- reader, fixed here
--     app.v666_till_customer_card                   <- reader, fixed here
--     public.lookup_client_by_phone                 <- reader, fixed here
--     public.customer_get_business_presentation_v95 <- reader, fixed here
--     app.sale_policy, app.sale_policy_defaults, app.sale_policy_set,
--     public.set_sale_policy, app.ps1c_plan_checkout, view v_program_rules_all
--                                                   <- these DEFINE or NAME the flag;
--                                                      none of them counts sales rows.
--
-- THE FIX IS AT THE AUTHORITY, NOT PER READER. `app.client_qualifying_visits_v677`
-- becomes the one place that answers "how many visits does this customer have", using
-- the predicate the rest of the estate already uses (nestly_v244 states it in prose:
-- a reversal row is never itself a visit, and an original is discounted when a
-- reversal referencing it exists inside the counts_as_visit set). The four readers
-- delegate to it.
--
-- WHAT THIS MIGRATION DELIBERATELY DOES NOT DO: it does not change what
-- app.on_sale_policy_snapshot writes on a reversal row. Flipping counts_as_visit to
-- false there would be a second authority for the same fact, it would not be enough on
-- its own (the reversed ORIGINAL would still count once), and it would silently change
-- the meaning of the ~40 readers that already do their own netting. The snapshot stays
-- an honest copy of the original's policy; the readers do the arithmetic.
--
-- HOW THE FOUR ARE PATCHED. Each is a one-line substitution inside a body this
-- migration must otherwise reproduce byte for byte, so each is rewritten from its own
-- live pg_get_functiondef with a guard that fails closed (42883 if the function is
-- gone, XX001 if the line this migration expects is no longer there) rather than from
-- a transcription that could silently drift. This is the same extract-and-diff shape
-- as nestly_v474 and nestly_v566.
--
-- AFTER APPLYING: run `npm run tenant-gate` — this touches the loyalty and tier
-- engines.

begin;

-- ---------------------------------------------------------------------------------------------
-- 1. THE AUTHORITY.
--
-- One function, one fact. The CTE is scoped to the client on purpose:
-- public.reverse_sale_v34_base writes the compensating row with the ORIGINAL's business_id and
-- client_id (verified against all 9 reversal rows in production), and it refuses to reverse a
-- reversal, so a client-scoped set always holds both halves of every pair and never a chain.
-- ---------------------------------------------------------------------------------------------

create or replace function app.client_qualifying_visits_v677(
  p_business uuid,
  p_client uuid
)
returns integer
language sql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
  with visit_rows as (
    select s.id, s.reversal_of
      from public.sales s
     where s.business_id = p_business
       and s.client_id   = p_client
       and s.counts_as_visit
  )
  select count(*)::integer
    from visit_rows v
   where v.reversal_of is null
     and not exists (
       select 1 from visit_rows r where r.reversal_of = v.id
     );
$function$;

comment on function app.client_qualifying_visits_v677(uuid, uuid) is
  'nestly_v677: the one answer to "how many qualifying visits does this customer have". A '
  'reversal row is never itself a visit, and an original is discounted once a reversal '
  'referencing it exists inside the counts_as_visit set — the predicate nestly_v244 and the '
  'client''s validVisitSales() already use. Callers: app.tier_resolve_v426, '
  'public.lookup_client_by_phone, app.v666_till_customer_card, '
  'public.customer_get_business_presentation_v95.';

-- ---------------------------------------------------------------------------------------------
-- 2. THE TIER RESOLVER — the visits branch of app.tier_resolve_v426.
-- ---------------------------------------------------------------------------------------------
do $outer$
declare
  v_src text;
  v_old constant text := $marker$    select count(*) into v_metric
      from public.sales
     where business_id = p_business and client_id = p_client and counts_as_visit;$marker$;
  v_new constant text := $marker$    -- nestly_v677: a reversed sale is not a visit. This read the raw counts_as_visit set,
    -- so a refund pushed the tier metric UP by two instead of back to zero.
    v_metric := app.client_qualifying_visits_v677(p_business, p_client);$marker$;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'tier_resolve_v426';
  if v_src is null then
    raise exception 'app.tier_resolve_v426 is missing' using errcode = '42883';
  end if;
  if position(v_old in v_src) = 0 then
    raise exception 'app.tier_resolve_v426 no longer has the visits-count line this migration patches'
      using errcode = 'XX001';
  end if;
  execute replace(v_src, v_old, v_new);
end $outer$;

-- ---------------------------------------------------------------------------------------------
-- 3. THE TILL'S PHONE LOOKUP — public.lookup_client_by_phone.
-- ---------------------------------------------------------------------------------------------
do $outer$
declare
  v_src text;
  v_old constant text := $marker$  select count(*) into v_visits
    from public.sales where business_id=p_business and client_id=c.id and counts_as_visit;$marker$;
  v_new constant text := $marker$  -- nestly_v677: net the reversals, so the till agrees with Customers and Reports.
  v_visits := app.client_qualifying_visits_v677(p_business, c.id);$marker$;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'lookup_client_by_phone';
  if v_src is null then
    raise exception 'public.lookup_client_by_phone is missing' using errcode = '42883';
  end if;
  if position(v_old in v_src) = 0 then
    raise exception 'public.lookup_client_by_phone no longer has the visits-count line this migration patches'
      using errcode = 'XX001';
  end if;
  execute replace(v_src, v_old, v_new);
end $outer$;

-- ---------------------------------------------------------------------------------------------
-- 4. THE TILL'S CUSTOMER CARD — app.v666_till_customer_card.
-- ---------------------------------------------------------------------------------------------
do $outer$
declare
  v_src text;
  v_old constant text := $marker$  select count(*) into v_visits
    from public.sales where business_id=p_business and client_id=v_client.id and counts_as_visit;$marker$;
  v_new constant text := $marker$  -- nestly_v677: net the reversals, so the card agrees with Customers and Reports.
  v_visits := app.client_qualifying_visits_v677(p_business, v_client.id);$marker$;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'v666_till_customer_card';
  if v_src is null then
    raise exception 'app.v666_till_customer_card is missing' using errcode = '42883';
  end if;
  if position(v_old in v_src) = 0 then
    raise exception 'app.v666_till_customer_card no longer has the visits-count line this migration patches'
      using errcode = 'XX001';
  end if;
  execute replace(v_src, v_old, v_new);
end $outer$;

-- ---------------------------------------------------------------------------------------------
-- 5. THE CUSTOMER'S OWN APP — public.customer_get_business_presentation_v95.
-- ---------------------------------------------------------------------------------------------
do $outer$
declare
  v_src text;
  v_old constant text := $marker$    select count(*) into v_metric from public.sales
    where business_id=p_business and client_id=v_client and counts_as_visit;$marker$;
  v_new constant text := $marker$    -- nestly_v677: a reversed sale is not a visit, here as in app.tier_resolve_v426.
    v_metric := app.client_qualifying_visits_v677(p_business, v_client);$marker$;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'customer_get_business_presentation_v95';
  if v_src is null then
    raise exception 'public.customer_get_business_presentation_v95 is missing' using errcode = '42883';
  end if;
  if position(v_old in v_src) = 0 then
    raise exception 'public.customer_get_business_presentation_v95 no longer has the visits-count line this migration patches'
      using errcode = 'XX001';
  end if;
  execute replace(v_src, v_old, v_new);
end $outer$;

-- ---------------------------------------------------------------------------------------------
-- 6. ACL. Signatures are unchanged, so CREATE OR REPLACE preserved every grant; restated from the
--    live proacl per the repo's preflight rule. The new helper is an app.* internal: reachable
--    only from the SECURITY DEFINER functions that own the surface, never from a client role.
-- ---------------------------------------------------------------------------------------------

revoke all on function app.client_qualifying_visits_v677(uuid, uuid) from public, anon, authenticated;

revoke all on function app.tier_resolve_v426(uuid, uuid, timestamptz) from public, anon, authenticated;

revoke all on function app.v666_till_customer_card(uuid, uuid) from public, anon, authenticated;

revoke all on function public.lookup_client_by_phone(uuid, text) from public, anon;
grant execute on function public.lookup_client_by_phone(uuid, text) to authenticated, service_role;

revoke all on function public.customer_get_business_presentation_v95(uuid, uuid, text) from public, anon;
grant execute on function public.customer_get_business_presentation_v95(uuid, uuid, text) to authenticated, service_role;

commit;
