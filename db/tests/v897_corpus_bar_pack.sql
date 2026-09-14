-- EXECUTED acceptance fixture for nestly_v897
-- (db/migrations/20261007_nestly_v897_bar_pack.sql).
--
-- Run: LC_ALL=C node scripts/db-tests/run.mjs --filter=v897 --migrated-only
--
-- WHAT IS BEING PROVED. nestly_v895 only ever auto-applies a mapping that lands in the
-- business's OWN pack, so a business whose industry resolves to 'generic' can match a dozen
-- beverage keywords and be told 'cross_pack' every time. That is what happened to the estate's
-- two live bars: app.business_pack_v648 knew fnb/salon/facial/massage and nothing else, so
-- 'bar' fell through. v897 adds the one branch, six draught-beer words, and re-drives v895's
-- backfill.
--
-- PREDETERMINED TRUTH TABLE (written before the first run; exact equality throughout).
--
--   app.business_pack_v648 by industry, after v897:
--     fnb -> fnb | bar -> fnb | salon -> hair_salon | facial -> beauty_wellness
--     massage -> beauty_wellness | fitness -> generic | retail -> generic | other -> generic
--     (a business id that does not exist -> generic, unchanged)
--
--   Business BAR, industry 'bar':
--     S1 'Tiger draught'   -> beverages.alcohol   kw 'draught'   own_pack_unique  CONFIDENT
--                             the headline: BEFORE v897 this same name resolved cross_pack,
--                             because beverages.alcohol is in the fnb pack and a bar was generic.
--     S2 'Massage'         -> massage_body.full_body_massage  kw 'massage'  cross_pack  not confident
--                             the guard still holds in the other direction: a bar that lists a
--                             massage is NOT auto-classified as a spa.
--
--   Trigger: S1 mapped (method auto_keyword), S2 left unmapped.
--   Backfill: clear S1's row, then app.service_automap_backfill_v895() -> exactly 1
--             (the estate is drained at the top of this fixture so the count is this tenant's),
--             the row carries method auto_keyword_backfill and mapped_by null, S2 stays unmapped,
--             and a second call returns 0.
--   An owner's own mapping is never overwritten by the re-drive.
--   The six bar keywords are on beverages.alcohol and 'ale' is deliberately NOT among them.
--
-- Any row in v897_out whose outcome starts with FAIL is a failure; the block at the end raises.

begin;

create temp table v897_out(seq integer, step text, outcome text) on commit drop;
grant insert, select on v897_out to public;
create temp table v897_biz(industry text, ord integer, id uuid) on commit drop;
grant insert, select on v897_biz to public;

create or replace function pg_temp.v897_system() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','',true);
end
$$;
grant execute on function pg_temp.v897_system() to public;

create or replace function pg_temp.v897_system_as(p_uid uuid) returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub',coalesce(p_uid::text,''),true);
  perform set_config('request.jwt.claims',
    json_build_object('sub',p_uid,'role','authenticated')::text,true);
end
$$;
grant execute on function pg_temp.v897_system_as(uuid) to public;

-- Industry in, business out: one throwaway tenant per industry so the resolver is asked the
-- question the product asks it, rather than being read out of pg_get_functiondef.
create or replace function pg_temp.v897_business(p_industry text) returns uuid
language plpgsql as $$
declare v_id uuid := gen_random_uuid();
begin
  perform set_config('app.v79_system_transition','on',true);
  insert into public.businesses(id,name,slug,industry,currency,enabled_modules)
  values (v_id,'V897 '||p_industry,'v897-'||p_industry||'-'||substr(v_id::text,1,8),
          p_industry,'SGD',array['dashboard','clients','sales','services']);
  perform set_config('app.v79_system_transition','',true);
  return v_id;
end
$$;
grant execute on function pg_temp.v897_business(text) to public;

do $v897$
declare
  bar_biz uuid; own uuid := gen_random_uuid();
  s1 uuid := gen_random_uuid(); s2 uuid := gen_random_uuid(); s3 uuid := gen_random_uuid();
  v_j jsonb; v_n integer; v_got text; r record;
begin
  perform pg_temp.v897_system();

  -- Drain the estate so the backfill count asserted in step 6 is this fixture's own row.
  perform app.service_automap_backfill_v895();

  -- ---------------------------------------------------------------- 1. the resolver, industry by industry
  /* The tenants are created in their OWN statements before anything resolves them:
     app.business_pack_v648 is STABLE, so inside a single statement it reads that statement's
     snapshot and cannot see a row a volatile helper inserted alongside it — every industry
     would fall through to the 'other' default and answer 'generic'. That is a fixture trap,
     not a product defect, and it is exactly the trap this comment exists to stop recurring. */
  for r in select * from (values ('fnb',1),('bar',2),('salon',3),('facial',4),
                                 ('massage',5),('fitness',6),('retail',7),('other',8))
                         i(industry,ord) order by i.ord
  loop
    insert into v897_biz(industry, ord, id) values (r.industry, r.ord, pg_temp.v897_business(r.industry));
  end loop;

  select string_agg(b.industry||'='||app.business_pack_v648(b.id), ' ' order by b.ord)
    into v_got from v897_biz b;
  if v_got = 'fnb=fnb bar=fnb salon=hair_salon facial=beauty_wellness '
           ||'massage=beauty_wellness fitness=generic retail=generic other=generic' then
    insert into v897_out values (1,'every one of the app''s eight industries resolves as ruled: bar is fnb, fitness/retail/other stay generic','PASS');
  else
    insert into v897_out values (1,'every one of the app''s eight industries resolves as ruled: bar is fnb, fitness/retail/other stay generic',
      'FAIL - '||v_got);
  end if;

  if app.business_pack_v648(gen_random_uuid()) = 'generic' then
    insert into v897_out values (2,'an unknown business still resolves to generic (the v648 fall-through is intact)','PASS');
  else
    insert into v897_out values (2,'an unknown business still resolves to generic (the v648 fall-through is intact)',
      'FAIL - '||app.business_pack_v648(gen_random_uuid()));
  end if;

  -- ---------------------------------------------------------------- 3. a real bar tenant
  bar_biz := pg_temp.v897_business('bar');
  if app.business_pack_v648(bar_biz) <> 'fnb' then
    insert into v897_out values (3,'the fixture bar genuinely resolves to the fnb pack (so steps 4-8 are about v897, not about a mis-set industry)',
      'FAIL - '||app.business_pack_v648(bar_biz));
  else
    insert into v897_out values (3,'the fixture bar genuinely resolves to the fnb pack (so steps 4-8 are about v897, not about a mis-set industry)','PASS');
  end if;

  perform pg_temp.v897_system_as(own);
  insert into public.services(id,business_id,name,price_cents,duration_min) values
    (s1,bar_biz,'Tiger draught',  1200,1),
    (s2,bar_biz,'Massage',        6000,60),
    (s3,bar_biz,'House Wine Glass',1500,1);
  perform pg_temp.v897_system();

  v_j := app.suggest_canonical_node_v2(bar_biz,s1);
  if v_j->>'node_key' = 'beverages.alcohol' and (v_j->>'confident')::boolean
     and v_j->>'reason' = 'own_pack_unique' and v_j->>'keyword' = 'draught' then
    insert into v897_out values (4,'"Tiger draught" in a bar is a CONFIDENT beverages.alcohol on the keyword "draught"','PASS');
  else
    insert into v897_out values (4,'"Tiger draught" in a bar is a CONFIDENT beverages.alcohol on the keyword "draught"',
      'FAIL - '||coalesce(v_j::text,'null'));
  end if;

  v_j := app.suggest_canonical_node_v2(bar_biz,s2);
  if v_j->>'node_key' = 'massage_body.full_body_massage' and not (v_j->>'confident')::boolean
     and v_j->>'reason' = 'cross_pack' then
    insert into v897_out values (5,'the pack guard still holds the other way: a bar''s "Massage" is cross_pack and is never auto-applied','PASS');
  else
    insert into v897_out values (5,'the pack guard still holds the other way: a bar''s "Massage" is cross_pack and is never auto-applied',
      'FAIL - '||coalesce(v_j::text,'null'));
  end if;

  if (select node_key||'/'||method from public.service_canonical_map
       where business_id=bar_biz and service_id=s1) = 'beverages.alcohol/auto_keyword'
     and (select node_key from public.service_canonical_map
           where business_id=bar_biz and service_id=s3) = 'beverages.alcohol'
     and not exists (select 1 from public.service_canonical_map
                      where business_id=bar_biz and service_id=s2) then
    insert into v897_out values (6,'creating the bar''s drinks maps them at once; the cross-pack "Massage" is left for the owner','PASS');
  else
    insert into v897_out values (6,'creating the bar''s drinks maps them at once; the cross-pack "Massage" is left for the owner',
      'FAIL - '||coalesce((select string_agg(service_id::text||':'||node_key||'/'||method,' ')
                             from public.service_canonical_map where business_id=bar_biz),'none'));
  end if;

  -- ---------------------------------------------------------------- 7. the re-driven backfill
  delete from public.service_canonical_map where business_id=bar_biz and service_id in (s1,s3);
  insert into public.service_canonical_map(business_id,service_id,node_key,version_no,method,mapped_by)
  values (bar_biz,s2,'set_experience',1,'owner_chosen',own);

  v_n := app.service_automap_backfill_v895();
  if v_n = 2 then
    insert into v897_out values (7,'the re-driven v895 backfill picks up exactly the two confident bar drinks','PASS');
  else
    insert into v897_out values (7,'the re-driven v895 backfill picks up exactly the two confident bar drinks',
      format('FAIL - returned %s, expected 2', v_n));
  end if;

  if (select count(*) from public.service_canonical_map
       where business_id=bar_biz and service_id in (s1,s3)
         and node_key='beverages.alcohol' and method='auto_keyword_backfill' and mapped_by is null) = 2
     and (select node_key||'/'||method from public.service_canonical_map
           where business_id=bar_biz and service_id=s2) = 'set_experience/owner_chosen' then
    insert into v897_out values (8,'they carry auto_keyword_backfill with nobody attributed, and the owner''s own (deliberately odd) mapping is untouched','PASS');
  else
    insert into v897_out values (8,'they carry auto_keyword_backfill with nobody attributed, and the owner''s own (deliberately odd) mapping is untouched',
      'FAIL - '||coalesce((select string_agg(service_id::text||':'||node_key||'/'||method,' ')
                             from public.service_canonical_map where business_id=bar_biz),'none'));
  end if;

  v_n := app.service_automap_backfill_v895();
  if v_n = 0 then
    insert into v897_out values (9,'the re-drive is idempotent: running it again writes nothing','PASS');
  else
    insert into v897_out values (9,'the re-drive is idempotent: running it again writes nothing', format('FAIL - returned %s', v_n));
  end if;

  -- ---------------------------------------------------------------- 10. the bar vocabulary
  if (select count(*) from public.taxonomy_keywords
       where node_key='beverages.alcohol'
         and keyword in ('draught','draught beer','pint','lager','stout','bottle beer')) = 6
     and not exists (select 1 from public.taxonomy_keywords where keyword = 'ale') then
    insert into v897_out values (10,'the six bar words are on beverages.alcohol and the rejected "ale" is not anywhere','PASS');
  else
    insert into v897_out values (10,'the six bar words are on beverages.alcohol and the rejected "ale" is not anywhere',
      format('FAIL - %s of 6 present', (select count(*) from public.taxonomy_keywords
              where node_key='beverages.alcohol'
                and keyword in ('draught','draught beer','pint','lager','stout','bottle beer'))));
  end if;
end
$v897$;

select seq, step, outcome from v897_out order by seq;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.seq, f.step), E'\n  ' order by f.seq)
    into n, d from v897_out f where f.outcome like 'FAIL%';
  if n > 0 then raise exception 'v897: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

rollback;
