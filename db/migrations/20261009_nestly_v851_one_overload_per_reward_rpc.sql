-- nestly_v851 — one signature per reward RPC again, no anonymous execute on either, and the
-- post-v744 reports stop counting synthetic test customers.
--
-- Numbered v851: v833 was free on origin/main but a parallel session has already applied its own
-- nestly_v832 (commission accuracy) to production and reserves v850 for its commit; v851 is the
-- first number neither session can collide on. Deploy slot 20261009190000: 170000 went to that
-- session's nestly_v850 and 180000 to its nestly_v861 while this was in flight.
--
-- FOUND while clearing the pre-existing failures in db/tests/executed (2026-09-09). Two fixtures
-- (v423_reward_edit, v675_stale_stamp_draft_superseded) and a third's diagnostic probe
-- (v433_v436_stamp_lifecycle) all failed with "function ... is not unique".
--
-- THE DEFECT. nestly_v754 added the optional trailing parameter p_claim_expires_after_days to
-- public.business_create_reward_v326 and public.business_update_reward_v326 with a plain
-- CREATE OR REPLACE. A changed parameter list is a NEW overload, not a replacement, so the
-- pre-v754 signatures stayed live beside the new ones: production carries two of each. Every
-- earlier migration on these functions (v343, v472, v477, v520) dropped the superseded signature
-- first, and v520 built an "exactly one overload" assertion for precisely this reason, quoting
-- nestly_v410 — where twin overloads reachable by the same named arguments (PGRST203) blocked
-- every promotion save. v754's own header says it "does not drop or rename any ... function",
-- which is the misunderstanding: dropping the superseded overload IS still required.
--
-- Why nothing is visibly broken today: app/app.js calls both RPCs with NAMED arguments that always
-- include p_claim_expires_after_days, and PostgREST's named-argument resolution excludes the
-- overload that lacks that name. Any positional caller — SQL, an admin tool, a maintenance
-- script, a fixture — gets 42883 "is not unique". No server-side function calls either RPC
-- (verified: zero pg_proc bodies reference them), so dropping the old signatures breaks nothing.
--
-- THE SECOND DEFECT, found reading the ACLs to restate them: the v754 overloads are executable by
-- `anon`. The overloads they superseded were authenticated + service_role only, and v520's
-- header is explicit — "nothing to PUBLIC". A business-configuration writer must not be callable
-- without a session, whatever its body does with auth.uid() (its first line refuses a caller
-- without owner loyalty access, so this was hygiene, not an open door). Revoked here, and the
-- grants of the surviving signatures are restated verbatim from the pre-v754 ACL.
--
-- THE THIRD DEFECT, from the same sweep. Two more executed fixtures (v743_corpus_synthetic_scanner,
-- v744_corpus_scanner_blind_spots) assert that app.ci_synthetic_scan_v743() — the scanner the
-- v730-v744 wave built so that "synthetic" QA customers never leak into a real business's
-- numbers — reports nothing. It reports six functions written AFTER the scanner was sealed:
--
--   EXCLUDE (real cross-customer reports, no synthetic predicate at all):
--     public.business_staff_commission_lines_v825  — the staff commission PAYOUT report. A QA
--                                                    customer's sale attributed to a real staff
--                                                    member inflates what that person is shown.
--     app.owner_brief_fact_bookings_ahead_v828     — the nightly brief's bookings-ahead count.
--     app.owner_brief_fact_stamps_v828             — the brief's stamp-card funnel.
--     app.owner_brief_fact_memberships_due_v828    — the brief's renewals, incl. a NAME list.
--   ALLOWLIST (single-entity scope, the scanner's known false-positive class — ~30 such rows):
--     app.on_sale_item_commission_snapshot_v825    — BEFORE INSERT trigger; sums the ONE sale's
--                                                    own bundle siblings (li.sale_id = new.sale_id).
--     public.customer_delete_account_v749          — the caller's own linked clients, in a loop.
--
-- Each exclusion uses the estate's own idiom for a non-sales reader — `not exists (select 1 from
-- public.clients c where c.id = X.client_id and c.is_synthetic)`, the shape nestly_v740 used —
-- and is spliced at a code-only anchor, read live, asserted to match exactly once. Anonymous
-- sales (client_id null) are unaffected: NOT EXISTS over a null key is true.
--
-- Heads-up carried in the commit: for any business/window where a synthetic customer's sale
-- carried a staff commission, a commission report re-run after this migration reads LOWER than
-- one run before it. That is the correction, and it is why the report was flagged.
--
-- Also allowlisted, by name only: app.sale_item_discount_commission_v832 and
-- public.sell_package_v832, which nestly_v850 (a parallel session's commission-accuracy work,
-- committed while this migration was in flight) defines without marking. Both were read before
-- being listed: the first computes ONE sale's own discount clawback (li.sale_id = p_sale, the
-- app.v106_sale_residual_minor shape), the second is a single-client purchase that adds p_staff
-- over the already-allowlisted public.sell_package_v102. Their bodies are v850's; this file only
-- records that the scanner may stop reporting them.

begin;

-- 1. The superseded pre-v754 signatures go. Exact signatures, so nothing else can match.
drop function if exists public.business_create_reward_v326(
  uuid, uuid, text, integer, integer, text, text, timestamp with time zone, text, integer);
drop function if exists public.business_update_reward_v326(
  uuid, uuid, text, integer, text, integer, text, boolean, timestamp with time zone, boolean,
  text, integer, boolean);

-- 2. The surviving signatures lose anon and keep exactly what v520 granted.
revoke all on function public.business_create_reward_v326(
  uuid, uuid, text, integer, integer, text, text, timestamp with time zone, text, integer, integer)
  from public, anon;
grant execute on function public.business_create_reward_v326(
  uuid, uuid, text, integer, integer, text, text, timestamp with time zone, text, integer, integer)
  to authenticated, service_role;
revoke all on function public.business_update_reward_v326(
  uuid, uuid, text, integer, text, integer, text, boolean, timestamp with time zone, boolean,
  text, integer, boolean, integer)
  from public, anon;
grant execute on function public.business_update_reward_v326(
  uuid, uuid, text, integer, text, integer, text, boolean, timestamp with time zone, boolean,
  text, integer, boolean, integer)
  to authenticated, service_role;

-- 3. v520's own invariant, re-asserted: exactly one overload each, and anon can execute neither.
do $verify$
declare v_n integer; v_anon integer;
begin
  select count(*) into v_n from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'business_create_reward_v326';
  if v_n <> 1 then
    raise exception 'nestly_v851: % overloads of business_create_reward_v326 — PGRST203 waiting to happen', v_n
      using errcode = 'XX001';
  end if;
  select count(*) into v_n from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'business_update_reward_v326';
  if v_n <> 1 then
    raise exception 'nestly_v851: % overloads of business_update_reward_v326 — PGRST203 waiting to happen', v_n
      using errcode = 'XX001';
  end if;
  select count(*) into v_anon from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname in ('business_create_reward_v326','business_update_reward_v326')
     and has_function_privilege('anon', p.oid, 'EXECUTE');
  if v_anon <> 0 then
    raise exception 'nestly_v851: anon can still execute % reward RPC(s)', v_anon using errcode = 'XX001';
  end if;
end
$verify$;


-- ---------------------------------------------------------------------------------------------
-- 4. The synthetic-client scanner: two allowlist rows, four excluded reports.
-- ---------------------------------------------------------------------------------------------
insert into app.ci_synthetic_scan_allowlist_v743 (function_signature, reason, added_by_migration) values
  ('app.on_sale_item_commission_snapshot_v825()',
   'BEFORE INSERT trigger on sale_items: computes commission for the one row being inserted (new.sale_id) and its own-statement bundle siblings (li.sale_id = new.sale_id); same shape as app.on_sale_recorded.',
   'nestly_v851'),
  ('public.customer_delete_account_v749(p_confirmation text, p_idempotency_key text)',
   'self-service account deletion: the count(*) checks run per caller-linked client inside a loop over the caller''s OWN verified customer_links (identity from auth.uid()), never a business-wide population; same shape as public.erase_client_v290.',
   'nestly_v851'),
  ('app.sale_item_discount_commission_v832(p_business uuid, p_sale uuid, p_line_cents integer)',
   'single-sale kernel (p_sale): computes the commission clawback for one sale''s own discount lines (nestly_v850); same shape as app.v106_sale_residual_minor.',
   'nestly_v851'),
  ('public.sell_package_v832(p_business uuid, p_client uuid, p_plan uuid, p_branch uuid, p_idempotency_key uuid, p_staff uuid)',
   'single-client transactional purchase (p_client), nestly_v850: adds p_staff over the already-allowlisted public.sell_package_v102.',
   'nestly_v851')
on conflict (function_signature) do nothing;

do $splice$
declare
  v_def text; v_new text; v_spec jsonb; v_target text; v_anchor text; v_inject text; v_hits integer;
  v_specs jsonb := jsonb_build_array(

    jsonb_build_object(
      'fn', $t$public.business_staff_commission_lines_v825(uuid,uuid,timestamp with time zone,timestamp with time zone)$t$,
      'anchor', $t$       and (p_branch is null or s.branch_id = p_branch)
       and app.can_see_branch(p_business, s.branch_id)
  ),$t$,
      'inject', $t$       and (p_branch is null or s.branch_id = p_branch)
       and app.can_see_branch(p_business, s.branch_id)
       -- nestly_v851: a QA customer's sale must not pay a real staff member. NOT EXISTS over a
       -- null client_id is true, so anonymous sales keep their commission lines exactly as before.
       and not exists (select 1 from public.clients c where c.id = s.client_id and c.is_synthetic)
  ),$t$),

    jsonb_build_object(
      'fn', $t$app.owner_brief_fact_bookings_ahead_v828(uuid)$t$,
      'anchor', $t$     where a.business_id = p_business
       and a.status not in ('cancelled', 'no_show');$t$,
      'inject', $t$     where a.business_id = p_business
       and a.status not in ('cancelled', 'no_show')
       -- nestly_v851: synthetic customers do not count as bookings.
       and not exists (select 1 from public.clients c where c.id = a.client_id and c.is_synthetic);$t$),

    jsonb_build_object(
      'fn', $t$app.owner_brief_fact_stamps_v828(uuid)$t$,
      'anchor', $t$       where pl.business_id = p_business and pl.programme_id = v_prog
      union all$t$,
      'inject', $t$       where pl.business_id = p_business and pl.programme_id = v_prog
         -- nestly_v851: filtered at the source so every derived CTE inherits it.
         and not exists (select 1 from public.clients c where c.id = pl.client_id and c.is_synthetic)
      union all$t$),
    jsonb_build_object(
      'fn', $t$app.owner_brief_fact_stamps_v828(uuid)$t$,
      'anchor', $t$       where sc.business_id = p_business and sc.programme_id = v_prog
    ),$t$,
      'inject', $t$       where sc.business_id = p_business and sc.programme_id = v_prog
         and not exists (select 1 from public.clients c where c.id = sc.client_id and c.is_synthetic)
    ),$t$),

    jsonb_build_object(
      'fn', $t$app.owner_brief_fact_memberships_due_v828(uuid)$t$,
      'anchor', $t$      from public.memberships m where m.business_id = p_business;$t$,
      'inject', $t$      from public.memberships m where m.business_id = p_business
       -- nestly_v851: synthetic members are not members.
       and not exists (select 1 from public.clients c where c.id = m.client_id and c.is_synthetic);$t$),
    jsonb_build_object(
      'fn', $t$app.owner_brief_fact_memberships_due_v828(uuid)$t$,
      'anchor', $t$      from public.memberships m where m.business_id = p_business and m.status = 'paused';$t$,
      'inject', $t$      from public.memberships m where m.business_id = p_business and m.status = 'paused'
       and not exists (select 1 from public.clients c where c.id = m.client_id and c.is_synthetic);$t$),
    jsonb_build_object(
      'fn', $t$app.owner_brief_fact_memberships_due_v828(uuid)$t$,
      'anchor', $t$       and m.current_period_end >= now() and m.current_period_end <= now() + interval '30 days';$t$,
      'inject', $t$       and m.current_period_end >= now() and m.current_period_end <= now() + interval '30 days'
       and not exists (select 1 from public.clients c where c.id = m.client_id and c.is_synthetic);$t$),
    jsonb_build_object(
      'fn', $t$app.owner_brief_fact_memberships_due_v828(uuid)$t$,
      'anchor', $t$           and m.current_period_end >= now() and m.current_period_end <= now() + interval '30 days'
         order by m.current_period_end$t$,
      'inject', $t$           and m.current_period_end >= now() and m.current_period_end <= now() + interval '30 days'
           and not c.is_synthetic
         order by m.current_period_end$t$),
    jsonb_build_object(
      'fn', $t$app.owner_brief_fact_memberships_due_v828(uuid)$t$,
      'anchor', $t$       and (m.current_period_end at time zone 'Asia/Singapore')::date <= app.sg_today();$t$,
      'inject', $t$       and (m.current_period_end at time zone 'Asia/Singapore')::date <= app.sg_today()
       and not exists (select 1 from public.clients c where c.id = m.client_id and c.is_synthetic);$t$)
  );
begin
  for v_spec in select * from jsonb_array_elements(v_specs) loop
    v_target := v_spec->>'fn'; v_anchor := v_spec->>'anchor'; v_inject := v_spec->>'inject';
    v_def := pg_get_functiondef(v_target::regprocedure);
    if position(v_inject in v_def) > 0 then
      raise notice 'nestly_v851: % already carries this edit, skipping', v_target; continue;
    end if;
    v_hits := (length(v_def) - length(replace(v_def, v_anchor, ''))) / nullif(length(v_anchor), 0);
    if v_hits is distinct from 1 then
      raise exception 'nestly_v851: anchor matched % time(s) in % — the body has drifted; re-derive the anchor',
        coalesce(v_hits, 0), v_target using errcode = 'XX001';
    end if;
    v_new := replace(v_def, v_anchor, v_inject);
    execute v_new;
    raise notice 'nestly_v851: % excludes synthetic customers', v_target;
  end loop;
end
$splice$;

-- Grants of the four spliced functions, restated verbatim from their live proacl.
revoke all on function public.business_staff_commission_lines_v825(uuid, uuid, timestamp with time zone, timestamp with time zone)
  from public, anon;
grant execute on function public.business_staff_commission_lines_v825(uuid, uuid, timestamp with time zone, timestamp with time zone)
  to authenticated, service_role;
revoke all on function app.owner_brief_fact_bookings_ahead_v828(uuid) from public, anon, authenticated;
revoke all on function app.owner_brief_fact_stamps_v828(uuid) from public, anon, authenticated;
revoke all on function app.owner_brief_fact_memberships_due_v828(uuid) from public, anon, authenticated;

-- 5. The scanner no longer reports any of the six.
do $verify2$
declare v_hit text;
begin
  select string_agg(s.schema_name || '.' || s.function_name, ', ') into v_hit
    from app.ci_synthetic_scan_v743() s
   where (s.schema_name, s.function_name) in (
     ('app','on_sale_item_commission_snapshot_v825'), ('app','owner_brief_fact_bookings_ahead_v828'),
     ('app','owner_brief_fact_memberships_due_v828'), ('app','owner_brief_fact_stamps_v828'),
     ('public','business_staff_commission_lines_v825'), ('public','customer_delete_account_v749'),
     ('app','sale_item_discount_commission_v832'), ('public','sell_package_v832'));
  if v_hit is not null then
    raise exception 'nestly_v851: still reported by the synthetic scanner: %', v_hit using errcode = 'XX001';
  end if;
end
$verify2$;

commit;
