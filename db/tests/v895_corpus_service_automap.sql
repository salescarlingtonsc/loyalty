-- EXECUTED acceptance fixture for nestly_v895
-- (db/migrations/20261007_nestly_v895_service_automap.sql).
--
-- Run: LC_ALL=C node scripts/db-tests/run.mjs --filter=v895 --migrated-only
--
-- WHAT IS BEING PROVED. v895 lets a service classify itself the moment it is created. The
-- danger is not that it maps too little — an unmapped service is a visible board row — it is
-- that it maps something WRONGLY and silently, because "What you sell" then lies to a tenant
-- that never asked for the mapping. So every assertion below is about the guard rails, not the
-- happy path: word-start matching, the pack rule, the ambiguity rule, and never-overwrite.
--
-- PREDETERMINED TRUTH TABLE (written before the first run; every assertion is exact equality).
--
--   Business B1, industry 'facial' -> pack beauty_wellness
--     S1 'Spa package 5x'        -> massage_body           kw 'spa'        own_pack_unique  CONFIDENT
--     S2 'Facials'               -> facial.general         kw 'facial'     own_pack_unique  CONFIDENT
--                                   ('facial' sits on BOTH facial and facial.general; same
--                                    length, same level-2 family, so the deeper node wins the
--                                    tie-break and the pair is not "ambiguous")
--     S3 'Threading'             -> brows_lashes           kw 'threading'  own_pack_unique  CONFIDENT
--                                   (v647 had threading on hair_removal; v895 moves it)
--     S4 'Herbal tea (add-on)'   -> beverages.coffee_tea   kw 'tea'        cross_pack       not confident
--     S5 'Zzz bespoke item'      -> (none)                                 no_match         not confident
--     S6 'Deluxe manicure'       -> a map row to nails.pedicure, method owner_chosen, written
--                                   BEFORE the service row exists (service_canonical_map has no
--                                   FK to services — nestly_v686 says so). Its own suggestion
--                                   would be nails.manicure and is never applied.
--
--   Business B2, industry 'fnb' -> pack fnb
--     S7 'Spaghetti bolognese'   -> food.mains             kw 'spaghetti'  own_pack_unique  CONFIDENT
--                                   THE HEADLINE: "spaghetti" word-starts with "spa", so the
--                                   beauty keyword really does match. The pack rule is what
--                                   makes the answer food.mains and not massage_body.
--     S8 'Foot reflexology 60min'-> massage_body.foot_reflexology kw 'foot reflexology'
--                                                                          cross_pack       not confident
--                                   the same guard in the other direction.
--
--   After the AFTER INSERT trigger: mapped = S1,S2,S3 (method auto_keyword, mapped_by = the
--   creating user) and S7; unmapped = S4, S5, S8; S6 keeps its owner_chosen nails.pedicure.
--   B1 board: suggestions.confident 0, suggestions.possible 1 (S4 only — S5 has no suggestion).
--
--   accept-all(B1, only_confident := true)  -> mapped 0, no_suggestion 1, not_confident 1
--   accept-all(B1)                          -> mapped 1 (S4 -> beverages.coffee_tea,
--                                              method accepted_suggestions), no_suggestion 1,
--                                              not_confident 0, rows length 1, confident false
--   accept-all(B1) again                    -> mapped 0  (idempotent)
--   O2 (a real owner of B2) calling accept-all on B1 -> 42501
--
--   Backfill: the estate is drained once at the top of this fixture so the count below is
--   exact. Delete every fixture mapping except S6's, then
--     app.service_automap_backfill_v895() -> 4   (S1,S2,S3,S7; S4/S8 are not confident,
--                                                 S5 has no suggestion, S6 is already mapped)
--     the same call again                 -> 0   (idempotent)
--     the four rows carry method auto_keyword_backfill and mapped_by null; S6 is untouched.
--
--   History carries all three new methods as change_kind 'set'.
--
--   Knock-on (nestly_v686): the owner can still HARD DELETE a service whose only reference is
--   an automatic mapping (used_by 0, row gone, mapping gone), while a service the owner mapped
--   by hand still RETIRES (used_by >= 1). Without this, auto-mapping would have made every new
--   service undeletable.
--
-- Any row in v895_out whose outcome starts with FAIL is a failure; the block at the end raises.

begin;

create temp table v895_out(seq integer, step text, outcome text) on commit drop;
grant insert, select on v895_out to public;

create or replace function pg_temp.v895_system() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','',true);
end
$$;
grant execute on function pg_temp.v895_system() to public;

-- Table owner (RLS does not apply) but with a JWT identity, so auth.uid() inside the
-- SECURITY DEFINER trigger is a real person while the insert itself needs no RLS policy.
create or replace function pg_temp.v895_system_as(p_uid uuid) returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub',coalesce(p_uid::text,''),true);
  perform set_config('request.jwt.claims',
    json_build_object('sub',p_uid,'role','authenticated')::text,true);
end
$$;
grant execute on function pg_temp.v895_system_as(uuid) to public;

create or replace function pg_temp.v895_user(p_uid uuid) returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','{}',true);
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub',coalesce(p_uid::text,''),true);
  perform set_config('request.jwt.claims',
    json_build_object('sub',p_uid,'role','authenticated')::text,true);
end
$$;
grant execute on function pg_temp.v895_user(uuid) to public;

-- A minimal but genuinely operational tenant (the CI-corpus recipe): approved workspace,
-- unpaused subscription, the services module on, one approved owner on a default branch.
create or replace function pg_temp.v895_tenant(
  p_business uuid, p_owner uuid, p_industry text, p_tag text
) returns void language plpgsql as $$
declare v_owner_staff uuid; v_branch uuid;
begin
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                         email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000',p_owner,'authenticated','authenticated',
          'v895-'||p_tag||'-'||substr(p_owner::text,1,8)||'@example.test','',now(),now(),now())
  on conflict (id) do nothing;

  perform set_config('app.v79_system_transition','on',true);
  insert into public.businesses(id,name,slug,industry,currency,enabled_modules)
  values (p_business,'V895 '||p_tag,'v895-'||p_tag||'-'||substr(p_business::text,1,8),
          p_industry,'SGD',
          array['dashboard','clients','sales','services','inventory','appointments']);
  perform set_config('app.v79_system_transition','',true);

  update public.business_workspace_controls_v94
     set approval_status='approved', decided_by=p_owner, decided_at=now(),
         decision_reason='v895 rollback fixture'
   where business_id = p_business;
  insert into public.business_subscription_lifecycle_v94(business_id)
  values (p_business) on conflict (business_id) do nothing;
  update public.business_subscription_lifecycle_v94
     set workspace_paused=false where business_id = p_business;
  insert into public.subscriptions(business_id) values (p_business) on conflict do nothing;

  insert into public.staff(business_id,user_id,role,full_name,active,access_state)
  values (p_business,p_owner,'owner','V895 Owner',true,'approved')
  returning id into v_owner_staff;
  insert into public.branches(business_id,name,active,is_default)
  values (p_business,'V895 Main',true,true)
  returning id into v_branch;
  insert into public.staff_branches(business_id,staff_id,branch_id)
  values (p_business,v_owner_staff,v_branch);
end
$$;
grant execute on function pg_temp.v895_tenant(uuid,uuid,text,text) to public;

do $v895$
declare
  b1 uuid := gen_random_uuid();  o1 uuid := gen_random_uuid();
  b2 uuid := gen_random_uuid();  o2 uuid := gen_random_uuid();
  s1 uuid := gen_random_uuid();  s2 uuid := gen_random_uuid();  s3 uuid := gen_random_uuid();
  s4 uuid := gen_random_uuid();  s5 uuid := gen_random_uuid();  s6 uuid := gen_random_uuid();
  s7 uuid := gen_random_uuid();  s8 uuid := gen_random_uuid();
  v_j jsonb; v_board jsonb; v_row jsonb; v_res json;
  v_n integer; v_err text;
begin
  perform pg_temp.v895_system();

  -- Drain whatever the migration's own backfill has already taken, so the count asserted in
  -- step 14 is exactly this fixture's four services and nothing the baseline happened to carry.
  perform app.service_automap_backfill_v895();

  perform pg_temp.v895_tenant(b1, o1, 'facial', 'beauty');
  perform pg_temp.v895_tenant(b2, o2, 'fnb',    'cafe');

  -- ---------------------------------------------------------------- 0. preconditions
  if app.business_pack_v648(b1) = 'beauty_wellness' and app.business_pack_v648(b2) = 'fnb' then
    insert into v895_out values (0,'the two fixture tenants really resolve to different packs','PASS');
  else
    insert into v895_out values (0,'the two fixture tenants really resolve to different packs',
      format('FAIL - b1=%s b2=%s', app.business_pack_v648(b1), app.business_pack_v648(b2)));
  end if;

  -- S6's mapping is written BEFORE the service exists, which is legal (no FK) and is how this
  -- fixture gets a service that is already mapped at the instant the trigger fires.
  insert into public.service_canonical_map(business_id,service_id,node_key,version_no,method,mapped_by)
  values (b1,s6,'nails.pedicure',1,'owner_chosen',o1);

  perform pg_temp.v895_system_as(o1);
  insert into public.services(id,business_id,name,price_cents,duration_min) values
    (s1,b1,'Spa package 5x',     15000,60),
    (s2,b1,'Facials',             9000,60),
    (s3,b1,'Threading',           2500,20),
    (s4,b1,'Herbal tea (add-on)',  500,5),
    (s5,b1,'Zzz bespoke item',    1000,30),
    (s6,b1,'Deluxe manicure',     4500,45);

  perform pg_temp.v895_system_as(o2);
  insert into public.services(id,business_id,name,price_cents,duration_min) values
    (s7,b2,'Spaghetti bolognese',    1800,1),
    (s8,b2,'Foot reflexology 60min', 4500,60);

  perform pg_temp.v895_system();

  -- ---------------------------------------------------------------- 1. the word-start + pack rule
  v_j := app.suggest_canonical_node_v2(b1,s1);
  if v_j->>'node_key' = 'massage_body' and (v_j->>'confident')::boolean
     and v_j->>'reason' = 'own_pack_unique' and v_j->>'keyword' = 'spa' then
    insert into v895_out values (1,'"Spa package 5x" in a beauty tenant is a CONFIDENT massage_body on the keyword "spa"','PASS');
  else
    insert into v895_out values (1,'"Spa package 5x" in a beauty tenant is a CONFIDENT massage_body on the keyword "spa"',
      'FAIL - '||coalesce(v_j::text,'null'));
  end if;

  v_j := app.suggest_canonical_node_v2(b2,s7);
  if v_j->>'node_key' = 'food.mains' and (v_j->>'confident')::boolean
     and v_j->>'reason' = 'own_pack_unique' and v_j->>'keyword' = 'spaghetti' then
    insert into v895_out values (2,'"spaghetti bolognese" in an F&B tenant is food.mains, NOT massage_body','PASS');
  else
    insert into v895_out values (2,'"spaghetti bolognese" in an F&B tenant is food.mains, NOT massage_body',
      'FAIL - '||coalesce(v_j::text,'null'));
  end if;

  -- The same text judged against the BEAUTY tenant proves the "spa" keyword really did match:
  -- the pack rule, not a missing keyword, is what produced food.mains above.
  v_j := app.suggest_canonical_node_text_v895(b1,'spaghetti bolognese');
  if v_j->>'node_key' = 'massage_body' then
    insert into v895_out values (3,'the "spa" keyword genuinely word-starts "spaghetti" (so step 2 is the pack rule working, not luck)','PASS');
  else
    insert into v895_out values (3,'the "spa" keyword genuinely word-starts "spaghetti" (so step 2 is the pack rule working, not luck)',
      'FAIL - '||coalesce(v_j::text,'null'));
  end if;

  -- ...and a mid-word hit is still refused: "germanicure" must not become a manicure.
  v_j := app.suggest_canonical_node_text_v895(b1,'germanicure');
  if v_j->>'reason' = 'no_match' and v_j->>'node_key' is null then
    insert into v895_out values (4,'a mid-word hit is refused: "germanicure" matches nothing (v648 substring matching would have said nails.manicure)','PASS');
  else
    insert into v895_out values (4,'a mid-word hit is refused: "germanicure" matches nothing (v648 substring matching would have said nails.manicure)',
      'FAIL - '||coalesce(v_j::text,'null'));
  end if;

  -- ---------------------------------------------------------------- 5. family + suffix
  v_j := app.suggest_canonical_node_v2(b1,s2);
  if v_j->>'node_key' = 'facial.general' and (v_j->>'confident')::boolean
     and v_j->>'keyword' = 'facial' then
    insert into v895_out values (5,'"Facials" lands in the facial family (facial.general — deeper node wins the same-length tie)','PASS');
  else
    insert into v895_out values (5,'"Facials" lands in the facial family (facial.general — deeper node wins the same-length tie)',
      'FAIL - '||coalesce(v_j::text,'null'));
  end if;

  v_j := app.suggest_canonical_node_v2(b1,s3);
  if v_j->>'node_key' = 'brows_lashes' and (v_j->>'confident')::boolean then
    insert into v895_out values (6,'"Threading" is brows_lashes, not hair_removal','PASS');
  else
    insert into v895_out values (6,'"Threading" is brows_lashes, not hair_removal',
      'FAIL - '||coalesce(v_j::text,'null'));
  end if;

  -- ---------------------------------------------------------------- 7. cross-pack is suggested, never applied
  v_j := app.suggest_canonical_node_v2(b1,s4);
  if v_j->>'node_key' = 'beverages.coffee_tea' and not (v_j->>'confident')::boolean
     and v_j->>'reason' = 'cross_pack' then
    insert into v895_out values (7,'a beauty tenant''s "Herbal tea" suggests an F&B node but is NOT confident (cross_pack)','PASS');
  else
    insert into v895_out values (7,'a beauty tenant''s "Herbal tea" suggests an F&B node but is NOT confident (cross_pack)',
      'FAIL - '||coalesce(v_j::text,'null'));
  end if;

  v_j := app.suggest_canonical_node_v2(b2,s8);
  if v_j->>'node_key' = 'massage_body.foot_reflexology' and not (v_j->>'confident')::boolean
     and v_j->>'reason' = 'cross_pack' then
    insert into v895_out values (8,'the same guard in reverse: an F&B tenant''s "Foot reflexology" is cross_pack and not confident','PASS');
  else
    insert into v895_out values (8,'the same guard in reverse: an F&B tenant''s "Foot reflexology" is cross_pack and not confident',
      'FAIL - '||coalesce(v_j::text,'null'));
  end if;

  v_j := app.suggest_canonical_node_v2(b1,s5);
  if v_j->>'reason' = 'no_match' and v_j->>'node_key' is null then
    insert into v895_out values (9,'a name nothing matches returns reason no_match rather than a guess','PASS');
  else
    insert into v895_out values (9,'a name nothing matches returns reason no_match rather than a guess',
      'FAIL - '||coalesce(v_j::text,'null'));
  end if;

  -- ---------------------------------------------------------------- 10. v1 is a projection of v2
  if app.suggest_canonical_node_v1(b1,s1) = 'massage_body'
     and app.suggest_canonical_node_v1(b1,s5) is null
     and app.suggest_canonical_node_v1(b2,s7) = 'food.mains' then
    insert into v895_out values (10,'app.suggest_canonical_node_v1 now re-emits v2''s node_key (one authority)','PASS');
  else
    insert into v895_out values (10,'app.suggest_canonical_node_v1 now re-emits v2''s node_key (one authority)',
      format('FAIL - %s / %s / %s', app.suggest_canonical_node_v1(b1,s1),
             coalesce(app.suggest_canonical_node_v1(b1,s5),'null'), app.suggest_canonical_node_v1(b2,s7)));
  end if;

  -- ---------------------------------------------------------------- 11. the creation trigger
  if (select count(*) from public.service_canonical_map
       where business_id=b1 and service_id in (s1,s2,s3)
         and method='auto_keyword' and version_no=1 and mapped_by=o1) = 3
     and (select node_key from public.service_canonical_map where business_id=b1 and service_id=s1) = 'massage_body'
     and (select node_key from public.service_canonical_map where business_id=b1 and service_id=s2) = 'facial.general'
     and (select node_key from public.service_canonical_map where business_id=b1 and service_id=s3) = 'brows_lashes'
     and (select node_key from public.service_canonical_map where business_id=b2 and service_id=s7) = 'food.mains' then
    insert into v895_out values (11,'creating a service auto-maps it when the match is confident, stamped auto_keyword and the creator','PASS');
  else
    insert into v895_out values (11,'creating a service auto-maps it when the match is confident, stamped auto_keyword and the creator',
      format('FAIL - %s auto rows', (select count(*) from public.service_canonical_map
              where business_id=b1 and service_id in (s1,s2,s3) and method='auto_keyword' and mapped_by=o1)));
  end if;

  if not exists (select 1 from public.service_canonical_map where business_id=b1 and service_id=s4)
     and not exists (select 1 from public.service_canonical_map where business_id=b1 and service_id=s5)
     and not exists (select 1 from public.service_canonical_map where business_id=b2 and service_id=s8) then
    insert into v895_out values (12,'a cross-pack or unmatched service is left unmapped by the trigger','PASS');
  else
    insert into v895_out values (12,'a cross-pack or unmatched service is left unmapped by the trigger','FAIL - something was mapped');
  end if;

  if (select node_key||'/'||method from public.service_canonical_map where business_id=b1 and service_id=s6)
     = 'nails.pedicure/owner_chosen' then
    insert into v895_out values (13,'an already-mapped service is not re-mapped by the trigger, even when the suggestion differs','PASS');
  else
    insert into v895_out values (13,'an already-mapped service is not re-mapped by the trigger, even when the suggestion differs',
      'FAIL - '||coalesce((select node_key||'/'||method from public.service_canonical_map where business_id=b1 and service_id=s6),'gone'));
  end if;

  -- ---------------------------------------------------------------- 14. the board
  perform pg_temp.v895_user(o1);
  v_board := public.get_service_mapping_board_v1(b1);
  perform pg_temp.v895_system();

  if (v_board#>>'{suggestions,confident}')::int = 0
     and (v_board#>>'{suggestions,possible}')::int = 1 then
    insert into v895_out values (14,'the board counts only UNMAPPED services: 0 confident, 1 possible','PASS');
  else
    insert into v895_out values (14,'the board counts only UNMAPPED services: 0 confident, 1 possible',
      'FAIL - '||coalesce((v_board->'suggestions')::text,'null'));
  end if;

  select x into v_row from jsonb_array_elements(v_board->'services') x where x->>'service_id' = s4::text;
  if v_row->>'suggested_reason' = 'cross_pack'
     and (v_row->>'suggested_confident')::boolean is false
     and v_row->>'suggested_keyword' = 'tea'
     and v_row->>'suggested_node_key' = 'beverages.coffee_tea'
     and v_row->>'mapped_method' is null then
    insert into v895_out values (15,'each board row carries suggested_confident / suggested_keyword / suggested_reason','PASS');
  else
    insert into v895_out values (15,'each board row carries suggested_confident / suggested_keyword / suggested_reason',
      'FAIL - '||coalesce(v_row::text,'row missing'));
  end if;

  select x into v_row from jsonb_array_elements(v_board->'services') x where x->>'service_id' = s1::text;
  if v_row->>'mapped_method' = 'auto_keyword' and v_row->>'mapped_at' is not null
     and v_row->>'node_key' = 'massage_body' and v_row->>'method' = 'auto_keyword' then
    insert into v895_out values (16,'a mapped board row states mapped_method and mapped_at, and v648''s own keys are unchanged','PASS');
  else
    insert into v895_out values (16,'a mapped board row states mapped_method and mapped_at, and v648''s own keys are unchanged',
      'FAIL - '||coalesce(v_row::text,'row missing'));
  end if;

  -- ---------------------------------------------------------------- 17. accept-all, confident only
  perform pg_temp.v895_user(o1);
  v_j := public.accept_service_mapping_suggestions_v1(b1, true);
  perform pg_temp.v895_system();
  if (v_j->>'mapped')::int = 0 and (v_j->>'skipped_no_suggestion')::int = 1
     and (v_j->>'skipped_not_confident')::int = 1
     and jsonb_array_length(v_j->'rows') = 0 then
    insert into v895_out values (17,'accept-all with p_only_confident := true maps nothing here and says why for each skip','PASS');
  else
    insert into v895_out values (17,'accept-all with p_only_confident := true maps nothing here and says why for each skip',
      'FAIL - '||coalesce(v_j::text,'null'));
  end if;

  -- ---------------------------------------------------------------- 18. accept-all, everything suggested
  perform pg_temp.v895_user(o1);
  v_j := public.accept_service_mapping_suggestions_v1(b1);
  perform pg_temp.v895_system();
  if (v_j->>'mapped')::int = 1 and (v_j->>'skipped_no_suggestion')::int = 1
     and (v_j->>'skipped_not_confident')::int = 0
     and jsonb_array_length(v_j->'rows') = 1
     and (v_j#>>'{rows,0,node_key}') = 'beverages.coffee_tea'
     and (v_j#>>'{rows,0,name}') = 'Herbal tea (add-on)'
     and (v_j#>>'{rows,0,confident}')::boolean is false
     and (select method||'/'||coalesce(mapped_by::text,'null') from public.service_canonical_map
           where business_id=b1 and service_id=s4) = 'accepted_suggestions/'||o1::text then
    insert into v895_out values (18,'accept-all takes the non-confident suggestion too, as accepted_suggestions by the caller','PASS');
  else
    insert into v895_out values (18,'accept-all takes the non-confident suggestion too, as accepted_suggestions by the caller',
      'FAIL - '||coalesce(v_j::text,'null'));
  end if;

  perform pg_temp.v895_user(o1);
  v_j := public.accept_service_mapping_suggestions_v1(b1);
  perform pg_temp.v895_system();
  if (v_j->>'mapped')::int = 0 and (v_j->>'skipped_no_suggestion')::int = 1 then
    insert into v895_out values (19,'accept-all is idempotent: a second tap maps nothing more','PASS');
  else
    insert into v895_out values (19,'accept-all is idempotent: a second tap maps nothing more','FAIL - '||coalesce(v_j::text,'null'));
  end if;

  if (select node_key||'/'||method from public.service_canonical_map where business_id=b1 and service_id=s6)
     = 'nails.pedicure/owner_chosen' then
    insert into v895_out values (20,'accept-all never overwrites an existing mapping','PASS');
  else
    insert into v895_out values (20,'accept-all never overwrites an existing mapping',
      'FAIL - '||coalesce((select node_key||'/'||method from public.service_canonical_map where business_id=b1 and service_id=s6),'gone'));
  end if;

  -- ---------------------------------------------------------------- 21. the tenant boundary
  perform pg_temp.v895_user(o2);
  if app.is_salon_member(b2) and app.can_module_write(b2,'services') then
    insert into v895_out values (21,'B2''s owner genuinely holds services write on their OWN business (so the refusal below is earned)','PASS');
  else
    insert into v895_out values (21,'B2''s owner genuinely holds services write on their OWN business (so the refusal below is earned)',
      'FAIL - the refusal in step 22 would prove nothing');
  end if;
  v_err := null;
  begin
    perform public.accept_service_mapping_suggestions_v1(b1);
  exception when others then v_err := sqlstate;
  end;
  perform pg_temp.v895_system();
  if v_err = '42501' then
    insert into v895_out values (22,'accept-all from another business is refused with 42501','PASS');
  else
    insert into v895_out values (22,'accept-all from another business is refused with 42501','FAIL - sqlstate '||coalesce(v_err,'none'));
  end if;

  -- ---------------------------------------------------------------- 23. the backfill
  delete from public.service_canonical_map
   where business_id in (b1,b2) and service_id <> s6;
  v_n := app.service_automap_backfill_v895();
  if v_n = 4 then
    insert into v895_out values (23,'the backfill maps exactly the four CONFIDENT unmapped services (S1,S2,S3,S7)','PASS');
  else
    insert into v895_out values (23,'the backfill maps exactly the four CONFIDENT unmapped services (S1,S2,S3,S7)',
      format('FAIL - returned %s, expected 4', v_n));
  end if;

  if (select count(*) from public.service_canonical_map
       where business_id in (b1,b2) and method='auto_keyword_backfill' and mapped_by is null) = 4
     and not exists (select 1 from public.service_canonical_map where business_id=b1 and service_id in (s4,s5))
     and not exists (select 1 from public.service_canonical_map where business_id=b2 and service_id=s8) then
    insert into v895_out values (24,'the backfilled rows are auto_keyword_backfill with no human attributed, and the unconfident ones stay unmapped','PASS');
  else
    insert into v895_out values (24,'the backfilled rows are auto_keyword_backfill with no human attributed, and the unconfident ones stay unmapped',
      format('FAIL - %s rows', (select count(*) from public.service_canonical_map
             where business_id in (b1,b2) and method='auto_keyword_backfill')));
  end if;

  if (select node_key||'/'||method from public.service_canonical_map where business_id=b1 and service_id=s6)
     = 'nails.pedicure/owner_chosen' then
    insert into v895_out values (25,'the backfill never overwrites an existing mapping','PASS');
  else
    insert into v895_out values (25,'the backfill never overwrites an existing mapping',
      'FAIL - '||coalesce((select node_key||'/'||method from public.service_canonical_map where business_id=b1 and service_id=s6),'gone'));
  end if;

  v_n := app.service_automap_backfill_v895();
  if v_n = 0 then
    insert into v895_out values (26,'the backfill is idempotent: a second run writes nothing','PASS');
  else
    insert into v895_out values (26,'the backfill is idempotent: a second run writes nothing', format('FAIL - returned %s', v_n));
  end if;

  -- ---------------------------------------------------------------- 27. history
  if (select count(distinct method) from public.service_canonical_map_history
       where business_id in (b1,b2) and change_kind='set'
         and method in ('auto_keyword','accepted_suggestions','auto_keyword_backfill')) = 3 then
    insert into v895_out values (27,'the append-only history records all three new provenances','PASS');
  else
    insert into v895_out values (27,'the append-only history records all three new provenances',
      'FAIL - '||coalesce((select string_agg(distinct method,',') from public.service_canonical_map_history
                            where business_id in (b1,b2) and change_kind='set'),'none'));
  end if;

  -- ---------------------------------------------------------------- 28. the v686 knock-on
  if exists (select 1 from public.service_canonical_map
              where business_id=b1 and service_id=s3 and method='auto_keyword_backfill') then
    insert into v895_out values (28,'S3''s only reference is an automatic mapping (so step 29 is about that, not about an unmapped service)','PASS');
  else
    insert into v895_out values (28,'S3''s only reference is an automatic mapping (so step 29 is about that, not about an unmapped service)',
      'FAIL - S3 carries no automatic mapping');
  end if;

  perform pg_temp.v895_user(o1);
  v_res := public.business_manage_catalogue_item_v660(b1,'service',s3,'delete');
  perform pg_temp.v895_system();
  if (v_res->>'action') = 'delete' and (v_res->>'used_by') = '0'
     and not exists (select 1 from public.services where id=s3)
     and not exists (select 1 from public.service_canonical_map where business_id=b1 and service_id=s3) then
    insert into v895_out values (29,'an automatic mapping does NOT make a service undeletable; the hard delete takes the mapping with it','PASS');
  else
    insert into v895_out values (29,'an automatic mapping does NOT make a service undeletable; the hard delete takes the mapping with it',
      'FAIL - '||coalesce(v_res::text,'null'));
  end if;

  perform pg_temp.v895_user(o1);
  v_res := public.business_manage_catalogue_item_v660(b1,'service',s6,'delete');
  perform pg_temp.v895_system();
  if (v_res->>'action') = 'retire' and (v_res->>'used_by')::int >= 1
     and exists (select 1 from public.services where id=s6 and active=false)
     and exists (select 1 from public.service_canonical_map where business_id=b1 and service_id=s6) then
    insert into v895_out values (30,'a mapping the OWNER made still counts as usage: the service retires and the mapping survives','PASS');
  else
    insert into v895_out values (30,'a mapping the OWNER made still counts as usage: the service retires and the mapping survives',
      'FAIL - '||coalesce(v_res::text,'null'));
  end if;

  -- ---------------------------------------------------------------- 31. the keyword list itself
  select count(*) into v_n from public.taxonomy_keywords;
  if v_n >= 400 then
    insert into v895_out values (31,'the curated keyword list is materially wider than v647''s 112 rows','PASS');
  else
    insert into v895_out values (31,'the curated keyword list is materially wider than v647''s 112 rows', format('FAIL - %s rows', v_n));
  end if;

  if not exists (
        select 1 from public.taxonomy_nodes n where n.version_no=1
         and (select count(*) from public.taxonomy_keywords k where k.node_key=n.node_key)
             < case n.level when 3 then 6 else 4 end) then
    insert into v895_out values (32,'every level-2 node has >=4 keywords and every level-3 node >=6','PASS');
  else
    insert into v895_out values (32,'every level-2 node has >=4 keywords and every level-3 node >=6',
      'FAIL - '||(select string_agg(n.node_key,', ') from public.taxonomy_nodes n where n.version_no=1
                   and (select count(*) from public.taxonomy_keywords k where k.node_key=n.node_key)
                       < case n.level when 3 then 6 else 4 end));
  end if;

  -- The categories themselves are still frozen.
  v_err := null;
  begin
    update public.taxonomy_nodes set label='tampered' where version_no=1 and node_key='facial';
  exception when others then v_err := sqlstate;
  end;
  if v_err = '42501' then
    insert into v895_out values (33,'taxonomy_nodes is still immutable — v895 widened keywords only','PASS');
  else
    insert into v895_out values (33,'taxonomy_nodes is still immutable — v895 widened keywords only','FAIL - sqlstate '||coalesce(v_err,'none'));
  end if;
end
$v895$;

select seq, step, outcome from v895_out order by seq;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.seq, f.step), E'\n  ' order by f.seq)
    into n, d from v895_out f where f.outcome like 'FAIL%';
  if n > 0 then raise exception 'v895: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

rollback;
