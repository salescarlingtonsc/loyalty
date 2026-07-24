-- Rollback-only v66a suite: v_business_billing must enforce caller RLS (SECURITY INVOKER), not the
-- view owner's privileges. Run after the chain through v66a in a disposable rehearsal DB. Proves:
--   (1) structural: the view carries reloption security_invoker=true;
--   (2) the v66 `where b.is_synthetic = false` filter is still present (v66a changed only the reloption);
--   (3) behavioural: a plain tenant owner (fixture A owner, NOT a super admin) querying the view sees
--       ONLY their own business row and CANNOT see another tenant's billing row — which is exactly what
--       breaks if the view is SECURITY DEFINER. owner_b is the fixture super admin and is used as the
--       positive control (a definer-equivalent all-tenant view over the same rows).
-- Config/DDL only: zero value writes, sv_authority untouched. The including txn owns BEGIN/ROLLBACK.
begin;
\ir fixtures/pristine_chain_fixture.psql

create or replace function pg_temp.as_v66a(p_uid uuid, p_role text)
returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','',true);
  if p_role='anon' then
    execute 'set local role anon';
    perform set_config('request.jwt.claims', json_build_object('role','anon')::text, true);
  else
    execute 'set local role authenticated';
    perform set_config('request.jwt.claim.sub', p_uid::text, true);
    perform set_config('request.jwt.claims', json_build_object('sub',p_uid,'role','authenticated')::text, true);
  end if;
end $$;
grant execute on function pg_temp.as_v66a(uuid,text) to authenticated, anon;

do $v66a$
declare
  A uuid; B uuid; A_owner uuid; B_owner uuid; v_reloptions text; v_def text;
  v_self int; v_other int; v_visible int; v_sa_visible int;
begin
  reset role;
  select id into A from public.businesses where name='Pristine chain fixture A';
  select id into B from public.businesses where name='Pristine chain fixture B';
  if A is null or B is null then raise exception 'need pristine fixtures A and B'; end if;
  select user_id into A_owner from public.staff where business_id=A and role='owner' and user_id is not null limit 1;
  select user_id into B_owner from public.staff where business_id=B and role='owner' and user_id is not null limit 1;
  if A_owner is null or B_owner is null then raise exception 'need owner logins for A and B'; end if;

  -- (1) structural: reloption restored
  select coalesce(array_to_string(c.reloptions,','),'') into v_reloptions
    from pg_class c join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relname='v_business_billing';
  assert position('security_invoker=true' in v_reloptions) > 0,
    'v_business_billing must carry security_invoker=true, got reloptions=['||v_reloptions||']';

  -- (2) v66 is_synthetic filter preserved (definition untouched by v66a)
  v_def := pg_get_viewdef('public.v_business_billing'::regclass, true);
  assert v_def ilike '%is_synthetic = false%',
    'v66 is_synthetic filter must remain in the view definition';

  -- (3a) behavioural: plain owner of A sees ONLY A, never B (RLS enforced as the caller)
  perform pg_temp.as_v66a(A_owner,'authenticated');
  select count(*) into v_self  from public.v_business_billing where business_id = A;
  select count(*) into v_other from public.v_business_billing where business_id = B;
  select count(*) into v_visible from public.v_business_billing;
  assert v_self = 1, 'owner A must see own billing row, saw '||v_self;
  assert v_other = 0, 'SECURITY DEFINER LEAK: owner A must NOT see tenant B billing, saw '||v_other;
  assert v_visible = 1, 'owner A must see exactly one (own) billing row, saw '||v_visible;

  -- (3b) positive control: the fixture super admin (owner_b) legitimately sees BOTH tenants,
  --      confirming the rows exist and the row-count restriction above is RLS, not an empty view.
  perform pg_temp.as_v66a(B_owner,'authenticated');
  select count(*) into v_sa_visible from public.v_business_billing where business_id in (A,B);
  assert v_sa_visible = 2, 'super admin must see both tenant billing rows, saw '||v_sa_visible;

  reset role;
  raise notice 'V66A SUITE PASS (all assertions)';
end $v66a$;
rollback;
