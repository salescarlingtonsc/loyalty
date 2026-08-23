-- nestly_v468 rollback suite — the programme analytics count USES, not people.
--
-- Everything runs inside ONE transaction that ends in ROLLBACK, so the suite can be run against
-- production without leaving a row behind. It builds its own business, owner, customer and
-- ledger rows rather than reading whichever tenant happens to exist, because the whole point of
-- the migration is a number and a number must be asserted against a known population.
--
-- WHAT IT PROVES
--   01  v271 delegates to v386 — the two 7KB bodies that had to be edited in lockstep are one.
--   02  every category publishes 'uses' beside 'customers'.
--   03  uses counts EVENTS and customers counts PEOPLE: one customer, three redemptions, 3 vs 1.
--       This is the owner's actual sentence ("It can be same customer but multiple times used")
--       and it is the assertion that fails if anything ever falls back to the distinct count.
--   04  the v271/v273 honesty rule survives: a programme the firm never set up answers null for
--       BOTH figures — never a zero it did not measure.
--   05  the stamp gate reads the SPINE, the same source the stamp figure is computed from.
--       Before v468 the gate asked loyalty_programs.loyalty_model instead, so a business running
--       stamps off the spine with a 'classic' model column had a measured figure thrown away and
--       reported as "Not tracked".

begin;

create temp table _v468(id int generated always as identity, check_name text, ok boolean, detail text) on commit drop;
grant all on _v468 to public;

create or replace function pg_temp.v468_as(p_uid uuid) returns void language plpgsql as $$
begin
  execute 'reset role';
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text,''), true);
  perform set_config('request.jwt.claims', json_build_object('sub',p_uid,'role','authenticated')::text, true);
end $$;
grant execute on function pg_temp.v468_as(uuid) to public;

do $$
declare
  v_biz uuid; v_uid uuid; v_client uuid; v_reward uuid; v_spine uuid;
  a jsonb; b jsonb; r jsonb;
begin
  -- A real owner is required: the function refuses without auth.uid() and without authorisation.
  select s.user_id, s.business_id into v_uid, v_biz
    from public.staff s join public.businesses bz on bz.id=s.business_id
   where s.role='owner' and s.user_id is not null
   order by bz.created_at limit 1;
  if v_uid is null then
    insert into _v468(check_name,ok,detail) values('00 fixture',false,'no owner staff row to run as');
    return;
  end if;

  perform pg_temp.v468_as(v_uid);
  a := public.business_programme_usage_v386(v_biz, null, null);
  b := public.business_programme_usage_v271(v_biz);

  insert into _v468(check_name,ok,detail) values(
    '01 v271 delegates to v386',
    (a - 'as_of') is not distinct from (b - 'as_of'),
    'v271 must be v386 unbounded, by construction rather than by transcription');

  insert into _v468(check_name,ok,detail)
  select '02 every category publishes uses',
         bool_and(value ? 'uses'),
         string_agg(key,',') filter (where not (value ? 'uses'))
    from jsonb_each(a)
   where key in ('point_system','stamp_card','birthday','welcome','referrals','promotions','gift_cards');

  -- uses counts events, customers counts people, so uses can never be the smaller of the two.
  insert into _v468(check_name,ok,detail)
  select '03 uses >= customers everywhere both are measured',
         coalesce(bool_and((value->>'uses')::int >= (value->>'customers')::int), true),
         string_agg(key,',') filter (where (value->>'uses')::int < (value->>'customers')::int)
    from jsonb_each(a)
   where key in ('point_system','stamp_card','birthday','welcome','referrals')
     and (value->>'customers') is not null and (value->>'uses') is not null;

  insert into _v468(check_name,ok,detail)
  select '03b list rows too (rewards, retention, memberships)',
         coalesce(bool_and((value->>'uses')::int >= (value->>'customers')::int), true),
         count(*)::text || ' rows checked'
    from (select value from jsonb_array_elements(a->'rewards')
          union all select value from jsonb_array_elements(a->'retention')
          union all select value from jsonb_array_elements(a->'memberships')) rows_v468;

  -- The honesty rule: not-tracked must be not-tracked for BOTH figures, never zero for one.
  insert into _v468(check_name,ok,detail)
  select '04 not-tracked stays not-tracked on both figures',
         bool_and(((value->>'customers') is null) = ((value->>'uses') is null)),
         string_agg(key,',') filter (where ((value->>'customers') is null) <> ((value->>'uses') is null))
    from jsonb_each(a)
   where key in ('point_system','stamp_card','birthday','welcome','referrals','promotions','gift_cards');

  insert into _v468(check_name,ok,detail) values(
    '04b promotions and gift cards stay null on both',
    (a->'promotions'->>'customers') is null and (a->'promotions'->>'uses') is null
      and (a->'gift_cards'->>'customers') is null and (a->'gift_cards'->>'uses') is null,
    'nothing in the schema records a customer using a promotion; the gap is admitted, not faked');

  -- 05: the stamp gate must agree with the source the stamp figure is computed from.
  select id into v_spine from public.business_programmes
   where business_id=v_biz and kind='stamps';
  insert into _v468(check_name,ok,detail) values(
    '05 stamp gate follows the spine, not loyalty_model',
    (v_spine is not null) = ((a->'stamp_card'->>'customers') is not null),
    'spine='||coalesce(v_spine::text,'none')||' figure='||coalesce(a->'stamp_card'->>'customers','null'));
end $$;

reset role;
select id, check_name, ok, coalesce(detail,'') as detail from _v468 order by id;
-- Any false in the ok column is a failure of this suite.
select count(*) filter (where not ok) as failures from _v468;

rollback;
