-- Rollback-only nestly_v690 acceptance: a stamp gift can be un-redeemed, and the wallet home
-- card reads the card the customer is actually holding.
--
-- WHAT THE BUGS WERE
--   F059  app.redeem_reward_core's STAMP arm writes no points_ledger row and no batch drains —
--         the value moves as a public.stamp_milestone_claims row plus, on the final slot, a
--         'claimed' public.stamp_cycles row that closes the card. public.reverse_loyalty_
--         redemption_v34_base only knew the POINTS arm: it demanded a points_ledger row at
--         prov.points_ledger_id and drains summing to points_spent, so EVERY stamp gift was
--         permanently irreversible, and public.staff_get_reversal_workflows agreed with it
--         (can_reverse=false, 'Original points-ledger provenance is incomplete.'). A cashier who
--         gave the 10th-stamp free coffee to the wrong customer had no way back: the claim kept
--         blocking a re-claim and the card stayed closed.
--   F128  app.c45_base_actionable_wallet_card resolved the next reward through
--         b.active_config_version_id — the business's CURRENT published version — while every
--         other stamp reader resolves through app.stamp_cycle_version_v416, the version the
--         customer's own open card is PINNED to. Since nestly_v433 made every stamp-reward edit
--         version-forward, one rename put Home and the Rewards tab on different gifts.
--
-- WHAT THIS SUITE PROVES, against two tenants it builds itself:
--    1. F059 the Reverse control now offers the stamp gift: can_reverse is true and no refusal
--       reason is given (before v690 it was false with the points-ledger refusal).
--    2. F059 the reversal itself succeeds and reports the stamp shape: restored_points 0,
--       restored_stamp_claims 1, reopened_stamp_cards 1, replayed false.
--    3. F059 the claim row and the 'claimed' cycle row are actually GONE — the card is open
--       again — while the redemption, its provenance and the new reversal row all survive, with
--       restored_points_ledger_id null (a stamp reversal restores no points and no longer has to
--       invent a points row to satisfy a NOT NULL).
--    4. F059 the entitlement really came back: the very same gift can be claimed again, and the
--       second claim lands on the same open cycle.
--    5. F059 negative — the GUC is the ONLY door. A plain DELETE of a claim, with no GUC set, is
--       still refused with the append-only message.
--    6. F059 negative — an UPDATE of a claim is refused EVEN with the reversal GUC set for that
--       exact redemption. A claim is removed or it stands; it is never edited.
--    7. F059 negative — a stamp_cycles row with a NULL redemption_id (every 'expired' and
--       'completed' card) can never be deleted, GUC or no GUC: the guard requires a redemption
--       to name.
--    8. F059 the shared app.v34_immutable_evidence_guard is untouched on the six other evidence
--       tables — public.loyalty_redemption_provenance still refuses a DELETE.
--    9. F059 control — the POINTS arm is unchanged: a points redemption still reverses, still
--       restores the points to the batch and the ledger, and its reversal row still names a
--       restored points_ledger row. The stamp arm was added, not swapped in.
--   10. F059 replay — reversing the same stamp redemption twice returns replayed:true and does
--       NOT remove a second claim.
--   11. F128 the wallet home card names the gift from the customer's PINNED version, not the
--       business's newest one, and agrees with app.stamp_cycle_version_v416.
--   12. F128 control — for a POINTS programme the wallet still reads the ACTIVE version. The pin
--       was applied to stamps only, which is correct: a points balance is not pinned to a cycle.
--   13. F059(b) fails closed. The whole fixture is deliberately in the state F059(b) is about:
--       the card is pinned to cfg1 while the business's active version is cfg2, so
--       loyalty_redemption_provenance.config_version_id and loyalty_redemptions.config_version_id
--       legitimately disagree and assertions 1 and 2 only pass because app.v690_config_provenance_ok
--       accepts that divergence ON EVIDENCE. This assertion shows the evidence is really required:
--       once the reversal has removed the claim row, the authority stops vouching for that same
--       redemption. It is not a blanket "stamps may differ" pass.
--
-- Run against production inside this transaction; every fixture row is rolled back:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/v690_stamp_gift_reversal_and_pin.sql
-- Assertions are recorded as rows rather than raised, so one final SELECT reports the whole
-- suite. Any row whose outcome starts with FAIL is a failure.

begin;

create temp table v690_out(seq integer, step text, outcome text) on commit drop;
grant insert, select on v690_out to public;

create or replace function pg_temp.as_v690_system() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','',true);
end
$$;
grant execute on function pg_temp.as_v690_system() to public;

create or replace function pg_temp.as_v690_user(p_uid uuid, p_role text default 'authenticated')
returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','{}',true);
  execute format('set local role %I',p_role);
  perform set_config('request.jwt.claim.sub',coalesce(p_uid::text,''),true);
  perform set_config('request.jwt.claims',
    json_build_object('sub',p_uid,'role',p_role)::text,true);
end
$$;
grant execute on function pg_temp.as_v690_user(uuid,text) to public;

-- An operational tenant that can sell and refund: approved workspace, unpaused subscription,
-- a paid subscriptions row (business_operational_v620), the loyalty and sales modules on, one
-- owner and a default branch.
create or replace function pg_temp.v690_tenant(
  p_business uuid, p_owner uuid, p_branch uuid, p_label text
) returns void language plpgsql as $$
declare
  v_owner_staff uuid;
begin
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                         email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000',p_owner,'authenticated','authenticated',
          'v690-owner-'||substr(p_owner::text,1,8)||'@example.test','',now(),now(),now())
  on conflict (id) do nothing;

  perform set_config('app.v79_system_transition','on',true);
  insert into public.businesses(id,name,slug,industry,currency,enabled_modules,points_mode)
  values (p_business,'V690 '||p_label,'v690-'||substr(p_business::text,1,8),
          'fnb','SGD',
          array['dashboard','clients','sales','services','till','loyalty','retention'],'redeem');
  perform set_config('app.v79_system_transition','',true);

  update public.business_workspace_controls_v94
     set approval_status='approved', version=version+1, decided_by=p_owner,
         decided_at=clock_timestamp(), decision_reason='v690 rollback fixture',
         updated_at=clock_timestamp()
   where business_id = p_business;
  insert into public.business_subscription_lifecycle_v94(business_id,workspace_paused)
  values (p_business,false)
  on conflict (business_id) do update set workspace_paused=false;
  insert into public.subscriptions(business_id,status,payment_status,current_period_end)
  values (p_business,'active','paid',now()+interval '30 days')
  on conflict (business_id) do update
    set status='active', payment_status='paid', current_period_end=now()+interval '30 days';

  insert into public.staff(business_id,user_id,role,full_name,active,access_state)
  values (p_business,p_owner,'owner','V690 Owner '||p_label,true,'approved')
  returning id into v_owner_staff;
  insert into public.branches(id,business_id,name,active,is_default)
  values (p_branch,p_business,'V690 Main '||p_label,true,true);
  insert into public.staff_branches(business_id,staff_id,branch_id)
  values (p_business,v_owner_staff,p_branch);
end
$$;
grant execute on function pg_temp.v690_tenant(uuid,uuid,uuid,text) to public;

-- A published firm configuration carrying one loyalty programme version. published_at is passed
-- in so a suite that needs TWO versions can place them on either side of the moment the
-- customer's card was started — which is exactly what app.stamp_cycle_version_v416 reads.
create or replace function pg_temp.v690_publish(
  p_business uuid, p_config uuid, p_owner uuid, p_kind text, p_published timestamptz,
  p_stamp_target integer
) returns void language plpgsql as $$
begin
  -- Only one row per business may be 'published' (firm_config_one_published_per_business), so a
  -- second publish supersedes the first — which is exactly what a real version-forward edit does.
  -- app.stamp_cycle_version_v416 reads published_at and does not care about the status, so a
  -- superseded version is still a legitimate pin.
  update public.firm_config_versions
     set status='superseded', superseded_at=p_published
   where business_id=p_business and status='published';
  insert into public.firm_config_versions(id,business_id,version_no,status,source,snapshot_hash,
                                          created_by,published_at)
  select p_config,p_business,coalesce(max(version_no),0)+1,'published','manual',
         md5(p_config::text),p_owner,p_published
    from public.firm_config_versions where business_id=p_business;
  insert into public.loyalty_program_versions(
    config_version_id,business_id,kind,loyalty_model,active,
    earn_points_per_dollar,redeem_points,reward_credit_cents,tier_basis,expiry_mode,
    stamp_target,stamp_per_cents)
  values (p_config,p_business,p_kind,
          case when p_kind='stamps' then 'stamps' else 'points_tiers' end,true,
          1,50,0,'points_earned','none',p_stamp_target,500);
  perform set_config('app.v79_system_transition','on',true);
  update public.businesses set active_config_version_id=p_config where id=p_business;
  perform set_config('app.v79_system_transition','',true);
end
$$;
grant execute on function pg_temp.v690_publish(uuid,uuid,uuid,text,timestamptz,integer) to public;

do $v690_test$
declare
  -- ---------------------------------------------------------------- the stamps tenant
  bS uuid := gen_random_uuid();
  oS uuid := gen_random_uuid();
  brS uuid := gen_random_uuid();
  cfg1 uuid := gen_random_uuid();   -- published first; the version the card is pinned to
  cfg2 uuid := gen_random_uuid();   -- published later; the business's ACTIVE version
  spineS uuid;
  clientS uuid := gen_random_uuid();
  giftS uuid := gen_random_uuid();
  -- ---------------------------------------------------------------- the points tenant
  bP uuid := gen_random_uuid();
  oP uuid := gen_random_uuid();
  brP uuid := gen_random_uuid();
  cfgP uuid := gen_random_uuid();
  spineP uuid;
  clientP uuid := gen_random_uuid();
  giftP uuid := gen_random_uuid();
  -- ---------------------------------------------------------------- working
  v_seed uuid;
  v_res jsonb;
  v_err text;
  v_msg text;
  v_redemption uuid;
  v_redemption2 uuid;
  v_prov uuid;
  v_cycle uuid;
  v_claims integer;
  v_cycles integer;
  v_wf jsonb;
  v_item jsonb;
  v_card jsonb;
  v_pin uuid;
  v_batch integer;
  v_ledger integer;
  v_restored uuid;
  v_key text;
begin
  perform pg_temp.as_v690_system();

  -- ============================================================ FIXTURE: the stamps tenant
  perform pg_temp.v690_tenant(bS,oS,brS,'Kopi');
  insert into public.business_programmes(business_id,kind,active,sort)
  values (bS,'stamps',true,3)
  on conflict (business_id,kind) do update set active=true;
  update public.business_programmes set active=false where business_id=bS and kind='points';
  select id into spineS from public.business_programmes where business_id=bS and kind='stamps';

  insert into public.loyalty_programs(business_id,active,loyalty_model,kind,
                                      configuration_status,stamp_target,stamp_per_cents)
  values (bS,true,'stamps','stamps','published',5,500)
  on conflict (business_id) do update
    set active=true, loyalty_model='stamps', kind='stamps',
        configuration_status='published', stamp_target=5, stamp_per_cents=500;

  -- Two published versions of the SAME final gift, two days apart, renamed in between.
  perform pg_temp.v690_publish(bS,cfg1,oS,'stamps',now()-interval '2 days',5);
  perform pg_temp.v690_publish(bS,cfg2,oS,'stamps',now()-interval '1 hour',5);
  update public.loyalty_programs set current_config_version_id=cfg2 where business_id=bS;

  insert into public.loyalty_rewards(
    id,business_id,name,internal_name,customer_name,fulfillment_kind,
    estimated_cost_cents,cost_points,credit_cents,active,paused,sort,
    programme_id,current_config_version_id)
  values (giftS,bS,'Free Kopi','Free Kopi','Free Kopi (new name)','manual_item',
          500,5,0,true,false,1,spineS,cfg2);
  insert into public.loyalty_reward_versions(
    config_version_id,business_id,reward_id,internal_name,customer_name,
    fulfillment_kind,estimated_cost_cents,cost_points,credit_cents,active,sort,programme_id)
  values (cfg1,bS,giftS,'Free Kopi','Free Kopi (as promised)','manual_item',500,5,0,true,1,spineS),
         (cfg2,bS,giftS,'Free Kopi','Free Kopi (new name)','manual_item',500,5,0,true,1,spineS);

  insert into public.clients(id,business_id,full_name,phone)
  values (clientS,bS,'V690 Stamp Customer','+65 9690 0001');

  -- A full card: five stamps, collected YESTERDAY — after cfg1 was published and before cfg2,
  -- which is what pins this card to cfg1.
  perform app.acquire_loyalty_shared_v480(bS);
  v_seed := gen_random_uuid();
  perform set_config('app.points_ledger_insert_id',v_seed::text,true);
  -- 'programme_pot_transfer' is the one approved route app.loyalty_ledger_write_guard admits
  -- from a system principal: entry_type 'adjust', a named programme, and a NULL actor.
  perform set_config('app.points_ledger_write_scope','programme_pot_transfer',true);
  insert into public.points_ledger(id,business_id,client_id,entry_type,points,reference,actor,
                                   programme_id,created_at)
  values (v_seed,bS,clientS,'adjust',5,'v690 seed stamps',null,spineS,now()-interval '1 day');
  perform set_config('app.points_ledger_insert_id','',true);
  perform set_config('app.points_ledger_write_scope','',true);
  insert into public.points_batches(business_id,client_id,programme_id,earned,remaining,earned_at)
  values (bS,clientS,spineS,5,5,now()-interval '1 day');

  -- ============================================================ FIXTURE: the points tenant
  perform pg_temp.as_v690_system();
  perform pg_temp.v690_tenant(bP,oP,brP,'Points');
  select id into spineP from public.business_programmes where business_id=bP and kind='points';
  update public.business_programmes set active=true where id=spineP;
  update public.business_programmes set active=false where business_id=bP and kind='stamps';
  insert into public.loyalty_programs(business_id,active,loyalty_model,kind,configuration_status)
  values (bP,true,'points_tiers','points','published')
  on conflict (business_id) do update
    set active=true, loyalty_model='points_tiers', kind='points', configuration_status='published';
  perform pg_temp.v690_publish(bP,cfgP,oP,'points',now()-interval '2 days',null);
  update public.loyalty_programs set current_config_version_id=cfgP where business_id=bP;

  insert into public.loyalty_rewards(
    id,business_id,name,internal_name,customer_name,fulfillment_kind,
    estimated_cost_cents,cost_points,credit_cents,active,paused,sort,
    programme_id,current_config_version_id)
  values (giftP,bP,'Points Gift','Points Gift','Points Gift','manual_item',
          500,50,0,true,false,1,spineP,cfgP);
  insert into public.loyalty_reward_versions(
    config_version_id,business_id,reward_id,internal_name,customer_name,
    fulfillment_kind,estimated_cost_cents,cost_points,credit_cents,active,sort,programme_id)
  values (cfgP,bP,giftP,'Points Gift','Points Gift','manual_item',500,50,0,true,1,spineP);

  insert into public.clients(id,business_id,full_name,phone)
  values (clientP,bP,'V690 Points Customer','+65 9690 0002');
  perform app.acquire_loyalty_shared_v480(bP);
  v_seed := gen_random_uuid();
  perform set_config('app.points_ledger_insert_id',v_seed::text,true);
  perform set_config('app.points_ledger_write_scope','programme_pot_transfer',true);
  insert into public.points_ledger(id,business_id,client_id,entry_type,points,reference,actor,programme_id)
  values (v_seed,bP,clientP,'adjust',50,'v690 seed points',null,spineP);
  perform set_config('app.points_ledger_insert_id','',true);
  perform set_config('app.points_ledger_write_scope','',true);
  insert into public.points_batches(business_id,client_id,programme_id,earned,remaining)
  values (bP,clientP,spineP,50,50);

  -- ============================================================ F128, before any claim
  -- The pin only differs from the active version while a card is OPEN, so these two run first:
  -- claiming the final gift closes the card and app.stamp_cycle_version_v416 then legitimately
  -- falls back to the active version.
  -- ------------------------------------------------------------------ 11. F128 the pinned gift
  perform pg_temp.as_v690_system();
  v_pin := app.stamp_cycle_version_v416(bS,clientS,spineS);
  v_card := app.c45_base_actionable_wallet_card(
    bS,clientS,'v690-'||substr(bS::text,1,8),'V690 Kopi','fnb','SGD',
    array['dashboard','clients','sales','services','till','loyalty','retention'],now());
  if v_pin = cfg1
     and (v_card #>> '{next_eligible_reward,name}') = 'Free Kopi (as promised)' then
    insert into v690_out values (11,'F128 the wallet card names the gift from the PINNED version, not the newest','PASS');
  else
    insert into v690_out values (11,'F128 the wallet card names the gift from the PINNED version, not the newest',
      format('FAIL - pin=%s (cfg1=%s cfg2=%s) wallet_name=%s',
             coalesce(v_pin::text,'<null>'),cfg1,cfg2,
             coalesce(v_card #>> '{next_eligible_reward,name}','<null>')));
  end if;

  -- ------------------------------------------------------------------ 12. F128 the points control
  v_card := app.c45_base_actionable_wallet_card(
    bP,clientP,'v690-'||substr(bP::text,1,8),'V690 Points','fnb','SGD',
    array['dashboard','clients','sales','services','till','loyalty','retention'],now());
  if (v_card #>> '{next_eligible_reward,name}') = 'Points Gift' then
    insert into v690_out values (12,'F128 control: a POINTS programme still reads the ACTIVE version','PASS');
  else
    insert into v690_out values (12,'F128 control: a POINTS programme still reads the ACTIVE version',
      format('FAIL - wallet_name=%s card=%s',
             coalesce(v_card #>> '{next_eligible_reward,name}','<null>'),v_card));
  end if;

  -- ============================================================ the stamp claim itself
  perform pg_temp.as_v690_user(oS);
  v_res := public.redeem_reward_at_context(
    bS,clientS,giftS,'v690-stamp-claim-'||replace(gen_random_uuid()::text,'-',''),
    brS,null,null)::jsonb;
  if coalesce(v_res->>'ok','') <> 'true' or (v_res->>'consumes_balance') <> 'false'
     or (v_res->>'stamp_card_closed') <> 'true' then
    raise exception 'FIXTURE: the stamp claim did not close the card as expected: %', v_res;
  end if;
  v_redemption := (v_res->>'redemption_id')::uuid;

  -- ------------------------------------------------------------------ 1. the Reverse control
  v_wf := public.staff_get_reversal_workflows(bS,clientS,50,'all');
  select item into v_item
    from pg_catalog.jsonb_array_elements(coalesce(v_wf->'redemptions','[]'::jsonb)) as e(item)
   where (item->>'id')::uuid = v_redemption;
  if v_item is not null and (v_item->>'can_reverse') = 'true'
     and coalesce(v_item->>'refusal_reason','') = '' then
    insert into v690_out values (1,'F059 the Reverse control offers the stamp gift (can_reverse, no refusal)','PASS');
  else
    insert into v690_out values (1,'F059 the Reverse control offers the stamp gift (can_reverse, no refusal)',
      format('FAIL - item=%s',coalesce(v_item::text,'<not listed>')));
  end if;

  -- ------------------------------------------------------------------ 2. the reversal result
  perform pg_temp.as_v690_system();
  select count(*) into v_claims from public.stamp_milestone_claims
   where business_id=bS and redemption_id=v_redemption;
  select count(*) into v_cycles from public.stamp_cycles
   where business_id=bS and redemption_id=v_redemption and origin='claimed';
  if v_claims <> 1 or v_cycles <> 1 then
    raise exception 'FIXTURE: expected one claim and one closed cycle, found %/%', v_claims, v_cycles;
  end if;

  perform pg_temp.as_v690_user(oS);
  v_key := 'v690-stamp-reverse-'||replace(gen_random_uuid()::text,'-','');
  v_err := null;
  begin
    v_res := public.reverse_loyalty_redemption(
      bS,v_redemption,'v690 acceptance: given to the wrong customer',v_key)::jsonb;
  exception when others then
    v_err := sqlstate; v_msg := sqlerrm; v_res := null;
  end;
  if v_err is null and (v_res->>'restored_points') = '0'
     and (v_res->>'restored_stamp_claims') = '1'
     and (v_res->>'reopened_stamp_cards') = '1'
     and (v_res->>'replayed') = 'false' then
    insert into v690_out values (2,'F059 the stamp reversal succeeds and reports the stamp shape','PASS');
  else
    insert into v690_out values (2,'F059 the stamp reversal succeeds and reports the stamp shape',
      format('FAIL - sqlstate=%s message=%s result=%s',
             coalesce(v_err,'<none>'),coalesce(v_msg,''),coalesce(v_res::text,'<null>')));
  end if;

  -- ------------------------------------------------------------------ 3. what survives, what goes
  perform pg_temp.as_v690_system();
  select count(*) into v_claims from public.stamp_milestone_claims
   where business_id=bS and redemption_id=v_redemption;
  select count(*) into v_cycles from public.stamp_cycles
   where business_id=bS and redemption_id=v_redemption;
  select id into v_prov from public.loyalty_redemption_provenance
   where business_id=bS and redemption_id=v_redemption;
  select restored_points_ledger_id into v_restored from public.loyalty_redemption_reversals
   where business_id=bS and redemption_id=v_redemption;
  if v_claims = 0 and v_cycles = 0 and v_prov is not null and v_restored is null
     and exists (select 1 from public.loyalty_redemptions where id=v_redemption)
     and exists (select 1 from public.loyalty_redemption_reversals
                  where business_id=bS and redemption_id=v_redemption) then
    insert into v690_out values (3,'F059 the claim and the closed cycle are gone; redemption, provenance and reversal survive with no restored points row','PASS');
  else
    insert into v690_out values (3,'F059 the claim and the closed cycle are gone; redemption, provenance and reversal survive with no restored points row',
      format('FAIL - claims=%s cycles=%s provenance=%s restored_points_ledger_id=%s',
             v_claims,v_cycles,coalesce(v_prov::text,'<null>'),coalesce(v_restored::text,'<null>')));
  end if;

  -- ------------------------------------------------------------------ 4. the entitlement came back
  perform pg_temp.as_v690_user(oS);
  v_err := null;
  begin
    v_res := public.redeem_reward_at_context(
      bS,clientS,giftS,'v690-stamp-reclaim-'||replace(gen_random_uuid()::text,'-',''),
      brS,null,null)::jsonb;
  exception when others then
    v_err := sqlstate; v_msg := sqlerrm; v_res := null;
  end;
  if v_err is null and coalesce(v_res->>'ok','') = 'true'
     and (v_res->>'from_expired_card') = 'false'
     and (v_res->>'stamp_card_closed') = 'true' then
    v_redemption2 := (v_res->>'redemption_id')::uuid;
    insert into v690_out values (4,'F059 the same gift can be claimed again on the reopened card','PASS');
  else
    insert into v690_out values (4,'F059 the same gift can be claimed again on the reopened card',
      format('FAIL - sqlstate=%s message=%s result=%s',
             coalesce(v_err,'<none>'),coalesce(v_msg,''),coalesce(v_res::text,'<null>')));
  end if;

  -- ------------------------------------------------------------------ 5. no GUC, no delete
  perform pg_temp.as_v690_system();
  v_err := null; v_msg := null;
  begin
    delete from public.stamp_milestone_claims where business_id=bS and redemption_id=v_redemption2;
  exception when others then
    v_err := sqlstate; v_msg := sqlerrm;
  end;
  select count(*) into v_claims from public.stamp_milestone_claims
   where business_id=bS and redemption_id=v_redemption2;
  if v_err = '23001' and position('append-only' in coalesce(v_msg,'')) > 0
     and v_claims = 1 then
    insert into v690_out values (5,'F059 negative: a plain DELETE of a claim is still refused append-only','PASS');
  else
    insert into v690_out values (5,'F059 negative: a plain DELETE of a claim is still refused append-only',
      format('FAIL - sqlstate=%s message=%s surviving_claims=%s',
             coalesce(v_err,'<none>'),coalesce(v_msg,''),v_claims));
  end if;

  -- ------------------------------------------------------------------ 6. the GUC does not open UPDATE
  perform set_config('app.v690_stamp_reversal_redemption_id',v_redemption2::text,true);
  v_err := null; v_msg := null;
  begin
    update public.stamp_milestone_claims set slot_position = slot_position
     where business_id=bS and redemption_id=v_redemption2;
  exception when others then
    v_err := sqlstate; v_msg := sqlerrm;
  end;
  perform set_config('app.v690_stamp_reversal_redemption_id','',true);
  if v_err = '23001' then
    insert into v690_out values (6,'F059 negative: an UPDATE of a claim is refused even with the reversal GUC set','PASS');
  else
    insert into v690_out values (6,'F059 negative: an UPDATE of a claim is refused even with the reversal GUC set',
      format('FAIL - sqlstate=%s message=%s',coalesce(v_err,'<none>'),coalesce(v_msg,'')));
  end if;

  -- ------------------------------------------------------------------ 7. a cycle naming no redemption
  v_cycle := gen_random_uuid();
  insert into public.stamp_cycles(id,business_id,programme_id,client_id,cycle_index,slots,
                                  origin,redemption_id,config_version_id,actor)
  values (v_cycle,bS,spineS,clientS,99,5,'expired',null,cfg1,oS);
  perform set_config('app.v690_stamp_reversal_redemption_id',v_redemption2::text,true);
  v_err := null; v_msg := null;
  begin
    delete from public.stamp_cycles where id = v_cycle;
  exception when others then
    v_err := sqlstate; v_msg := sqlerrm;
  end;
  perform set_config('app.v690_stamp_reversal_redemption_id','',true);
  if v_err = '23001'
     and exists (select 1 from public.stamp_cycles where id = v_cycle) then
    insert into v690_out values (7,'F059 negative: a cycle with a NULL redemption_id can never be deleted','PASS');
  else
    insert into v690_out values (7,'F059 negative: a cycle with a NULL redemption_id can never be deleted',
      format('FAIL - sqlstate=%s message=%s still_there=%s',
             coalesce(v_err,'<none>'),coalesce(v_msg,''),
             exists (select 1 from public.stamp_cycles where id = v_cycle)));
  end if;

  -- ------------------------------------------------------------------ 8. the shared v34 guard stands
  perform set_config('app.v690_stamp_reversal_redemption_id',v_redemption2::text,true);
  v_err := null; v_msg := null;
  begin
    delete from public.loyalty_redemption_provenance
     where business_id=bS and redemption_id=v_redemption2;
  exception when others then
    v_err := sqlstate; v_msg := sqlerrm;
  end;
  perform set_config('app.v690_stamp_reversal_redemption_id','',true);
  if v_err = '23001'
     and exists (select 1 from public.loyalty_redemption_provenance
                  where business_id=bS and redemption_id=v_redemption2) then
    insert into v690_out values (8,'F059 the shared v34 guard is untouched on the other evidence tables','PASS');
  else
    insert into v690_out values (8,'F059 the shared v34 guard is untouched on the other evidence tables',
      format('FAIL - sqlstate=%s message=%s',coalesce(v_err,'<none>'),coalesce(v_msg,'')));
  end if;

  -- ------------------------------------------------------------------ 9. the POINTS arm control
  perform pg_temp.as_v690_user(oP);
  v_err := null; v_msg := null;
  begin
    v_res := public.redeem_reward_at_context(
      bP,clientP,giftP,'v690-points-claim-'||replace(gen_random_uuid()::text,'-',''),
      brP,null,null)::jsonb;
  exception when others then
    v_err := sqlstate; v_msg := sqlerrm; v_res := null;
  end;
  if v_err is not null or coalesce(v_res->>'ok','') <> 'true' then
    raise exception 'FIXTURE: the points claim failed (% %) %', v_err, v_msg, v_res;
  end if;
  v_redemption2 := (v_res->>'redemption_id')::uuid;
  v_err := null; v_msg := null;
  begin
    v_res := public.reverse_loyalty_redemption(
      bP,v_redemption2,'v690 acceptance: points control reversal',
      'v690-points-reverse-'||replace(gen_random_uuid()::text,'-',''))::jsonb;
  exception when others then
    v_err := sqlstate; v_msg := sqlerrm; v_res := null;
  end;
  perform pg_temp.as_v690_system();
  select coalesce(sum(remaining),0)::integer into v_batch from public.points_batches
   where business_id=bP and client_id=clientP;
  select coalesce(sum(points),0)::integer into v_ledger from public.points_ledger
   where business_id=bP and client_id=clientP;
  select restored_points_ledger_id into v_restored from public.loyalty_redemption_reversals
   where business_id=bP and redemption_id=v_redemption2;
  if v_err is null and (v_res->>'restored_points') = '50'
     and v_batch = 50 and v_ledger = 50 and v_restored is not null then
    insert into v690_out values (9,'F059 control: the POINTS arm still restores points, batches and a named ledger row','PASS');
  else
    insert into v690_out values (9,'F059 control: the POINTS arm still restores points, batches and a named ledger row',
      format('FAIL - sqlstate=%s message=%s result=%s batch=%s ledger=%s restored=%s',
             coalesce(v_err,'<none>'),coalesce(v_msg,''),coalesce(v_res::text,'<null>'),
             v_batch,v_ledger,coalesce(v_restored::text,'<null>')));
  end if;

  -- ------------------------------------------------------------------ 10. the replay
  perform pg_temp.as_v690_system();
  select count(*) into v_claims from public.stamp_milestone_claims where business_id=bS;
  perform pg_temp.as_v690_user(oS);
  v_err := null; v_msg := null;
  begin
    v_res := public.reverse_loyalty_redemption(
      bS,v_redemption,'v690 acceptance: given to the wrong customer',v_key)::jsonb;
  exception when others then
    v_err := sqlstate; v_msg := sqlerrm; v_res := null;
  end;
  perform pg_temp.as_v690_system();
  select count(*) into v_cycles from public.stamp_milestone_claims where business_id=bS;
  if v_err is null and (v_res->>'replayed') = 'true' and v_cycles = v_claims then
    insert into v690_out values (10,'F059 a second reversal of the same redemption replays and removes nothing','PASS');
  else
    insert into v690_out values (10,'F059 a second reversal of the same redemption replays and removes nothing',
      format('FAIL - sqlstate=%s message=%s result=%s claims_before=%s claims_after=%s',
             coalesce(v_err,'<none>'),coalesce(v_msg,''),coalesce(v_res::text,'<null>'),
             v_claims,v_cycles));
  end if;

  -- ------------------------------------------------------------------ 13. the authority is evidence-based
  perform pg_temp.as_v690_system();
  if not app.v690_config_provenance_ok(bP,v_redemption2)
     and not app.v690_config_provenance_ok(bS,v_redemption)
     and not app.v690_config_provenance_ok(bS,gen_random_uuid()) then
    insert into v690_out values (13,'F059(b) the config authority is evidence-based: no claim row, no pass','FAIL - the points redemption should still vouch');
  elsif app.v690_config_provenance_ok(bP,v_redemption2)
        and not app.v690_config_provenance_ok(bS,v_redemption)
        and not app.v690_config_provenance_ok(bS,gen_random_uuid()) then
    insert into v690_out values (13,'F059(b) the config authority is evidence-based: no claim row, no pass','PASS');
  else
    insert into v690_out values (13,'F059(b) the config authority is evidence-based: no claim row, no pass',
      format('FAIL - points=%s stamp_after_reversal=%s unknown_redemption=%s',
             app.v690_config_provenance_ok(bP,v_redemption2),
             app.v690_config_provenance_ok(bS,v_redemption),
             app.v690_config_provenance_ok(bS,gen_random_uuid())));
  end if;
end
$v690_test$;

select seq, step, outcome from v690_out order by seq;

/* The report above is printed first so a human sees WHICH assertion failed; this block then
   makes the failure fatal. It matters because scripts/db-tests/run.mjs judges a file purely by
   psql's exit code — a suite that only records FAIL rows is reported green. */
do $v690_gate$
declare
  v_bad integer;
  v_all integer;
begin
  select count(*) filter (where outcome not like 'PASS%'), count(*) into v_bad, v_all from v690_out;
  if v_all <> 13 then
    raise exception 'nestly_v690: % of 13 assertions ran — the suite aborted early', v_all;
  end if;
  if v_bad > 0 then
    raise exception 'nestly_v690: % assertion(s) FAILED — see the report above', v_bad;
  end if;
end
$v690_gate$;

rollback;
