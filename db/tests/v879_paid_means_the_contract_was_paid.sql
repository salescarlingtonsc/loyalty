-- nestly_v879 rollback suite — "paid" means the contract was paid.
--
-- Two synthetic tenants, both billing_provider='manual', built inside the transaction and rolled
-- back. app.v680_apply_paid_period is called directly (it is the one function both platform
-- payment routes end in), so no super-admin session is staged.
--
--   T  a tenant with NO accepted commercial terms — the shape of all fifteen live manual tenants.
--      A verified payment must still flip it to active/paid (the carve-out), or v879 would have
--      made every pilot tenant unactivatable.
--   C  a tenant WITH accepted terms (240,000 cents) and NO evidence matching them. The same
--      payment must leave status/payment_status/current_period untouched, record last_paid_at,
--      and write an audit row saying evidenced=false.
--   C2 (negative control) the same tenant with the contract DETACHED (accepted terms are frozen by
--      v512_freeze_accepted_terms, so the subscription's commercial_terms_id is nulled instead):
--      now the same payment flips it, proving C was refused BECAUSE of the contract.
--
-- The matched-contract path (full payment on the contract invoice -> active/paid) is exercised by
-- the executed fixtures v510_operating_system_crm_foundation and v512_commercial_handoff_integrity
-- in the local chain; this suite proves the two edges around it against production.

\set ON_ERROR_STOP on

begin;

do $suite$
declare
  biz_t uuid := gen_random_uuid(); biz_c uuid := gen_random_uuid();
  prospect uuid; terms uuid := gen_random_uuid(); ver integer;
  r public.subscriptions%rowtype; res jsonb; n integer := 0;
begin
  -- A terms row must hang off a prospect, and a prospect row has its own evidence rules; the
  -- gate and v510 only ever join subscription -> terms by id, so any existing UNCONVERTED
  -- prospect will do (app.guard_converted_commercial_terms_v79 freezes a converted one's terms).
  select id into prospect from public.sme_prospects where converted_business_id is null order by created_at limit 1;
  if prospect is null then raise exception 'setup: no sme_prospects row to attach the terms to'; end if;
  select coalesce(max(version), 0) + 1 into ver from public.sme_commercial_terms where prospect_id = prospect;

  insert into public.businesses(id, name, slug, industry, enabled_modules) values
    (biz_t, 'v879 term-less', 'v879-t-' || substr(biz_t::text,1,8), 'fnb', array['dashboard']),
    (biz_c, 'v879 contracted', 'v879-c-' || substr(biz_c::text,1,8), 'fnb', array['dashboard']);
  insert into public.sme_commercial_terms(id, prospect_id, version, plan_code, product_code, billing_cycle, seats,
    currency, accepted_value_cents, owner_email, contract_status, accepted_at)
  values (terms, prospect, ver, 'v879', 'v879', 'annual', 1, 'SGD', 240000, 'v879@example.invalid', 'accepted', now());
  -- period_total_cents is left at its default: subscriptions_period_amounts_check ties it to the
  -- other amount columns, and neither case here needs it — T never consults v510, and C has no
  -- payment document for v510 to match whatever the total says.
  insert into public.subscriptions(business_id, billing_provider, status, payment_status, currency,
    obligation_period_start, obligation_period_end, commercial_terms_id)
  values (biz_t, 'manual', 'incomplete', 'not_collected', 'SGD', current_date, current_date + 364, null),
         (biz_c, 'manual', 'incomplete', 'not_collected', 'SGD', current_date, current_date + 364, terms);

  -- T: no contract -> a verified payment still activates.
  res := app.v680_apply_paid_period(biz_t, now() + interval '364 days', 'v879-suite-T-00000001', 'suite', null,
           'v879_suite', null, null, null, 'annual', now(), 240000, 'V879-T');
  select * into r from public.subscriptions where business_id = biz_t;
  n := n + 1; if r.status <> 'active' or r.payment_status <> 'paid' then
    raise exception 'T failed: a term-less manual tenant no longer activates on a verified payment (%/%)', r.status, r.payment_status; end if;

  -- C: contract on file, no matching evidence -> nothing flips, the payment is still recorded.
  res := app.v680_apply_paid_period(biz_c, now() + interval '364 days', 'v879-suite-C-00000001', 'suite', null,
           'v879_suite', null, null, null, 'annual', now(), 120000, 'V879-C');
  select * into r from public.subscriptions where business_id = biz_c;
  n := n + 1; if r.status <> 'incomplete' or r.payment_status <> 'not_collected' then
    raise exception 'C failed: an unmatched payment flipped a contracted tenant to %/%', r.status, r.payment_status; end if;
  n := n + 1; if r.last_paid_at is null then raise exception 'C failed: the payment itself was not recorded'; end if;
  n := n + 1; if not exists (select 1 from public.audit_log a where a.business_id = biz_c
                and a.action = 'SUBSCRIPTION_MANUAL_PAYMENT_V664' and (a.detail->>'evidenced') = 'false') then
    raise exception 'C failed: the audit row does not say evidenced=false'; end if;

  -- C2 (negative control): detach the contract and the same tenant flips on the next payment.
  -- (Accepted terms themselves are frozen by v512_freeze_accepted_terms; the link is not.)
  update public.subscriptions set commercial_terms_id = null where business_id = biz_c;
  res := app.v680_apply_paid_period(biz_c, now() + interval '364 days', 'v879-suite-C-00000002', 'suite', null,
           'v879_suite', null, null, null, 'annual', now(), 120000, 'V879-C2');
  select * into r from public.subscriptions where business_id = biz_c;
  n := n + 1; if r.status <> 'active' or r.payment_status <> 'paid' then
    raise exception 'C2 failed (negative control): with the contract detached the tenant still did not flip, so C proved nothing'; end if;

  raise notice 'nestly_v879 suite: % assertions passed', n;
end
$suite$;

select 'v879 suite passed' as result;

rollback;
