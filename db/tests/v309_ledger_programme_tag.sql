-- Rollback-only v309 acceptance: the W3 programme TAG on the two points money tables.
--
-- v309 adds a nullable programme_id to public.points_ledger and public.points_batches, points it
-- at the W2 spine, backfills every existing row through the v26 sanctioned append-only escape,
-- and tags all new traffic with a BEFORE INSERT trigger that resolves the programme from the
-- BUSINESS. Nothing reads the tag yet. So the things worth proving are: the tag lands, it lands
-- on the RIGHT programme for both model shapes, it never overwrites an explicit value, the
-- pre-W5 anti-double-earn world is exactly as it was, the backfill is complete and tenant-clean,
-- the money guards this migration temporarily disabled are enforcing again, and the W2 spine sync
-- and this tag do not interact. Nine jobs.
--
--   1. POINTS FIRM (step 1). A sale-earned ledger row inserted WITHOUT programme_id, through the
--      real v20 write-guard route ('sale_trigger'), arrives carrying the POINTS spine row id —
--      and so does its points_batches row. This is the shape app.on_sale_recorded writes
--      (v37b:653-661); the wave deliberately does not touch that function, so the fixture
--      reproduces its INSERT rather than calling it (the sale is written earns_points=false /
--      counts_as_visit=false with policy_resolved_at pinned, the v106/v300 house idiom, so the
--      live earn trigger early-returns and the manual row owns the sale).
--
--   2. STAMPS FIRM (step 2). The same two inserts at a loyalty_model='stamps' tenant land on the
--      STAMPS spine row. Stamps are stored as points in this ledger (v24 design note); before
--      this wave nothing in the row said which of the two it was.
--
--   3. AN EXPLICIT VALUE IS NEVER OVERRIDDEN (step 3). The trigger fills a NULL and does nothing
--      else. This is load-bearing for W5, whose earn loop supplies programme_id once per accruing
--      programme per sale — a trigger that recomputed the single-pot answer would silently
--      collapse that loop back onto one programme.
--
--   4. THE PRE-W5 WORLD IS PINNED (step 4). Both indexes exist, unique and valid. Then the
--      assertion that will be DELIBERATELY FLIPPED at W5: a second earn row for the same sale but
--      a DIFFERENT programme — which the new `unique (sale_id, programme_id)` index would happily
--      accept — is still REFUSED, by the v2 points_earn_once_per_sale index on sale_id alone
--      (v2:70-71). That index is untouched here and is dropped in W5's single-transaction swap.
--      When this step goes red, it should be because W5 landed, and the step is rewritten with it.
--
--   5. BACKFILL PARITY ON REAL TENANTS (step 5). The same three predicates the migration asserts
--      — zero untagged rows, zero cross-tenant or dangling tags, zero disagreements with the
--      resolver — recomputed as SELECTable PASS/FAIL rows over the PRODUCTION rows only. The two
--      fixture businesses are excluded by id, because step 3 deliberately plants a row whose tag
--      is not the resolver's answer; including it would make this step assert the opposite of
--      step 3.
--
--   6. THE STANDING DETECTOR IS EMPTY (step 6), over the whole database, fixtures included.
--
--   7. THE MONEY GUARDS STILL BITE (step 7). §5 of the migration disables
--      trg_points_ledger_append_only for exactly one UPDATE. This step proves, on a TAGGED row,
--      that UPDATE and DELETE both raise again — and that the BEFORE INSERT write guard, which
--      now fires AFTER the tag trigger in name order, still refuses an untokened insert. The
--      migration asserts the same three things about its own transaction; this suite asserts them
--      about the committed database.
--
--   8. ACL FLOOR (step 8). Neither browser role may execute the resolver, the trigger function or
--      the detector; service_role may execute the two callable ones. The trigger function needs no
--      grant at all — PostgreSQL does not check EXECUTE when firing a trigger.
--
--   9. W2 AND W3 DO NOT INTERACT (step 9). Flipping a business from classic to stamps moves what
--      NEW rows are tagged with (the resolver follows the model, and the v308 sync moves the spine
--      flags) but does NOT retag a single existing row. History is immutable — it is an
--      append-only ledger, and the tag is provenance, not a live pointer.
--
-- Fixture note: the wizard writes loyalty_programs.kind='points' even for the stamps model, so
-- both fixtures keep kind='points' and move loyalty_model alone — the production shape, inherited
-- from db/tests/v307_programme_read_model.sql and db/tests/v308_programme_spine.sql.
--
-- Run against production inside this transaction; every fixture row is rolled back:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/v309_ledger_programme_tag.sql
-- Assertions are recorded as rows rather than raised, so one final SELECT reports the whole suite.
-- Any row whose outcome starts with FAIL is a failure.

begin;

create temp table v309_out(seq integer, step text, outcome text) on commit drop;

-- Tenant-context calls need a real JWT; privileged seeding needs NO JWT, because several write
-- guards (branch enforcement, link insertion) bypass only when no claims are in scope.
create or replace function pg_temp.as_v309_user(
  p_uid uuid,
  p_role text default 'authenticated'
) returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','{}',true);
  execute format('set local role %I',p_role);
  perform set_config('request.jwt.claim.sub',coalesce(p_uid::text,''),true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub',p_uid,'role',p_role)::text,
    true
  );
end
$$;
grant execute on function pg_temp.as_v309_user(uuid,text) to public;

create or replace function pg_temp.as_v309_system() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','',true);
end
$$;
grant execute on function pg_temp.as_v309_system() to public;

-- One earn row, written exactly the way app.on_sale_recorded writes one (v37b:653-661): the v20
-- write-guard token pair, entry_type='earn', positive points, a sale_id. p_programme is normally
-- NULL — the whole point is that the trigger fills it — and is passed non-null only by step 3.
create or replace function pg_temp.v309_earn(
  p_business uuid, p_client uuid, p_sale uuid, p_points integer,
  p_programme uuid default null
) returns uuid language plpgsql as $$
declare v_id uuid := gen_random_uuid();
begin
  perform set_config('app.points_ledger_insert_id', v_id::text, true);
  perform set_config('app.points_ledger_write_scope', 'sale_trigger', true);
  insert into public.points_ledger(
    id, business_id, client_id, entry_type, points, sale_id, reference, actor, programme_id
  ) values (
    v_id, p_business, p_client, 'earn', p_points, p_sale, 'v309 fixture earn', null, p_programme
  );
  perform set_config('app.points_ledger_insert_id', '', true);
  perform set_config('app.points_ledger_write_scope', '', true);
  return v_id;
end
$$;
grant execute on function pg_temp.v309_earn(uuid,uuid,uuid,integer,uuid) to public;

create or replace function pg_temp.v309_spine(p_business uuid, p_kind text) returns uuid
language sql stable as $$
  select spine.id from public.business_programmes spine
   where spine.business_id = p_business and spine.kind = p_kind
$$;
grant execute on function pg_temp.v309_spine(uuid,text) to public;

do $v309_test$
declare
  v_owner uuid := gen_random_uuid();
  v_points_biz uuid := gen_random_uuid();
  v_stamps_biz uuid := gen_random_uuid();
  v_points_client uuid := gen_random_uuid();
  v_stamps_client uuid := gen_random_uuid();
  v_points_slug text := 'v309-points-'||substr(gen_random_uuid()::text,1,8);
  v_stamps_slug text := 'v309-stamps-'||substr(gen_random_uuid()::text,1,8);
  v_sale uuid;
  v_sale_b uuid;
  v_sale_c uuid;
  v_sale_d uuid;
  v_earn uuid;
  v_earn_stamps uuid;
  v_earn_explicit uuid;
  v_batch_programme uuid;
  v_tag uuid;
  v_tag_after uuid;
  v_points_spine uuid;
  v_tiers_spine uuid;
  v_stamps_spine uuid;
  v_flip_points_spine uuid;
  v_flip_stamps_spine uuid;
  v_msg text;
  v_nulls bigint;
  v_cross bigint;
  v_disagree bigint;
  v_detected bigint;
  v_old_index bigint;
  v_new_index bigint;
begin
  perform pg_temp.as_v309_system();

  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                         email_confirmed_at,created_at,updated_at) values
    ('00000000-0000-0000-0000-000000000000',v_owner,'authenticated','authenticated',
     'v309-owner-'||substr(v_owner::text,1,8)||'@example.test','',now(),now(),now());

  -- Two tenants, created through the v79 system-transition path the other suites use; the
  -- workspace decision is UPDATEd the way platform review would rather than inserted.
  perform set_config('app.v79_system_transition','on',true);
  insert into public.businesses(id,name,slug,industry,currency,enabled_modules,points_mode) values
    (v_points_biz,'V309 points fixture',v_points_slug,'retail','SGD',
     array['dashboard','clients','sales','loyalty'],'redeem'),
    (v_stamps_biz,'V309 stamps fixture',v_stamps_slug,'cafe','SGD',
     array['dashboard','clients','sales','loyalty'],'redeem');
  perform set_config('app.v79_system_transition','',true);

  update public.business_workspace_controls_v94
     set approval_status='approved',decided_by=v_owner,decided_at=now(),
         decision_reason='v309 rollback fixture'
   where business_id in (v_points_biz,v_stamps_biz);
  insert into public.business_subscription_lifecycle_v94(business_id)
  values(v_points_biz),(v_stamps_biz)
  on conflict (business_id) do nothing;
  update public.business_subscription_lifecycle_v94
     set workspace_paused=false
   where business_id in (v_points_biz,v_stamps_biz);

  insert into public.staff(business_id,user_id,role,full_name,active) values
    (v_points_biz,v_owner,'owner','V309 Owner',true),
    (v_stamps_biz,v_owner,'owner','V309 Owner',true);

  insert into public.loyalty_programs(
    business_id,kind,active,loyalty_model,configuration_status,
    redeem_points,reward_credit_cents
  ) values(v_points_biz,'points',true,'classic','published',100,500);
  insert into public.loyalty_programs(
    business_id,kind,active,loyalty_model,configuration_status,
    stamp_target,stamp_per_cents
  ) values(v_stamps_biz,'points',true,'stamps','published',10,1000);

  insert into public.clients(id,business_id,full_name,phone) values
    (v_points_client,v_points_biz,'V309 Points Member','+6580003091'),
    (v_stamps_client,v_stamps_biz,'V309 Stamps Member','+6580003092');

  v_points_spine := pg_temp.v309_spine(v_points_biz,'points');
  v_tiers_spine  := pg_temp.v309_spine(v_points_biz,'tiers');
  v_stamps_spine := pg_temp.v309_spine(v_stamps_biz,'stamps');

  -- ---- 1. points firm: ledger row and batch row both land on the POINTS spine row ----
  -- earns_points/counts_as_visit false with policy_resolved_at pinned (v106/v300 idiom) so the
  -- live app.on_sale_recorded early-returns and this fixture's own earn row owns the sale.
  v_sale := gen_random_uuid();
  insert into public.sales(id,business_id,client_id,kind,amount_cents,occurred_at,
                           counts_as_revenue,counts_as_visit,earns_points,policy_resolved_at,note)
  values(v_sale,v_points_biz,v_points_client,'quick_sale',5000,now(),
         true,false,false,now(),'v309 fixture');
  v_earn := pg_temp.v309_earn(v_points_biz,v_points_client,v_sale,50);

  insert into public.points_batches(business_id,client_id,earned,remaining,sale_id,earned_at)
  values(v_points_biz,v_points_client,50,50,v_sale,now())
  returning programme_id into v_batch_programme;

  select ledger.programme_id into v_tag from public.points_ledger ledger where ledger.id = v_earn;
  insert into v309_out values(1,'points_firm_row_and_batch_tagged_points',
    case when v_tag = v_points_spine and v_batch_programme = v_points_spine
      then 'PASS ledger + batch -> points spine '||v_points_spine
      else 'FAIL ledger='||coalesce(v_tag::text,'null')
             ||' batch='||coalesce(v_batch_programme::text,'null')
             ||' expected='||v_points_spine end);

  -- ---- 2. stamps firm: both land on the STAMPS spine row ----
  v_sale_b := gen_random_uuid();
  insert into public.sales(id,business_id,client_id,kind,amount_cents,occurred_at,
                           counts_as_revenue,counts_as_visit,earns_points,policy_resolved_at,note)
  values(v_sale_b,v_stamps_biz,v_stamps_client,'quick_sale',3000,now(),
         true,false,false,now(),'v309 fixture');
  v_earn_stamps := pg_temp.v309_earn(v_stamps_biz,v_stamps_client,v_sale_b,3);

  insert into public.points_batches(business_id,client_id,earned,remaining,sale_id,earned_at)
  values(v_stamps_biz,v_stamps_client,3,3,v_sale_b,now())
  returning programme_id into v_batch_programme;

  select ledger.programme_id into v_tag
    from public.points_ledger ledger where ledger.id = v_earn_stamps;
  insert into v309_out values(2,'stamps_firm_row_and_batch_tagged_stamps',
    case when v_tag = v_stamps_spine and v_batch_programme = v_stamps_spine
      then 'PASS ledger + batch -> stamps spine '||v_stamps_spine
      else 'FAIL ledger='||coalesce(v_tag::text,'null')
             ||' batch='||coalesce(v_batch_programme::text,'null')
             ||' expected='||v_stamps_spine end);

  -- ---- 3. an explicitly supplied programme_id is NOT overridden ----
  -- The tiers spine row of the SAME business: a value the single-pot resolver would never
  -- produce, so "not overridden" cannot be confused with "recomputed to the same answer".
  v_sale_c := gen_random_uuid();
  insert into public.sales(id,business_id,client_id,kind,amount_cents,occurred_at,
                           counts_as_revenue,counts_as_visit,earns_points,policy_resolved_at,note)
  values(v_sale_c,v_points_biz,v_points_client,'quick_sale',1000,now(),
         true,false,false,now(),'v309 fixture');
  v_earn_explicit := pg_temp.v309_earn(v_points_biz,v_points_client,v_sale_c,10,v_tiers_spine);
  select ledger.programme_id into v_tag
    from public.points_ledger ledger where ledger.id = v_earn_explicit;
  insert into v309_out values(3,'explicit_programme_not_overridden',
    case when v_tag = v_tiers_spine
      then 'PASS kept the supplied tiers spine '||v_tiers_spine
      else 'FAIL got '||coalesce(v_tag::text,'null')||' expected '||v_tiers_spine end);

  -- ---- 4. both indexes present; the OLD one still refuses a second earn for the same sale ----
  select count(*) into v_old_index
    from pg_index idx join pg_class cls on cls.oid = idx.indexrelid
   where cls.relname = 'points_earn_once_per_sale'
     and idx.indrelid = 'public.points_ledger'::regclass
     and idx.indisunique and idx.indisvalid and idx.indisready;
  select count(*) into v_new_index
    from pg_index idx join pg_class cls on cls.oid = idx.indexrelid
   where cls.relname = 'points_earn_once_per_sale_per_programme'
     and idx.indrelid = 'public.points_ledger'::regclass
     and idx.indisunique and idx.indisvalid and idx.indisready;

  -- A DIFFERENT programme, same sale. The v309 index would allow this pair; the v2 index must
  -- not. THIS IS THE ASSERTION W5 DELIBERATELY FLIPS, in the transaction that drops the old
  -- index and removes the v308 tripwire.
  v_msg := '';
  begin
    perform pg_temp.v309_earn(v_points_biz,v_points_client,v_sale,50,v_tiers_spine);
  exception when others then v_msg := sqlerrm;
  end;
  insert into v309_out values(4,'old_sale_id_index_still_authoritative',
    case when v_old_index = 1 and v_new_index = 1
              and v_msg like '%points_earn_once_per_sale%'
              and v_msg not like '%per_programme%'
      then 'PASS both indexes valid; the v2 sale_id index refused the second earn: '||v_msg
      else 'FAIL old='||v_old_index||' new='||v_new_index
             ||' error='||coalesce(nullif(v_msg,''),'no error at all') end);

  -- ---- 5. backfill parity on the REAL tenants (fixtures excluded — see the header) ----
  select count(*) into v_nulls
    from (
      select 1 from public.points_ledger ledger
       where ledger.programme_id is null
         and ledger.business_id not in (v_points_biz,v_stamps_biz)
      union all
      select 1 from public.points_batches batch
       where batch.programme_id is null
         and batch.business_id not in (v_points_biz,v_stamps_biz)
    ) untagged;

  select count(*) into v_cross
    from (
      select 1 from public.points_ledger ledger
       left join public.business_programmes spine on spine.id = ledger.programme_id
       where ledger.business_id not in (v_points_biz,v_stamps_biz)
         and (spine.id is null or spine.business_id <> ledger.business_id)
      union all
      select 1 from public.points_batches batch
       left join public.business_programmes spine on spine.id = batch.programme_id
       where batch.business_id not in (v_points_biz,v_stamps_biz)
         and (spine.id is null or spine.business_id <> batch.business_id)
    ) crossed;

  select count(*) into v_disagree
    from (
      select 1 from public.points_ledger ledger
       where ledger.business_id not in (v_points_biz,v_stamps_biz)
         and ledger.programme_id
             is distinct from app.resolve_ledger_programme_v309(ledger.business_id)
      union all
      select 1 from public.points_batches batch
       where batch.business_id not in (v_points_biz,v_stamps_biz)
         and batch.programme_id
             is distinct from app.resolve_ledger_programme_v309(batch.business_id)
    ) disagreeing;

  insert into v309_out values(5,'real_tenant_backfill_parity',
    case when v_nulls = 0 and v_cross = 0 and v_disagree = 0
      then 'PASS zero untagged, zero cross-tenant, zero resolver disagreements'
      else 'FAIL untagged='||v_nulls||' cross_tenant='||v_cross||' disagreements='||v_disagree end);

  -- ---- 6. the standing detector, over the WHOLE database ----
  select count(*) into v_detected from app.detect_double_earn_v309();
  insert into v309_out values(6,'detect_double_earn_empty',
    case when v_detected = 0 then 'PASS zero rows database-wide'
         else 'FAIL '||v_detected||' row(s)' end);

  -- ---- 7. the money guards still bite on a TAGGED row ----
  v_msg := '';
  begin
    update public.points_ledger set points = points + 1 where id = v_earn;
  exception when others then v_msg := sqlerrm;
  end;
  insert into v309_out values(7,'append_only_update_refused',
    case when v_msg like '%append-only%' then 'PASS '||v_msg
         else 'FAIL '||coalesce(nullif(v_msg,''),'the UPDATE succeeded') end);

  v_msg := '';
  begin
    delete from public.points_ledger where id = v_earn;
  exception when others then v_msg := sqlerrm;
  end;
  insert into v309_out values(8,'append_only_delete_refused',
    case when v_msg like '%append-only%' then 'PASS '||v_msg
         else 'FAIL '||coalesce(nullif(v_msg,''),'the DELETE succeeded') end);

  -- The write guard fires AFTER the tag trigger in name order. Prove the tag did not neuter it.
  v_msg := '';
  begin
    insert into public.points_ledger(business_id,client_id,entry_type,points,sale_id,reference)
    values(v_points_biz,v_points_client,'earn',1,null,'v309 untokened insert');
  exception when others then v_msg := sqlerrm;
  end;
  insert into v309_out values(9,'write_guard_still_refuses_untokened_insert',
    case when v_msg like '%approved loyalty routes%' then 'PASS '||v_msg
         else 'FAIL '||coalesce(nullif(v_msg,''),'the untokened INSERT succeeded') end);

  -- ---- 8. ACL floor ----
  insert into v309_out values(10,'function_acl_floor',
    case when has_function_privilege('authenticated','app.resolve_ledger_programme_v309(uuid)','execute') = false
          and has_function_privilege('anon','app.resolve_ledger_programme_v309(uuid)','execute') = false
          and has_function_privilege('service_role','app.resolve_ledger_programme_v309(uuid)','execute') = true
          and has_function_privilege('authenticated','app.tag_ledger_programme_v309()','execute') = false
          and has_function_privilege('anon','app.tag_ledger_programme_v309()','execute') = false
          and has_function_privilege('authenticated','app.detect_double_earn_v309()','execute') = false
          and has_function_privilege('anon','app.detect_double_earn_v309()','execute') = false
          and has_function_privilege('service_role','app.detect_double_earn_v309()','execute') = true
      then 'PASS resolver/tag/detector closed to anon+authenticated; resolver+detector open to service_role'
      else 'FAIL resolver auth='
             ||has_function_privilege('authenticated','app.resolve_ledger_programme_v309(uuid)','execute')::text
             ||' anon='||has_function_privilege('anon','app.resolve_ledger_programme_v309(uuid)','execute')::text
             ||' service='||has_function_privilege('service_role','app.resolve_ledger_programme_v309(uuid)','execute')::text
             ||' tag auth='||has_function_privilege('authenticated','app.tag_ledger_programme_v309()','execute')::text
             ||' detector auth='||has_function_privilege('authenticated','app.detect_double_earn_v309()','execute')::text end);

  -- ---- 9. the W2 spine sync and the W3 tag do not interact ----
  -- Flip the points fixture classic -> stamps. The v308 sync recomputes its spine flags; the
  -- resolver starts answering 'stamps' for NEW rows; nothing retags history.
  update public.loyalty_programs
     set loyalty_model='stamps', stamp_target=8, stamp_per_cents=1000
   where business_id = v_points_biz;

  v_flip_points_spine := pg_temp.v309_spine(v_points_biz,'points');
  v_flip_stamps_spine := pg_temp.v309_spine(v_points_biz,'stamps');

  select ledger.programme_id into v_tag_after
    from public.points_ledger ledger where ledger.id = v_earn;

  v_sale_d := gen_random_uuid();
  insert into public.sales(id,business_id,client_id,kind,amount_cents,occurred_at,
                           counts_as_revenue,counts_as_visit,earns_points,policy_resolved_at,note)
  values(v_sale_d,v_points_biz,v_points_client,'quick_sale',2000,now(),
         true,false,false,now(),'v309 fixture');
  v_earn := pg_temp.v309_earn(v_points_biz,v_points_client,v_sale_d,2);
  select ledger.programme_id into v_tag
    from public.points_ledger ledger where ledger.id = v_earn;

  insert into v309_out values(11,'model_flip_moves_new_rows_only',
    case when v_tag_after = v_flip_points_spine and v_tag = v_flip_stamps_spine
          and v_flip_points_spine is distinct from v_flip_stamps_spine
      then 'PASS history kept the points spine, the new row took the stamps spine'
      else 'FAIL existing='||coalesce(v_tag_after::text,'null')
             ||' (expected '||v_flip_points_spine||') new='||coalesce(v_tag::text,'null')
             ||' (expected '||v_flip_stamps_spine||')' end);

  -- ...and the spine itself moved, so the flip really happened rather than being a no-op.
  insert into v309_out values(12,'spine_followed_the_flip',
    case when (select spine.active from public.business_programmes spine
                where spine.id = v_flip_stamps_spine)
          and not (select spine.active from public.business_programmes spine
                    where spine.id = v_flip_points_spine)
      then 'PASS v308 sync: stamps active, points inactive'
      else 'FAIL points_active='
             ||(select spine.active from public.business_programmes spine
                 where spine.id = v_flip_points_spine)::text
             ||' stamps_active='
             ||(select spine.active from public.business_programmes spine
                 where spine.id = v_flip_stamps_spine)::text end);
end
$v309_test$;

reset role;

select seq, step, outcome from v309_out order by seq;

rollback;
