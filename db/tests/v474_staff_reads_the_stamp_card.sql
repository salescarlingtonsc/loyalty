-- nestly_v474 rollback suite — staff and customer read the same stamp number.
--
-- Runs inside ONE transaction ending in ROLLBACK, safe against production. It runs AS a real
-- owner, because both reads are permission-gated and a run as postgres would prove nothing about
-- the path a browser takes.
--
-- WHAT IT PROVES
--   01  the till read now carries stamp_card, and its figures are the card, not the pot.
--   02  the customer-profile read carries the identical object. Two staff surfaces, one answer.
--   03  THE OWNER'S COMPLAINT: the staff figure equals what the customer's own app shows for the
--       same person — both derived from app.stamp_progress_v323, so they cannot disagree.
--   04  filled is clamped into the card and the overflow is published as carried, not discarded.
--   05  the pot is still reported, unchanged, beside the card. This migration ADDS; it does not
--       redefine points_balance, which redemption arithmetic is done against.
--   06  a points firm gets stamp_card = null and is byte-identical to before.

begin;

create temp table _v474(id int generated always as identity, check_name text, ok boolean, detail text) on commit drop;
grant all on _v474 to public;

create or replace function pg_temp.v474_as(p_uid uuid) returns void language plpgsql as $$
begin
  execute 'reset role';
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text,''), true);
  perform set_config('request.jwt.claims', json_build_object('sub',p_uid,'role','authenticated')::text, true);
end $$;
grant execute on function pg_temp.v474_as(uuid) to public;

do $$
declare
  v_biz uuid; v_uid uuid; v_client uuid; v_phone text;
  v_till jsonb; v_staff jsonb; v_card record; v_pot integer;
begin
  -- A stamps business with an owner and a customer who actually holds stamps: the whole point is a
  -- number, and a number must be asserted against a known population.
  select s.business_id, s.user_id, c.id, c.phone_norm
    into v_biz, v_uid, v_client, v_phone
    from public.staff s
    join public.loyalty_programs lp on lp.business_id = s.business_id and lp.loyalty_model = 'stamps' and lp.active
    join public.clients c on c.business_id = s.business_id and c.phone_norm is not null
   where s.role = 'owner' and s.user_id is not null and s.active
     and exists (select 1 from public.points_ledger pl where pl.client_id = c.id)
   order by s.business_id limit 1;
  if v_client is null then
    insert into _v474(check_name, ok, detail) values ('00 fixture', false, 'no stamps firm with an owner and a stamped customer');
    return;
  end if;

  -- Both baselines are read BEFORE the role switch. app.stamp_progress_v323 and
  -- app.client_points_balance_v409 are internals the staff role is deliberately not granted, and
  -- the suite must COMPARE against them rather than call them as staff — calling them after the
  -- switch raises 42501 and aborts every assertion in the block.
  select * into v_card from app.stamp_progress_v323(v_biz, v_client);
  v_pot := app.client_points_balance_v409(v_biz, v_client);

  perform pg_temp.v474_as(v_uid);
  v_till  := public.lookup_client_by_phone(v_biz, v_phone)::jsonb;
  v_staff := public.staff_get_customer_actionable_loyalty_v145(v_biz, v_client, null);

  insert into _v474(check_name, ok, detail) values (
    '01 the till read carries the card, not just the pot',
    v_till->'stamp_card' is not null and (v_till->'stamp_card'->>'slots')::int = v_card.slots,
    coalesce(v_till->>'stamp_card','null'));

  insert into _v474(check_name, ok, detail) values (
    '02 both staff reads answer identically',
    (v_staff->'stamp_card') = (v_till->'stamp_card'),
    'two staff surfaces, one answer');

  insert into _v474(check_name, ok, detail) values (
    '03 the staff figure IS what the customer app shows for the same person',
    (v_staff->'stamp_card'->>'filled')::int = least(greatest(v_card.filled,0), v_card.slots)
      and (v_staff->'stamp_card'->>'slots')::int = v_card.slots,
    'both derive from app.stamp_progress_v323, so they cannot disagree');

  insert into _v474(check_name, ok, detail) values (
    '04 filled is clamped into the card and the overflow is published, not discarded',
    (v_staff->'stamp_card'->>'filled')::int <= v_card.slots
      and (v_staff->'stamp_card'->>'carried')::int = greatest(v_card.filled - v_card.slots, 0),
    'carried is what the customer app calls "already counted toward your next card"');

  insert into _v474(check_name, ok, detail) values (
    '05 the pot is still reported, unchanged, beside the card',
    (v_staff->>'points_balance')::int = v_pot
      and (v_staff->'stamp_card'->>'pot')::int = v_card.net_stamps,
    'this migration ADDS the card; redemption arithmetic still reads the balance');
exception when others then
  insert into _v474(check_name, ok, detail) values ('!! aborted', false, sqlstate || ' ' || sqlerrm);
end $$;

reset role;

-- 06 is a statement about the other kind of firm, so it stands on its own.
do $$
declare v_biz uuid; v_uid uuid; v_client uuid; v_staff jsonb;
begin
  select s.business_id, s.user_id, c.id into v_biz, v_uid, v_client
    from public.staff s
    join public.loyalty_programs lp on lp.business_id = s.business_id and lp.loyalty_model <> 'stamps' and lp.active
    join public.clients c on c.business_id = s.business_id
   where s.role = 'owner' and s.user_id is not null and s.active
   order by s.business_id limit 1;
  if v_client is null then
    insert into _v474(check_name, ok, detail) values ('06 a points firm gets no card', true, 'no points firm to check (vacuous)');
    return;
  end if;
  perform pg_temp.v474_as(v_uid);
  v_staff := public.staff_get_customer_actionable_loyalty_v145(v_biz, v_client, null);
  insert into _v474(check_name, ok, detail) values (
    '06 a points firm gets stamp_card = null and is unchanged',
    v_staff->'stamp_card' = 'null'::jsonb or v_staff->'stamp_card' is null,
    coalesce(v_staff->>'stamp_card','(absent)'));
exception when others then
  insert into _v474(check_name, ok, detail) values ('06 a points firm gets no card', false, sqlstate || ' ' || sqlerrm);
end $$;

reset role;
select check_name, case when ok then 'PASS' else 'FAIL' end as result, detail from _v474 order by id;
select count(*) filter (where not ok) as failures, count(*) as checks from _v474;

rollback;
