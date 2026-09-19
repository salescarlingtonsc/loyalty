-- nestly_v999 — the Home card stops telling the owner to chase people who asked to be erased.
--
-- OWNER, 2026-09-16: "continue testing until the business view is 100/100 fully tested and bugs free."
-- Found by the business-view sweep; confirmed by executing the reader as each tenant's real owner.
--
-- THE DEFECT. public.get_attention_list_v548 feeds the Home "Regulars overdue - SGD X a month at
-- stake" tile and the Bring-back card. Its whole purpose is to put names in front of the owner and
-- prompt them to get in touch. It filters out synthetic fixtures; it has never filtered out people
-- who exercised their right to erasure.
--
-- MEASURED, running the RPC as each tenant's owner principal inside a rolled-back transaction:
--     Cubbly SPA      2 flagged, 2 erased   (100%)
--     QA Kaya Toast   1 flagged, 1 erased   (100%)
--     3 of the 6 people flagged across the whole estate had a client_erasures_v290 row
-- One of the recorded erasure reasons is "customer deleted their own Peekaa account".
--
-- WHAT IT IS AND IS NOT. No message could actually have gone out, and saying so matters more than
-- the headline: erase_client_v290 nulls clients.phone, and 0 of the 21 erased clients on this estate
-- have one, so every send path is already dead for them. nestly-v551-retention-dispatch is inactive
-- besides. The live harm is the SCREEN -- the owner is shown a row for someone who asked to be
-- forgotten and told to win them back. That is a privacy-adjacent product defect, not a breach.
--
-- THE NEIGHBOURING READER IS ALREADY SAFE, and it is worth recording why rather than patching it
-- too. public.preview_campaign_audience_v155 filters on marketing_consent, and erase_client_v290
-- sets marketing_consent = false in the same statement that anonymises the row -- so erased people
-- fall out of every campaign audience through a gate that already exists. I checked instead of
-- assuming, and then left it alone. Consent is the right gate for marketing; it is NOT the right
-- gate for the attention list, which is an operational "who has stopped coming" view, not a
-- marketing audience -- which is exactly why v548 does not read consent and needed its own answer.
--
-- ONE AUTHORITY. app.client_is_erased_v999 is the single predicate for "this person asked to be
-- erased". It exists because 15 outreach-shaped functions in this database reference clients and not
-- one of them mentions client_erasures_v290; the next reader that needs this should call the
-- predicate rather than re-derive the join. Only the reader with a demonstrated live defect is
-- changed here -- the others are listed in the commit message with what each one actually does, so
-- the follow-up is a decision rather than a rediscovery.
--
-- Rollback suite: db/tests/v999_the_attention_list_forgets_erased_people.sql

begin;

do $v999_assert$
declare v_body text := pg_get_functiondef('public.get_attention_list_v548(uuid,uuid,integer)'::regprocedure);
begin
  if position('client_is_erased_v999' in v_body) > 0 then
    raise exception 'v999: get_attention_list_v548 already carries v999';
  end if;
  if position('coalesce(c.is_synthetic, false) = false' in v_body) = 0 then
    raise exception 'v999: get_attention_list_v548 has drifted -- the synthetic filter is not where this migration expects it';
  end if;
end
$v999_assert$;

-- ---------------------------------------------------------------------------------------------
-- 1 · The one predicate for "this person asked to be erased".
-- ---------------------------------------------------------------------------------------------
create or replace function app.client_is_erased_v999(p_business uuid, p_client uuid)
returns boolean
language sql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select exists (
    select 1 from public.client_erasures_v290 e
     where e.business_id = p_business and e.client_id = p_client
  );
$$;

revoke all on function app.client_is_erased_v999(uuid,uuid) from public, anon, authenticated;
grant execute on function app.client_is_erased_v999(uuid,uuid) to service_role;

comment on function app.client_is_erased_v999(uuid,uuid) is
  'nestly_v999: true when this client has a recorded PDPA erasure. The one authority for that question; outreach readers must exclude these people.';

-- ---------------------------------------------------------------------------------------------
-- 2 · The reader that was naming them.
-- ---------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_attention_list_v548(p_business uuid, p_branch uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 8)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_now timestamptz := now();
  v_window constant integer := 365;
  v_limit integer := greatest(1, least(50, coalesce(p_limit, 8)));
  v_result jsonb;
begin
  -- Same gate the customer book applies (raises 42501 for outsiders).
  perform public.require_module_scope_v145(p_business, p_branch, 'clients');

  with raw_visits as (
    select s.client_id, s.occurred_at,
      app.v106_sale_residual_minor(s.id, v_now) as amount_cents
    from public.sales s
    where s.business_id = p_business
      and (p_branch is null or s.branch_id = p_branch)
      and s.client_id is not null
      and s.counts_as_visit
      and s.reversal_of is null
      and s.occurred_at >= v_now - make_interval(days => v_window)
      and s.occurred_at < v_now
      and app.v106_sale_residual_minor(s.id, v_now) > 0
      and not exists (
        select 1 from public.sales r
        where r.business_id = s.business_id and r.reversal_of = s.id
      )
  ),
  visit_days as (
    -- nestly_v724 (estate sweep 2): collapse same-day sales (a split bill) into ONE visit-day per
    -- client via the one visit-day authority (app.ci_visit_day_v699, nestly_v699), anchored at the
    -- day's FIRST qualifying sale's occurred_at (same anchor rule as nestly_v709/v711/v714);
    -- amounts summed per day so average_transaction_cents/monthly_at_risk_cents totals reflect the
    -- true per-visit spend -- only the visit-count/cadence denominator collapses.
    select client_id, app.ci_visit_day_v699(occurred_at) as visit_day,
           min(occurred_at) as occurred_at,
           sum(amount_cents) as amount_cents
    from raw_visits
    group by client_id, app.ci_visit_day_v699(occurred_at)
  ),
  visits as (
    select vd.client_id, vd.occurred_at, vd.amount_cents,
      extract(epoch from (
        vd.occurred_at - lag(vd.occurred_at) over (
          partition by vd.client_id order by vd.occurred_at
        )
      )) / 86400.0 as interval_days
    from visit_days vd
  ),
  metrics as (
    select v.client_id,
      count(*)::integer as prior_visits,
      max(v.occurred_at) as last_visit_at,
      percentile_cont(0.5) within group (order by v.interval_days)
        filter (where v.interval_days is not null) as cadence_days_raw,
      floor(extract(epoch from (v_now - max(v.occurred_at))) / 86400)::integer as lapse_days,
      round(avg(v.amount_cents))::bigint as average_transaction_cents
    from visits v
    group by v.client_id
  ),
  judged as (
    -- The clients join sits HERE, not only on the flagged rows, so that the
    -- synthetic exclusion also governs the 'considered' count: a demo fixture
    -- must not inflate any number this function reports.
    select m.client_id, m.prior_visits, m.last_visit_at, m.lapse_days,
      m.average_transaction_cents,
      c.full_name, c.phone,
      greatest(m.cadence_days_raw, 1.0) as cadence_days,
      round(m.average_transaction_cents * 30.0
        / greatest(m.cadence_days_raw, 1.0))::bigint as monthly_value_cents,
      case
        when m.lapse_days >= greatest(7, ceil(greatest(m.cadence_days_raw, 1.0) * 2.5)) then 'slipping'
        when m.lapse_days >= greatest(7, ceil(greatest(m.cadence_days_raw, 1.0) * 1.5)) then 'overdue'
        when m.lapse_days >= greatest(7, ceil(greatest(m.cadence_days_raw, 1.0)))       then 'due'
        else null
      end as status
    from metrics m
    join public.clients c on c.id = m.client_id and c.business_id = p_business
    where m.prior_visits >= 3 and m.cadence_days_raw is not null
      and coalesce(c.is_synthetic, false) = false
      /* nestly_v999: a person who asked to be erased is not a regular to chase. This list is the
         source of the Home "Regulars overdue" tile and the Bring-back card, whose whole purpose is
         to prompt the owner to contact the people on it. Measured before this shipped: 3 of the 6
         people flagged estate-wide had a client_erasures_v290 row, and on Cubbly SPA and QA Kaya
         Toast it was every single one. */
      and not app.client_is_erased_v999(p_business, c.id)
  ),
  flagged as (
    select j.* from judged j where j.status is not null
  )
  select jsonb_build_object(
    'summary', jsonb_build_object(
      'considered', (select count(*) from judged),
      'due',      (select count(*) from flagged where status = 'due'),
      'overdue',  (select count(*) from flagged where status = 'overdue'),
      'slipping', (select count(*) from flagged where status = 'slipping'),
      'monthly_at_risk_cents', (
        select coalesce(sum(monthly_value_cents), 0)
        from flagged where status in ('overdue', 'slipping')
      ),
      'one_time_count', (
        select count(*)
        from metrics m
        join public.clients c on c.id = m.client_id and c.business_id = p_business
        where m.prior_visits = 1 and m.lapse_days >= 30
          and coalesce(c.is_synthetic, false) = false
          and not app.client_is_erased_v999(p_business, c.id)   /* nestly_v999, as above */
      )
    ),
    'rows', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'client_id', t.client_id,
        'full_name', t.full_name,
        'phone', t.phone,
        'last_visit_at', t.last_visit_at,
        'last_visit_days', t.lapse_days,
        'cadence_days', round(t.cadence_days::numeric, 1),
        'status', t.status,
        'average_transaction_cents', t.average_transaction_cents,
        'monthly_value_cents', t.monthly_value_cents
      ) order by t.ord), '[]'::jsonb)
      from (
        select f.*, row_number() over (
          order by (f.status = 'due')::int asc,
                   f.monthly_value_cents desc,
                   f.lapse_days desc,
                   f.client_id
        ) as ord
        from flagged f
        order by (f.status = 'due')::int asc,
                 f.monthly_value_cents desc,
                 f.lapse_days desc,
                 f.client_id
        limit v_limit
      ) t
    )
  )
  into v_result;

  return v_result;
end;
$function$;


-- Signature unchanged, so CREATE OR REPLACE preserved the grants; restated from the live proacl per
-- the repo's preflight rule.
revoke all on function public.get_attention_list_v548(uuid,uuid,integer) from public, anon;
grant execute on function public.get_attention_list_v548(uuid,uuid,integer) to authenticated, service_role;

commit;
