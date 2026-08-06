-- v188 rolled-back verification — self-service account deletion is closed off.
--
-- A revoke has nothing to mutate, so this asserts the resulting privilege state and proves the
-- call actually fails for a customer session. Everything is inside the transaction and the file
-- ends in `rollback;`.

begin;

do $test$
declare
  v_user uuid;
  v_denied boolean := false;
begin
  -- 1. the submit path is closed to browser sessions, and open to nothing else by accident
  assert not has_function_privilege('authenticated',
    'public.request_account_deletion_v131(text, text)', 'execute'),
    'a customer or firm session must not be able to submit a deletion request';
  assert not has_function_privilege('anon',
    'public.request_account_deletion_v131(text, text)', 'execute'),
    'anon must never have had it';
  assert has_function_privilege('service_role',
    'public.request_account_deletion_v131(text, text)', 'execute'),
    'Peekaa must still be able to record a request that arrived by email';

  -- 2. reading an EXISTING request is deliberately still allowed: someone who asked before this
  -- change must be able to see the outcome.
  assert has_function_privilege('authenticated',
    'public.get_account_deletion_request_v131()', 'execute'),
    'the status read must survive';

  -- 3. prove it end to end as a real customer session rather than trusting the catalogue alone
  select auth_user_id into v_user from public.customer_links
   where auth_user_id is not null and state = 'verified' limit 1;
  if v_user is null then
    raise notice 'v188: no verified customer session to drive; privilege assertions still passed';
  else
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);
    perform set_config('role', 'authenticated', true);
    begin
      perform public.request_account_deletion_v131('DELETE', gen_random_uuid()::text);
    exception when insufficient_privilege then
      v_denied := true;
    end;
    perform set_config('role', 'postgres', true);
    assert v_denied, 'a customer session must be refused by the database, not merely by the UI';
  end if;

  raise notice 'v188 verification passed';
end $test$;

rollback;
