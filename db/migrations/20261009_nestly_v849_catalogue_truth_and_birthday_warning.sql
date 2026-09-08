-- NESTLY v849 — the reward catalogue stops advertising a gift no counter will honour, and a
-- business that publishes a birthday gift the platform cannot deliver is TOLD so.
--
-- Two independent defects, both of the same family: a surface that reports success while the
-- machinery behind it refuses.
--
-- ============================================================================================
-- CONTRACT — what the two birthday RPCs return after this file, for whoever writes the screen.
-- ============================================================================================
-- The business is still not TOLD until a client renders this; that change belongs to app/app.js
-- and is made on a different branch. This section is the shape that branch can rely on. Every
-- field below is ADDITIVE: no existing key changes its name, its type or its meaning, and none
-- is removed, so a client that has not been updated behaves exactly as it does today.
--
--   public.business_save_birthday_program_v424(business uuid, payload jsonb, key text) -> jsonb
--     unchanged   status      text     -- 'published'
--                 version_id  uuid
--                 program_id  uuid
--                 replayed    boolean
--     NEW         platform_delivery  object, ALWAYS present:
--                   feature_key       text     -- always the literal 'customer_birthday_benefits'
--                   platform_enabled  boolean  -- true = birthday gifts are actually delivered
--     NEW         warnings           array, ALWAYS present, may be empty. Each entry:
--                   code     text  -- machine-readable. The only value today is the literal
--                                  --   'birthday_delivery_disabled'
--                   message  text  -- a finished sentence written for a business owner
--
--   public.get_active_birthday_program(business uuid) -> jsonb
--     unchanged   status  text ('published' | 'unavailable'), as_of timestamptz, programs array
--     NEW         platform_delivery  the same object, the same two fields, on BOTH status values
--     NEW         warnings           the same array, the same entry shape, on BOTH status values
--
-- HOW TO CONSUME IT, one rule for both calls: if `warnings` is non-empty, show every entry's
-- `message`; branch on `code`, never on the message text. Do NOT re-derive the condition from
-- `platform_delivery` plus the programme rows — the server applies one rule ("a programme that
-- is ACTIVE on the firm's live config version is published while platform delivery is off") on
-- both surfaces, and the acceptance suite asserts the two sentences are identical (T13), so a
-- second copy of the rule in the browser could only drift away from it.
-- `platform_delivery` is there for a screen that wants to show the state even when nothing is
-- wrong. A save that returns status 'published' WITH a warning DID publish: the warning says
-- the platform will not deliver it yet, never that the save failed — so it must not be rendered
-- as an error, and the existing success path must not be replaced by a failure path.
--
-- ============================================================================================
-- (A) THE CATALOGUE ADVERTISED A GIFT NO PATH CAN CLAIM  (latent today — see LATENCY below)
-- ============================================================================================
-- public.customer_get_reward_catalog renders every row app.reward_availability_v432 returns.
-- For a gift restricted to a branch, a service or a product it reported
--   availability = 'available_at_counter', claim_method = 'counter', quantity = 1
-- and an eligibility block saying scope='restricted'. Observed on production 2026-09-08 in a
-- rolled-back probe: a service-scoped gift came back
--   available_at_counter | claim_method=counter | services {"count":1,"scope":"restricted"}
--
-- There is no path that honours that. Read from production before writing this file:
--   * public.customer_create_redemption_intent_v89 refuses EVERY context-restricted gift —
--     'context-restricted rewards require staff-assisted redemption';
--   * public.merchant_scan_redemption_qr_v117 refuses service/product scope outright, and it can
--     only ever scan an intent the line above already refused to mint;
--   * public.staff_manual_redeem_reward_v404 calls
--     app.redeem_reward_core(p_business, p_client, p_reward, key, p_branch, null, null), so
--     app.redeem_reward_core's own checks raise 'reward not eligible for service' /
--     'reward not eligible for product' unconditionally — observed on production in the same
--     probe: P0001 reward not eligible for service;
--   * and public.staff_get_customer_actionable_loyalty_v145, which is the list the counter
--     redeems FROM, drops every restricted row (`branch_count = 0 and service_count = 0 and
--     product_count = 0`), so even the branch-only case — the one app.redeem_reward_core would
--     accept if a staff member passed the matching branch — never reaches a staff member at all.
--     Observed on production 2026-09-08, in a firm holding one unrestricted and one
--     service-scoped gift: that reader listed the unrestricted gift and nothing else -- the
--     restricted one was simply absent.
--
-- Two sibling readers already state the honest predicate: app.customer_ready_reward_count_v465
-- and public.staff_get_customer_actionable_loyalty_v145 both filter
-- `branch_count = 0 and service_count = 0 and product_count = 0`. Observed on production in
-- the same probe, where the customer could afford both gifts: the catalogue advertised BOTH as
-- 'available_at_counter', while app.customer_ready_reward_count_v465 returned
-- {"count": 1, "choose_one": false} -- it counts only the unrestricted one. The readiness tile
-- said one gift was ready; the list underneath it promised two. This migration makes the
-- catalogue agree with its siblings.
--
-- WHICH OF THE TWO OPTIONS, AND WHY. The brief allowed either "stop calling it available" or
-- "mark it in a way the customer app can render honestly". This file MARKS it, and does not drop
-- it, for one reason: the row carries the owner's own "Where it works" sentence
-- (customerRewardRulesRowsV468 in app/app.js prints `N eligible services` from this very
-- eligibility block). Dropping the row would hide a gift the business really did publish and
-- leave the customer no way to learn it exists or why it is out of reach; marking it keeps the
-- explanation on screen and takes away only the false promise.
--
-- HOW THE MARK RENDERS TODAY, WITH NO CLIENT CHANGE. app/app.js gates redeemability on the
-- server's word — customerRewardCanRedeem() requires availability === 'available_at_counter' —
-- so the new value removes the gift from claimableRewardsV422, from the ready carousel and from
-- readyCountV397 automatically. Its copy table CUSTOMER_REWARD_AVAILABILITY_COPY_V399 has no
-- entry for 'context_restricted' and falls through to 'Not available right now', which is
-- deliberate in that file: "an availability we do not recognise must never render as ready".
-- Truthful, and no worse than silence. A follow-up UI change can give 'context_restricted' its
-- own sentence; it is NOT made here because this migration owns database objects only.
--
-- WHAT (A) DOES NOT TOUCH. app.reward_availability_v432 — not owned by this change and shared by
-- every sibling reader; the eligibility block itself (the customer still reads exactly the same
-- "where it works" counts); every availability value other than 'available_at_counter' (a
-- restricted gift that is 'ended', 'reward_expired' or 'tier_locked' keeps the more specific and
-- equally true word it already had); and the three scope tables and their writers.
--
-- LATENCY. public.loyalty_reward_branches / _services / _products hold 0 rows each estate-wide
-- (counted on production 2026-09-08), so no live customer is looking at this today. The fix is
-- preventative: the first firm to scope a gift would have hit it.
--
-- ============================================================================================
-- (B) A BUSINESS COULD PUBLISH A BIRTHDAY GIFT THE PLATFORM WILL NEVER DELIVER  (live)
-- ============================================================================================
-- app.platform_feature_enabled('customer_birthday_benefits') has been FALSE since
-- 2026-07-22 08:13:35+00 (app.platform_feature_flags, read on production 2026-09-08). Every
-- customer- and staff-facing birthday RPC guards on it and refuses with 0A000:
-- public.customer_get_birthday_participation, public.redeem_customer_birthday_benefit,
-- public.staff_get_customer_birthday_benefit, and app.c45_customer_birthday_context /
-- app.c44_actionable_wallet_card downstream of them.
--
-- The BUSINESS-side pair did not mention it. Observed on production in a rolled-back probe:
--   business_save_birthday_program_v424 returned
--     {"status":"published","replayed":false,"program_id":"…","version_id":"…"}
--   get_active_birthday_program returned top-level keys  as_of, programs, status
--   and the published programme's `active` was true.
--   Neither payload contained the string 'birthday_benefits' anywhere.
-- Four tenants (heng-heng-888, jess-salon, kky-demo, kopi-tiam-tyeh) each hold exactly one
-- active birthday_program_versions row on their live config version, and nothing has ever told
-- them it is inert.
--
-- THE FLAG IS NOT FLIPPED HERE. Switching birthday benefits on is the owner's decision and a
-- different change. This migration fixes the SILENCE.
--
-- WARNING, NOT REFUSAL — and why. Refusing the save would strand exactly the people it is meant
-- to protect: the four firms above could no longer edit, correct or DEACTIVATE the programme
-- they already have, because turning it off is itself a save. It would also block a firm from
-- preparing a programme ahead of the switch-on. The brief names the real defect precisely — "a
-- save that a firm cannot distinguish from a working one" — so what is added is a distinction,
-- not a wall: every save now returns `platform_delivery` (the switch's live state) and, when the
-- programme it just published is ACTIVE while delivery is off, exactly one machine-readable
-- `warnings` entry coded 'birthday_delivery_disabled'. get_active_birthday_program returns the
-- same `platform_delivery` object AND the same `warnings` array on both of its return paths, so
-- the business screen can show the state without a second round trip, and — more importantly —
-- without re-deriving the rule in the browser from the parts.
--
-- BOTH HALVES OF THE ADVISORY ARE FACTS ABOUT TODAY, INCLUDING ON A REPLAY. The advisory asks
-- two questions: is the platform switch off, and is the programme this receipt names ACTIVE.
-- The first is read live. So is the second, and it must be: public.birthday_program_versions
-- rows are CLONED FORWARD on every publish, including publishes that have nothing to do with
-- birthdays, so the config version frozen in a receipt is a historical snapshot. Counted on
-- production 2026-09-08: kopi-tiam-tyeh holds 20 birthday rows across 20 distinct config
-- versions, exactly one of them on its live version, and 19 of the 20 say active. Of the seven
-- receipts in birthday_program_save_operations_v424, four already sit on a stale version, and
-- one of those — key 5ff4f850…, saved 2026-08-25 — is frozen at active=false while the firm's
-- LIVE birthday row says active=true. Judging that key's replay by its frozen version would
-- have stayed silent about a programme that is active and undeliverable right now. The replay
-- branch therefore resolves the programme against the firm's CURRENT active_config_version_id,
-- by the same join this function already uses to find a firm's live birthday programme and the
-- same one get_active_birthday_program reads by. (On the fresh path the version just published
-- IS the live one — publish_loyalty_config sets businesses.active_config_version_id to it — so
-- that path asks the same question with the id already in hand.)
--
-- THE FOUR LIVE PROGRAMMES ARE UNTOUCHED. No stored row changes; the draft→save→publish chain is
-- byte-identical; the advisory is computed at RETURN time and is deliberately NOT written into
-- birthday_program_save_operations_v424.result, so the stored receipt stays the stable identity
-- of the operation and a replay answers about today — both the platform switch and the
-- programme — rather than about the moment of the original save. The moment the flag is
-- switched on, the same rows light up and the warning stops being emitted — asserted in the
-- acceptance suite (T12/T15/T16, with T19 for the delayed replay).
--
-- WHAT (B) DOES NOT TOUCH. app.platform_feature_flags (not one row is written by this file),
-- public.save_birthday_program_draft, public.create_loyalty_config_draft,
-- public.publish_loyalty_config, public.birthday_program_save_operations_v424's columns or
-- contents, the idempotency/replay contract, the 40001 key-reuse refusal, the owner
-- authorisation gate app.c45_owner_loyalty_write, or any customer- or staff-facing birthday RPC.
--
-- ============================================================================================
-- FORM. All five changes are extract-and-diff splices: the live definition is read with
-- pg_get_functiondef, each anchor is asserted to occur EXACTLY ONCE, the replacement is made and
-- the definition is executed. Nothing is restated whole, so no block of any of these three
-- functions can be silently reverted by this file. If production has drifted, the pre-flight
-- raises and the migration refuses. Re-applying this migration also refuses (the anchors are
-- gone), which is the intended behaviour for a one-shot splice.
--
-- ACCEPTANCE: db/tests/v849_catalogue_truth_and_birthday_warning.sql (and the identical
-- db/tests/executed/ copy).
-- Replay: LC_ALL=C node scripts/db-tests/run.mjs --migrated-only --filter=v849

begin;

set local search_path = pg_catalog, public, app, pg_temp;

-- ============================================================================================
-- 1 · PRE-FLIGHT — the live bodies are the ones this migration was written against, and the
--     premises it reasons from are still true.
-- ============================================================================================
do $v849_pre$
declare
  v_cat  text;
  v_get  text;
  v_save text;
  v_ready text;
  v_staff text;
  function_missing constant text := 'v849: %s is not present -- refusing to splice a function that does not exist';
begin
  select pg_get_functiondef(p.oid) into v_cat from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'customer_get_reward_catalog';
  if v_cat is null then raise exception '%', format(function_missing, 'public.customer_get_reward_catalog'); end if;

  select pg_get_functiondef(p.oid) into v_get from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_active_birthday_program';
  if v_get is null then raise exception '%', format(function_missing, 'public.get_active_birthday_program'); end if;

  select pg_get_functiondef(p.oid) into v_save from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'business_save_birthday_program_v424';
  if v_save is null then raise exception '%', format(function_missing, 'public.business_save_birthday_program_v424'); end if;

  /* Anchor 1..3 — the three catalogue fields being spliced. Each must occur exactly once. */
  if (length(v_cat) - length(replace(v_cat, $a$    'availability', core.availability,$a$, ''))) <> length($a$    'availability', core.availability,$a$)
     or (length(v_cat) - length(replace(v_cat, $a$    'quantity', core.quantity,$a$, ''))) <> length($a$    'quantity', core.quantity,$a$)
     or (length(v_cat) - length(replace(v_cat, $a$    'claim_method', 'counter',$a$, ''))) <> length($a$    'claim_method', 'counter',$a$)
  then
    raise exception 'v849: public.customer_get_reward_catalog does not carry the availability / '
      'quantity / claim_method lines v849 splices, each exactly once -- production has drifted, '
      'or v849 is already applied. Re-read pg_get_functiondef before replacing it.';
  end if;

  /* The eligibility block v849 reasons from: it is what tells the reader WHY a gift is
     restricted, and it is carried forward untouched. */
  if position($a$'branches', jsonb_build_object('scope', case when core.branch_count = 0 then 'all' else 'restricted' end, 'count', core.branch_count)$a$ in v_cat) = 0 then
    raise exception 'v849: the catalogue eligibility block is not the one v849 was written against';
  end if;

  /* Anchor 4..5 — the two get_active_birthday_program return paths. */
  if (length(v_get) - length(replace(v_get, $a$      'status','unavailable','as_of',v_as_of,'programs','[]'::jsonb$a$, ''))) <> length($a$      'status','unavailable','as_of',v_as_of,'programs','[]'::jsonb$a$)
     or (length(v_get) - length(replace(v_get, $a$    'status','published',
    'as_of',v_as_of,$a$, ''))) <> length($a$    'status','published',
    'as_of',v_as_of,$a$)
  then
    raise exception 'v849: public.get_active_birthday_program does not carry both of its return '
      'headers exactly once -- production has drifted, or v849 is already applied';
  end if;

  /* Anchor 6..8 — the save function's declare tail and its two return statements. */
  if (length(v_save) - length(replace(v_save, $a$  v_result      jsonb;$a$, ''))) <> length($a$  v_result      jsonb;$a$)
     or (length(v_save) - length(replace(v_save, $a$    return coalesce(v_replay.result,'{}'::jsonb) || jsonb_build_object('replayed', true);$a$, ''))) <> length($a$    return coalesce(v_replay.result,'{}'::jsonb) || jsonb_build_object('replayed', true);$a$)
     or (length(v_save) - length(replace(v_save, $a$  return v_result || jsonb_build_object('replayed', false);$a$, ''))) <> length($a$  return v_result || jsonb_build_object('replayed', false);$a$)
  then
    raise exception 'v849: public.business_save_birthday_program_v424 does not carry its declare '
      'tail and both return statements exactly once -- production has drifted, or v849 is '
      'already applied';
  end if;

  /* The save chain v849 carries forward untouched. If any of these has been re-plumbed, the
     reasoning in this file's header is no longer describing the live function. */
  if position('public.save_birthday_program_draft(v_version, v_program_id, v_program, v_hash)' in v_save) = 0
     or position('public.publish_loyalty_config(v_version)' in v_save) = 0
     or position('app.c45_owner_loyalty_write(p_business)' in v_save) = 0
     or position('birthday_program_save_operations_v424' in v_save) = 0
  then
    raise exception 'v849: the birthday save chain (owner gate, draft, publish, receipt) is not '
      'the one v849 was written against';
  end if;

  /* PREMISE OF (A): the two sibling readers really do exclude context-restricted gifts. If a
     later change taught them to include such gifts through some new claim path, marking them
     unavailable here would be wrong, and this migration must be re-thought rather than applied. */
  select pg_get_functiondef('app.customer_ready_reward_count_v465(uuid,uuid,timestamptz)'::regprocedure) into v_ready;
  select pg_get_functiondef('public.staff_get_customer_actionable_loyalty_v145(uuid,uuid,uuid)'::regprocedure) into v_staff;
  if position('core.branch_count = 0' in v_ready) = 0
     or position('core.service_count = 0' in v_ready) = 0
     or position('core.product_count = 0' in v_ready) = 0
     or position('core.branch_count = 0' in v_staff) = 0
     or position('core.service_count = 0' in v_staff) = 0
     or position('core.product_count = 0' in v_staff) = 0
  then
    raise exception 'v849: app.customer_ready_reward_count_v465 / '
      'public.staff_get_customer_actionable_loyalty_v145 no longer exclude context-restricted '
      'gifts -- a claim path may have been added, and the catalogue must agree with THAT, not '
      'with this file';
  end if;

  /* PREMISE OF (A), the other half: the redemption paths really do refuse. */
  if position('context-restricted rewards require staff-assisted redemption'
       in pg_get_functiondef('public.customer_create_redemption_intent_v89(uuid,uuid,uuid,text)'::regprocedure)) = 0
     or position('app.redeem_reward_core(p_business, p_client, p_reward, v_unit_key, p_branch, null, null)'
       in pg_get_functiondef('public.staff_manual_redeem_reward_v404(uuid,uuid,uuid,integer,uuid,text,text,text)'::regprocedure)) = 0
     or position('reward not eligible for service'
       in pg_get_functiondef('app.redeem_reward_core(uuid,uuid,uuid,text,uuid,uuid,uuid)'::regprocedure)) = 0
  then
    raise exception 'v849: the redemption refusals this migration is telling the truth ABOUT are '
      'no longer in place -- re-read them before changing the catalogue';
  end if;

  /* PREMISE OF (B): the platform switch exists and is the one every birthday RPC reads. Its
     VALUE is not asserted -- this migration is correct with the flag on or off. */
  if not exists (select 1 from app.platform_feature_flags where feature_key = 'customer_birthday_benefits') then
    raise exception 'v849: app.platform_feature_flags has no customer_birthday_benefits row -- '
      'the state this migration reports does not exist';
  end if;
  if position($a$app.platform_feature_enabled('customer_birthday_benefits')$a$
       in pg_get_functiondef('public.staff_get_customer_birthday_benefit(uuid,uuid)'::regprocedure)) = 0 then
    raise exception 'v849: public.staff_get_customer_birthday_benefit no longer guards on '
      'customer_birthday_benefits -- the flag may no longer be what blocks delivery';
  end if;
end
$v849_pre$;

-- ============================================================================================
-- 2 · (A) public.customer_get_reward_catalog — three field splices.
-- ============================================================================================
do $v849_catalog$
declare
  v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'customer_get_reward_catalog';

  v_def := replace(v_def,
$old$    'availability', core.availability,$old$,
$new$    -- nestly_v849: a gift restricted to a branch, a service or a product has no claim path
    -- left. customer_create_redemption_intent_v89 refuses every context-restricted gift;
    -- staff_manual_redeem_reward_v404 calls app.redeem_reward_core(..., p_branch, null, null),
    -- so a service- or product-scoped gift is refused there unconditionally; and
    -- staff_get_customer_actionable_loyalty_v145 -- the list a counter redeems FROM -- drops
    -- every restricted row, so even the branch-only case never reaches a staff member. Saying
    -- 'available_at_counter' was the catalogue promising something the counter would refuse.
    -- app.customer_ready_reward_count_v465 and staff_get_customer_actionable_loyalty_v145 both
    -- already filter on `branch_count = 0 and service_count = 0 and product_count = 0`; this is
    -- the same judgement, stated for the catalogue. Only the one dishonest value is overridden:
    -- a restricted gift that is 'ended', 'reward_expired' or 'tier_locked' keeps that more
    -- specific -- and equally true -- word.
    'availability', case
      when core.branch_count + core.service_count + core.product_count > 0
           and core.availability = 'available_at_counter'
        then 'context_restricted'
      else core.availability end,$new$);

  v_def := replace(v_def,
$old$    'quantity', core.quantity,$old$,
$new$    -- nestly_v849: core.quantity counts only the arms that are 'available_at_counter', so
    -- every OTHER unavailable state already reports 0. The context-restricted row was the one
    -- exception -- it would have shipped "1 claimable" beside an availability that says nothing
    -- is claimable. Reported as 0 so the payload cannot contradict itself.
    -- This changes no rendering today, and is not claimed to: app/app.js reads quantity only
    -- through instanceCountV496, and only for rows that already passed the availability gate
    -- (claimableRewardsV422), where it floors at 1. The availability value above is what does
    -- the work; this is payload hygiene, so a later reader cannot be misled by the count.
    'quantity', case
      when core.branch_count + core.service_count + core.product_count > 0
        then 0 else core.quantity end,$new$);

  v_def := replace(v_def,
$old$    'claim_method', 'counter',$old$,
$new$    -- nestly_v849: this field names HOW the gift is claimed and was hardcoded 'counter' for
    -- every row. For a context-restricted gift there is no counter that will take it. No client
    -- reads this field today -- 'claim_method' appears nowhere in app/app.js -- so, like the
    -- quantity below, this is the payload being made to stop contradicting itself rather than a
    -- rendering change.
    'claim_method', case
      when core.branch_count + core.service_count + core.product_count > 0
        then 'unavailable' else 'counter' end,$new$);

  if position('context_restricted' in v_def) = 0
     or position($q$then 'unavailable' else 'counter' end$q$ in v_def) = 0
     or position($q$then 0 else core.quantity end$q$ in v_def) = 0 then
    raise exception 'v849: the catalogue splice did not take -- refusing to execute an unchanged '
      'definition';
  end if;
  execute v_def;
end
$v849_catalog$;

-- ============================================================================================
-- 3 · (B) public.get_active_birthday_program — the platform state, on BOTH return paths.
-- ============================================================================================
do $v849_get$
declare
  v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_active_birthday_program';

  v_def := replace(v_def,
$old$      'status','unavailable','as_of',v_as_of,'programs','[]'::jsonb$old$,
$new$      'status','unavailable','as_of',v_as_of,'programs','[]'::jsonb,
      -- nestly_v849: reported on BOTH return paths, so a business screen never has to decide
      -- whether a missing key means "delivering" or "this reader is too old to say". `warnings`
      -- is here for the same reason and is necessarily empty: this path lists no programme, so
      -- nothing has been promised to anybody.
      'warnings','[]'::jsonb,
      'platform_delivery', jsonb_build_object(
        'feature_key','customer_birthday_benefits',
        'platform_enabled', app.platform_feature_enabled('customer_birthday_benefits'))$new$);

  v_def := replace(v_def,
$old$    'status','published',
    'as_of',v_as_of,$old$,
$new$    'status','published',
    'as_of',v_as_of,
    -- nestly_v849: the platform switch that decides whether ANY programme listed below can
    -- actually reach a customer. app.platform_feature_enabled('customer_birthday_benefits') has
    -- been false since 2026-07-22 and every customer- and staff-facing birthday RPC refuses on
    -- it -- while this reader returned a published, ACTIVE programme and said nothing about it.
    -- Four firms are live on exactly that state. The flag is not read to change behaviour here
    -- and is emphatically not flipped: switching it on is the owner's decision. What changes is
    -- that the business screen can now see the state its customers are already living in.
    'platform_delivery', jsonb_build_object(
      'feature_key','customer_birthday_benefits',
      'platform_enabled', app.platform_feature_enabled('customer_birthday_benefits')),
    -- nestly_v849: the SAME advisory the save returns, so a business screen has exactly one
    -- rule to render -- "show every entry of `warnings`" -- and never has to re-derive the
    -- condition in the browser out of the delivery object and the programme rows. The rule is
    -- the save's, stated for this reader: an ACTIVE programme on the firm's live config version
    -- is published while platform delivery is off. The sentence is repeated verbatim rather than
    -- shared through a new database object, and the acceptance suite (T13) asserts the two
    -- payloads carry the identical string, so the copies cannot drift apart unnoticed.
    -- (The word the guard below counts must appear once per return path, so this comment says
    -- "delivery object" rather than naming the key.)
    'warnings', case
      when app.platform_feature_enabled('customer_birthday_benefits') then '[]'::jsonb
      when exists (select 1 from public.birthday_program_versions bpv
                    where bpv.business_id = p_business_id
                      and bpv.config_version_id = v_version
                      and bpv.active)
        then jsonb_build_array(jsonb_build_object(
               'code','birthday_delivery_disabled',
               'message','This birthday gift is published, but birthday benefits are switched '
                 || 'off across the platform, so no customer can be given it yet. It will start '
                 || 'working the moment birthday benefits are switched on.'))
      else '[]'::jsonb end,$new$);

  if (length(v_def) - length(replace(v_def, 'platform_delivery', ''))) <> 2 * length('platform_delivery')
     or (length(v_def) - length(replace(v_def, $q$'warnings'$q$, ''))) <> 2 * length($q$'warnings'$q$)
     or (length(v_def) - length(replace(v_def, 'birthday_delivery_disabled', '')))
          <> length('birthday_delivery_disabled') then
    raise exception 'v849: get_active_birthday_program did not gain platform_delivery and '
      'warnings on exactly both return paths, with the advisory on the published path only';
  end if;
  execute v_def;
end
$v849_get$;

-- ============================================================================================
-- 4 · (B) public.business_save_birthday_program_v424 — an explicit, machine-readable warning.
-- ============================================================================================
do $v849_save$
declare
  v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'business_save_birthday_program_v424';

  v_def := replace(v_def,
$old$  v_result      jsonb;$old$,
$new$  v_result      jsonb;
  -- nestly_v849. The advisory this function now returns beside its receipt.
  v_delivery    jsonb;
  v_live_active boolean;
  v_warn_msg    constant text :=
    'This birthday gift is published, but birthday benefits are switched off across the '
    || 'platform, so no customer can be given it yet. It will start working the moment birthday '
    || 'benefits are switched on.';$new$);

  v_def := replace(v_def,
$old$    return coalesce(v_replay.result,'{}'::jsonb) || jsonb_build_object('replayed', true);$old$,
$new$    -- nestly_v849: the advisory is computed NOW rather than read out of the stored receipt.
    -- The receipt is the identity of an operation that already happened and must stay
    -- byte-stable for the request-hash comparison above; whether the platform will deliver the
    -- gift is a fact about today, and a replay hours or months later must not quote a stale one.
    -- That applies to BOTH halves of the judgement, which is why the programme is resolved
    -- against the firm's CURRENT active config version and NOT against
    -- v_replay.config_version_id. birthday_program_versions rows are cloned forward on every
    -- publish, including unrelated ones, so a receipt's version is a historical snapshot:
    -- counted on production 2026-09-08, kopi-tiam-tyeh holds 20 rows across 20 distinct config
    -- versions with one on its live version, and its receipt 5ff4f850… is frozen at
    -- active=false while the live row says active=true. Reading the frozen row would have kept
    -- that replay silent about a programme that is active and undeliverable today. The join
    -- below is the same idiom this function uses a few lines further down to resolve a firm's
    -- live birthday programme, and the one get_active_birthday_program reads by. No row on the
    -- live version (the programme has since been removed) leaves v_live_active null, which
    -- coalesces to false: nothing is being promised, so nothing is warned about.
    select coalesce(bpv.active, false) into v_live_active
      from public.birthday_program_versions bpv
      join public.businesses b
        on b.id = bpv.business_id and b.active_config_version_id = bpv.config_version_id
     where bpv.business_id = p_business
       and bpv.program_id = v_replay.program_id;
    v_delivery := jsonb_build_object(
      'feature_key','customer_birthday_benefits',
      'platform_enabled', app.platform_feature_enabled('customer_birthday_benefits'));
    return coalesce(v_replay.result,'{}'::jsonb) || jsonb_build_object(
      'replayed', true,
      'platform_delivery', v_delivery,
      'warnings', case
        when coalesce(v_live_active, false)
             and not (v_delivery->>'platform_enabled')::boolean
          then jsonb_build_array(jsonb_build_object(
                 'code','birthday_delivery_disabled','message', v_warn_msg))
        else '[]'::jsonb end);$new$);

  v_def := replace(v_def,
$old$  return v_result || jsonb_build_object('replayed', false);$old$,
$new$  -- nestly_v849: the same advisory on the fresh path, judged against the row that was ACTUALLY
  -- published rather than against whatever the payload said -- an omitted 'active' key is
  -- defaulted downstream by save_birthday_program_draft, and it is the stored row that decides
  -- whether a customer would have been given anything. The advisory is deliberately NOT written
  -- into birthday_program_save_operations_v424.result above; see the replay branch.
  -- This names v_version directly where the replay branch joins through
  -- businesses.active_config_version_id, and the two are the SAME question: publish_loyalty_config
  -- has just set active_config_version_id to v_version (asserted by acceptance T18), so on this
  -- path the version in hand IS the live one. The replay branch cannot make that assumption —
  -- its version may be many publishes old.
  select coalesce(bpv.active, false) into v_live_active
    from public.birthday_program_versions bpv
   where bpv.business_id = p_business
     and bpv.program_id = v_program_id
     and bpv.config_version_id = v_version;
  v_delivery := jsonb_build_object(
    'feature_key','customer_birthday_benefits',
    'platform_enabled', app.platform_feature_enabled('customer_birthday_benefits'));
  return v_result || jsonb_build_object(
    'replayed', false,
    'platform_delivery', v_delivery,
    'warnings', case
      when coalesce(v_live_active, false)
           and not (v_delivery->>'platform_enabled')::boolean
        then jsonb_build_array(jsonb_build_object(
               'code','birthday_delivery_disabled','message', v_warn_msg))
      else '[]'::jsonb end);$new$);

  if (length(v_def) - length(replace(v_def, 'birthday_delivery_disabled', '')))
       <> 2 * length('birthday_delivery_disabled')
     or position('v_warn_msg    constant text' in v_def) = 0 then
    raise exception 'v849: the birthday-save splice did not take on both return paths';
  end if;
  execute v_def;
end
$v849_save$;

-- ============================================================================================
-- 5 · ACLs restated, not assumed. A same-signature CREATE OR REPLACE preserves proacl, but that
--     is a fact about Postgres, not a promise this file is entitled to make. Live production ACL
--     before this migration, on all three: {postgres=X/postgres, authenticated=X/postgres,
--     service_role=X/postgres} -- no PUBLIC, no anon. Restated exactly, not widened.
-- ============================================================================================
revoke all on function public.customer_get_reward_catalog(text) from public, anon;
revoke all on function public.get_active_birthday_program(uuid) from public, anon;
revoke all on function public.business_save_birthday_program_v424(uuid, jsonb, text) from public, anon;

grant execute on function public.customer_get_reward_catalog(text) to authenticated, service_role;
grant execute on function public.get_active_birthday_program(uuid) to authenticated, service_role;
grant execute on function public.business_save_birthday_program_v424(uuid, jsonb, text) to authenticated, service_role;

do $v849_acl$
begin
  if pg_catalog.has_function_privilege('anon', 'public.customer_get_reward_catalog(text)', 'execute')
     or pg_catalog.has_function_privilege('anon', 'public.get_active_birthday_program(uuid)', 'execute')
     or pg_catalog.has_function_privilege('anon', 'public.business_save_birthday_program_v424(uuid,jsonb,text)', 'execute')
  then
    raise exception 'v849: anon can execute one of the three functions this migration replaced';
  end if;
  if not pg_catalog.has_function_privilege('authenticated', 'public.customer_get_reward_catalog(text)', 'execute')
     or not pg_catalog.has_function_privilege('authenticated', 'public.get_active_birthday_program(uuid)', 'execute')
     or not pg_catalog.has_function_privilege('authenticated', 'public.business_save_birthday_program_v424(uuid,jsonb,text)', 'execute')
  then
    raise exception 'v849: an authenticated principal lost execute on a function it had before';
  end if;
end
$v849_acl$;

-- ============================================================================================
-- 6 · IN-TRANSACTION VERIFICATION — behaviour, not source text.
--
--     Every fixture below lives in a PL/pgSQL SUB-TRANSACTION that ALWAYS rolls back, and the
--     block ends with before/after row counts on every table it touches -- plus a before/after
--     dump of the WHOLE app.platform_feature_flags table. Production must be byte-identical
--     after this block ran.
--
--     ONE platform flag is touched, inside that rolled-back sub-transaction and only when it is
--     not already on: 'customer_wallet', because app.v32_customer_wallet_context refuses every
--     catalogue read without it and the (A) assertions cannot otherwise run. On production it is
--     already true (since 2026-07-26), so on the real apply this is a no-op; it exists for the
--     scratch cluster the acceptance harness builds. 'customer_birthday_benefits' -- the switch
--     whose state the (B) assertions READ -- is never written, here or anywhere in this file,
--     and the flag-table comparison at the end proves it. The flag-ON half of the birthday
--     contract is proved in the acceptance suite (T15/T16), which never runs against production.
-- ============================================================================================
do $v849_verify$
declare
  v_business uuid; v_slug text; v_branch uuid := gen_random_uuid();
  v_owner_u uuid := gen_random_uuid(); v_owner_s uuid;
  v_customer uuid := gen_random_uuid(); v_identity uuid; v_client uuid;
  v_link uuid := gen_random_uuid();
  v_prog uuid; v_ver uuid; v_service uuid;
  v_reward_free uuid; v_reward_scoped uuid; v_rv uuid;
  v_out jsonb; v_cat jsonb; v_free jsonb; v_scoped jsonb; v_saved jsonb; v_read jsonb;
  v_replay jsonb;
  v_seed uuid := gen_random_uuid();
  v_flag boolean;
  v_biz_before bigint; v_users_before bigint; v_rewards_before bigint;
  v_bpv_before bigint; v_ops_before bigint; v_flags_before text;
  v_biz_after bigint; v_users_after bigint; v_rewards_after bigint;
  v_bpv_after bigint; v_ops_after bigint; v_flags_after text;
begin
  select count(*) into v_biz_before from public.businesses;
  select count(*) into v_users_before from auth.users;
  select count(*) into v_rewards_before from public.loyalty_rewards;
  select count(*) into v_bpv_before from public.birthday_program_versions;
  select count(*) into v_ops_before from public.birthday_program_save_operations_v424;
  select string_agg(feature_key || '=' || enabled::text, ',' order by feature_key)
    into v_flags_before from app.platform_feature_flags;

  v_flag := app.platform_feature_enabled('customer_birthday_benefits');

  begin
    /* app.v32_customer_wallet_context refuses every catalogue read unless this is on. Enabled
       here only if it is off, inside the always-rolled-back sub-transaction, and NEVER
       'customer_birthday_benefits' -- that one is read, not written. */
    if not app.platform_feature_enabled('customer_wallet') then
      insert into app.platform_feature_flags(feature_key, enabled, changed_at)
      values ('customer_wallet', true, now())
      on conflict (feature_key) do update set enabled = true, changed_at = now();
    end if;

    perform set_config('app.v79_system_transition','on',true);
    insert into public.businesses(name,slug,industry,is_synthetic,enabled_modules)
    values('v849 verify','v849-verify-'||substr(gen_random_uuid()::text,1,8),'test',true,
           array['dashboard','clients','sales','loyalty'])
    returning id, slug into v_business, v_slug;
    perform set_config('app.v79_system_transition','',true);

    insert into public.branches(id,business_id,name,is_default,active)
    values(v_branch,v_business,'v849 branch',true,true);
    /* decision_reason is restated in the ON CONFLICT branch, and that is load-bearing on
       PRODUCTION only. public.businesses carries an AFTER INSERT trigger there
       (trg_business_workspace_control_v94 -> app.seed_business_workspace_control_v94), so the row
       already exists as 'pending' by the time this statement runs and the INSERT never happens --
       the DO UPDATE does. Setting approval_status without decision_reason then violates
       business_workspace_controls_v94_decision_shape (approved requires decided_at not null and a
       3..1000 char reason). Observed as 23514 against production 2026-09-08. The scratch cluster
       the acceptance harness builds has no such trigger, takes the INSERT path, and stays green
       either way -- so this is a trap the harness cannot see and only the real apply would hit. */
    insert into public.business_workspace_controls_v94(business_id,approval_status,decided_at,decision_reason)
    values(v_business,'approved',now(),'v849 verify')
    on conflict (business_id) do update set approval_status='approved', decided_at=now(), decision_reason='v849 fixture';
    insert into public.business_subscription_lifecycle_v94(business_id,state,workspace_paused)
    values(v_business,'current',false)
    on conflict (business_id) do update set state='current', workspace_paused=false;
    insert into public.subscriptions(business_id,status,payment_status,current_period_end)
    values(v_business,'active','paid',now()+interval '30 days')
    on conflict (business_id) do update set status='active', payment_status='paid';

    insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
      email_confirmed_at,created_at,updated_at)
    values('00000000-0000-0000-0000-000000000000',v_owner_u,'authenticated','authenticated',
      'v849-owner-'||substr(v_owner_u::text,1,8)||'@example.test','',now(),now(),now());
    insert into public.staff(business_id,user_id,role,active,access_state,full_name)
    values(v_business,v_owner_u,'owner',true,'approved','v849 owner') returning id into v_owner_s;
    insert into public.staff_branches(business_id,staff_id,branch_id)
    values(v_business,v_owner_s,v_branch) on conflict do nothing;

    insert into public.loyalty_programs(business_id,kind,active,loyalty_model,
      configuration_status,earn_points_per_dollar)
    values(v_business,'points',true,'classic','published',1);
    select id into v_ver from public.firm_config_versions
     where business_id=v_business and status='published' order by version_no desc limit 1;
    update public.businesses set active_config_version_id=v_ver
     where id=v_business and active_config_version_id is null;
    insert into public.business_programmes(business_id,kind,active,sort,activated_at)
    values(v_business,'points',true,1,now())
    on conflict (business_id,kind) do update set active=true returning id into v_prog;
    insert into public.services(business_id,name,price_cents,duration_min,active)
    values(v_business,'v849 service',1000,30,true) returning id into v_service;

    insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
      email_confirmed_at,created_at,updated_at)
    values('00000000-0000-0000-0000-000000000000',v_customer,'authenticated','authenticated',
      'v849-cust-'||substr(v_customer::text,1,8)||'@example.test','',now(),now(),now());
    insert into public.customer_identities(auth_user_id,status,created_via)
    values(v_customer,'active','phone_registration') returning id into v_identity;
    insert into public.clients(business_id,full_name)
    values(v_business,'v849 customer') returning id into v_client;
    perform set_config('app.customer_link_insert_id',v_link::text,true);
    insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,state,
      verification_method,verified_at)
    values(v_link,v_business,v_identity,v_customer,v_client,'verified','firm_invitation',now());
    perform set_config('app.customer_link_insert_id','',true);

    /* The EXCLUSIVE fence, not the shared one every till write takes. This block publishes a
       birthday programme further down, and public.publish_loyalty_config calls
       app.acquire_loyalty_exclusive_v480, which REFUSES to upgrade a fence already held
       shared ('unsafe loyalty fence upgrade from shared to exclusive', 40P01) -- observed as
       a hard failure of this very block before the fence was changed. Same idiom, same
       reason, as db/tests/executed/v814_stamp_gift_pause_version_forward.sql. */
    perform app.acquire_loyalty_exclusive_v480(v_business);
    perform set_config('app.points_ledger_insert_id',v_seed::text,true);
    perform set_config('app.points_ledger_write_scope','adjust_points',true);
    insert into public.points_ledger(id,business_id,client_id,entry_type,points,reference,
      programme_id,actor)
    values(v_seed,v_business,v_client,'adjust',500,'v849 verify seed',v_prog,null);
    insert into public.points_batches(business_id,client_id,programme_id,remaining,earned,
      expires_at,earned_at)
    values(v_business,v_client,v_prog,500,500,null,now());
    perform set_config('app.points_ledger_insert_id','',true);
    perform set_config('app.points_ledger_write_scope','',true);

    perform set_config('request.jwt.claims',
      json_build_object('sub',v_owner_u,'role','authenticated')::text,true);
    set local role authenticated;
    v_out := public.business_create_reward_v326(v_business, v_prog, 'v849 free gift'::text,
      10, 0, 'v849'::text, null::text, null::timestamptz, null::text, null::integer, null::integer);
    v_reward_free := (v_out->>'reward_id')::uuid;
    v_out := public.business_create_reward_v326(v_business, v_prog, 'v849 scoped gift'::text,
      10, 0, 'v849'::text, null::text, null::timestamptz, null::text, null::integer, null::integer);
    v_reward_scoped := (v_out->>'reward_id')::uuid;
    reset role;

    /* business_create_reward_v326 publishes; the firm's ACTIVE config version is re-read rather
       than assumed, so the scope row lands on the version reward_availability_v432 reads. */
    select active_config_version_id into v_ver from public.businesses where id=v_business;
    select id into v_rv from public.loyalty_reward_versions
     where reward_id=v_reward_scoped and business_id=v_business and config_version_id=v_ver;
    if v_rv is null then
      raise exception 'v849 verify: the scoped fixture gift has no published version row';
    end if;
    insert into public.loyalty_reward_services(reward_version_id,reward_id,business_id,service_id)
    values(v_rv,v_reward_scoped,v_business,v_service);

    perform set_config('request.jwt.claims',
      json_build_object('sub',v_customer,'role','authenticated')::text,true);
    set local role authenticated;
    v_cat := public.customer_get_reward_catalog(v_slug);
    reset role;
    select value into v_scoped from jsonb_array_elements(v_cat->'rewards') value
     where value->>'customer_name'='v849 scoped gift' limit 1;
    select value into v_free from jsonb_array_elements(v_cat->'rewards') value
     where value->>'customer_name'='v849 free gift' limit 1;

    if v_scoped is null or v_free is null then
      raise exception 'v849 verify: the catalogue did not return both fixture gifts';
    end if;
    if v_scoped->>'availability' <> 'context_restricted'
       or v_scoped->>'claim_method' <> 'unavailable'
       or (v_scoped->>'quantity')::integer <> 0 then
      raise exception 'v849 verify: a service-scoped gift is still advertised as claimable: %',
        v_scoped;
    end if;
    if v_scoped->'eligibility'->'services'->>'scope' <> 'restricted'
       or (v_scoped->'eligibility'->'services'->>'count')::integer <> 1 then
      raise exception 'v849 verify: the eligibility block the customer reads was damaged: %',
        v_scoped->'eligibility';
    end if;
    if v_free->>'availability' <> 'available_at_counter'
       or v_free->>'claim_method' <> 'counter'
       or (v_free->>'quantity')::integer <> 1 then
      raise exception 'v849 verify: v849 took availability away from an UNRESTRICTED gift: %',
        v_free;
    end if;
    if (app.customer_ready_reward_count_v465(v_business, v_client, now())->>'count')::integer <> 1 then
      raise exception 'v849 verify: the catalogue and the ready count no longer agree';
    end if;

    /* (B) — the platform switch is REPORTED, whatever it currently is, and the warning appears
       exactly when the published programme is active and delivery is off. */
    perform set_config('request.jwt.claims',
      json_build_object('sub',v_owner_u,'role','authenticated')::text,true);
    set local role authenticated;
    v_saved := public.business_save_birthday_program_v424(v_business, jsonb_build_object(
      'active',true,'customer_label','v849 birthday','customer_description','A treat.',
      'customer_terms','One a year.','fulfillment_kind','free_item','manual_item','Free slice',
      'window_mode','month','window_days_before',0,'window_days_after',0,'sort',0),
      'v849-verify-'||substr(v_business::text,1,8));
    v_read := public.get_active_birthday_program(v_business);
    reset role;

    if v_saved->>'status' <> 'published' then
      raise exception 'v849 verify: the birthday save stopped publishing: %', v_saved;
    end if;
    if (v_saved->'platform_delivery'->>'platform_enabled')::boolean is distinct from v_flag
       or (v_read->'platform_delivery'->>'platform_enabled')::boolean is distinct from v_flag then
      raise exception 'v849 verify: the reported platform state (% / %) does not match the live '
        'flag (%)', v_saved->'platform_delivery', v_read->'platform_delivery', v_flag;
    end if;
    if v_flag then
      if jsonb_array_length(coalesce(v_saved->'warnings','[]'::jsonb)) <> 0
         or jsonb_array_length(coalesce(v_read->'warnings','[]'::jsonb)) <> 0 then
        raise exception 'v849 verify: delivery is ON and a birthday surface still warned: % / %',
          v_saved->'warnings', v_read->'warnings';
      end if;
    else
      if jsonb_array_length(coalesce(v_saved->'warnings','[]'::jsonb)) <> 1
         or v_saved->'warnings'->0->>'code' <> 'birthday_delivery_disabled' then
        raise exception 'v849 verify: an active birthday programme was published while delivery '
          'is off and the save did not say so: %', v_saved;
      end if;
      /* The reader must carry the SAME advisory, worded identically. The two sentences are
         separate string literals in two functions, and this is what stops them drifting. */
      if jsonb_array_length(coalesce(v_read->'warnings','[]'::jsonb)) <> 1
         or v_read->'warnings'->0->>'code' <> 'birthday_delivery_disabled'
         or v_read->'warnings'->0->>'message'
              is distinct from v_saved->'warnings'->0->>'message' then
        raise exception 'v849 verify: get_active_birthday_program does not carry the save''s '
          'advisory, word for word: % vs %', v_read->'warnings', v_saved->'warnings';
      end if;
    end if;
    if not exists (
      select 1 from public.birthday_program_versions bpv
       join public.businesses b on b.id=bpv.business_id
        and b.active_config_version_id=bpv.config_version_id
       where bpv.business_id=v_business and bpv.active)
    then
      raise exception 'v849 verify: the published birthday row is not live on the firm''s active '
        'config version -- the four existing tenants would not light up';
    end if;
    if (select result from public.birthday_program_save_operations_v424
         where business_id=v_business) ? 'warnings' then
      raise exception 'v849 verify: the live advisory was frozen into the stored receipt';
    end if;

    /* The REPLAY path, exercised here the way a browser retry actually hits it: with a publish
       in between. The intervening save switches the programme off, which — because every publish
       clones birthday_program_versions forward — leaves the ORIGINAL key's receipt pointing at a
       historical version that still says active=true. A replay that read that frozen row would
       warn about a promise the firm has already withdrawn. Four of production's seven receipts
       are on a stale version today and one of them already disagrees with the live row, so this
       is the shape of a real replay here, not a synthetic one. (With delivery switched ON the
       assertion below holds trivially — no surface warns at all; on production, where the flag
       is off, it discriminates.) */
    perform set_config('request.jwt.claims',
      json_build_object('sub',v_owner_u,'role','authenticated')::text,true);
    set local role authenticated;
    perform public.business_save_birthday_program_v424(v_business, jsonb_build_object(
      'program_id',(v_saved->>'program_id')::uuid,
      'active',false,'customer_label','v849 birthday','customer_description','A treat.',
      'customer_terms','One a year.','fulfillment_kind','free_item','manual_item','Free slice',
      'window_mode','month','window_days_before',0,'window_days_after',0,'sort',0),
      'v849-verify-off-'||substr(v_business::text,1,8));
    /* Byte-identical payload and key, or the 40001 key-reuse refusal fires instead of a replay. */
    v_replay := public.business_save_birthday_program_v424(v_business, jsonb_build_object(
      'active',true,'customer_label','v849 birthday','customer_description','A treat.',
      'customer_terms','One a year.','fulfillment_kind','free_item','manual_item','Free slice',
      'window_mode','month','window_days_before',0,'window_days_after',0,'sort',0),
      'v849-verify-'||substr(v_business::text,1,8));
    reset role;
    if not coalesce((v_replay->>'replayed')::boolean,false)
       or v_replay->>'version_id' is distinct from v_saved->>'version_id' then
      raise exception 'v849 verify: the replay contract changed: %', v_replay;
    end if;
    if (v_replay->'platform_delivery'->>'platform_enabled')::boolean is distinct from v_flag then
      raise exception 'v849 verify: a replay reported the wrong platform state: %', v_replay;
    end if;
    if jsonb_array_length(coalesce(v_replay->'warnings','[]'::jsonb)) <> 0 then
      raise exception 'v849 verify: a replay judged the programme by its FROZEN version -- it '
        'warned about a gift the firm has since switched off: %', v_replay;
    end if;

    raise exception 'v849 verify: rollback sentinel' using errcode = 'P0849';
  exception
    when sqlstate 'P0849' then
      null;  -- expected: every assertion passed, the whole fixture is thrown away
  end;

  select count(*) into v_biz_after from public.businesses;
  select count(*) into v_users_after from auth.users;
  select count(*) into v_rewards_after from public.loyalty_rewards;
  select count(*) into v_bpv_after from public.birthday_program_versions;
  select count(*) into v_ops_after from public.birthday_program_save_operations_v424;
  select string_agg(feature_key || '=' || enabled::text, ',' order by feature_key)
    into v_flags_after from app.platform_feature_flags;

  if v_biz_after <> v_biz_before or v_users_after <> v_users_before
     or v_rewards_after <> v_rewards_before or v_bpv_after <> v_bpv_before
     or v_ops_after <> v_ops_before then
    raise exception 'v849 verify: the verification block leaked rows (businesses %/%, users %/%, '
      'rewards %/%, birthday versions %/%, save receipts %/%)',
      v_biz_before, v_biz_after, v_users_before, v_users_after,
      v_rewards_before, v_rewards_after, v_bpv_before, v_bpv_after, v_ops_before, v_ops_after;
  end if;
  if v_flags_after is distinct from v_flags_before then
    raise exception 'v849 verify: a platform feature flag changed -- this migration must never '
      'write one (before: %, after: %)', v_flags_before, v_flags_after;
  end if;

  raise notice 'v849: context-restricted gifts are no longer advertised as claimable, and the '
    'birthday save/read pair now reports the platform delivery switch (currently %). Verified in '
    'a rolled-back sub-transaction; production state unchanged.', v_flag;
end
$v849_verify$;

commit;
