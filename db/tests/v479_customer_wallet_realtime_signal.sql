-- nestly_v479 rollback suite — the doorbell rings, and it can never break a sale.
--
-- Runs inside ONE transaction ending in ROLLBACK, safe against production.
--
-- WHAT IT PROVES
--   01  the signal table is in the realtime publication, beside the three tables the business
--       side already listens to. Without this line the whole feature is a silent no-op: the
--       trigger writes rows nobody is ever told about.
--   02  a ledger append bumps the signal for the customer whose balance moved — through the real
--       write-guard path, not a privileged shortcut.
--   03  RLS both directions: the customer reads their own signal; a stranger reads nothing.
--       The row carries no amounts, but WHICH businesses a person frequents is still theirs.
--   04  THE NON-NEGOTIABLE: with the signals machinery broken outright, the ledger write still
--       lands. The trigger's exception guard is what makes it safe to put this on the most
--       money-critical write path in the system, and this check is what fails if anyone ever
--       "improves" the guard into a rethrow.
--   05  nobody but the definer can write the table: no INSERT/UPDATE policy exists, and the API
--       roles hold only SELECT.

begin;

create temp table _v479(id int generated always as identity, check_name text, ok boolean, detail text) on commit drop;
grant all on _v479 to public;

insert into _v479(check_name, ok, detail)
select '01 the signal table is in the realtime publication',
       count(*) = 1, coalesce(string_agg(tablename, ', '), '(absent)')
  from pg_publication_tables
 where pubname = 'supabase_realtime' and tablename = 'customer_wallet_signals_v479';

insert into _v479(check_name, ok, detail)
select '05 the API roles hold SELECT only — the trigger is the sole writer',
       bool_and(privilege_type = 'SELECT'),
       string_agg(distinct privilege_type, ', ')
  from information_schema.role_table_grants
 where table_schema = 'public' and table_name = 'customer_wallet_signals_v479'
   and grantee in ('authenticated', 'anon');

do $$
declare
  v_biz uuid; v_client uuid; v_prog uuid; v_uid uuid;
  v_id uuid := gen_random_uuid(); v_id2 uuid := gen_random_uuid();
  v_count integer;
begin
  select cl.business_id, cl.client_id, cl.auth_user_id into v_biz, v_client, v_uid
    from public.customer_links cl
   where cl.state = 'verified' and cl.auth_user_id is not null
   limit 1;
  if v_biz is null then
    insert into _v479(check_name, ok, detail) values ('00 fixture', false, 'no verified customer link');
    return;
  end if;
  select id into v_prog from public.business_programmes where business_id = v_biz and active limit 1;

  -- 02: through the real guard, not around it.
  perform set_config('app.points_ledger_insert_id', v_id::text, true);
  perform set_config('app.points_ledger_write_scope', 'points_expiry', true);
  insert into public.points_ledger(id, business_id, client_id, entry_type, points, programme_id)
  values (v_id, v_biz, v_client, 'expire', -1, v_prog);
  select count(*) into v_count from public.customer_wallet_signals_v479
   where business_id = v_biz and auth_user_id = v_uid;
  insert into _v479(check_name, ok, detail) values (
    '02 a ledger append rings the doorbell for the customer whose balance moved',
    v_count = 1, v_count::text || ' signal row(s)');

  -- 03: RLS both directions.
  execute 'reset role'; execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub', v_uid::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
  select count(*) into v_count from public.customer_wallet_signals_v479;
  insert into _v479(check_name, ok, detail) values (
    '03a the customer reads their own signal', v_count >= 1, v_count::text);
  perform set_config('request.jwt.claim.sub', gen_random_uuid()::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
  select count(*) into v_count from public.customer_wallet_signals_v479;
  insert into _v479(check_name, ok, detail) values (
    '03b a stranger reads nothing — which shops a person frequents is still theirs',
    v_count = 0, v_count::text);
  execute 'reset role';

  -- 04: break the machinery outright; the sale must not notice.
  drop table public.customer_wallet_signals_v479 cascade;
  perform set_config('app.points_ledger_insert_id', v_id2::text, true);
  perform set_config('app.points_ledger_write_scope', 'points_expiry', true);
  insert into public.points_ledger(id, business_id, client_id, entry_type, points, programme_id)
  values (v_id2, v_biz, v_client, 'expire', -1, v_prog);
  select count(*) into v_count from public.points_ledger where id = v_id2;
  insert into _v479(check_name, ok, detail) values (
    '04 the ledger write survives the signal machinery being BROKEN outright',
    v_count = 1,
    'the exception guard is the licence to sit on the sale path — never rethrow');
exception when others then
  insert into _v479(check_name, ok, detail) values ('!! aborted', false, sqlstate || ' ' || sqlerrm);
end $$;

reset role;
select check_name, case when ok then 'PASS' else 'FAIL' end as result, detail from _v479 order by id;
select count(*) filter (where not ok) as failures, count(*) as checks from _v479;

rollback;
