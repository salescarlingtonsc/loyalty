-- V340: does claiming this reward require a purchase?
--
-- NOT APPLIED. This file is written, not run. Apply it the way this repo applies every kernel
-- change: replay it inside a rolled-back transaction against production first, assert the eight
-- checks listed at the foot of this file, and only then apply for real.
--
-- WHY A NEW COLUMN AND NOT A DERIVATION
-- The owner mockup ("photo 1") prints "Valid until <date> · No purchase required" under a
-- claimable reward. Nothing in this product could honestly answer that question, and the v339
-- pass therefore refused to render the clause at all. Every candidate field was checked first:
--   fulfillment_kind ('credit' | 'manual_item') says what the customer RECEIVES, not what they
--     must do to get it. A store-credit reward and a free-item reward are both redeemed purely
--     against the points balance today, so neither value implies a purchase requirement.
--   cost_points / credit_cents / estimated_cost_cents are prices and costs, not conditions.
--   claim_available_from / _until and entitlement_expiry_days are a schedule.
--   min_tier_id / min_tier_threshold are a membership gate, a different question entirely.
--   eligibility (branches/services/products) narrows WHERE a reward may be used, and it is
--     tempting to read "restricted to services" as "you must buy that service". It is not: the
--     eligibility tables are checked by app.redeem_reward_core against a context the TILL
--     supplies, and the customer-QR route (merchant_scan_redemption_qr_v89) passes none — so a
--     restricted reward is not, today, a reward that requires a purchase.
-- There is therefore no field that can answer this, and the honest options were to keep the
-- clause unrendered forever or to give owners a real control. This is the control.
--
-- DEFAULT false, DELIBERATELY
-- false = "no purchase required", and that is what every reward in this system does today: the
-- points are proven and deducted by app.redeem_reward_core, no sale is looked at, no minimum
-- spend is checked anywhere in the redemption path. So the default is not a guess about owner
-- intent, it is a statement of current engine behaviour, and existing rewards keep meaning
-- exactly what they already meant. Setting it true is an owner asserting a condition their
-- COUNTER enforces — this migration adds no engine enforcement, and the customer-facing copy
-- reflects that by simply omitting the "No purchase required" clause rather than printing a
-- promise the software does not keep.
--
-- THE THREE KERNEL SURFACES
-- The versioned-config kernel copies reward columns EXPLICITLY in three places, so a new column
-- is silently dropped unless every one learns it (this is the exact failure V176 documented):
--   app.clone_reward_versions_for_config   draft -> draft clone (column-explicit INSERT..SELECT)
--   public.publish_loyalty_config          versions -> live loyalty_rewards (explicit UPDATE)
--   public.save_loyalty_reward_draft       editor -> draft (key allow-list + INSERT + ON CONFLICT)
-- plus two read surfaces:
--   public.get_loyalty_reward_draft        so the editor reads back what it saved
--   public.customer_get_reward_catalog     so the customer card can print the clause
--
-- WHY PATCHES AND NOT RETYPED DEFINITIONS
-- Every one of these five has been amended in production since its last full definition landed
-- in this repo (v197 for the clone, v313's programme_id, v314's switchboard inversion, v331/v332
-- for publish). Retyping them here would silently REVERT those live changes. Each block below
-- therefore reads the live definition with pg_get_functiondef, asserts its anchor is present,
-- refuses to patch blind if it is not, and returns early if the change is already there — so
-- the file is idempotent and can never overwrite work it does not know about.

begin;

alter table public.loyalty_rewards
  add column if not exists requires_purchase boolean not null default false;

alter table public.loyalty_reward_versions
  add column if not exists requires_purchase boolean not null default false;

comment on column public.loyalty_rewards.requires_purchase is
  'V340 owner assertion: true = the customer must also make a purchase to claim this reward. '
  'false (the default, and the behaviour of every redemption path in this product) = the points '
  'balance alone is enough. Not enforced by app.redeem_reward_core — it is a counter condition '
  'the owner states, and the customer surface only ever renders the false case.';
comment on column public.loyalty_reward_versions.requires_purchase is
  'V340 draft-side purchase requirement; carried by app.clone_reward_versions_for_config and '
  'promoted by public.publish_loyalty_config.';

-- 1. draft -> draft clone.
do $$
declare
  v_def text;
  v_cols_anchor text := 'entitlement_expiry_days, instructions, terms, image_ref, usage_limit,';
  v_sel_anchor text := 'source.entitlement_expiry_days, source.instructions, source.terms, source.image_ref,';
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'clone_reward_versions_for_config';
  if v_def is null then raise exception 'app.clone_reward_versions_for_config not found'; end if;
  if v_def like '%requires_purchase%' then return; end if;
  if position(v_cols_anchor in v_def) = 0 or position(v_sel_anchor in v_def) = 0 then
    raise exception 'clone anchors not found; refusing to patch blind';
  end if;
  v_def := replace(v_def, v_cols_anchor,
    'entitlement_expiry_days, instructions, terms, image_ref, requires_purchase, usage_limit,');
  v_def := replace(v_def, v_sel_anchor,
    'source.entitlement_expiry_days, source.instructions, source.terms, source.image_ref, source.requires_purchase,');
  execute v_def;
end $$;

-- 2. publish: draft version -> live loyalty_rewards row.
do $$
declare
  v_def text;
  v_anchor text := 'image_ref=rv.image_ref,usage_limit=rv.usage_limit,';
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'publish_loyalty_config';
  if v_def is null then raise exception 'public.publish_loyalty_config not found'; end if;
  if v_def like '%requires_purchase%' then return; end if;
  if position(v_anchor in v_def) = 0 then
    raise exception 'publish image_ref/usage_limit anchor not found; refusing to patch blind';
  end if;
  execute replace(v_def, v_anchor,
    'image_ref=rv.image_ref,requires_purchase=rv.requires_purchase,usage_limit=rv.usage_limit,');
end $$;

-- 3. editor -> draft. Four edits: the key allow-list, the local, the two INSERTs and the upsert.
--    An unlisted key raises 22023, so the allow-list must learn the field BEFORE the app ever
--    sends it — the owner editor feature-detects this exact column and stays silent until then.
do $$
declare
  v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'save_loyalty_reward_draft';
  if v_def is null then raise exception 'public.save_loyalty_reward_draft not found'; end if;
  if v_def like '%requires_purchase%' then return; end if;

  if position('''instructions'',''terms'',''image_ref'',''usage_limit''' in v_def) = 0
     or position('  v_limit integer;' in v_def) = 0
     or position('v_claim_from, v_claim_until, v_entitlement_days, v_instructions, v_terms, v_image, v_limit,' in v_def) = 0
     or position('v_claim_from, v_claim_until, v_entitlement_days, v_instructions, v_terms, v_image, v_limit' in v_def) = 0
     or position('terms = excluded.terms, image_ref = excluded.image_ref,' in v_def) = 0 then
    raise exception 'save_loyalty_reward_draft anchors not found; refusing to patch blind';
  end if;

  -- allow-list
  v_def := replace(v_def,
    '''instructions'',''terms'',''image_ref'',''usage_limit''',
    '''instructions'',''terms'',''image_ref'',''usage_limit'',''requires_purchase''');
  -- local + its resolution (unset key keeps the stored value, exactly like every field above it)
  v_def := replace(v_def, '  v_limit integer;',
    '  v_limit integer;' || E'\n  v_requires_purchase boolean;');
  v_def := replace(v_def,
    '  v_limit := case when p_reward ? ''usage_limit''',
    '  v_requires_purchase := case when p_reward ? ''requires_purchase'''
      || ' then coalesce((p_reward->>''requires_purchase'')::boolean, false)'
      || ' else coalesce(v_existing.requires_purchase, false) end;' || E'\n'
      || '  v_limit := case when p_reward ? ''usage_limit''');
  -- live-row seed INSERT and draft-version INSERT (same value list text, both replaced)
  v_def := replace(v_def,
    'image_ref, usage_limit, current_config_version_id',
    'image_ref, requires_purchase, usage_limit, current_config_version_id');
  v_def := replace(v_def,
    'v_claim_from, v_claim_until, v_entitlement_days, v_instructions, v_terms, v_image, v_limit,',
    'v_claim_from, v_claim_until, v_entitlement_days, v_instructions, v_terms, v_image, v_requires_purchase, v_limit,');
  v_def := replace(v_def,
    E'    terms, image_ref, usage_limit\n',
    E'    terms, image_ref, requires_purchase, usage_limit\n');
  v_def := replace(v_def,
    E'v_claim_from, v_claim_until, v_entitlement_days, v_instructions, v_terms, v_image, v_limit\n',
    E'v_claim_from, v_claim_until, v_entitlement_days, v_instructions, v_terms, v_image, v_requires_purchase, v_limit\n');
  -- upsert
  v_def := replace(v_def,
    'terms = excluded.terms, image_ref = excluded.image_ref,',
    'terms = excluded.terms, image_ref = excluded.image_ref, requires_purchase = excluded.requires_purchase,');
  execute v_def;
end $$;

do $$
declare v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'save_loyalty_reward_draft';
  if v_def !~ 'v_requires_purchase'
     or v_def !~ 'requires_purchase = excluded.requires_purchase' then
    raise exception 'requires_purchase did not land in save_loyalty_reward_draft';
  end if;
end $$;

-- 4. Owner editor reads back what it saved. Without this the control silently resets on reopen,
--    which is the exact bug V176 hit with the tier picker.
do $$
declare
  v_def text;
  v_anchor text := '''image_ref'', rv.image_ref,';
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_loyalty_reward_draft';
  if v_def is null then raise exception 'public.get_loyalty_reward_draft not found'; end if;
  if v_def like '%requires_purchase%' then return; end if;
  if position(v_anchor in v_def) = 0 then
    raise exception 'get_loyalty_reward_draft image_ref anchor not found; refusing to patch blind';
  end if;
  execute replace(v_def, v_anchor,
    v_anchor || E'\n        ''requires_purchase'', coalesce(rv.requires_purchase, false),');
end $$;

-- 5. Customer read path. Patched, not retyped: V314 recorded an md5 of this function's live
--    definition precisely because it has been amended since V176B wrote it here.
do $$
declare
  v_def text;
  v_out_anchor text := '''cost_points'', listed.cost_points,';
  v_sel_anchor text := 'rv.taxonomy_label, rv.fulfillment_kind, rv.cost_points,';
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'customer_get_reward_catalog';
  if v_def is null then raise exception 'public.customer_get_reward_catalog not found'; end if;
  if v_def like '%requires_purchase%' then return; end if;
  if position(v_out_anchor in v_def) = 0 or position(v_sel_anchor in v_def) = 0 then
    raise exception 'reward catalog anchors not found; refusing to patch blind';
  end if;
  v_def := replace(v_def, v_out_anchor,
    v_out_anchor || E'\n    ''requires_purchase'', coalesce(listed.requires_purchase, false),');
  v_def := replace(v_def, v_sel_anchor,
    'rv.taxonomy_label, rv.fulfillment_kind, rv.cost_points, rv.requires_purchase,');
  execute v_def;
end $$;

do $$
declare v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'customer_get_reward_catalog';
  if v_def !~ 'requires_purchase' then
    raise exception 'requires_purchase did not land in customer_get_reward_catalog';
  end if;
end $$;

commit;

-- REHEARSAL CHECKLIST (run inside a transaction that is ROLLED BACK, as `authenticated` with a
-- real owner and a real verified customer of the same business, before applying for real):
--   1 an existing reward reports requires_purchase=false and nothing about it changed;
--   2 save_loyalty_reward_draft accepts requires_purchase=true and stores it on the draft;
--   3 save_loyalty_reward_draft with the key ABSENT leaves the stored value untouched;
--   4 an unrelated unsupported key still raises 22023 (the allow-list is not now open);
--   5 creating a NEW draft generation clones the flag (clone_reward_versions_for_config);
--   6 publish promotes the flag onto public.loyalty_rewards;
--   7 get_loyalty_reward_draft returns the flag so the editor reads back its own save;
--   8 customer_get_reward_catalog returns requires_purchase for every listed reward, and
--     redemption behaviour is byte-for-byte unchanged in both directions (this migration adds
--     no enforcement — app.redeem_reward_core is deliberately untouched).
