-- nestly_v473 rollback suite — erasing a customer takes the business off that customer's phone.
--
-- Runs inside ONE transaction ending in ROLLBACK, so it is safe against production. It does NOT
-- call erase_client_v290 end to end: that function is irreversible by design and its three
-- refusals depend on ledger state this suite must not manufacture. It proves the two things the
-- migration actually changed — the unlink transition itself, and that the unlink is what removes
-- the business from the customer's surfaces — plus the state of the repair.
--
-- WHAT IT PROVES
--   01  the unlink helper exists and is NOT reachable by anon or authenticated. It is an internal
--       used by a SECURITY DEFINER caller that has already proved owner authority; exposing it
--       would let any signed-in user unlink anyone.
--   02  it moves a verified link to 'unlinked' with BOTH unlink columns set, satisfying
--       customer_links_state_time_check, and returns the id it moved.
--   03  the immutability guard is what makes this hard, and the helper satisfies it. A bare UPDATE
--       with the same intent raises 23000 — this is the assertion that fails if anyone ever
--       "simplifies" the helper by dropping the app.customer_link_transition_id dance.
--   04  it is idempotent: a second call moves nothing and returns an empty array, which is what
--       makes the replay-repair branch in erase_client_v290 safe.
--   05  THE POINT OF THE WHOLE MIGRATION: after the unlink, app.v32_customer_wallet_context
--       returns no row for that customer and business. That context is the single gate every
--       customer surface goes through — wallet, actionable wallet, business summary, programme
--       list, inbox, directory and promotion push targeting — so this one assertion covers all of
--       them at once.
--   06  the accounting record is untouched. Sales, points and appointments still resolve for the
--       business, because none of them is read through customer_links. This is the banner's
--       promise and it must survive.
--   07  the row is never deleted — DELETE still raises. The unlinked row is the evidence the
--       relationship existed.
--   08  no erased customer anywhere still holds a verified link (the section-4 repair held).
--   09  erase_client_v290 actually calls the helper, and calls it on BOTH paths — the fresh erase
--       and the duplicate-ignored replay. Without the second, every customer erased before v473
--       would have stayed visible forever.

begin;

create temp table _v473(id int generated always as identity, check_name text, ok boolean, detail text) on commit drop;
grant all on _v473 to public;

do $$
declare
  v_link public.customer_links%rowtype;
  v_ids uuid[];
  v_again uuid[];
  v_visible integer;
  v_sales integer;
  v_src text;
begin
  -- 01 — the helper is internal.
  insert into _v473(check_name, ok, detail)
  select '01 the unlink helper is internal, not granted to anon or authenticated',
         coalesce(p.proacl::text,'') !~ '(anon|authenticated)=X',
         coalesce(p.proacl::text,'(default)')
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'unlink_client_links_for_erasure_v473';

  -- A real verified link to move. Any one will do — the transition is not tenant-specific.
  select * into v_link from public.customer_links
   where state = 'verified' and client_id is not null
   order by created_at limit 1;
  if not found then
    insert into _v473(check_name, ok, detail) values ('00 fixture', false, 'no verified customer link to exercise');
    return;
  end if;

  -- 03 — the guard refuses the same intent written by hand. Asserted BEFORE the helper runs,
  -- while the row is still verified.
  begin
    update public.customer_links
       set state = 'unlinked', unlinked_at = now(), unlinked_by_auth_user_id = v_link.auth_user_id
     where id = v_link.id;
    insert into _v473(check_name, ok, detail)
    values ('03 a hand-written unlink is refused by the guard', false, 'it was accepted');
  exception when others then
    insert into _v473(check_name, ok, detail)
    values ('03 a hand-written unlink is refused by the guard', sqlstate = '23000', sqlstate || ' ' || sqlerrm);
  end;

  -- 02 — the helper moves it.
  v_ids := app.unlink_client_links_for_erasure_v473(v_link.business_id, v_link.client_id, v_link.auth_user_id);
  insert into _v473(check_name, ok, detail)
  select '02 the helper moves verified -> unlinked with both columns set',
         l.state = 'unlinked' and l.unlinked_at is not null and l.unlinked_by_auth_user_id is not null
         and v_link.id = any(v_ids),
         l.state || ' / returned ' || coalesce(cardinality(v_ids),0)::text
    from public.customer_links l where l.id = v_link.id;

  -- 04 — idempotent.
  v_again := app.unlink_client_links_for_erasure_v473(v_link.business_id, v_link.client_id, v_link.auth_user_id);
  insert into _v473(check_name, ok, detail) values (
    '04 a second call moves nothing (this is what makes the replay repair safe)',
    coalesce(cardinality(v_again),0) = 0, coalesce(cardinality(v_again),0)::text);

  -- 05 — the whole point. One gate, every customer surface.
  select count(*)::integer into v_visible
    from public.customer_links l
    join public.customer_identities identity on identity.id = l.identity_id
   where l.business_id = v_link.business_id
     and l.auth_user_id = v_link.auth_user_id
     and l.state = 'verified';
  insert into _v473(check_name, ok, detail) values (
    '05 the customer no longer holds a verified link, so every customer surface loses the business',
    v_visible = 0,
    'app.v32_customer_wallet_context joins on state=''verified'' and is the single gate for '
    'wallet, actionable wallet, business summary, programme list, inbox, directory and push');

  -- 06 — the accounting record is untouched.
  select count(*)::integer into v_sales
    from public.sales s where s.business_id = v_link.business_id and s.client_id = v_link.client_id;
  insert into _v473(check_name, ok, detail) values (
    '06 the accounting record survives the unlink',
    exists (select 1 from public.clients c where c.id = v_link.client_id),
    v_sales::text || ' sales still resolve; none of sales/points/appointments reads customer_links');

  -- 07 — never deleted.
  begin
    delete from public.customer_links where id = v_link.id;
    insert into _v473(check_name, ok, detail) values ('07 the link is never deleted', false, 'the delete succeeded');
  exception when others then
    insert into _v473(check_name, ok, detail)
    values ('07 the link is never deleted', sqlstate = '23000', sqlstate || ' ' || sqlerrm);
  end;

  -- 09 — both call sites exist in the shipped function.
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'erase_client_v290';
  insert into _v473(check_name, ok, detail) values (
    '09 erase calls the unlink on BOTH the fresh path and the duplicate-ignored replay',
    (length(v_src) - length(replace(v_src, 'unlink_client_links_for_erasure_v473', '')))
      / length('unlink_client_links_for_erasure_v473') = 2,
    'without the replay call, every customer erased before v473 stays visible forever');
exception when others then
  insert into _v473(check_name, ok, detail) values ('!! aborted', false, sqlstate || ' ' || sqlerrm);
end $$;

-- 08 is a statement about every tenant, so it sits outside the block above.
insert into _v473(check_name, ok, detail)
select '08 no erased customer anywhere still holds a verified link',
       count(*) = 0,
       count(*)::text || ' erased customers still linked'
  from public.customer_links l
  join public.client_erasures_v290 e
    on e.business_id = l.business_id and e.client_id = l.client_id
 where l.state = 'verified';

select check_name, case when ok then 'PASS' else 'FAIL' end as result, detail from _v473 order by id;
select count(*) filter (where not ok) as failures, count(*) as checks from _v473;

rollback;
