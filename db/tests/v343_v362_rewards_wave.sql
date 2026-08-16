-- Rollback-only acceptance for the 2026-08-16 rewards wave: v343, v345, v347, v348, v350, v353,
-- v354, v355, v359, v361, v362.
--
-- One suite covers the whole wave because the migrations are one connected change: every one of
-- them exists to move a reward setting OFF the draft/publish wizard and onto an immediate-write
-- page, and several only make sense against each other (v354 fixes drift v353 introduced; v355
-- removes a pot migration v354 would otherwise fire more often). Testing them apart would test a
-- state the product is never in.
--
-- Run against production inside this transaction; every fixture row is rolled back:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/v343_v362_rewards_wave.sql
-- Assertions are recorded as rows rather than raised, so one final SELECT reports the whole suite.
-- Any row whose outcome starts with FAIL is a failure.

begin;

create temp table _r(check_name text, outcome text) on commit drop;
create temp table _ctx(business uuid, owner_user uuid, programme uuid, client uuid) on commit drop;

insert into _ctx(business, owner_user)
select b.id, s.user_id
  from public.businesses b
  join public.staff s on s.business_id = b.id and s.role = 'owner' and s.user_id is not null
 where b.name ilike '%cubbly%'
 limit 1;

update _ctx set programme = (
  select spine.id from public.business_programmes spine
   where spine.business_id = (select business from _ctx) and spine.kind = 'points');
update _ctx set client = (
  select c.id from public.clients c where c.business_id = (select business from _ctx) limit 1);

-- ---------------------------------------------------------------------------
-- Signatures: every RPC the wave claims to ship exists exactly once.
-- ---------------------------------------------------------------------------
insert into _r
select 'signature ' || want.fn,
       case when count(p.oid) = 1 then 'PASS' else 'FAIL expected 1 overload, found ' || count(p.oid) end
  from (values
    ('business_update_reward_v326'), ('business_create_reward_v326'),
    ('business_create_tier_v331'), ('business_update_tier_v331'),
    ('business_set_tier_basis_v347'), ('set_programmes_v314'),
    ('business_set_welcome_offer_v215'), ('business_set_loyalty_model_v353'),
    ('business_set_earning_rule_v359'), ('business_upsert_bringback_v361'),
    ('business_set_bringback_paused_v361'), ('business_delete_bringback_v361'),
    ('staff_redeem_bringback_v361')
  ) as want(fn)
  left join pg_proc p on p.proname = want.fn and p.pronamespace = 'public'::regnamespace
 group by want.fn;

-- v348: the switch response carries the spine row id (a null id here is the defect that broke
-- gift saving on every toggle).
insert into _r
select 'v348 set_programmes_v314 returns spine id',
       case when position('''id'', spine.id' in pg_get_functiondef(p.oid)) > 0
            then 'PASS' else 'FAIL id key absent from the programmes payload' end
  from pg_proc p where p.proname='set_programmes_v314' and p.pronamespace='public'::regnamespace;

-- v355: neither remaining path may auto-migrate a pot on a switch.
insert into _r
select 'v355 no automatic pot migration from the switch',
       case when position('enqueue_programme_pot_migration_v312' in pg_get_functiondef(p.oid)) = 0
            then 'PASS' else 'FAIL set_programmes_v314 still enqueues a pot migration' end
  from pg_proc p where p.proname='set_programmes_v314' and p.pronamespace='public'::regnamespace;
insert into _r
select 'v355 loyalty_model pot-switch trigger dropped',
       case when count(*) = 0 then 'PASS' else 'FAIL trigger still present' end
  from pg_trigger t join pg_class c on c.oid = t.tgrelid
 where c.relname = 'loyalty_programs' and t.tgname = 'trg_programme_pot_switch_v312';

-- v361: tables, RLS and the browser-role ACL.
insert into _r
select 'v361 ' || want.t || ' has RLS',
       case when bool_or(c.relrowsecurity) then 'PASS' else 'FAIL RLS not enabled' end
  from (values ('bringback_campaigns_v361'), ('bringback_grants_v361')) as want(t)
  left join pg_class c on c.relname = want.t and c.relnamespace = 'public'::regnamespace
 group by want.t;
insert into _r
select 'v361 ' || want.t || ' is SELECT-only for authenticated',
       case when has_table_privilege('authenticated','public.'||want.t,'SELECT')
             and not has_table_privilege('authenticated','public.'||want.t,'INSERT')
             and not has_table_privilege('authenticated','public.'||want.t,'UPDATE')
             and not has_table_privilege('authenticated','public.'||want.t,'DELETE')
            then 'PASS' else 'FAIL browser role has more than SELECT' end
  from (values ('bringback_campaigns_v361'), ('bringback_grants_v361')) as want(t);

-- ---------------------------------------------------------------------------
-- Behaviour, as the real owner role.
-- ---------------------------------------------------------------------------
select set_config('request.jwt.claims',
  json_build_object('sub',(select owner_user::text from _ctx),'role','authenticated')::text, true);
set local role authenticated;

-- v343: a gift can be created with description + photo and then edited.
select public.business_create_reward_v326((select business from _ctx),(select programme from _ctx),
  'WAVE gift', 12, 0, 'wave description', null) as r \gset
insert into _r select 'v343 create carries description',
  case when exists(select 1 from public.loyalty_rewards
                    where business_id=(select business from _ctx) and name='WAVE gift'
                      and description='wave description')
       then 'PASS' else 'FAIL description not stored' end;
select public.business_update_reward_v326((select business from _ctx),
  (select id from public.loyalty_rewards where business_id=(select business from _ctx) and name='WAVE gift' limit 1),
  'WAVE gift 2', 15, 'edited', 0, null, false) as r2 \gset
insert into _r select 'v343 update rewrites name/points/description',
  case when exists(select 1 from public.loyalty_rewards
                    where business_id=(select business from _ctx) and name='WAVE gift 2'
                      and cost_points=15 and description='edited')
       then 'PASS' else 'FAIL update did not apply' end;

-- v345: tier create with benefit text, then edit it.
select public.business_create_tier_v331((select business from _ctx),'WAVE tier',777,1,'Free coffee') as t \gset
insert into _r select 'v345 tier create stores perk_note',
  case when exists(select 1 from public.loyalty_tiers
                    where business_id=(select business from _ctx) and name='WAVE tier' and perk_note='Free coffee')
       then 'PASS' else 'FAIL perk_note not stored' end;
select public.business_update_tier_v331((select business from _ctx),
  (select id from public.loyalty_tiers where business_id=(select business from _ctx) and name='WAVE tier' limit 1),
  'WAVE tier 2', 888, '10% off', 1) as t2 \gset
insert into _r select 'v345 tier update rewrites name/threshold/benefit',
  case when exists(select 1 from public.loyalty_tiers
                    where business_id=(select business from _ctx) and name='WAVE tier 2'
                      and threshold=888 and perk_note='10% off')
       then 'PASS' else 'FAIL tier update did not apply' end;

-- v347: tier basis is writable without the wizard.
select public.business_set_tier_basis_v347((select business from _ctx),'visits') as b \gset
insert into _r select 'v347 tier_basis writes immediately',
  case when (select tier_basis from public.loyalty_programs where business_id=(select business from _ctx))='visits'
       then 'PASS' else 'FAIL tier_basis unchanged' end;

-- v359: the earning rule writes immediately, and a partial call leaves other columns alone.
select public.business_set_earning_rule_v359((select business from _ctx), 7, null, null, null) as e1 \gset
select public.business_set_earning_rule_v359((select business from _ctx), null, 250, 'fixed', 365) as e2 \gset
insert into _r select 'v359 partial update never resets the points rate',
  case when (select earn_points_per_dollar from public.loyalty_programs where business_id=(select business from _ctx))=7
        and (select stamp_per_cents        from public.loyalty_programs where business_id=(select business from _ctx))=250
        and (select expiry_mode            from public.loyalty_programs where business_id=(select business from _ctx))='fixed'
       then 'PASS' else 'FAIL a partial call clobbered another column' end;

-- v350: a welcome offer may name a free-text item with no catalogue row behind it.
select public.business_set_welcome_offer_v215((select business from _ctx), true, 0, 'custom', null, null, 'WAVE thank-you card') as w \gset
insert into _r select 'v350 welcome offer accepts a custom item',
  case when exists(select 1 from public.business_welcome_offers_v215
                    where business_id=(select business from _ctx)
                      and reward_catalog_kind='custom' and reward_catalog_id is null
                      and reward_label='WAVE thank-you card')
       then 'PASS' else 'FAIL custom welcome item not stored' end;

-- v361: a campaign, and issuing exactly once per absence.
select public.business_upsert_bringback_v361((select business from _ctx), null,'WAVE campaign','Free coffee',1,30) as c \gset
reset role;
select app.issue_bringback_for_business_v361((select business from _ctx)) as first_run \gset
select app.issue_bringback_for_business_v361((select business from _ctx)) as second_run \gset
insert into _r select 'v361 issues to lapsed customers then stops',
  case when (:'first_run')::int > 0 and (:'second_run')::int = 0
       then 'PASS' else 'FAIL first=' || :'first_run' || ' second=' || :'second_run' end;
insert into _r select 'v361 issuing records no sale',
  case when not exists(select 1 from public.sales
                        where business_id=(select business from _ctx) and note like 'bring-back voucher%')
       then 'PASS' else 'FAIL issuing wrote a sale row' end;

-- v353/v354: the spine owns loyalty_model. Switching to stamps and back must carry the column with
-- it, and must NOT move a pot (v355).
select coalesce(sum(pl.points),0) as points_pot_before
  from public.points_ledger pl
  join public.business_programmes sp on sp.id = pl.programme_id and sp.kind='points'
 where pl.business_id=(select business from _ctx) \gset
select set_config('request.jwt.claims',
  json_build_object('sub',(select owner_user::text from _ctx),'role','authenticated')::text, true);
set local role authenticated;
select public.set_programmes_v314((select business from _ctx),
  '{"stamps":true,"points":false,"tiers":false}'::jsonb, gen_random_uuid()) as s1 \gset
reset role;
insert into _r select 'v354 switching to stamps carries loyalty_model/kind',
  case when (select loyalty_model from public.loyalty_programs where business_id=(select business from _ctx))='stamps'
        and (select kind          from public.loyalty_programs where business_id=(select business from _ctx))='stamps'
       then 'PASS' else 'FAIL declared model did not follow the spine' end;
insert into _r select 'v355 the switch left the points pot where it was earned',
  case when (select coalesce(sum(pl.points),0)
               from public.points_ledger pl
               join public.business_programmes sp on sp.id=pl.programme_id and sp.kind='points'
              where pl.business_id=(select business from _ctx)) = (:'points_pot_before')::bigint
       then 'PASS' else 'FAIL the points pot moved on a programme switch' end;

-- v362: a held voucher reaches the till's own entitlements read.
insert into _r select 'v362 entitlements expose a held bring-back voucher',
  case when position('bringback_grants_v361' in pg_get_functiondef(p.oid)) > 0
       then 'PASS' else 'FAIL entitlements never read bringback grants' end
  from pg_proc p
 where p.proname='staff_get_customer_entitlements_v102' and p.pronamespace='public'::regnamespace;

select check_name, outcome from _r order by check_name;

rollback;
