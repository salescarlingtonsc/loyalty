-- Stamp card — EARN AND REDEEM, END TO END, 2026-09-08.
--
-- Walked on QA Kopi Lab (Bedok), one of the two tenants running a stamp card, as the real
-- principals: the owner for every till write, the linked customer (own auth.uid) for every
-- customer read. Rolled back; nothing is left behind.
--
-- The card's contract, as the migrations state it, and what this suite holds it to:
--   earn      floor(amount_cents / stamp_per_cents) of the OPEN CARD'S PINNED version (v416/v436)
--             written as a points_ledger row in the stamps pot; $6 a stamp here
--   progress  filled = net stamps in the pot - slots of closed cycles (v323)
--   gift      a milestone gift is claimable once filled >= its slot, once per cycle
--             (app.redeem_reward_core stamps arm -> stamp_milestone_claims)
--   replay    the same idempotency key claims once
--   reversal  a stamp gift can be un-redeemed and the claim REMOVED (nestly_v802)
--   rollover  reaching the last slot closes the cycle (origin 'completed') and any excess
--             flows onto the new card (nestly_v489)
--
-- WHY EVERY BALANCE ASSERTION IS A COMPARISON. The stamp card has three readers — the
-- customer's card (customer_get_stamp_card_v323), the till's card (app.till_stamp_card_v809,
-- what the counter shows) and the progress function both derive from — and its defects have
-- always been two of them disagreeing (v473: staff read the pot, not the card; v416: the card
-- moved under the customer when the config changed). Every step below reads all three.
--
-- NEGATIVE CONTROL, run 2026-09-08 so the un-redeem assertion is known to discriminate: replace
-- the reverse_loyalty_redemption call with a no-op and the suite fails at
--   S13: reversing the stamp gift did not remove its claim
-- The earn, gift and rollover steps are all positive checks (a ledger row, a claims row, a
-- 'completed' cycle row) and cannot pass on a path that did nothing.
--
--   supabase db query --linked -f db/tests/v820_stamp_card_end_to_end.sql

begin;

do $suite$
declare
  c_biz     constant uuid := '8ad4a375-2d42-4e0d-b509-b0e4ed6ccf8c';  -- QA Kopi Lab (Bedok)
  c_slug    constant text := 'qa-kopi-lab';
  c_owner   constant uuid := 'f73a9423-33fd-424c-9fb9-2d5ba058a2d7';
  c_branch  constant uuid := '3f3a88f0-a154-4b50-925b-41c0e93c6321';
  c_svc15   constant uuid := '49d40266-3523-4377-9ca6-c11b0a4a6066';  -- SGD 15.00 service
  c_prog    constant uuid := 'a16c5b4c-8c83-47e0-bb4d-b60aff921972';  -- the stamps pot
  c_gift10  constant uuid := '92997aeb-f9e9-4d86-8cd6-6bbd26b51969';  -- "Free Kopi Set", slot 10
  v_user    uuid; v_client uuid;
  v_per     integer;   -- stamp_per_cents of the pinned version
  v_slots   integer;
  v_cust    jsonb; v_till jsonb; v_prog record;
  v_f0      integer; v_c0 integer; v_l0 integer;
  v_eval    jsonb; v_sale uuid; v_res jsonb;
  v_ledger  integer;
  v_claims  integer;
  v_redemption uuid;
  v_got     integer; v_txt text;
  v_key     text;
  n         integer := 0;

begin
  select l.auth_user_id, l.client_id into v_user, v_client
    from public.customer_links l join public.customer_identities ci on ci.id = l.identity_id and ci.status='active'
   where l.business_id = c_biz and l.state = 'verified' order by l.created_at limit 1;
  if v_client is null then raise exception 'S0: no linked Kopi Lab customer'; end if;

  -- The rate the OPEN card is pinned to (v416), not whatever is published now.
  -- read straight from the pinned version row (loyalty_program_versions is keyed by
  -- config_version_id), the same row the earn trigger resolves through v416
  select v.stamp_per_cents into v_per from public.loyalty_program_versions v
   where v.config_version_id = app.stamp_cycle_version_v416(c_biz, v_client, c_prog);
  if v_per is null then
    select lp.stamp_per_cents into v_per from public.loyalty_programs lp where lp.business_id = c_biz;
  end if;
  if coalesce(v_per,0) <= 0 then raise exception 'S0: no stamp rate on the card'; end if;

  -- ================================================================= S1 baseline agreement
  n := n + 1;
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_user, 'role','authenticated')::text, true);
  v_cust := public.customer_get_stamp_card_v323(c_slug);
  reset role; perform set_config('request.jwt.claims','',true);
  v_till := app.till_stamp_card_v809(c_biz, v_client);
  select * into v_prog from app.stamp_progress_v323(c_biz, v_client) where programme_id = c_prog;
  v_f0 := (v_cust->>'filled')::int; v_c0 := (v_cust->>'cycle_index')::int; v_l0 := (v_cust->>'lifetime')::int;
  v_slots := (v_cust->>'slots')::int;
  if v_f0 is distinct from (v_till->>'filled')::int or v_f0 is distinct from v_prog.filled
     or v_slots is distinct from (v_till->>'slots')::int or v_slots is distinct from v_prog.slots then
    raise exception 'S%: customer card filled=% slots=% | till filled=% slots=% | progress filled=% slots=% — not one card',
      n, v_f0, v_slots, v_till->>'filled', v_till->>'slots', v_prog.filled, v_prog.slots;
  end if;
  if v_f0 >= 10 then
    raise exception 'S%: fixture card already at % stamps; this walk needs headroom below the slot-10 gift', n, v_f0;
  end if;

  -- ====================================================================== S2 EARN
  -- Enough to land exactly on the slot-10 gift from wherever the card is: (10 - filled) stamps.
  -- Each SGD 15.00 service is floor(1500 / per) stamps; buy the qty that gets there exactly.
  n := n + 1;
  v_got := (10 - v_f0);                                   -- stamps wanted
  v_txt := ceil(v_got::numeric * v_per / 1500)::int::text; -- qty of the $15 service
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', c_owner, 'role','authenticated')::text, true);
  v_eval := public.evaluate_checkout(c_biz, c_branch, v_client,
    jsonb_build_array(jsonb_build_object('catalog_kind','service','catalog_id',c_svc15,'qty',v_txt::int)),
    gen_random_uuid(), null::uuid, false)::jsonb;
  v_res := public.record_cart_sale(c_biz, v_client, c_branch, null, 'cash', 'stamp-e2e-'||gen_random_uuid()::text,
    jsonb_build_array(jsonb_build_object('catalog_kind','service','catalog_id',c_svc15,'qty',v_txt::int)),
    (v_eval->>'evaluation_id')::uuid, true, now(), '[]'::jsonb)::jsonb;
  reset role; perform set_config('request.jwt.claims','',true);
  v_sale := (v_res->>'sale_id')::uuid;
  if v_sale is null then raise exception 'S%: the till returned no sale (%)', n, left(v_res::text,200); end if;

  -- the stamps the sale must have earned, from the sale's own amount and the pinned rate
  select floor(s.amount_cents::numeric / v_per)::int into v_got from public.sales s where s.id = v_sale;
  n := n + 1;
  select coalesce(sum(pl.points),0)::int into v_ledger from public.points_ledger pl
   where pl.business_id = c_biz and pl.sale_id = v_sale and pl.programme_id = c_prog and pl.points > 0;
  if v_ledger <> v_got then
    raise exception 'S%: a sale of % cents at % cents/stamp wrote % stamps, expected %',
      n, (select amount_cents from public.sales where id = v_sale), v_per, v_ledger, v_got;
  end if;

  -- all three readers moved by exactly that, together
  n := n + 1;
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_user, 'role','authenticated')::text, true);
  v_cust := public.customer_get_stamp_card_v323(c_slug);
  reset role; perform set_config('request.jwt.claims','',true);
  v_till := app.till_stamp_card_v809(c_biz, v_client);
  select * into v_prog from app.stamp_progress_v323(c_biz, v_client) where programme_id = c_prog;
  if (v_cust->>'filled')::int <> v_f0 + v_got or (v_till->>'filled')::int <> v_f0 + v_got or v_prog.filled <> v_f0 + v_got then
    raise exception 'S%: after earning % stamps: customer %, till %, progress % (from %)',
      n, v_got, v_cust->>'filled', v_till->>'filled', v_prog.filled, v_f0;
  end if;
  n := n + 1;
  if (v_cust->>'lifetime')::int <> v_l0 + v_got then
    raise exception 'S%: lifetime stamps moved % -> %, expected +%', n, v_l0, v_cust->>'lifetime', v_got;
  end if;

  -- the slot-10 gift now shows as claimable on the customer's card, and not yet claimed
  n := n + 1;
  select count(*)::int into v_got from jsonb_array_elements(v_cust->'milestones') m
   where (m->>'reward_id')::uuid = c_gift10 and (m->>'stamps_to_go')::int = 0
     and (m->>'claimed_this_cycle')::boolean = false;
  if v_got <> 1 then
    raise exception 'S%: the slot-10 gift is not shown as claimable on the customer''s card (%)',
      n, (select m::text from jsonb_array_elements(v_cust->'milestones') m where (m->>'reward_id')::uuid = c_gift10);
  end if;

  -- ================================================================ S3 REDEEM the gift
  n := n + 1;
  select count(*)::int into v_claims from public.stamp_milestone_claims
   where business_id = c_biz and client_id = v_client and reward_id = c_gift10;
  v_key := 'stamp-e2e-claim-' || gen_random_uuid()::text;
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', c_owner, 'role','authenticated')::text, true);
  v_res := public.staff_manual_redeem_reward_v404(c_biz, v_client, c_gift10, 1, c_branch, 'other', 'stamp e2e', v_key);
  reset role; perform set_config('request.jwt.claims','',true);
  if coalesce(v_res->>'status','') <> 'ok' then
    raise exception 'S%: redeeming the slot-10 gift answered % ', n, left(v_res::text, 300);
  end if;
  n := n + 1;
  if (select count(*) from public.stamp_milestone_claims where business_id = c_biz and client_id = v_client and reward_id = c_gift10) <> v_claims + 1 then
    raise exception 'S%: the redemption wrote no stamp_milestone_claims row', n;
  end if;

  -- a mid-card gift does not consume stamps or close the card: filled unchanged, both readers
  n := n + 1;
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_user, 'role','authenticated')::text, true);
  v_cust := public.customer_get_stamp_card_v323(c_slug);
  reset role; perform set_config('request.jwt.claims','',true);
  v_till := app.till_stamp_card_v809(c_biz, v_client);
  if (v_cust->>'filled')::int <> 10 or (v_till->>'filled')::int <> 10 then
    raise exception 'S%: claiming the slot-10 gift changed the stamps: customer % till %', n, v_cust->>'filled', v_till->>'filled';
  end if;
  n := n + 1;
  if not exists (select 1 from jsonb_array_elements(v_cust->'milestones') m
                  where (m->>'reward_id')::uuid = c_gift10 and (m->>'claimed_this_cycle')::boolean) then
    raise exception 'S%: the customer''s card does not show the gift as claimed this cycle', n;
  end if;

  -- ================================================================= S4 REPLAY
  n := n + 1;
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', c_owner, 'role','authenticated')::text, true);
  v_res := public.staff_manual_redeem_reward_v404(c_biz, v_client, c_gift10, 1, c_branch, 'other', 'stamp e2e', v_key);
  reset role; perform set_config('request.jwt.claims','',true);
  if (select count(*) from public.stamp_milestone_claims where business_id = c_biz and client_id = v_client and reward_id = c_gift10) <> v_claims + 1 then
    raise exception 'S%: REPLAYING the same key claimed the gift twice', n;
  end if;
  -- and a FRESH key cannot claim it again this cycle either
  n := n + 1;
  begin
    set local role authenticated;
    perform set_config('request.jwt.claims', json_build_object('sub', c_owner, 'role','authenticated')::text, true);
    perform public.staff_manual_redeem_reward_v404(c_biz, v_client, c_gift10, 1, c_branch, 'other', 'stamp e2e again', 'stamp-e2e-again-'||gen_random_uuid()::text);
    reset role; perform set_config('request.jwt.claims','',true);
  exception when others then
    reset role; perform set_config('request.jwt.claims','',true);
  end;
  if (select count(*) from public.stamp_milestone_claims where business_id = c_biz and client_id = v_client and reward_id = c_gift10) <> v_claims + 1 then
    raise exception 'S%: the same gift was claimed twice in one cycle', n;
  end if;

  -- =========================================================== S5 UN-REDEEM (nestly_v802)
  n := n + 1;
  select r.id into v_redemption from public.loyalty_redemptions r
   where r.business_id = c_biz and r.client_id = v_client and r.reward_id = c_gift10
   order by r.redeemed_at desc limit 1;
  if v_redemption is null then raise exception 'S%: no loyalty_redemptions row to reverse', n; end if;
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', c_owner, 'role','authenticated')::text, true);
  v_res := public.reverse_loyalty_redemption(c_biz, v_redemption, 'stamp e2e: wrong customer', 'stamp-e2e-rev-'||gen_random_uuid()::text)::jsonb;
  reset role; perform set_config('request.jwt.claims','',true);
  if (select count(*) from public.stamp_milestone_claims where business_id = c_biz and client_id = v_client and reward_id = c_gift10) <> v_claims then
    raise exception 'S%: reversing the stamp gift did not remove its claim (%)', n, left(v_res::text, 300);
  end if;
  n := n + 1;
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_user, 'role','authenticated')::text, true);
  v_cust := public.customer_get_stamp_card_v323(c_slug);
  reset role; perform set_config('request.jwt.claims','',true);
  if exists (select 1 from jsonb_array_elements(v_cust->'milestones') m
              where (m->>'reward_id')::uuid = c_gift10 and (m->>'claimed_this_cycle')::boolean) then
    raise exception 'S%: after the reversal the customer''s card still shows the gift as claimed', n;
  end if;

  -- ============================================== S6 FILL PAST THE LAST SLOT: ROLLOVER + CARRY
  -- From 10, earn 6 so the card passes 15 by one: qty of the $15 service = ceil(6*per/1500).
  n := n + 1;
  v_txt := ceil(6::numeric * v_per / 1500)::int::text;
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', c_owner, 'role','authenticated')::text, true);
  v_eval := public.evaluate_checkout(c_biz, c_branch, v_client,
    jsonb_build_array(jsonb_build_object('catalog_kind','service','catalog_id',c_svc15,'qty',v_txt::int)),
    gen_random_uuid(), null::uuid, false)::jsonb;
  v_res := public.record_cart_sale(c_biz, v_client, c_branch, null, 'cash', 'stamp-e2e-fill-'||gen_random_uuid()::text,
    jsonb_build_array(jsonb_build_object('catalog_kind','service','catalog_id',c_svc15,'qty',v_txt::int)),
    (v_eval->>'evaluation_id')::uuid, true, now(), '[]'::jsonb)::jsonb;
  reset role; perform set_config('request.jwt.claims','',true);
  v_sale := (v_res->>'sale_id')::uuid;
  select floor(s.amount_cents::numeric / v_per)::int into v_got from public.sales s where s.id = v_sale;  -- stamps earned now
  if 10 + v_got <= v_slots then
    raise exception 'S%: fixture arithmetic: 10 + % earned does not pass the % slots', n, v_got, v_slots;
  end if;

  -- v489: the cycle closed with origin completed, the index advanced, the excess carried
  n := n + 1;
  if not exists (select 1 from public.stamp_cycles c
                  where c.business_id = c_biz and c.client_id = v_client and c.programme_id = c_prog
                    and c.cycle_index = v_c0 and c.origin = 'completed') then
    raise exception 'S%: reaching the last slot did not close cycle % as completed', n, v_c0;
  end if;
  n := n + 1;
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_user, 'role','authenticated')::text, true);
  v_cust := public.customer_get_stamp_card_v323(c_slug);
  reset role; perform set_config('request.jwt.claims','',true);
  v_till := app.till_stamp_card_v809(c_biz, v_client);
  select * into v_prog from app.stamp_progress_v323(c_biz, v_client) where programme_id = c_prog;
  if (v_cust->>'cycle_index')::int <> v_c0 + 1 then
    raise exception 'S%: the customer''s card did not move to the next cycle (% -> %)', n, v_c0, v_cust->>'cycle_index';
  end if;
  n := n + 1;
  if (v_cust->>'filled')::int <> (10 + v_got - v_slots)
     or (v_till->>'filled')::int <> (10 + v_got - v_slots)
     or v_prog.filled <> (10 + v_got - v_slots) then
    raise exception 'S%: the excess did not flow onto the new card: customer % till % progress % (expected %)',
      n, v_cust->>'filled', v_till->>'filled', v_prog.filled, 10 + v_got - v_slots;
  end if;
  n := n + 1;
  if (v_cust->>'lifetime')::int <> v_l0 + (10 - v_f0) + v_got then
    raise exception 'S%: lifetime stamps % != expected %', n, v_cust->>'lifetime', v_l0 + (10 - v_f0) + v_got;
  end if;

  raise notice 'stamp card end to end: % / % assertions passed', n, n;
end
$suite$;

rollback;
