-- nestly_v999 acceptance — the attention list forgets people who asked to be forgotten.
--
-- Run:  supabase db query --linked -f db/tests/v999_the_attention_list_forgets_erased_people.sql
-- Ends by raising V999_RESULT so nothing commits. PASS is an exception saying ALL PASS.
--
-- PROVEN RED FIRST against production, executing get_attention_list_v548 as each tenant's real owner
-- principal: 3 of the 6 people flagged estate-wide had a client_erasures_v290 row, and on Cubbly SPA
-- (2 of 2) and QA Kaya Toast (1 of 1) every flagged person was erased.
--
-- This suite does not rely on that production state, which the backfill may clear: it builds a
-- customer with the visit history the list keys on, asserts they appear, erases them, and asserts
-- they are gone. Appearing FIRST is the control — without it the suite would pass on a customer the
-- list was never going to flag for reasons that have nothing to do with erasure.

begin;

do $v999$
declare
  n integer := 0;
  v_biz uuid; v_owner uuid; v_client uuid;
  v_before int; v_after int;
  v_flagged boolean;
  v_json jsonb; v_row jsonb;
begin
  -- ==========================================================================================
  -- 1 · A tenant whose owner can read the list, and a customer with >= 3 visits on a steady
  --     cadence that has since lapsed — the exact shape get_attention_list_v548 flags.
  -- ==========================================================================================
  select s.business_id, s.user_id into v_biz, v_owner
    from public.staff s
   where s.role = 'owner' and s.active and s.user_id is not null
     and exists (select 1 from public.branches br where br.business_id = s.business_id and br.active)
   limit 1;
  if v_biz is null then
    raise exception 'V999 INCONCLUSIVE: no tenant with an active owner login and an active branch';
  end if;

  insert into public.clients(business_id, full_name, phone)
  values (v_biz, 'V999 Lapsed Regular', '+65 8000 0999')
  returning id into v_client;

  /* four visits, 14 days apart, the most recent well past the cadence so the row reads 'overdue' */
  insert into public.sales(business_id, client_id, kind, amount_cents, occurred_at, branch_id)
  select v_biz, v_client, 'service', 5000,
         (now() at time zone 'Asia/Singapore' - make_interval(days => d))::timestamptz,
         (select id from public.branches where business_id = v_biz and active limit 1)
    from unnest(array[120, 106, 92, 78]) as d;
  n := n + 1;

  -- ==========================================================================================
  -- 2 · CONTROL — they really are flagged before any erasure. If this fails the suite is not
  --     testing erasure at all, it is testing an empty list.
  -- ==========================================================================================
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  set local role authenticated;
  v_json := public.get_attention_list_v548(v_biz);
  reset role;

  v_flagged := false;
  for v_row in select jsonb_array_elements(coalesce(v_json->'rows','[]'::jsonb)) loop
    if nullif(v_row->>'client_id','')::uuid = v_client then v_flagged := true; end if;
  end loop;
  if not v_flagged then
    raise exception 'V999 INCONCLUSIVE: the probe customer was not flagged even before erasure — the fixture does not match what the list looks for';
  end if;
  select jsonb_array_length(coalesce(v_json->'rows','[]'::jsonb)) into v_before;
  n := n + 1;

  -- ==========================================================================================
  -- 3 · Erase them, through the real RPC as the owner.
  -- ==========================================================================================
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  set local role authenticated;
  perform public.erase_client_v290(v_biz, v_client, 'V999 acceptance probe erasure', 'v999-probe-' || v_client::text);
  reset role;
  n := n + 1;

  -- ==========================================================================================
  -- 4 · THE DEFECT. They must be gone from the list. This was red.
  -- ==========================================================================================
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  set local role authenticated;
  v_json := public.get_attention_list_v548(v_biz);
  reset role;

  for v_row in select jsonb_array_elements(coalesce(v_json->'rows','[]'::jsonb)) loop
    if nullif(v_row->>'client_id','')::uuid = v_client then
      raise exception 'V999 ASSERT 4 FAILED: an erased customer is still on the attention list, which exists to prompt the owner to contact them';
    end if;
  end loop;
  n := n + 1;

  -- ==========================================================================================
  -- 5 · The COUNT moved too, not just the rows. The summary tile and the list must agree —
  --     hiding someone from the rows while still counting them in "Regulars overdue" would be a
  --     different bug wearing this fix as a disguise.
  -- ==========================================================================================
  select jsonb_array_length(coalesce(v_json->'rows','[]'::jsonb)) into v_after;
  if v_after <> v_before - 1 then
    raise exception 'V999 ASSERT 5 FAILED: rows went from % to % — the erased person was not the only thing that changed', v_before, v_after;
  end if;
  n := n + 1;

  -- ==========================================================================================
  -- 6 · The predicate itself answers both ways, on a real row.
  -- ==========================================================================================
  if not app.client_is_erased_v999(v_biz, v_client) then
    raise exception 'V999 ASSERT 6 FAILED: client_is_erased_v999 says an erased client is not erased';
  end if;
  if app.client_is_erased_v999(v_biz, gen_random_uuid()) then
    raise exception 'V999 ASSERT 6 FAILED: client_is_erased_v999 says an unknown client IS erased';
  end if;
  n := n + 1;

  raise exception 'V999_RESULT ALL PASS (% assertions)', n;
end
$v999$;

rollback;
