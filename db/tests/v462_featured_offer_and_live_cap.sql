-- Rollback-only acceptance for nestly_v462 — the offers model (owner ruling R2).
--   supabase db query --linked -f db/tests/v462_featured_offer_and_live_cap.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
-- Every check CALLS a real RPC as a real role. Only check 13 (privileges) reads catalog metadata
-- rather than behaviour, and no check asserts on a function's source text.
--
--   01  fixture shape: two firms, one customer verified at both, eight live offers at firm A
--   02  NEGATIVE CONTROL — business page: with the pre-v462 reader re-installed inside this
--       transaction, customer_get_promotions_v155 returns 6 of the 8 live offers and reports
--       'limit' 2. Proves 03/04 can detect the defect. Against an UNPATCHED database 02 passes
--       and 03/04 fail, which is the defect reproducing itself and the expected pre-apply result.
--   03  business page returns ALL live offers and reports a truthful 'limit'
--   04  the bound is the ENTITLEMENT, not a constant: lower it to 3 and both the item count and
--       the reported limit follow; restore it and the offers come back
--   05  featured: default until picked is the most recently published live offer, and the owner
--       editor states the same offer and admits it is still the default
--   06  featured: the writer pins, replaces and clears; a second row is unrepresentable
--   07  featured: refusals — a draft, another firm's offer, a manager, an anonymous caller
--   08  featured: a stale pin (its offer drafted) falls back rather than blanking the feed, is
--       remembered, and comes back when the offer is republished
--   09  NEGATIVE CONTROL — Home: with the featured join removed, Home returns every live offer
--       across both firms. Proves 10 can detect the defect.
--   10  Home returns exactly ONE offer per business, and it is that business's featured one
--   11  the cap: an 11th publish is refused with a distinguishable
--       promotion_publish_limit_reached; republishing an already-live offer is never blocked;
--       drafting one frees the slot and the same publish then succeeds
--   12  NEGATIVE CONTROL — cap: with the pre-v462 lifetime gate re-installed, the same publish
--       is refused even though only 9 are live. Proves 11 is measuring the rule change.
--   13  privileges: the featured table is unreachable through the API in either direction; the
--       writer is executable by authenticated and not by anon
--
-- FIXTURE TRAPS, recorded so the next author does not rediscover them:
--   * promotions are rows in public.business_customer_content_v95 — there is no public.promotions
--     — and three v104 triggers refuse any write that does not come through the v104 RPCs.
--   * publishing requires a customer-visible image, so every published offer needs a
--     storage.objects row (inserted as postgres) before finalize.
--   * business_create_promotion_draft_v155 writes the branch scope AFTER the v104 receipt and
--     bumps content.version (v280). Finalize must be handed the TRUE versions, read as postgres —
--     `authenticated` cannot select those tables and a wrong version is itself a conflict, which
--     would test v280 instead of this.
--   * metadata.published_once_at is written with now(), which is TRANSACTION time: eleven offers
--     published inside one transaction would all carry the same instant and "most recently
--     published" would have no answer. The fixture therefore spreads that timestamp explicitly,
--     standing in for eleven separate production transactions.

begin;

create temp table _r(k text, v text) on commit drop;
create temp table _c(
  bizA uuid, bizB uuid, ownerA uuid, ownerB uuid, mgrA uuid, superU uuid,
  brA uuid, brB uuid, userC uuid, identC uuid, cliA uuid, cliB uuid,
  linkA uuid, linkB uuid
) on commit drop;
create temp table _o(biz uuid, seq int, id uuid) on commit drop;
grant select,insert,update,delete on _r,_c,_o to authenticated;

create or replace function pg_temp.as_v462(p_uid uuid) returns void language plpgsql as $$
begin
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text,''), true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
end
$$;
grant execute on function pg_temp.as_v462(uuid) to public;

-- One offer, created and (optionally) published exactly the way the editor does it.
create or replace function pg_temp.v462_offer(
  p_business uuid, p_owner uuid, p_label text, p_publish boolean
) returns uuid language plpgsql as $$
declare
  v_id uuid := gen_random_uuid();
  v_path text;
  v_cv bigint;
  v_copyv bigint;
begin
  execute 'reset role';
  perform pg_temp.as_v462(p_owner);
  perform public.business_create_promotion_draft_v155(
    p_business, v_id, gen_random_uuid(), 'all', null, null,
    p_label, null, 'A rolled-back acceptance offer for '||p_label||'.', null,
    now()-interval '1 day', now()+interval '30 days',
    100, 'counter', 'Show at counter', 'Ten percent off any visit.', null);
  execute 'reset role';

  v_path := p_business||'/offer/'||gen_random_uuid()||'.png';
  insert into storage.objects(bucket_id,name,metadata)
  values('business-public', v_path, '{"mimetype":"image/png","size":"4096"}'::jsonb);

  -- A draft gets its photo too, hidden. Publishing REQUIRES a customer-visible image
  -- (promotion_image_required, checked after the cap), so a draft with no asset could never be
  -- published later and checks 11/12 would measure the missing photo instead of the cap.
  if not p_publish then
    perform set_config('app.v104_promotion_media_write','on',true);
    insert into public.business_media_assets_v95(
      business_id,asset_kind,entity_id,branch_id,object_path,mime_type,
      width_px,height_px,alt_en,customer_visible)
    values(p_business,'offer',v_id,null,v_path,'image/png',1200,800,p_label||' photo',false);
    perform set_config('app.v104_promotion_media_write','',true);
    return v_id;
  end if;

  select content.version into v_cv
  from public.business_customer_content_v95 content where content.id = v_id;
  select copy.version into v_copyv
  from public.business_localized_copy_v95 copy
  where copy.business_id = p_business and copy.entity_type = 'offer'
    and copy.entity_id = v_id and copy.locale = 'en';

  perform pg_temp.as_v462(p_owner);
  perform public.business_finalize_promotion_v155(
    p_business, v_id, 'all', null, null,
    p_label, null, 'A rolled-back acceptance offer for '||p_label||'.', null,
    now()-interval '1 day', now()+interval '30 days',
    100, 'counter', 'Show at counter', 'Ten percent off any visit.', null,
    true, v_path, 'image/png', 1200, 800, p_label||' photo',
    v_cv, v_copyv, 0, gen_random_uuid());
  execute 'reset role';
  return v_id;
end
$$;
grant execute on function pg_temp.v462_offer(uuid,uuid,text,boolean) to public;

-- Publish or draft an EXISTING offer, returning the finalize payload untouched so a refusal can
-- be inspected rather than swallowed.
create or replace function pg_temp.v462_set_publish(
  p_business uuid, p_owner uuid, p_offer uuid, p_publish boolean
) returns jsonb language plpgsql as $$
declare
  v_cv bigint; v_copyv bigint; v_mv bigint; v_label text; v_out jsonb;
begin
  execute 'reset role';
  select content.version into v_cv
  from public.business_customer_content_v95 content where content.id = p_offer;
  select copy.version, copy.name into v_copyv, v_label
  from public.business_localized_copy_v95 copy
  where copy.business_id = p_business and copy.entity_type = 'offer'
    and copy.entity_id = p_offer and copy.locale = 'en';
  select coalesce(max(asset.version),0) into v_mv
  from public.business_media_assets_v95 asset
  where asset.business_id = p_business and asset.asset_kind = 'offer'
    and asset.entity_id = p_offer and asset.branch_id is null;

  perform pg_temp.as_v462(p_owner);
  v_out := public.business_finalize_promotion_v155(
    p_business, p_offer, 'all', null, null,
    v_label, null, 'A rolled-back acceptance offer for '||v_label||'.', null,
    now()-interval '1 day', now()+interval '30 days',
    100, 'counter', 'Show at counter', 'Ten percent off any visit.', null,
    p_publish, null, null, null, null, null,
    v_cv, v_copyv, v_mv, gen_random_uuid());
  execute 'reset role';
  return v_out;
end
$$;
grant execute on function pg_temp.v462_set_publish(uuid,uuid,uuid,boolean) to public;

-- The negative-control harness: put a pre-v462 behaviour back, then take it out again. Restoring
-- re-executes the EXACT definition snapshotted before stripping, so the harness cannot drift the
-- functions it is testing. Against an UNPATCHED database the search text is simply absent and
-- nothing is replaced — which is right, because the deployed body already IS the pre-v462 body.
create temp table _v462_snapshot(proname text primary key, def text) on commit drop;

create or replace function pg_temp.v462_unfix(p_proname text, p_pairs text[]) returns void
language plpgsql as $$
declare v_src text; v_new text; i int;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = p_proname;
  if v_src is null then
    raise exception 'v462 harness: public.% is missing', p_proname;
  end if;
  insert into _v462_snapshot(proname, def) values (p_proname, v_src)
    on conflict (proname) do update set def = excluded.def;
  v_new := v_src;
  i := 1;
  while i < array_length(p_pairs,1) loop
    v_new := replace(v_new, p_pairs[i], p_pairs[i+1]);
    i := i + 2;
  end loop;
  if v_new <> v_src then execute v_new; end if;
end
$$;
grant execute on function pg_temp.v462_unfix(text,text[]) to public;

create or replace function pg_temp.v462_refix(p_proname text) returns void
language plpgsql as $$
declare v_src text;
begin
  select def into v_src from _v462_snapshot where proname = p_proname;
  if v_src is null then
    raise exception 'v462 harness: no snapshot to restore for public.%', p_proname;
  end if;
  execute v_src;
end
$$;
grant execute on function pg_temp.v462_refix(text) to public;

-- ---------------------------------------------------------------------------
-- FIXTURE
-- ---------------------------------------------------------------------------
do $fixture$
declare
  v_bizA uuid := gen_random_uuid();
  v_bizB uuid := gen_random_uuid();
  v_ownerA uuid := gen_random_uuid();
  v_ownerB uuid := gen_random_uuid();
  v_mgrA uuid := gen_random_uuid();
  v_super uuid := gen_random_uuid();
  v_userC uuid := gen_random_uuid();
  v_identC uuid;
  v_cliA uuid; v_cliB uuid;
  v_linkA uuid := gen_random_uuid();
  v_linkB uuid := gen_random_uuid();
  v_brA uuid := gen_random_uuid();
  v_brB uuid := gen_random_uuid();
  v_i int;
begin
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                         email_confirmed_at,created_at,updated_at)
  values
   ('00000000-0000-0000-0000-000000000000',v_ownerA,'authenticated','authenticated',
    'v462-owner-a-'||substr(v_ownerA::text,1,8)||'@example.test','',now(),now(),now()),
   ('00000000-0000-0000-0000-000000000000',v_ownerB,'authenticated','authenticated',
    'v462-owner-b-'||substr(v_ownerB::text,1,8)||'@example.test','',now(),now(),now()),
   ('00000000-0000-0000-0000-000000000000',v_mgrA,'authenticated','authenticated',
    'v462-mgr-'||substr(v_mgrA::text,1,8)||'@example.test','',now(),now(),now()),
   ('00000000-0000-0000-0000-000000000000',v_super,'authenticated','authenticated',
    'v462-super-'||substr(v_super::text,1,8)||'@example.test','',now(),now(),now()),
   ('00000000-0000-0000-0000-000000000000',v_userC,'authenticated','authenticated',
    'v462-cust-'||substr(v_userC::text,1,8)||'@example.test','',now(),now(),now());

  insert into public.super_admins(user_id,email,note)
  values(v_super,'v462-super-'||substr(v_super::text,1,8)||'@example.test',
         'rollback-only v462 fixture');

  insert into public.businesses(id,name,slug,enabled_modules) values
   (v_bizA,'V462 Firm A','v462a-'||substr(v_bizA::text,1,8),
    array['dashboard','clients','sales','loyalty','retention']),
   (v_bizB,'V462 Firm B','v462b-'||substr(v_bizB::text,1,8),
    array['dashboard','clients','sales','loyalty','retention']);

  insert into public.staff(business_id,user_id,role,full_name,active,access_state) values
   (v_bizA,v_ownerA,'owner','V462 Owner A',true,'approved'),
   (v_bizA,v_mgrA,'manager','V462 Manager A',true,'approved'),
   (v_bizB,v_ownerB,'owner','V462 Owner B',true,'approved');

  insert into public.business_workspace_controls_v94(
    business_id,approval_status,decided_by,decided_at,decision_reason)
  values (v_bizA,'approved',v_ownerA,now(),'v462 fixture'),
         (v_bizB,'approved',v_ownerB,now(),'v462 fixture')
  on conflict (business_id) do update
    set approval_status='approved', decided_by=excluded.decided_by,
        decided_at=excluded.decided_at, decision_reason=excluded.decision_reason;
  insert into public.business_subscription_lifecycle_v94(business_id,workspace_paused)
  values (v_bizA,false),(v_bizB,false)
  on conflict (business_id) do update set workspace_paused=false;

  insert into public.branches(id,business_id,name,is_default,active) values
   (v_brA,v_bizA,'V462 Main A',true,true),
   (v_brB,v_bizB,'V462 Main B',true,true);

  update app.platform_feature_flags set enabled=true, changed_at=now()
  where feature_key in ('customer_identity','customer_claims','customer_wallet');

  insert into public.clients(business_id,full_name,phone)
  values(v_bizA,'V462 Customer','81990462') returning id into v_cliA;
  insert into public.clients(business_id,full_name,phone)
  values(v_bizB,'V462 Customer','81990463') returning id into v_cliB;

  insert into public.customer_identities(auth_user_id,status,created_via)
  values(v_userC,'active','wallet_start') returning id into v_identC;

  perform set_config('app.customer_link_insert_id',v_linkA::text,true);
  insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,
                                    state,verification_method,verified_at)
  values(v_linkA,v_bizA,v_identC,v_userC,v_cliA,'verified','qr_join',now());
  perform set_config('app.customer_link_insert_id',v_linkB::text,true);
  insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,
                                    state,verification_method,verified_at)
  values(v_linkB,v_bizB,v_identC,v_userC,v_cliB,'verified','qr_join',now());
  perform set_config('app.customer_link_insert_id','',true);

  insert into _c(bizA,bizB,ownerA,ownerB,mgrA,superU,brA,brB,userC,identC,cliA,cliB,linkA,linkB)
  values(v_bizA,v_bizB,v_ownerA,v_ownerB,v_mgrA,v_super,v_brA,v_brB,
         v_userC,v_identC,v_cliA,v_cliB,v_linkA,v_linkB);

  -- Eight live offers at A, three at B. Eight is the number that matters: more than the hard six
  -- the reader used to impose, fewer than the ten the entitlement allows.
  for v_i in 1..8 loop
    insert into _o(biz,seq,id)
    values(v_bizA, v_i, pg_temp.v462_offer(v_bizA, v_ownerA, 'V462 A Offer '||v_i, true));
  end loop;
  for v_i in 1..3 loop
    insert into _o(biz,seq,id)
    values(v_bizB, v_i, pg_temp.v462_offer(v_bizB, v_ownerB, 'V462 B Offer '||v_i, true));
  end loop;

  -- Stand in for eleven separate production publishes: higher seq = published more recently.
  perform set_config('app.v104_promotion_write','on',true);
  update public.business_customer_content_v95 content
  set metadata = jsonb_set(content.metadata,'{published_once_at}',
        to_jsonb(now() - ((100 - _o.seq) * interval '1 minute'))),
      updated_at = now() - ((100 - _o.seq) * interval '1 minute')
  from _o
  where content.id = _o.id;
  perform set_config('app.v104_promotion_write','',true);
end
$fixture$;

-- 01 ---------------------------------------------------------------- fixture shape
do $$
declare v_liveA int; v_liveB int; v_ent int;
begin
  select app.v462_live_offer_count(bizA), app.v462_live_offer_count(bizB)
    into v_liveA, v_liveB from _c;
  select max_published_offers into v_ent
    from app.v104_effective_promotion_entitlement((select bizA from _c));
  insert into _r values('01_eight_live_offers_at_firm_a',
    case when v_liveA = 8 then 'PASS 8 live offers' else 'FAIL live='||v_liveA end);
  insert into _r values('01_three_live_offers_at_firm_b',
    case when v_liveB = 3 then 'PASS 3 live offers' else 'FAIL live='||v_liveB end);
  insert into _r values('01_entitlement_is_the_v104_default_ten',
    case when v_ent = 10 then 'PASS entitlement 10, read rather than hardcoded'
         else 'FAIL entitlement='||v_ent end);
end
$$;

-- 02 -------------------------------------------- NEGATIVE CONTROL: the pre-v462 business reader
do $$
declare v_out jsonb;
begin
  perform pg_temp.v462_unfix('customer_get_promotions_v155', array[
    'limit v_limit', 'limit 6',
    '''limit'',v_limit', '''limit'',2'
  ]);
  perform pg_temp.as_v462((select userC from _c));
  v_out := public.customer_get_promotions_v155((select bizA from _c), null, 'en');
  execute 'reset role';
  perform pg_temp.v462_refix('customer_get_promotions_v155');

  insert into _r values('02_negctl_old_reader_truncates_to_six',
    case when jsonb_array_length(v_out->'items') = 6
      then 'PASS the pre-v462 reader returns 6 of the 8 live offers'
      else 'FAIL items='||jsonb_array_length(v_out->'items') end);
  insert into _r values('02_negctl_old_reader_lies_about_its_limit',
    case when (v_out->>'limit') = '2'
      then 'PASS the pre-v462 payload reports limit 2 while returning 6'
      else 'FAIL limit='||coalesce(v_out->>'limit','<null>') end);
end
$$;

-- 03 ------------------------------------------------ business page returns every live offer
do $$
declare v_out jsonb;
begin
  perform pg_temp.as_v462((select userC from _c));
  v_out := public.customer_get_promotions_v155((select bizA from _c), null, 'en');
  execute 'reset role';
  insert into _r values('03_business_page_returns_all_eight',
    case when jsonb_array_length(v_out->'items') = 8
      then 'PASS all 8 live offers reach the business page'
      else 'FAIL items='||jsonb_array_length(v_out->'items') end);
  insert into _r values('03_limit_field_tells_the_truth',
    case when (v_out->>'limit') = '10'
      then 'PASS the payload reports the entitlement it actually applies'
      else 'FAIL limit='||coalesce(v_out->>'limit','<null>') end);
end
$$;

-- 04 -------------------------------------------------- the bound follows the entitlement
do $$
declare v_out jsonb; v_ent jsonb;
begin
  perform pg_temp.as_v462((select superU from _c));
  v_ent := public.platform_set_promotion_entitlement_v104(
    (select bizA from _c), 3, timestamptz '2026-11-01 00:00:00+08', 0);
  execute 'reset role';

  perform pg_temp.as_v462((select userC from _c));
  v_out := public.customer_get_promotions_v155((select bizA from _c), null, 'en');
  execute 'reset role';
  insert into _r values('04_lowering_the_entitlement_moves_both_numbers',
    case when jsonb_array_length(v_out->'items') = 3 and (v_out->>'limit') = '3'
      then 'PASS items and limit both follow the entitlement'
      else 'FAIL items='||jsonb_array_length(v_out->'items')
           ||' limit='||coalesce(v_out->>'limit','<null>') end);

  perform pg_temp.as_v462((select superU from _c));
  perform public.platform_set_promotion_entitlement_v104(
    (select bizA from _c), 10, timestamptz '2026-11-01 00:00:00+08',
    (v_ent->>'version')::bigint);
  execute 'reset role';

  perform pg_temp.as_v462((select userC from _c));
  v_out := public.customer_get_promotions_v155((select bizA from _c), null, 'en');
  execute 'reset role';
  insert into _r values('04_restoring_the_entitlement_restores_the_offers',
    case when jsonb_array_length(v_out->'items') = 8 and (v_out->>'limit') = '10'
      then 'PASS back to 8 items under a limit of 10'
      else 'FAIL items='||jsonb_array_length(v_out->'items')
           ||' limit='||coalesce(v_out->>'limit','<null>') end);
end
$$;

-- 05 ------------------------------------------------------- default until the owner picks
do $$
declare v_effective uuid; v_newest uuid; v_editor jsonb;
begin
  select id into v_newest from _o where biz = (select bizA from _c) and seq = 8;
  v_effective := app.v462_effective_featured_offer((select bizA from _c));
  insert into _r values('05_default_is_the_most_recently_published_live_offer',
    case when v_effective = v_newest
      then 'PASS the newest publication is featured before anyone chooses'
      else 'FAIL effective='||coalesce(v_effective::text,'null')
           ||' newest='||v_newest::text end);
  insert into _r values('05_no_pin_row_exists_yet',
    case when not exists(select 1 from public.business_featured_offer_v462
                          where business_id = (select bizA from _c))
      then 'PASS the default needs no backfill row'
      else 'FAIL a pin row was created without anyone asking' end);

  perform pg_temp.as_v462((select ownerA from _c));
  v_editor := public.business_get_promotion_editor_v155((select bizA from _c));
  execute 'reset role';
  insert into _r values('05_owner_editor_states_the_same_offer',
    case when (v_editor->>'featured_offer_id') = v_newest::text
          and (v_editor->>'featured_offer_pinned') = 'false'
      then 'PASS the owner screen names the default and says it is not a choice yet'
      else 'FAIL featured='||coalesce(v_editor->>'featured_offer_id','<null>')
           ||' pinned='||coalesce(v_editor->>'featured_offer_pinned','<null>') end);
  insert into _r values('05_owner_editor_reports_the_live_count',
    case when (v_editor#>>'{entitlement,live_count}') = '8'
          and (v_editor#>>'{entitlement,quota_used}') = '8'
      then 'PASS the slots figure the owner reads is the live count the gate enforces'
      else 'FAIL live_count='||coalesce(v_editor#>>'{entitlement,live_count}','<null>')
           ||' quota_used='||coalesce(v_editor#>>'{entitlement,quota_used}','<null>') end);
end
$$;

-- 06 -------------------------------------------------------- pin, replace, clear, one row
do $$
declare v_two uuid; v_five uuid; v_out jsonb; v_rows int;
begin
  select id into v_two  from _o where biz = (select bizA from _c) and seq = 2;
  select id into v_five from _o where biz = (select bizA from _c) and seq = 5;

  perform pg_temp.as_v462((select ownerA from _c));
  v_out := public.business_set_featured_offer_v462((select bizA from _c), v_two);
  execute 'reset role';
  insert into _r values('06_owner_pins_an_offer',
    case when (v_out->>'featured_offer_id') = v_two::text
          and (v_out->>'featured_offer_pinned') = 'true'
          and app.v462_effective_featured_offer((select bizA from _c)) = v_two
      then 'PASS the chosen offer overrides the default'
      else 'FAIL '||v_out::text end);

  perform pg_temp.as_v462((select ownerA from _c));
  perform public.business_set_featured_offer_v462((select bizA from _c), v_five);
  execute 'reset role';
  select count(*) into v_rows from public.business_featured_offer_v462
   where business_id = (select bizA from _c);
  insert into _r values('06_a_second_choice_replaces_it_never_adds',
    case when v_rows = 1 and app.v462_effective_featured_offer((select bizA from _c)) = v_five
      then 'PASS exactly one featured row, and it is the newest choice'
      else 'FAIL rows='||v_rows end);

  -- The invariant is the KEY, not the writer's manners: a second row is unrepresentable.
  begin
    insert into public.business_featured_offer_v462(business_id,promotion_id)
    values((select bizA from _c), v_two);
    insert into _r values('06_two_featured_rows_are_unrepresentable',
      'FAIL a second featured row was accepted for the same business');
  exception when unique_violation then
    insert into _r values('06_two_featured_rows_are_unrepresentable',
      'PASS the primary key refuses a second row (23505)');
  end;

  perform pg_temp.as_v462((select ownerA from _c));
  v_out := public.business_set_featured_offer_v462((select bizA from _c), null);
  execute 'reset role';
  select count(*) into v_rows from public.business_featured_offer_v462
   where business_id = (select bizA from _c);
  insert into _r values('06_clearing_returns_to_the_default',
    case when v_rows = 0
          and (v_out->>'featured_offer_id')
              = (select id::text from _o where biz=(select bizA from _c) and seq=8)
          and (v_out->>'featured_offer_pinned') = 'false'
      then 'PASS the pin is removable and the default comes back'
      else 'FAIL rows='||v_rows||' out='||v_out::text end);

  -- Leave firm A pinned to offer 5 and firm B unpinned, for checks 08 and 10.
  perform pg_temp.as_v462((select ownerA from _c));
  perform public.business_set_featured_offer_v462((select bizA from _c), v_five);
  execute 'reset role';
end
$$;

-- 07 ------------------------------------------------------------------- writer refusals
do $$
declare v_draft uuid; v_foreign uuid; v_state text;
begin
  v_draft := pg_temp.v462_offer((select bizA from _c), (select ownerA from _c),
                                'V462 A Draft', false);
  select id into v_foreign from _o where biz = (select bizB from _c) and seq = 1;

  perform pg_temp.as_v462((select ownerA from _c));
  begin
    perform public.business_set_featured_offer_v462((select bizA from _c), v_draft);
    v_state := 'accepted';
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate;
  end;
  execute 'reset role';
  insert into _r values('07_a_draft_cannot_be_featured',
    case when v_state = '23514' then 'PASS refused with featured_offer_must_be_live'
         else 'FAIL '||v_state end);

  perform pg_temp.as_v462((select ownerA from _c));
  begin
    perform public.business_set_featured_offer_v462((select bizA from _c), v_foreign);
    v_state := 'accepted';
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate;
  end;
  execute 'reset role';
  insert into _r values('07_another_firms_offer_cannot_be_featured',
    case when v_state = '23514' then 'PASS a cross-tenant id is not a candidate'
         else 'FAIL '||v_state end);

  perform pg_temp.as_v462((select mgrA from _c));
  begin
    perform public.business_set_featured_offer_v462(
      (select bizA from _c), (select id from _o where biz=(select bizA from _c) and seq=1));
    v_state := 'accepted';
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate;
  end;
  execute 'reset role';
  insert into _r values('07_a_manager_cannot_feature',
    case when v_state = '42501' then 'PASS owner_required, the same gate as the other offer writes'
         else 'FAIL '||v_state end);

  perform pg_temp.as_v462(null);
  begin
    perform public.business_set_featured_offer_v462(
      (select bizA from _c), (select id from _o where biz=(select bizA from _c) and seq=1));
    v_state := 'accepted';
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate;
  end;
  execute 'reset role';
  insert into _r values('07_a_caller_with_no_session_cannot_feature',
    case when v_state in ('28000','42501')
      then 'PASS refused ('||v_state||')' else 'FAIL '||v_state end);

  insert into _r values('07_no_refusal_left_a_row_behind',
    case when (select count(*) from public.business_featured_offer_v462
                where business_id=(select bizA from _c)) = 1
      then 'PASS the four refusals changed nothing'
      else 'FAIL rows='||(select count(*) from public.business_featured_offer_v462
                           where business_id=(select bizA from _c)) end);
end
$$;

-- 08 --------------------------------------------------------------------- a stale pin
do $$
declare v_five uuid; v_effective uuid;
begin
  select id into v_five from _o where biz = (select bizA from _c) and seq = 5;
  -- Offer 8 is the newest publication, so drafting 5 must fall back to 8, not to nothing.
  perform pg_temp.v462_set_publish((select bizA from _c),(select ownerA from _c),v_five,false);
  v_effective := app.v462_effective_featured_offer((select bizA from _c));
  insert into _r values('08_a_pin_whose_offer_went_to_draft_falls_back',
    case when v_effective = (select id from _o where biz=(select bizA from _c) and seq=8)
      then 'PASS the feed keeps a card instead of going blank'
      else 'FAIL effective='||coalesce(v_effective::text,'null') end);
  insert into _r values('08_the_stale_pin_row_is_left_alone',
    case when exists(select 1 from public.business_featured_offer_v462
                      where business_id=(select bizA from _c) and promotion_id=v_five)
      then 'PASS the owner choice is remembered, not silently deleted'
      else 'FAIL the pin row disappeared' end);
  perform pg_temp.v462_set_publish((select bizA from _c),(select ownerA from _c),v_five,true);
  insert into _r values('08_republishing_restores_the_remembered_choice',
    case when app.v462_effective_featured_offer((select bizA from _c)) = v_five
      then 'PASS'
      else 'FAIL effective='
        ||coalesce(app.v462_effective_featured_offer((select bizA from _c))::text,'null') end);
end
$$;

-- 09 ------------------------------------------------ NEGATIVE CONTROL: Home without featuring
do $$
declare v_out jsonb; v_live int;
begin
  select app.v462_live_offer_count(bizA) + app.v462_live_offer_count(bizB) into v_live from _c;
  perform pg_temp.v462_unfix('customer_get_home_offers_v167', array[
    E'    join featured\n      on featured.business_id=context.business_id\n', '',
    E'     and content.id=featured.promotion_id\n', ''
  ]);
  perform pg_temp.as_v462((select userC from _c));
  v_out := public.customer_get_home_offers_v167('en');
  execute 'reset role';
  perform pg_temp.v462_refix('customer_get_home_offers_v167');

  insert into _r values('09_negctl_old_home_returns_every_live_offer',
    case when jsonb_array_length(v_out->'items') = v_live and v_live > 2
      then 'PASS the pre-v462 Home returns all '||v_live||' live offers across the two firms'
      else 'FAIL items='||jsonb_array_length(v_out->'items')||' live='||v_live end);
end
$$;

-- 10 ----------------------------------------------------- Home: one per business, the featured
do $$
declare v_out jsonb; v_ids text[]; v_five uuid; v_bnewest uuid;
begin
  select id into v_five from _o where biz = (select bizA from _c) and seq = 5;
  select id into v_bnewest from _o where biz = (select bizB from _c) and seq = 3;

  perform pg_temp.as_v462((select userC from _c));
  v_out := public.customer_get_home_offers_v167('en');
  execute 'reset role';

  select array_agg(item->>'id' order by item->>'id')
    into v_ids from jsonb_array_elements(v_out->'items') item;

  insert into _r values('10_home_carries_one_offer_per_business',
    case when jsonb_array_length(v_out->'items') = 2
      then 'PASS two linked firms, two cards'
      else 'FAIL items='||jsonb_array_length(v_out->'items') end);
  insert into _r values('10_each_card_is_that_firms_featured_offer',
    case when v_ids @> array[v_five::text] and v_ids @> array[v_bnewest::text]
      then 'PASS firm A''s owner-chosen offer and firm B''s default, nothing else'
      else 'FAIL ids='||coalesce(array_to_string(v_ids,','),'<null>') end);
  insert into _r values('10_home_says_it_is_a_featured_feed',
    case when (v_out->>'featured_only') = 'true' and (v_out->>'limit') = '12'
      then 'PASS the payload describes what it did'
      else 'FAIL featured_only='||coalesce(v_out->>'featured_only','<null>')
           ||' limit='||coalesce(v_out->>'limit','<null>') end);
  insert into _r values('10_no_business_appears_twice',
    case when (select count(distinct item#>>'{business,id}')
                 from jsonb_array_elements(v_out->'items') item)
              = jsonb_array_length(v_out->'items')
      then 'PASS' else 'FAIL a firm contributed more than one card' end);
end
$$;

-- 11 ------------------------------------------------------------------------ the live cap
do $$
declare
  v_ninth uuid; v_tenth uuid; v_eleventh uuid; v_out jsonb; v_live int;
begin
  v_ninth := pg_temp.v462_offer((select bizA from _c),(select ownerA from _c),'V462 A Offer 9',true);
  v_tenth := pg_temp.v462_offer((select bizA from _c),(select ownerA from _c),'V462 A Offer 10',true);
  select app.v462_live_offer_count(bizA) into v_live from _c;
  insert into _r values('11_the_firm_is_at_the_cap',
    case when v_live = 10 then 'PASS 10 live offers' else 'FAIL live='||v_live end);

  v_eleventh := pg_temp.v462_offer((select bizA from _c),(select ownerA from _c),'V462 A Offer 11',false);
  v_out := pg_temp.v462_set_publish((select bizA from _c),(select ownerA from _c),v_eleventh,true);
  insert into _r values('11_the_eleventh_publish_is_refused_distinguishably',
    case when (v_out->>'ok') = 'false' and (v_out->>'blocked') = 'true'
          and (v_out->>'code') = 'promotion_finalize_rejected'
          and (v_out->>'reason') = 'promotion_publish_limit_reached'
      then 'PASS a named refusal the client can turn into the demote dialog'
      else 'FAIL '||v_out::text end);
  insert into _r values('11_the_refused_offer_did_not_go_live',
    case when app.v462_live_offer_count((select bizA from _c)) = 10
      then 'PASS the cap held'
      else 'FAIL live='||app.v462_live_offer_count((select bizA from _c)) end);

  -- Republishing an offer that is ALREADY live is not a transition and must never be blocked.
  v_out := pg_temp.v462_set_publish((select bizA from _c),(select ownerA from _c),v_ninth,true);
  insert into _r values('11_republishing_a_live_offer_at_the_cap_is_allowed',
    case when coalesce(v_out->>'blocked','false') <> 'true'
      then 'PASS an edit to a live offer is not a new publication'
      else 'FAIL '||v_out::text end);

  -- Moving one back to draft frees the slot at once — the whole point of the owner's dialog.
  perform pg_temp.v462_set_publish((select bizA from _c),(select ownerA from _c),v_tenth,false);
  insert into _r values('11_drafting_one_frees_a_slot',
    case when app.v462_live_offer_count((select bizA from _c)) = 9
      then 'PASS live fell to 9'
      else 'FAIL live='||app.v462_live_offer_count((select bizA from _c)) end);

  v_out := pg_temp.v462_set_publish((select bizA from _c),(select ownerA from _c),v_eleventh,true);
  insert into _r values('11_the_same_publish_now_succeeds',
    case when coalesce(v_out->>'blocked','false') <> 'true'
          and app.v462_live_offer_count((select bizA from _c)) = 10
      then 'PASS the owner instruction "move one to draft first" is true'
      else 'FAIL '||v_out::text end);

  -- Leave the firm one under the cap, with eleven offers already published at least once.
  perform pg_temp.v462_set_publish((select bizA from _c),(select ownerA from _c),v_eleventh,false);
end
$$;

-- 12 ----------------------------------------- NEGATIVE CONTROL: the pre-v462 lifetime cap
do $$
declare v_out jsonb; v_live int; v_ever int; v_twelfth uuid;
begin
  -- A never-published draft: the pre-v462 gate only ever fired on an offer's FIRST publish.
  v_twelfth := pg_temp.v462_offer((select bizA from _c),(select ownerA from _c),
                                  'V462 A Offer 12',false);

  select app.v462_live_offer_count(bizA) into v_live from _c;
  select count(*)::integer into v_ever
    from public.business_customer_content_v95 content, _c
   where content.business_id = _c.bizA and content.content_type = 'offer'
     and content.metadata ? 'published_once_at';

  perform pg_temp.v462_unfix('business_finalize_promotion_v104', array[
    'if p_publish and not coalesce(v_content.active,false) then',
      'if v_first_adoption then',
    E'    v_quota_used:=app.v462_live_offer_count(p_business);\n    if v_quota_used>=v_entitlement.max_published_offers then',
      E'    select count(*)::integer into v_quota_used from public.business_customer_content_v95 content where content.business_id=p_business and content.content_type=''offer'' and content.metadata ? ''published_once_at'';\n    if v_quota_used>=v_entitlement.max_published_offers then'
  ]);
  v_out := pg_temp.v462_set_publish((select bizA from _c),(select ownerA from _c),v_twelfth,true);
  perform pg_temp.v462_refix('business_finalize_promotion_v104');

  insert into _r values('12_negctl_shape',
    case when v_live < 10 and v_ever >= 10
      then 'PASS '||v_live||' live but '||v_ever||' ever published — the two rules disagree here'
      else 'FAIL live='||v_live||' ever='||v_ever end);
  insert into _r values('12_negctl_the_lifetime_cap_refuses_what_the_live_cap_allows',
    case when (v_out->>'reason') = 'promotion_publish_limit_reached'
      then 'PASS under the old rule drafting frees nothing, so check 11 measures the change'
      else 'FAIL '||v_out::text end);

  -- And with v462 back in place the very same publish goes through.
  v_out := pg_temp.v462_set_publish((select bizA from _c),(select ownerA from _c),v_twelfth,true);
  insert into _r values('12_the_live_cap_allows_it_again',
    case when coalesce(v_out->>'blocked','false') <> 'true'
      then 'PASS both directions demonstrated inside one transaction'
      else 'FAIL '||v_out::text end);
end
$$;

-- 13 ------------------------------------------------------------------------- privileges
do $$
declare v_api int; v_grant boolean;
begin
  select count(*)::int into v_api
    from information_schema.role_table_grants
   where table_schema = 'public'
     and table_name = 'business_featured_offer_v462'
     and grantee in ('anon','authenticated');
  insert into _r values('13_the_featured_table_is_api_unwritable_and_unreadable',
    case when v_api = 0
      then 'PASS no anon/authenticated privileges exist on the table at all'
      else 'FAIL '||v_api||' grants leaked to the API roles' end);

  select has_function_privilege('authenticated',
    'public.business_set_featured_offer_v462(uuid,uuid)','execute') into v_grant;
  insert into _r values('13_the_writer_is_callable_by_an_owner_session',
    case when v_grant then 'PASS authenticated may execute the RPC'
         else 'FAIL the RPC is not granted' end);

  select has_function_privilege('anon',
    'public.business_set_featured_offer_v462(uuid,uuid)','execute') into v_grant;
  insert into _r values('13_the_writer_is_not_callable_anonymously',
    case when not v_grant then 'PASS anon has no execute'
         else 'FAIL anon may execute the RPC' end);
end
$$;

select k, v from _r order by k;

rollback;
