-- Rolled-back acceptance for v280 — branch plan units, and the promotion version a wrapper
-- reports. Everything runs inside one transaction that is rolled back: no branch survives, no
-- promotion survives, no subscription flag survives, and Stripe is never called from SQL.
--
-- CORRECTION (first run, 2026-08-11, against production gadpooereceldfpfxsod): this suite had
-- never been executed, and three scaffolding gaps had to be closed before it could report
-- anything. All three are marked CORRECTION inline. The assertions themselves are unchanged.
--
-- CORRECTION 3 (reporting + rollback): a bare `assert` prints nothing when it passes, so a green
-- run was indistinguishable from a run that asserted nothing. Every step now appends to v_log and
-- the block ENDS in `raise exception 'V280_RESULT ALL PASS -- %'`. That is deliberate on both
-- counts: it prints the real values behind each assertion, and it aborts the transaction, so the
-- suite rolls itself back even when it is fed to a single-statement executor (the Supabase MCP
-- execute_sql path) that never sees the trailing `rollback;`. In psql the trailing `rollback;`
-- still runs and is harmless.
begin;

do $$
declare
  v_biz uuid; v_owner uuid; v_src uuid;
  v_covers_before boolean; v_covers_after boolean;
  v_added jsonb; v_units jsonb;
  v_promotion uuid; v_attempt uuid; v_draft jsonb; v_row_version bigint;
  v_receipt jsonb; v_final jsonb;
  v_log text := '';
begin
  -- CORRECTION 1 (determinism): `limit 1` with no ORDER BY picked an arbitrary tenant, so two
  -- runs could exercise two different businesses and a failure could not be reproduced. Worse,
  -- it could land on a live tenant (Bistro 999, Cubbly) and mint a branch + a billing command
  -- against them; the rollback undoes it, but a suite should not choose a paying customer by
  -- accident. Ordered so a synthetic 'ZZ%' fixture wins, then by business_id for stability.
  select s.business_id, s.user_id into v_biz, v_owner
    from public.staff s
    join public.businesses b on b.id = s.business_id
   where s.role='owner' and s.user_id is not null and s.active
     and exists (select 1 from public.branches br where br.business_id=s.business_id and br.is_default)
     and exists (select 1 from public.subscriptions sub where sub.business_id=s.business_id
                   and sub.provider_subscription_id is null)
   order by (b.name like 'ZZ%') desc, s.business_id
   limit 1;
  -- CORRECTION 2 (silent skip): the original `raise notice ...; return;` exited zero, so a
  -- missing fixture reported exactly the same as a full pass. A suite that tested nothing must
  -- not look green.
  if v_biz is null then
    raise exception 'V280_RESULT SKIPPED -- no owner fixture without a Stripe subscription';
  end if;
  v_log := v_log || format('fixture business=%s owner=%s; ', v_biz, v_owner);
  select id into v_src from public.branches where business_id=v_biz and is_default limit 1;
  select provider_covers_base_unit into v_covers_before
    from public.subscriptions where business_id=v_biz;

  -- 1. every subscription that already exists is treated as covering its own base unit. A firm
  --    is never retro-classified as "branch only" by this migration.
  assert v_covers_before, 'an existing subscription must default to covering its base unit';
  v_log := v_log || '1 default-covers-base=PASS; ';

  perform set_config('request.jwt.claims',
    json_build_object('sub',v_owner,'role','authenticated')::text, true);

  -- 2. buying a branch when the firm has no Stripe subscription mints a checkout that pays for
  --    the BRANCH. The firm's base plan is being collected elsewhere and must not be charged
  --    again inside this purchase.
  v_added := public.business_add_branch_v202(v_biz,'ZZ V280 Rollback Branch',null,null,null,v_src,
    gen_random_uuid());
  assert v_added->>'command_type' = 'create_checkout', 'no Stripe subscription means a checkout';
  assert (v_added->>'covers_base_unit')::boolean is false,
    'a branch-only checkout must say it does not carry the base unit';
  select provider_covers_base_unit into v_covers_after
    from public.subscriptions where business_id=v_biz;
  assert v_covers_after is false,
    'the branch checkout must record that it does not collect the base plan';
  v_log := v_log || format('2 branch-only-checkout=PASS (command_type=%s covers_base_unit=%s stored=%s); ',
    v_added->>'command_type', v_added->>'covers_base_unit', v_covers_after);

  -- 3. the three numbers the owner is shown, and the quantity they imply. One added branch is
  --    ONE billable branch — never two.
  v_units := public.business_branch_billing_units_v280(v_biz);
  assert (v_units->>'included_branches')::int >= 1,
    'the firm keeps at least its own included branch';
  assert (v_units->>'billable_branches')::int
         = (select count(*) from public.branches
             where business_id=v_biz and billing_state in ('pending_payment','active')),
    'billable must count exactly the paid states';
  assert (v_units->>'base_unit_billed_by_provider')::boolean is false,
    'the base unit is not on this Stripe subscription';
  assert (v_units->>'plan_units')::int = (v_units->>'billable_branches')::int,
    'a branch-only subscription bills one unit per billable branch and nothing else';
  assert (v_units->>'total_branches')::int
         = (v_units->>'included_branches')::int + (v_units->>'billable_branches')::int
           + (v_units->>'lapsed_branches')::int,
    'the counts shown to the owner must add up to the branches they have';
  v_log := v_log || format('3 units-branch-only=PASS %s; ', v_units::text);

  -- 4. a firm whose subscription DOES cover its base unit still bills base + branches.
  update public.subscriptions set provider_covers_base_unit=true where business_id=v_biz;
  v_units := public.business_branch_billing_units_v280(v_biz);
  assert (v_units->>'plan_units')::int = 1 + (v_units->>'billable_branches')::int,
    'a firm billed through Stripe still pays for its own base unit';
  v_log := v_log || format('4 units-base-covered=PASS plan_units=%s; ', v_units->>'plan_units');

  -- 5. the promotion wrapper reports the version it actually left behind.
  v_promotion := gen_random_uuid();
  v_attempt := gen_random_uuid();
  v_draft := public.business_create_promotion_draft_v155(
    v_biz,v_promotion,v_attempt,'all',null,null,
    'ZZ V280 Rollback Offer',null,
    'A rolled-back promotion used only to prove the reported version matches the stored row.',
    null,now(),now()+interval '10 days',100,'programme','View offer',
    'ZZ rollback offer facts',null);
  select version into v_row_version
    from public.business_customer_content_v95 where id=v_promotion and business_id=v_biz;
  assert (v_draft->>'content_version')::bigint = v_row_version,
    'the draft must report the version the row actually holds after the scope write';
  assert (v_draft->'item'->>'content_version')::bigint = v_row_version,
    'the embedded item must report the same version';
  select response_payload into v_receipt
    from public.business_promotion_attempt_receipts_v104
   where business_id=v_biz and attempt_key=v_attempt;
  assert (v_receipt->>'content_version')::bigint = v_row_version,
    'a replay of the receipt must not hand back the stale version';
  v_log := v_log || format('5 draft-version-sync=PASS (reported=%s item=%s receipt=%s row=%s); ',
    v_draft->>'content_version', v_draft->'item'->>'content_version',
    v_receipt->>'content_version', v_row_version);

  -- 6. …and finalizing with exactly what the draft reported is accepted. Before v280 this raised
  --    promotion_version_conflict, which is what "cannot publish" was.
  v_final := public.business_finalize_promotion_v155(
    v_biz,v_promotion,'all',null,null,
    'ZZ V280 Rollback Offer',null,
    'A rolled-back promotion used only to prove the reported version matches the stored row.',
    null,now(),now()+interval '10 days',100,'programme','View offer',
    'ZZ rollback offer facts',null,false,null,null,null,null,null,
    (v_draft->>'content_version')::bigint,
    (v_draft->>'copy_version')::bigint,
    0,gen_random_uuid());
  assert v_final->>'status' = 'draft', 'the finalize must succeed and stay a draft';
  select version into v_row_version
    from public.business_customer_content_v95 where id=v_promotion and business_id=v_biz;
  assert (v_final->>'content_version')::bigint = v_row_version,
    'the finalize must also report the version it left behind';
  v_log := v_log || format('6 finalize-accepted=PASS (status=%s reported=%s row=%s)',
    v_final->>'status', v_final->>'content_version', v_row_version);

  perform set_config('request.jwt.claims', null, true);
  -- CORRECTION 3: see the header. This raise is the pass signal AND the rollback.
  raise exception 'V280_RESULT ALL PASS -- %', v_log;
end$$;

rollback;
