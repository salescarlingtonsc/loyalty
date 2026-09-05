-- nestly_v790 — the catalogue knows the sandbox plan id beside the live one (2026-09-06).
--
-- OWNER RULING (2026-09-05): a demo account "looks exactly as how live account will look like …
-- backend no money enter our system". With the platform keys about to go LIVE, a demo firm's
-- checkout has to run against Razorpay's TEST account (the edge functions choose the account by
-- businesses.is_demo since v790), and the test account has its own plan ids.
--
-- WHAT THIS MIGRATION DOES
--   1. billing_capacity_tier_catalog_v664 gains provider_test_price_id. provider_base_price_id
--      stays the id the PLATFORM account charges from (live once the live keys are installed);
--      provider_test_price_id is the same plan in the sandbox.
--   2. Every active tier's current provider_base_price_id — which is a sandbox id today, the
--      platform has only ever run in test mode — is copied into provider_test_price_id, so the
--      sandbox mapping is complete before anything switches.
--   3. app.razorpay_plan_cadence_v755 (plan id -> cadence, read by the applier for every event)
--      matches either column, so a sandbox event resolves its cadence exactly like a live one.
--   4. app.apply_razorpay_branch_event_v786's unit-amount lookup matches either column too.
--
-- Recording the LIVE ids is a data step done at go-live, not here: it must coincide with the
-- live keys being installed, or a checkout would send a live plan id to the test account.
--
-- Rollback suite: db/tests/v790_sandbox_plan_ids.sql
begin;

alter table public.billing_capacity_tier_catalog_v664
  add column if not exists provider_test_price_id text;
comment on column public.billing_capacity_tier_catalog_v664.provider_test_price_id is
  'v790: the same plan in the Razorpay TEST account; demo firms are billed against it so no money moves.';

update public.billing_capacity_tier_catalog_v664
   set provider_test_price_id = provider_base_price_id
 where provider_test_price_id is null
   and provider_base_price_id like 'plan_%';

create or replace function app.razorpay_plan_cadence_v755(p_plan_id text)
returns table(cadence text, cadence_months integer)
language sql
stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select found_row.cadence, found_row.cadence_months::integer
    from (
      select tier.cadence, tier.cadence_months, tier.effective_from, 1 as source_rank
        from public.billing_capacity_tier_catalog_v664 tier
       where p_plan_id is not null
         and p_plan_id in (tier.provider_base_price_id, tier.provider_test_price_id)
      union all
      select catalog.cadence, catalog.cadence_months, catalog.effective_from, 2 as source_rank
        from public.billing_plan_catalog_v124 catalog
       where p_plan_id is not null
         and p_plan_id in (catalog.provider_base_price_id,catalog.provider_capacity_price_id)
    ) found_row
   order by found_row.source_rank, found_row.effective_from desc
   limit 1
$$;
/* Restated from the live proacl: {postgres=X/postgres}. */
revoke all on function app.razorpay_plan_cadence_v755(text) from public, anon, authenticated;

do $v790_patch$
declare v_body text; v_new text;
begin
  v_body := pg_get_functiondef('app.apply_razorpay_branch_event_v786(text,uuid,uuid,smallint)'::regprocedure);
  v_new := replace(v_body,
    $n$          where tier.provider_base_price_id = v_plan limit 1),$n$,
    $n$          where v_plan in (tier.provider_base_price_id, tier.provider_test_price_id) limit 1),$n$);
  if v_new = v_body then raise exception 'v790: branch applier unit-amount needle did not apply'; end if;
  execute v_new;
end
$v790_patch$;

commit;
