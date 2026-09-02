-- NESTLY v685 — one Singapore day authority in SQL.
--
-- OWNER RULING (2026-09-02): every date and time in Peekaa is Asia/Singapore (GMT+8),
-- never UTC. Peekaa is a Singapore-first product; a "day" in this product is a Singapore
-- business day and nothing else.
--
-- WHY THIS IS A BUG AND NOT A PREFERENCE. The live Postgres session TimeZone on
-- gadpooereceldfpfxsod is UTC (confirmed on production). So in every function body:
--
--     current_date                 -> the UTC day, 8 hours behind Singapore
--     <timestamptz>::date          -> the UTC day of that instant
--     date_trunc('day', <tstz>)    -> UTC midnight
--     <date>::timestamptz          -> UTC midnight, i.e. 08:00 Singapore time
--
-- Between 16:00 and 24:00 UTC — which is 00:00 to 08:00 the NEXT morning in Singapore,
-- i.e. the first eight hours of every Singapore day — all four are off by one day. A
-- renewal KPI, a commission eligibility date, an overdue clock, a contract obligation
-- window, a bring-back dedupe key and a customer's age were all being decided on the
-- wrong day for a third of every day.
--
-- WHY THERE WAS NOWHERE TO FIX IT. There is no SG date helper in SQL anywhere in this
-- estate (verified twice: repo-wide grep over db/migrations, and a live pg_proc scan).
-- The convention is the literal `at time zone 'Asia/Singapore'` open-coded inline across
-- 88 migration files. That convention has exactly the failure mode you would predict: 14
-- sites drifted, and a reviewer cannot tell "deliberately UTC" from "forgot". §1 below
-- creates the missing authority, and the companion repo guard
-- tests/phase0-foundation/tz-sql-authority.test.mjs makes the invariant greppable so the
-- drift cannot recur in any future migration.
--
-- WHAT THIS MIGRATION CHANGES, SITE BY SITE (ids are from the 2026-09-02 TZ inventory):
--
--   §1  THE AUTHORITY — app.sg_today() / sg_day() / sg_day_start() / sg_month().
--
--   §2  THE READERS AND WRITERS
--   D-01 public.platform_get_subscription_operations_v156
--          "renewing in 30/14/7 days" — the KPI tiles AND the list filter, six
--          `current_date`-bounded predicates. Additionally (found while patching, same
--          defect class, same function): `new_this_month` / `cancelled_this_month`
--          compared a timestamptz against `date_trunc('month', clock_timestamp() at time
--          zone 'Asia/Singapore')`, which is a `timestamp` — the SG wall clock, then
--          re-read as UTC by the comparison. The month therefore started at 08:00 SGT on
--          the 1st. app.sg_day_start(app.sg_month(...)) is the correct instant.
--   D-02 app.accrue_consultant_invoice_v78
--          `paid_at::date` vs employment start. An invoice paid between 00:00 and 08:00
--          SGT on the consultant's own start day was FORFEITED.
--   D-03 public.platform_set_workspace_pause_v622
--          `coalesce(due_date, current_date)` seeds the overdue clock a day early.
--   D-06 app.issue_bringback_for_business_v361  (full CREATE OR REPLACE — short body)
--          `max(created_at)::date` becomes the stored cycle_key (the re-issue dedupe) and
--          the customer-visible "last seen" day.
--   D-07 public.platform_conversion_funnel_v312
--          `current_date::timestamptz` = 08:00 SGT: every funnel bucket shifted 8 hours.
--   D-09 public.refresh_growth_recommendation_v108
--          `date_trunc('day', v_now)` in the bring-back dedupe hash — the daily window
--          rolled at 08:00 SGT. The hash text changes shape once (a timestamp literal
--          becomes a bare date); the only consequence is one extra refresh on first run,
--          which is exactly what the dedupe is for.
--   D-10 public.platform_sweep_stalled_onboarding_v513
--          `current_date::text` is the day suffix of the nudge idempotency key.
--   D-11 app.customer_demographics_v1
--          a customer's age, and therefore their age band, on their birthday.
--   D-12 app.sme_prospect_card_v76
--          `stage_age_days` subtracted a UTC day from a Singapore day — mixed-zone
--          arithmetic, off by one for eight hours a day, every day.
--   D-13 public.platform_generate_subscription_reminders_v156  (full CREATE OR REPLACE)
--          the renewal DECISION was already Singapore; the task dedupe key two lines
--          later was UTC. Internally inconsistent with itself.
--
--   §3  D-04 + D-05 SHIPPED TOGETHER, PLUS A BACKFILL. These are a matched pair:
--       public.convert_sme_prospect_v79 WRITES subscriptions.obligation_period_start/_end
--       from `accepted_at::date` (UTC), and app.v510_verified_initial_payment READS them
--       back by matching a Stripe invoice's `period_start::date` (UTC) against them. They
--       agree today, so the bug is latent — and fixing EITHER ONE ALONE would start
--       rejecting valid payments and leaving paid workspaces locked. Hence one migration,
--       both sites, plus a replay-safe backfill of the rows already written in the wrong
--       zone, with the v510 evidence asserted unchanged across the whole transaction.
--
--   §4  D-08 + D-14 — the two cron jobs still on a UTC-morning schedule. Every other daily
--       job in this estate fires 16:xx–19:xx UTC (00:xx–03:xx SGT), deliberately, so the
--       night's work is done before Singapore opens.
--         job "nestly-v94-subscription-lifecycle-daily"  15 0 * * *  -> 15 16 * * *
--             (08:15 SGT -> 00:15 SGT). A subscription that lapses at Singapore midnight
--             stayed active through the first eight hours of the business day.
--         job "nestly-v361-bringback-issue-daily"        20 3 * * *  -> 20 19 * * *
--             (11:20 SGT -> 03:20 SGT), off convention, mid-business-day.
--
--   §5  ACL, restated from the live grant of every function replaced above.
--
-- HOW THE PATCHES ARE APPLIED. Ten of the twelve functions get a one-line substitution
-- inside a body this migration must otherwise reproduce byte for byte, so each is
-- rewritten from its own live pg_get_functiondef through app.v685_patch(), which fails
-- CLOSED — 42883 if the function is gone, XX001 if the text this migration expects is not
-- there in exactly the expected number of places — rather than from a transcription that
-- could silently drift. This is the extract-and-diff shape of nestly_v474, v566 and v677,
-- with the per-site DO block factored into one throwaway helper that is dropped again at
-- the end of §3.  The two short bodies (D-06, D-13) are restated in full instead.
--
-- Every definition patched here was read from db/migrations (the LAST definition of each)
-- and confirmed identical against production read-only via pg_get_functiondef. Nothing in
-- this migration was executed against production.
--
-- BEHAVIOUR IS OTHERWISE UNCHANGED. No signature, no return shape, no predicate, no
-- ordering and no permission moves. Only the zone in which a day is decided.
--
-- AFTER APPLYING: run `npm run tenant-gate` — this touches billing, commissions and the
-- workspace lifecycle.

begin;

-- =============================================================================================
-- §0. THE BEFORE-PICTURE FOR §3's BACKFILL.
--
-- Captured with the OLD app.v510_verified_initial_payment still in place, because the whole
-- point of the assertion is that no business which could prove a paid initial invoice before
-- this migration loses that proof because of it.
-- =============================================================================================

create temporary table v685_v510_before on commit drop as
  select subscription.business_id,
         (app.v510_verified_initial_payment(subscription.business_id) is not null) as verified
    from public.subscriptions subscription
   where subscription.commercial_terms_id is not null;

-- =============================================================================================
-- §1. THE AUTHORITY. One place that answers "what day is it in Singapore".
--
-- sg_day / sg_day_start / sg_month are IMMUTABLE, not STABLE. `at time zone` with a LITERAL
-- zone name is deterministic — the result depends on nothing but the argument (Singapore has
-- had no DST since 1935 and a fixed +08:00 offset since 1982; a tzdata change here would be a
-- change to the calendar itself). Immutability is what lets these appear in an index
-- expression and be constant-folded inside a plan, which a bare `current_date` comparison
-- against a timestamptz column never could. sg_today() reads now() and is therefore STABLE.
--
-- All four pin the canonical search_path and are revoked from every client role: they are
-- internal plumbing for SECURITY DEFINER bodies, not API surface.
-- =============================================================================================

create or replace function app.sg_today()
returns date
language sql
stable
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
  select (now() at time zone 'Asia/Singapore')::date;
$function$;

create or replace function app.sg_day(p_instant timestamptz)
returns date
language sql
immutable
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
  select (p_instant at time zone 'Asia/Singapore')::date;
$function$;

create or replace function app.sg_day_start(p_day date)
returns timestamptz
language sql
immutable
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
  select (p_day::timestamp at time zone 'Asia/Singapore');
$function$;

create or replace function app.sg_month(p_instant timestamptz)
returns date
language sql
immutable
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
  select date_trunc('month', p_instant at time zone 'Asia/Singapore')::date;
$function$;

comment on function app.sg_today() is
  'nestly_v685: today, in Singapore. The ONE replacement for current_date. The live session '
  'TimeZone is UTC, so current_date is the UTC day and is wrong for the first eight hours of '
  'every Singapore day.';
comment on function app.sg_day(timestamptz) is
  'nestly_v685: the Singapore calendar day an instant falls on. The ONE replacement for '
  '<timestamptz>::date. IMMUTABLE because the zone is a literal.';
comment on function app.sg_day_start(date) is
  'nestly_v685: the instant a Singapore day begins. Gives half-open [sg_day_start(d), '
  'sg_day_start(d+1)) bounds — the correct replacement for <date>::timestamptz, which is UTC '
  'midnight, i.e. 08:00 Singapore time.';
comment on function app.sg_month(timestamptz) is
  'nestly_v685: the first day of the Singapore calendar month an instant falls in, for rollup '
  'and KPI bucketing. Pair with sg_day_start() to get the instant that month begins.';

revoke all on function app.sg_today() from public, anon, authenticated;
revoke all on function app.sg_day(timestamptz) from public, anon, authenticated;
revoke all on function app.sg_day_start(date) from public, anon, authenticated;
revoke all on function app.sg_month(timestamptz) from public, anon, authenticated;

-- =============================================================================================
-- §2. THE READERS AND WRITERS.
--
-- app.v685_patch is a throwaway: created here, used twelve times, dropped at the end of §3. It
-- exists so the fail-closed guard is written ONCE rather than copied twelve times, and so the
-- occurrence COUNT is asserted rather than mere presence — one of these functions carries the
-- same predicate in six places, and patching three of six is exactly the kind of half-fix this
-- migration exists to prevent.
--
-- Every old-text anchor is passed as a $marker$-quoted literal. That is the repo convention
-- for "text being removed", and the companion guard test exempts $marker$ blocks for precisely
-- this reason: a guard that forbade `current_date` inside the anchor would forbid ever
-- deleting a `current_date`.
-- =============================================================================================

create or replace function app.v685_patch(
  p_schema text,
  p_name text,
  p_old text,
  p_new text,
  p_expect integer
)
returns void
language plpgsql
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_src text;
  v_hits integer;
begin
  select pg_get_functiondef(procedure.oid) into v_src
    from pg_proc procedure
    join pg_namespace namespace on namespace.oid = procedure.pronamespace
   where namespace.nspname = p_schema and procedure.proname = p_name;
  if v_src is null then
    raise exception 'nestly_v685: %.% is missing', p_schema, p_name using errcode = '42883';
  end if;
  v_hits := (length(v_src) - length(replace(v_src, p_old, ''))) / length(p_old);
  if v_hits <> p_expect then
    raise exception
      'nestly_v685: %.% no longer carries the text this migration patches (expected % occurrence(s), found %)',
      p_schema, p_name, p_expect, v_hits using errcode = 'XX001';
  end if;
  execute replace(v_src, p_old, p_new);
end
$function$;

revoke all on function app.v685_patch(text, text, text, text, integer) from public, anon, authenticated;

-- --------------------------------------------------------------------------------- D-01
-- The qualified predicate is patched FIRST: the unqualified anchor is a suffix of it, so
-- patching the short form first would produce `subscription.app.sg_day(...)`. The helper
-- re-reads the definition on every call, so after the qualified pass exactly the three
-- unqualified KPI predicates remain — which is what the count of 3 then asserts.
select app.v685_patch('public', 'platform_get_subscription_operations_v156',
  $marker$subscription.current_period_end::date between current_date and current_date+$marker$,
  $marker$app.sg_day(subscription.current_period_end) between app.sg_today() and app.sg_today()+$marker$,
  3);
select app.v685_patch('public', 'platform_get_subscription_operations_v156',
  $marker$current_period_end::date between current_date and current_date+$marker$,
  $marker$app.sg_day(current_period_end) between app.sg_today() and app.sg_today()+$marker$,
  3);
select app.v685_patch('public', 'platform_get_subscription_operations_v156',
  $marker$created_at>=date_trunc('month',clock_timestamp() at time zone 'Asia/Singapore')$marker$,
  $marker$created_at>=app.sg_day_start(app.sg_month(clock_timestamp()))$marker$,
  1);
select app.v685_patch('public', 'platform_get_subscription_operations_v156',
  $marker$ended_at>=date_trunc('month',clock_timestamp() at time zone 'Asia/Singapore')$marker$,
  $marker$ended_at>=app.sg_day_start(app.sg_month(clock_timestamp()))$marker$,
  1);

-- --------------------------------------------------------------------------------- D-02
select app.v685_patch('app', 'accrue_consultant_invoice_v78',
  $marker$v_consultant.employment_started_on<=v_invoice.paid_at::date$marker$,
  $marker$v_consultant.employment_started_on<=app.sg_day(v_invoice.paid_at)$marker$,
  1);

-- --------------------------------------------------------------------------------- D-03
select app.v685_patch('public', 'platform_set_workspace_pause_v622',
  $marker$due_date = case when p_paused then coalesce(due_date, current_date) else due_date end,$marker$,
  $marker$due_date = case when p_paused then coalesce(due_date, app.sg_today()) else due_date end,$marker$,
  1);

-- --------------------------------------------------------------------------------- D-07
select app.v685_patch('public', 'platform_conversion_funnel_v312',
  $marker$v_from := coalesce(p_from, current_date - 3650)::timestamptz;
  v_to := coalesce(p_to, current_date)::timestamptz + interval '1 day';$marker$,
  $marker$v_from := app.sg_day_start(coalesce(p_from, app.sg_today() - 3650));
  v_to := app.sg_day_start(coalesce(p_to, app.sg_today()) + 1);$marker$,
  1);

-- --------------------------------------------------------------------------------- D-09
select app.v685_patch('public', 'refresh_growth_recommendation_v108',
  $marker$date_trunc('day',v_now)::text$marker$,
  $marker$app.sg_day(v_now)::text$marker$,
  1);

-- --------------------------------------------------------------------------------- D-10
select app.v685_patch('public', 'platform_sweep_stalled_onboarding_v513',
  $marker$v_day text:=current_date::text;$marker$,
  $marker$v_day text:=app.sg_today()::text;$marker$,
  1);

-- --------------------------------------------------------------------------------- D-11
select app.v685_patch('app', 'customer_demographics_v1',
  $marker$date_part('year', age(current_date, v_birth))::integer$marker$,
  $marker$date_part('year', age(app.sg_today(), v_birth))::integer$marker$,
  1);

-- --------------------------------------------------------------------------------- D-12
select app.v685_patch('app', 'sme_prospect_card_v76',
  $marker$greatest(0,current_date-(prospect.stage_entered_at at time zone 'Asia/Singapore')::date)$marker$,
  $marker$greatest(0,app.sg_today()-app.sg_day(prospect.stage_entered_at))$marker$,
  1);

-- --------------------------------------------------------------------------------- D-06
-- Short body, restated in full. Only `max(s.created_at)::date` moves.
create or replace function app.issue_bringback_for_business_v361(p_business uuid)
returns integer language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_campaign public.bringback_campaigns_v361%rowtype;
  v_issued integer := 0;
  v_rows integer;
begin
  for v_campaign in
    select * from public.bringback_campaigns_v361
     where business_id=p_business and active and deleted_at is null
  loop
    -- "Away for the stated period" uses the SAME definition as the Gone-quiet report the owner
    -- already reads: last completed, non-reversed sale older than away_days. Anyone with no sale
    -- at all is excluded — they never came, so there is nothing to bring them back from.
    insert into public.bringback_grants_v361(
      business_id,campaign_id,client_id,reward_label,away_days,cycle_key,expires_at)
    select p_business, v_campaign.id, last_seen.client_id, v_campaign.reward_label,
           v_campaign.away_days, last_seen.last_day,
           case when v_campaign.expiry_days is null then null
                else now() + make_interval(days => v_campaign.expiry_days) end
      from (
        -- nestly_v685: the cycle_key and the customer-visible "last seen" day are Singapore
        -- days. The UTC day filed a customer last seen between midnight and 08:00 SGT under
        -- the previous day, which is both a wrong date on screen and a second dedupe cycle.
        select s.client_id, app.sg_day(max(s.created_at)) as last_day
          from public.sales s
         where s.business_id=p_business and s.client_id is not null and s.reversal_of is null
           and not exists(select 1 from public.sales r where r.reversal_of=s.id)
         group by s.client_id
        having max(s.created_at) < now() - make_interval(days => v_campaign.away_days)
      ) last_seen
    on conflict (campaign_id, client_id, cycle_key) do nothing;
    get diagnostics v_rows = row_count;
    v_issued := v_issued + v_rows;
  end loop;
  return v_issued;
end $$;

-- --------------------------------------------------------------------------------- D-13
-- Short body, restated in full. The renewal DECISION was already Singapore; the dedupe key
-- suffix was the UTC day, so on any evening the two disagreed and one renewal could be filed
-- under two different keys. The p_as_of default is unchanged in VALUE — it now reads through
-- the authority instead of open-coding the same expression.
create or replace function public.platform_generate_subscription_reminders_v156(p_as_of date default app.sg_day(clock_timestamp()))
returns jsonb language plpgsql security definer set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare r record;v_count integer:=0;v_day integer;v_prospect uuid;
begin
  if auth.uid() is not null and not app.v156_can('rw') then raise exception 'billing write access is required' using errcode='42501';end if;
  for r in select subscription.* from public.billing_provider_subscriptions subscription where subscription.status in ('active','trialing','past_due') loop
    select id into v_prospect from public.sme_prospects where converted_business_id=r.business_id order by converted_at desc nulls last limit 1;
    if r.status='past_due' then perform app.v156_upsert_task('past-due:'||r.provider_subscription_id,'past_due',r.business_id,v_prospect,r.provider_subscription_id,null,'urgent',p_as_of::timestamptz,'Subscription payment is past due',null);v_count:=v_count+1;end if;
    if r.cadence='annual' and r.current_period_end is not null then
      v_day:=(app.sg_day(r.current_period_end)-p_as_of);
      if v_day in (30,14,7) then perform app.v156_upsert_task('renewal-'||v_day||':'||r.provider_subscription_id||':'||(app.sg_day(r.current_period_end)),'renewal_'||v_day,r.business_id,v_prospect,r.provider_subscription_id,null,case when v_day=7 then 'high' else 'normal' end,p_as_of::timestamptz,'Annual subscription renews in '||v_day||' days',null);v_count:=v_count+1;end if;
    end if;
  end loop;
  return jsonb_build_object('created_or_refreshed',v_count,'as_of',p_as_of);
end $$;

-- =============================================================================================
-- §3. D-04 + D-05 — the obligation window, written and read in the same zone, plus a backfill.
-- =============================================================================================

-- --------------------------------------------------------------------------------- D-04 (writer)
select app.v685_patch('public', 'convert_sme_prospect_v79',
  $marker$v_terms.accepted_at::date,(v_terms.accepted_at+make_interval(months=>v_months)-interval '1 day')::date);$marker$,
  $marker$app.sg_day(v_terms.accepted_at),app.sg_day(v_terms.accepted_at+make_interval(months=>v_months)-interval '1 day'));$marker$,
  1);

-- --------------------------------------------------------------------------------- D-05 (reader)
select app.v685_patch('app', 'v510_verified_initial_payment',
  $marker$invoice.period_start::date=obligation.obligation_period_start
      and (invoice.period_end::date=obligation.obligation_period_end
        or invoice.period_end::date=obligation.obligation_period_end+1)$marker$,
  $marker$app.sg_day(invoice.period_start)=obligation.obligation_period_start
      and (app.sg_day(invoice.period_end)=obligation.obligation_period_end
        or app.sg_day(invoice.period_end)=obligation.obligation_period_end+1)$marker$,
  1);

drop function app.v685_patch(text, text, text, text, integer);

-- --------------------------------------------------------------------------------- the backfill
--
-- Rows already written in UTC. The obligation window is RECOMPUTED FROM ITS SOURCE — the
-- immutable sme_commercial_terms.accepted_at instant — never nudged by a day, because a naive
-- +1 would be wrong for the two thirds of rows that were already on the right day.
--
-- REPLAY-SAFE: a row whose stored pair already equals the recomputed pair is skipped and
-- writes no audit row, so running this twice changes nothing.
--
-- FAIL-SOFT PER ROW, FAIL-CLOSED OVERALL: if moving a row would make its already-matching
-- payment evidence stop matching, the move is REVERTED for that row and recorded as skipped —
-- correcting a date must never lock a workspace whose owner has paid. The assertion after the
-- loop then proves, over the whole table, that nobody lost verified evidence.
--
-- PRODUCTION BLAST RADIUS, measured read-only on 2026-09-02 before this was written: 0 rows.
-- public.subscriptions holds no row with a non-null obligation window at all, so on production
-- this loop is a no-op. It is written to be correct anyway — the assisted-sale rail is live and
-- the first conversion would otherwise have landed in the wrong zone.
do $backfill$
declare
  v_row record;
  v_start date;
  v_end date;
  v_was_verified boolean;
  v_still_verified boolean;
  v_changed integer := 0;
  v_skipped integer := 0;
begin
  for v_row in
    select subscription.business_id, subscription.cadence_months,
           subscription.obligation_period_start, subscription.obligation_period_end,
           terms.accepted_at
      from public.subscriptions subscription
      join public.sme_commercial_terms terms on terms.id = subscription.commercial_terms_id
     where terms.accepted_at is not null
       and (subscription.obligation_period_start is not null
         or subscription.obligation_period_end is not null)
     order by subscription.business_id
       for update of subscription
  loop
    v_start := app.sg_day(v_row.accepted_at);
    v_end := app.sg_day(v_row.accepted_at
              + make_interval(months => coalesce(v_row.cadence_months, 12))
              - interval '1 day');
    if (v_row.obligation_period_start, v_row.obligation_period_end)
       is not distinct from (v_start, v_end) then
      continue;
    end if;

    select coalesce(snapshot.verified, false) into v_was_verified
      from v685_v510_before snapshot where snapshot.business_id = v_row.business_id;

    update public.subscriptions
       set obligation_period_start = v_start, obligation_period_end = v_end
     where business_id = v_row.business_id;

    v_still_verified := app.v510_verified_initial_payment(v_row.business_id) is not null;
    if coalesce(v_was_verified, false) and not v_still_verified then
      update public.subscriptions
         set obligation_period_start = v_row.obligation_period_start,
             obligation_period_end = v_row.obligation_period_end
       where business_id = v_row.business_id;
      v_skipped := v_skipped + 1;
      insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
      values (v_row.business_id, null, 'SUBSCRIPTION_OBLIGATION_SG_DAY_SKIPPED_V685',
              'subscriptions', v_row.business_id,
              jsonb_build_object(
                'reason', 'moving the obligation window to the Singapore day would have '
                       || 'invalidated an already-verified initial payment; left as written',
                'accepted_at', v_row.accepted_at,
                'kept', jsonb_build_object('obligation_period_start', v_row.obligation_period_start,
                                           'obligation_period_end', v_row.obligation_period_end),
                'rejected', jsonb_build_object('obligation_period_start', v_start,
                                               'obligation_period_end', v_end)));
      continue;
    end if;

    v_changed := v_changed + 1;
    insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
    values (v_row.business_id, null, 'SUBSCRIPTION_OBLIGATION_SG_DAY_BACKFILL_V685',
            'subscriptions', v_row.business_id,
            jsonb_build_object(
              'reason', 'nestly_v685: the obligation window was written from accepted_at as a '
                     || 'UTC day; recomputed from the same instant as a Singapore day',
              'accepted_at', v_row.accepted_at,
              'cadence_months', coalesce(v_row.cadence_months, 12),
              'before', jsonb_build_object('obligation_period_start', v_row.obligation_period_start,
                                           'obligation_period_end', v_row.obligation_period_end),
              'after', jsonb_build_object('obligation_period_start', v_start,
                                          'obligation_period_end', v_end),
              'payment_evidence_preserved', v_still_verified));
  end loop;
  raise notice 'nestly_v685 obligation backfill: % row(s) moved to the Singapore day, % left as written',
    v_changed, v_skipped;
end
$backfill$;

do $assert$
declare
  v_lost integer;
begin
  select count(*) into v_lost
    from v685_v510_before snapshot
   where snapshot.verified
     and app.v510_verified_initial_payment(snapshot.business_id) is null;
  if v_lost <> 0 then
    raise exception
      'nestly_v685: % business(es) that could prove a verified initial payment before this '
      'migration can no longer prove one', v_lost using errcode = 'XX001';
  end if;
end
$assert$;

-- =============================================================================================
-- §4. D-08 + D-14 — the two crons that still fire inside the Singapore business day.
--
-- Looked up by jobname, never by a hard-coded jobid (11 and 25 on production today, but a
-- jobid is not a contract). alter_job to a schedule a job already has is a no-op, so this is
-- idempotent. A job that is absent is a NOTICE, not an error: cron rows are project state, not
-- schema — the local rehearsal cluster restores no cron data, and failing there would block
-- the whole chain over a registration this migration does not own.
-- =============================================================================================

do $cron$
declare
  v_job bigint;
begin
  select jobid into v_job from cron.job where jobname = 'nestly-v94-subscription-lifecycle-daily';
  if v_job is null then
    raise notice 'nestly_v685: cron job nestly-v94-subscription-lifecycle-daily is not registered here; schedule unchanged';
  else
    -- 16:15 UTC = 00:15 SGT. Lapse the subscription before Singapore opens, not eight hours in.
    perform cron.alter_job(v_job, schedule => '15 16 * * *');
  end if;

  select jobid into v_job from cron.job where jobname = 'nestly-v361-bringback-issue-daily';
  if v_job is null then
    raise notice 'nestly_v685: cron job nestly-v361-bringback-issue-daily is not registered here; schedule unchanged';
  else
    -- 19:20 UTC = 03:20 SGT, in with the rest of the overnight batch instead of 11:20 in the
    -- middle of the morning.
    perform cron.alter_job(v_job, schedule => '20 19 * * *');
  end if;
end
$cron$;

-- =============================================================================================
-- §5. ACL.
--
-- Every signature above is unchanged, so CREATE OR REPLACE preserved every grant. They are
-- restated per the repo's preflight rule, read from the live proacl of each function on
-- 2026-09-02 and cross-checked against the migration that last defined it.
-- =============================================================================================

revoke all on function public.platform_get_subscription_operations_v156(text, text, integer) from public, anon;
grant execute on function public.platform_get_subscription_operations_v156(text, text, integer) to authenticated, service_role;

revoke all on function public.platform_generate_subscription_reminders_v156(date) from public, anon;
grant execute on function public.platform_generate_subscription_reminders_v156(date) to authenticated, service_role;

revoke all on function public.platform_set_workspace_pause_v622(uuid, boolean, text) from public, anon;
grant execute on function public.platform_set_workspace_pause_v622(uuid, boolean, text) to authenticated, service_role;

revoke all on function public.platform_conversion_funnel_v312(date, date) from public, anon;
grant execute on function public.platform_conversion_funnel_v312(date, date) to authenticated, service_role;

revoke all on function public.refresh_growth_recommendation_v108(uuid, uuid) from public, anon;
grant execute on function public.refresh_growth_recommendation_v108(uuid, uuid) to authenticated, service_role;

revoke all on function public.convert_sme_prospect_v79(uuid, bigint, text) from public, anon;
grant execute on function public.convert_sme_prospect_v79(uuid, bigint, text) to authenticated, service_role;

revoke all on function public.platform_sweep_stalled_onboarding_v513(integer) from public, anon, authenticated;
grant execute on function public.platform_sweep_stalled_onboarding_v513(integer) to service_role;

revoke all on function app.customer_demographics_v1(uuid, uuid) from public, anon;
grant execute on function app.customer_demographics_v1(uuid, uuid) to authenticated, service_role;

revoke all on function app.accrue_consultant_invoice_v78(uuid) from public, anon, authenticated;
revoke all on function app.issue_bringback_for_business_v361(uuid) from public, anon, authenticated;
revoke all on function app.sme_prospect_card_v76(uuid) from public, anon, authenticated;
revoke all on function app.v510_verified_initial_payment(uuid) from public, anon, authenticated;

commit;
