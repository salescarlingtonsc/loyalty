-- v433–v436 acceptance — the stamp lifecycle wave: edit version split (v433), publish/save keyed
-- on the draft's declared model (v434), versioned cycle expiry with surviving entitlements
-- (v435), pinned earn rate + lazy close on the sale path (v436). Structural post-apply checks,
-- read-only against production; the behavioural proof is the executed dual-mode suite
-- (db/tests/executed/v433_v436_stamp_lifecycle.sql). BEGIN/ROLLBACK per house convention.
begin;

do $$
declare
  v_def text;
  v_name text;
  v_acl aclitem[];
  v_count integer;
begin
  -- 01  v433: the split helpers exist and are definer-internal
  foreach v_name in array array[
    'stamp_open_card_risk_v433', 'stamp_config_edit_begin_v433', 'stamp_config_edit_commit_v433',
    'stamp_cycle_deadline_v435', 'stamp_expire_open_cycle_v435',
    'run_stamp_expiry_for_business', 'run_stamp_expiry'
  ] loop
    select p.proacl into v_acl
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = v_name;
    if not found then
      raise exception '01 FAIL app.% does not exist', v_name;
    end if;
    if exists (
      select 1 from unnest(coalesce(v_acl, '{}'::aclitem[])) acl
       where acl::text like 'authenticated=%' or acl::text like 'anon=%' or acl::text like '=%'
    ) then
      raise exception '01 FAIL app.% is directly callable by client roles: %', v_name, v_acl;
    end if;
  end loop;
  raise notice '01 PASS the v433/v435 engine helpers exist and are definer-internal';

  -- 02  v433: the program-row guard carries the token carve-out and its allow-list
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'loyalty_version_immutable_guard';
  if position('v433_program_edit_version_id' in coalesce(v_def, '')) = 0
     or position('stamp_validity_days' in coalesce(v_def, '')) = 0 then
    raise exception '02 FAIL app.loyalty_version_immutable_guard lacks the v433 token carve-out';
  end if;
  raise notice '02 PASS the published-program guard admits only token-bracketed allow-listed edits';

  -- 03  v433: every stamp-affecting editor routes through the split
  foreach v_name in array array[
    'business_update_reward_v326', 'business_create_reward_v326',
    'business_set_stamp_card_length_v414', 'business_set_earning_rule_v359'
  ] loop
    select pg_get_functiondef(p.oid) into v_def
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = v_name;
    if position('stamp_config_edit_begin_v433' in coalesce(v_def, '')) = 0 then
      raise exception '03 FAIL public.% does not route stamp edits through the version split', v_name;
    end if;
  end loop;
  raise notice '03 PASS all four stamp editors version-forward instead of editing the open card';

  -- 04  v434: publish judges the DRAFT's declared model; draft gifts bind to the declared programme
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'publish_loyalty_config';
  if position('nestly_v434' in coalesce(v_def, '')) = 0
     or position($v$v_typed.loyalty_model = 'stamps'$v$ in coalesce(v_def, '')) = 0 then
    raise exception '04 FAIL publish_loyalty_config still keys its stamps guards on the outgoing spine';
  end if;
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'save_loyalty_reward_draft';
  if position('nestly_v434' in coalesce(v_def, '')) = 0 then
    raise exception '04 FAIL save_loyalty_reward_draft does not bind gifts to the draft''s declared programme';
  end if;
  raise notice '04 PASS the wizard switch path publishes on the draft''s own declaration';

  -- 05  v435 schema: validity columns + the expired cycle shape
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='loyalty_program_versions'
                    and column_name='stamp_validity_days')
     or not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='loyalty_programs'
                    and column_name='stamp_validity_days') then
    raise exception '05 FAIL stamp_validity_days columns are missing';
  end if;
  select pg_get_constraintdef(c.oid) into v_def
    from pg_constraint c join pg_class t on t.oid = c.conrelid
   where t.relname = 'stamp_cycles' and c.conname = 'stamp_cycles_origin_check';
  if position('expired' in coalesce(v_def, '')) = 0 then
    raise exception '05 FAIL stamp_cycles_origin_check does not admit ''expired''';
  end if;
  select pg_get_constraintdef(c.oid) into v_def
    from pg_constraint c join pg_class t on t.oid = c.conrelid
   where t.relname = 'stamp_cycles' and c.conname = 'stamp_cycles_shape_check';
  if position('expired' in coalesce(v_def, '')) = 0 then
    raise exception '05 FAIL stamp_cycles_shape_check has no arm for expired cycles';
  end if;
  raise notice '05 PASS validity lives on the version and expired cycles have a legal shape';

  -- 06  v435 sweep is scheduled
  if not exists (select 1 from cron.job where jobname = 'nestly-stamp-expiry') then
    raise exception '06 FAIL the daily stamp expiry sweep is not scheduled';
  end if;
  raise notice '06 PASS the daily stamp expiry sweep is scheduled';

  -- 07  v435 redemption: lazy close + survival + claims-while-off for stamps only
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'redeem_reward_core';
  if position('stamp_expire_open_cycle_v435' in coalesce(v_def, '')) = 0
     or position($v$origin='expired'$v$ in coalesce(v_def, '')) = 0
     or position($v$is distinct from 'stamps'$v$ in coalesce(v_def, '')) = 0 then
    raise exception '07 FAIL redeem_reward_core lacks lazy close, survival, or the points-only spine gate';
  end if;
  raise notice '07 PASS redemption closes due cards, honours survivors, and lets earned stamps claim while off';

  -- 08  v435 readers: availability lists survivors; the customer card carries its clock
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'reward_availability_v432';
  if position($v$'expired'$v$ in coalesce(v_def, '')) = 0 then
    raise exception '08 FAIL the availability core has no survival arm';
  end if;
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'customer_get_stamp_card_v323';
  if position('validity_days' in coalesce(v_def, '')) = 0
     or position('expires_at' in coalesce(v_def, '')) = 0 then
    raise exception '08 FAIL the customer stamp card does not expose its clock';
  end if;
  raise notice '08 PASS availability and the customer card both understand expiry';

  -- 09  v436: the sale path earns at the OPEN CARD''s pinned rate and closes due cards first
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'on_sale_recorded';
  if position('stamp_cycle_version_v416' in coalesce(v_def, '')) = 0
     or position('stamp_expire_open_cycle_v435' in coalesce(v_def, '')) = 0 then
    raise exception '09 FAIL on_sale_recorded does not pin the stamp earn rate to the open card';
  end if;
  raise notice '09 PASS sales stamp the card at the rate the card was started under';

  -- 10b v437: history rows keep their unit; the wallet card carries the expiry rule
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'customer_get_transaction_history_v81';
  if position('loyalty_unit' in coalesce(v_def, '')) = 0 then
    raise exception '10b FAIL customer history does not resolve each row''s own pot unit';
  end if;
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'c45_base_actionable_wallet_card';
  if position('expiry_days' in coalesce(v_def, '')) = 0 then
    raise exception '10b FAIL the wallet card does not carry the points expiry rule';
  end if;
  raise notice '10b PASS history rows keep their unit and the wallet knows its expiry rule';

  -- 10  v435: exactly ONE earning-rule overload survives (twin overloads = PGRST203, every
  --      save blocked — the v410 promotion lesson)
  select count(*) into v_count
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'business_set_earning_rule_v359';
  if v_count <> 1 then
    raise exception '10 FAIL business_set_earning_rule_v359 has % overloads (must be exactly 1)', v_count;
  end if;
  raise notice '10 PASS one earning-rule signature, no PGRST203 ambiguity';
end $$;

rollback;
select 'v433–v436 ALL CHECKS PASSED' as result;
