-- nestly_v393 — customer tier visibility
--
-- FINDING (wave-4 audit follow-up, 2026-08-19): no customer-facing reader ever emitted tier
-- data. public.customer_get_wallet nests app.customer_live_loyalty_v384, which emits
-- model/unit/balances only; customer_get_loyalty_details and customer_list_programmes_v89
-- carry no tier either. Every tier pill a customer has ever seen in a demo came from the QA
-- double's fabricated `tier_name` field — on production, a firm with a live Tier membership
-- programme shows its customers nothing.
--
-- FIX, in two parts:
--
-- 1) app.customer_tier_json_v393(business, client) — a DISPLAY-grade tier snapshot. It mirrors
--    app.v365_client_tier's basis metric (spend / points_earned / visits) but additionally
--    filters paused and soft-deleted ladder rows (v365 is the CHECKOUT authority and is
--    deliberately not touched here), and adds the next rung: name, threshold, and remaining
--    distance, so the customer app can draw tier progress, not just a label.
--
-- 2) app.customer_live_loyalty_v384 gains one additive key: 'tier'. It is DOUBLE-gated — the
--    key is non-null only when the tiers spine row is active (the same lateral join the
--    function already computes), and the helper itself returns null when the ladder is empty.
--    Because business_switch_to_stamps_v384 writes the spine {stamps:true, points:false,
--    tiers:false}, switching a firm to stamps makes the customer's tier vanish in the same
--    transaction — the exclusivity the owner specified, now observable end to end.
--    The existing keys and the 'programmes_contract' marker are byte-identical to before;
--    nothing that reads v384 today can break on an added key.

begin;

set search_path = pg_catalog, public, app, pg_temp;

create or replace function app.customer_tier_json_v393(p_business_id uuid, p_client_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_basis  text;
  v_metric numeric := 0;
  v_cur    public.loyalty_tiers%rowtype;
  v_next   public.loyalty_tiers%rowtype;
begin
  select coalesce(tier_basis, 'visits') into v_basis
    from public.loyalty_programs
   where business_id = p_business_id and active
   limit 1;

  if v_basis = 'spend' then
    select coalesce(sum(amount_cents), 0) / 100.0 into v_metric
      from public.sales
     where business_id = p_business_id and client_id = p_client_id and counts_as_revenue;
  elsif v_basis = 'points_earned' then
    select coalesce(sum(points), 0) into v_metric
      from public.points_ledger
     where business_id = p_business_id and client_id = p_client_id and entry_type = 'earn';
  else
    select count(*) into v_metric
      from public.sales
     where business_id = p_business_id and client_id = p_client_id and counts_as_visit;
  end if;

  select * into v_cur
    from public.loyalty_tiers
   where business_id = p_business_id
     and threshold <= v_metric
     and coalesce(paused, false) = false
     and deleted_at is null
     and (effective_from is null or effective_from <= statement_timestamp())
     and (expires_at is null or expires_at > statement_timestamp())
   order by threshold desc, sort desc, id
   limit 1;

  select * into v_next
    from public.loyalty_tiers
   where business_id = p_business_id
     and threshold > v_metric
     and coalesce(paused, false) = false
     and deleted_at is null
     and (effective_from is null or effective_from <= statement_timestamp())
     and (expires_at is null or expires_at > statement_timestamp())
   order by threshold asc, sort asc, id
   limit 1;

  if v_cur.id is null and v_next.id is null then
    return null; -- no visible ladder: the customer app draws nothing rather than an empty shell
  end if;

  return jsonb_build_object(
    'name',              v_cur.name,
    'threshold',         v_cur.threshold,
    'perk_note',         v_cur.perk_note,
    'points_multiplier', v_cur.points_multiplier,
    'basis',             v_basis,
    'metric',            v_metric,
    'next', case when v_next.id is null then null else jsonb_build_object(
      'name',      v_next.name,
      'threshold', v_next.threshold,
      'remaining', greatest(v_next.threshold - v_metric, 0)
    ) end
  );
end
$function$;

-- Internal helper: reached only through SECURITY DEFINER wallet readers, exactly like
-- app.customer_live_loyalty_v384 itself (live proacl {postgres=X/postgres} — no API role
-- may call either directly).
revoke all on function app.customer_tier_json_v393(uuid, uuid) from public, anon, authenticated;

create or replace function app.customer_live_loyalty_v384(p_business_id uuid, p_client_id uuid, p_enabled_modules text[], p_as_of timestamp with time zone DEFAULT statement_timestamp())
 returns jsonb
 language sql
 stable security definer
 set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
  with live as (
    select
      points.id as points_programme_id,
      stamps.id as stamps_programme_id,
      tiers.id as tiers_programme_id,
      coalesce(lp.expiry_mode, 'none') as expiry_mode
    from (select 1) scope
    left join public.loyalty_programs lp on lp.business_id = p_business_id
    left join lateral (
      select spine.id
        from public.business_programmes spine
       where spine.business_id = p_business_id
         and spine.kind = 'points'
         and spine.active
       order by spine.sort, spine.id
       limit 1
    ) points on true
    left join lateral (
      select spine.id
        from public.business_programmes spine
       where spine.business_id = p_business_id
         and spine.kind = 'stamps'
         and spine.active
       order by spine.sort, spine.id
       limit 1
    ) stamps on true
    left join lateral (
      select spine.id
        from public.business_programmes spine
       where spine.business_id = p_business_id
         and spine.kind = 'tiers'
         and spine.active
       order by spine.sort, spine.id
       limit 1
    ) tiers on true
  ), selected as (
    select
      case when stamps_programme_id is not null then stamps_programme_id
           else points_programme_id end as programme_id,
      case when stamps_programme_id is not null then 'stamps'
           when points_programme_id is not null then 'points'
           when tiers_programme_id is not null then 'tiers'
           else null end as unit,
      case when stamps_programme_id is not null then 'stamps'
           when points_programme_id is not null and tiers_programme_id is not null then 'both'
           when points_programme_id is not null then 'redeem'
           when tiers_programme_id is not null then 'tiers'
           else null end as model,
      expiry_mode,
      points_programme_id,
      stamps_programme_id,
      tiers_programme_id
    from live
  ), ledger_balance as (
    select greatest(coalesce(sum(pl.points), 0), 0)::integer as units
      from selected s
      left join public.points_ledger pl
        on pl.business_id = p_business_id
       and pl.client_id = p_client_id
       and pl.programme_id = s.programme_id
  ), batch_balance as (
    select greatest(coalesce(sum(pb.remaining), 0), 0)::integer as units
      from selected s
      left join public.points_batches pb
        on pb.business_id = p_business_id
       and pb.client_id = p_client_id
       and pb.programme_id = s.programme_id
       and pb.remaining > 0
       and (pb.expires_at is null or pb.expires_at > p_as_of)
  ), credit as (
    select greatest(coalesce(sum(cl.amount_cents), 0), 0)::integer as cents
      from selected s
      left join public.credit_ledger cl
        on cl.business_id = p_business_id
       and cl.client_id = p_client_id
       and ('loyalty' = any(p_enabled_modules))
       and (s.programme_id is not null or s.tiers_programme_id is not null)
  )
  select jsonb_build_object(
    'enabled', 'loyalty' = any(p_enabled_modules)
      and (selected.programme_id is not null or selected.tiers_programme_id is not null),
    'model', selected.model,
    'unit', selected.unit,
    'balance', case when selected.programme_id is not null
      then least(ledger_balance.units, batch_balance.units) else 0 end,
    'ledger_balance', case when selected.programme_id is not null then ledger_balance.units else 0 end,
    'batch_balance', case when selected.programme_id is not null then batch_balance.units else 0 end,
    'credit_balance_cents', credit.cents,
    'tier', case when selected.tiers_programme_id is not null
      then app.customer_tier_json_v393(p_business_id, p_client_id) else null end,
    'programme', jsonb_build_object(
      'id', selected.programme_id,
      'kind', selected.unit,
      'active', selected.programme_id is not null or selected.tiers_programme_id is not null,
      'balance_scope', 'programme_pot'
    ),
    'programmes_contract', 'v384'
  )
  from selected cross join ledger_balance cross join batch_balance cross join credit;
$function$;

-- Restate the live ACL verbatim (proacl {postgres=X/postgres}): owner-only, no API role.
revoke all on function app.customer_live_loyalty_v384(uuid, uuid, text[], timestamp with time zone) from public, anon, authenticated;

commit;
