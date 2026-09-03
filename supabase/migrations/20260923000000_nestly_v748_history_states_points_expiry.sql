-- nestly_v748 — an earn row on the customer's Activity says when those points expire.
--
-- OWNER (2026-09-03, photo 5, against the customer Activity list): "when points earned > it should
-- clearly state the expiry date per points earned."
--
-- THE GAP. Points expiry has existed since v3 (three modes, batches, a daily pg_cron sweep) and
-- public.points_batches has carried expires_at that whole time, but no customer-facing reader ever
-- surfaced it PER EVENT. The wallet could tell a customer how many points they held and, in the
-- expiry band, that some were going soon; it could not answer "these 164 — when do they go?",
-- which is the only question a row on the history list raises.
--
-- THE FIX. customer_get_transaction_history_v81 emits one new key, `points_expires_at`, resolved
-- from the batch the earn actually created:
--   · sale rows join public.points_batches on sale_id — an exact link, written by
--     app.on_sale_recorded in the same transaction as the ledger row, so it cannot be attributed
--     to the wrong sale. min() because a sale writes one batch and min of one is that one; it also
--     keeps the answer honest ("the earliest of these expires then") should a sale ever write two.
--   · standalone earns (adjust_points, a referral payout) have no sale to join on, so they match
--     the batch this business wrote for this client within five seconds of the ledger row. Both
--     writers insert the pair inside one statement, so the window is generous rather than tight;
--     a miss returns null and the row simply says nothing, which is what it says today.
-- A programme with no expiry configured leaves expires_at null and the row is unchanged. The key
-- is ADDITIVE: nothing is removed or renamed, `||` in the v167/v469 wrapper carries it through
-- untouched, and a client that ignores it renders exactly as before.
--
-- Read-only. No table, column, policy or grant changes; the function is replaced in place and its
-- grants are restated verbatim from the live proacl.

begin;

CREATE OR REPLACE FUNCTION public.customer_get_transaction_history_v81(p_business_slug text, p_cursor jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_context record;
  v_cursor jsonb := coalesce(p_cursor, '{}'::jsonb);
  v_limit integer := 20;
  v_before_at timestamptz;
  v_before_order integer;
  v_before_id uuid;
  v_result jsonb;
begin
  if auth.uid() is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;
  if jsonb_typeof(v_cursor) <> 'object'
     or exists (
       select 1
         from jsonb_object_keys(v_cursor) as cursor_keys(key)
        where key not in ('limit', 'before_at', 'before_order', 'before_id')
     ) then
    raise exception 'invalid transaction history cursor' using errcode = '22023';
  end if;
  begin
    v_limit := least(greatest(coalesce((v_cursor->>'limit')::integer, 20), 1), 50);
    v_before_at := nullif(v_cursor->>'before_at', '')::timestamptz;
    v_before_order := nullif(v_cursor->>'before_order', '')::integer;
    v_before_id := nullif(v_cursor->>'before_id', '')::uuid;
  exception when others then
    raise exception 'invalid transaction history cursor' using errcode = '22023';
  end;
  if num_nonnulls(v_before_at, v_before_order, v_before_id) not in (0, 3)
     or (v_before_order is not null and v_before_order not in (1, 2)) then
    raise exception 'transaction history cursor is incomplete' using errcode = '22023';
  end if;

  select * into v_context
    from app.v32_customer_wallet_context(p_business_slug)
   limit 1;
  if not found then
    raise exception 'verified customer link required' using errcode = '42501';
  end if;

  with sale_events as (
    select
      sale.id as source_id,
      sale.occurred_at as event_at,
      2 as event_order,
      'sale'::text as source_kind,
      case when sale.reversal_of is null then 'sale' else 'sale_reversal' end
        as event_type,
      case
        when sale.reversal_of is not null then 'reversal'
        when reversal.id is not null then 'reversed'
        else 'completed'
      end as status,
      branch.name as branch_name,
      sale.kind as sale_kind,
      sale.amount_cents::integer as gross_cents,
      case when sale.reversal_of is not null then 0
        else (sale.amount_cents + coalesce(reversal.amount_cents, 0))::integer
      end as net_cents,
      coalesce(points.points_earned, 0)::integer as points_earned,
      coalesce(points.points_redeemed, 0)::integer as points_redeemed,
      coalesce(points.points_removed, 0)::integer as points_removed,
      points.loyalty_unit as loyalty_unit,
      /* nestly_v748: the deadline on the points THIS sale earned. */
      expiry.points_expires_at as points_expires_at,
      case when sale.reversal_of is not null then sale.reversal_of else reversal.id end
        as related_source_id,
      case sale.kind
        when 'quick_sale' then 'Purchase'
        when 'service' then 'Service purchase'
        when 'retail' then 'Retail purchase'
        when 'membership' then 'Membership purchase'
        else 'Purchase'
      end as description,
      coalesce((
        select jsonb_agg(jsonb_build_object(
          'item_id', item.id,
          'item_type', item.item_type,
          'description', item.description,
          'qty', item.qty,
          'unit_cents', item.unit_cents,
          'line_cents', item.line_cents
        ) order by item.created_at, item.id)
          from public.sale_items item
         where item.business_id = sale.business_id
           and item.sale_id = sale.id
      ), '[]'::jsonb) as line_items
      from public.sales sale
      left join public.branches branch
        on branch.business_id = sale.business_id
       and branch.id = sale.branch_id
      left join lateral (
        select reversal_sale.id, reversal_sale.amount_cents
          from public.sales reversal_sale
         where reversal_sale.business_id = sale.business_id
           and reversal_sale.reversal_of = sale.id
         order by reversal_sale.occurred_at desc, reversal_sale.id desc
         limit 1
      ) reversal on true
      left join lateral (
        select
          coalesce(sum(ledger.points) filter (where ledger.points > 0), 0)::integer
            as points_earned,
          abs(coalesce(sum(ledger.points) filter (
            where ledger.points < 0 and ledger.entry_type = 'redeem'
          ), 0))::integer as points_redeemed,
          abs(coalesce(sum(ledger.points) filter (
            where ledger.points < 0 and ledger.entry_type <> 'redeem'
          ), 0))::integer as points_removed,
          /* nestly_v437: the pot these rows actually live in. */
          (array_agg(spine.kind order by ledger.created_at, ledger.id)
             filter (where spine.kind is not null))[1] as loyalty_unit
          from public.points_ledger ledger
          left join public.business_programmes spine
            on spine.id = ledger.programme_id
         where ledger.business_id = sale.business_id
           and ledger.client_id = sale.client_id
           and ledger.sale_id = sale.id
      ) points on true
      /* nestly_v748: the batch this sale created, joined on sale_id — the link
         app.on_sale_recorded writes itself, so it can never name another sale's points. */
      left join lateral (
        select min(batch.expires_at) as points_expires_at
          from public.points_batches batch
         where batch.business_id = sale.business_id
           and batch.client_id = sale.client_id
           and batch.sale_id = sale.id
           and batch.expires_at is not null
      ) expiry on true
     where sale.business_id = v_context.business_id
       and sale.client_id = v_context.client_id
  ), standalone_point_events as (
    select
      ledger.id as source_id,
      ledger.created_at as event_at,
      1 as event_order,
      'points_ledger'::text as source_kind,
      'points_' || ledger.entry_type as event_type,
      'completed'::text as status,
      null::text as branch_name,
      null::text as sale_kind,
      null::integer as gross_cents,
      null::integer as net_cents,
      greatest(ledger.points, 0)::integer as points_earned,
      case when ledger.entry_type = 'redeem'
        then greatest(-ledger.points, 0) else 0 end::integer as points_redeemed,
      case when ledger.entry_type <> 'redeem'
        then greatest(-ledger.points, 0) else 0 end::integer as points_removed,
      spine.kind as loyalty_unit,
      /* nestly_v748: no sale to join on, so the batch is matched by when it was written. */
      expiry.points_expires_at as points_expires_at,
      null::uuid as related_source_id,
      /* nestly_v437: the noun follows the ROW's pot, not the live programme (owner rule 13). */
      case when spine.kind = 'stamps' then
        case ledger.entry_type
          when 'earn' then 'Stamps earned'
          when 'redeem' then 'Stamps redeemed'
          when 'expire' then 'Stamps expired'
          when 'adjust' then 'Stamps adjustment'
          else 'Loyalty activity'
        end
      else
        case ledger.entry_type
          when 'earn' then 'Points earned'
          when 'redeem' then 'Points redeemed'
          when 'expire' then 'Points expired'
          when 'adjust' then 'Points adjustment'
          else 'Loyalty activity'
        end
      end as description,
      '[]'::jsonb as line_items
      from public.points_ledger ledger
      left join public.business_programmes spine
        on spine.id = ledger.programme_id
      left join lateral (
        select batch.expires_at as points_expires_at
          from public.points_batches batch
         where ledger.points > 0
           and batch.business_id = ledger.business_id
           and batch.client_id = ledger.client_id
           and batch.sale_id is null
           and batch.expires_at is not null
           and batch.earned_at between ledger.created_at - interval '5 seconds'
                                   and ledger.created_at + interval '5 seconds'
         order by abs(extract(epoch from (batch.earned_at - ledger.created_at)))
         limit 1
      ) expiry on true
     where ledger.business_id = v_context.business_id
       and ledger.client_id = v_context.client_id
       and ledger.sale_id is null
  ), history as (
    select * from sale_events
    union all
    select * from standalone_point_events
  ), eligible as (
    select *
      from history
     where v_before_at is null
        or (event_at, event_order, source_id)
           < (v_before_at, v_before_order, v_before_id)
     order by event_at desc, event_order desc, source_id desc
     limit v_limit + 1
  ), visible as (
    select *
      from eligible
     order by event_at desc, event_order desc, source_id desc
     limit v_limit
  )
  select jsonb_build_object(
    'business', jsonb_build_object(
      'slug', v_context.business_slug,
      'name', v_context.business_name,
      'currency', v_context.business_currency
    ),
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'source_kind', source_kind,
        'source_id', source_id,
        'event_at', event_at,
        'event_type', event_type,
        'status', status,
        'branch_name', branch_name,
        'sale_kind', sale_kind,
        'gross_cents', gross_cents,
        'net_cents', net_cents,
        'points_earned', points_earned,
        'points_redeemed', points_redeemed,
        'points_removed', points_removed,
        'loyalty_unit', loyalty_unit,
        'points_expires_at', points_expires_at,
        'related_source_id', related_source_id,
        'description', description,
        'line_items', line_items
      ) order by event_at desc, event_order desc, source_id desc)
        from visible
    ), '[]'::jsonb),
    'next_cursor', case when (select count(*) from eligible) > v_limit then (
      select jsonb_build_object(
        'before_at', event_at,
        'before_order', event_order,
        'before_id', source_id,
        'limit', v_limit
      )
        from visible
       order by event_at, event_order, source_id
       limit 1
    ) else null end
  ) into v_result;

  return v_result;
end;
$function$;

-- Grants restated verbatim from the live proacl
-- ({postgres=X/postgres,service_role=X/postgres,authenticated=X/postgres}); CREATE OR REPLACE
-- preserves them, but the preflight requires them written out.
revoke all on function public.customer_get_transaction_history_v81(p_business_slug text, p_cursor jsonb) from public, anon;
grant execute on function public.customer_get_transaction_history_v81(p_business_slug text, p_cursor jsonb) to authenticated, service_role;

commit;
