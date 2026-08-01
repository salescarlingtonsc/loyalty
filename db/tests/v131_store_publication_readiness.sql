-- Rollback-only acceptance for V131 account-deletion request intake.
-- Run after the complete canonical chain on a disposable database.
begin;

create or replace function pg_temp.as_v131_user(
  p_uid uuid,
  p_role text default 'authenticated'
) returns void language plpgsql as $$
begin
  execute format('set local role %I',p_role);
  perform set_config('request.jwt.claim.sub',coalesce(p_uid::text,''),true);
  perform set_config('request.jwt.claims',json_build_object('sub',p_uid,'role',p_role)::text,true);
end
$$;
grant execute on function pg_temp.as_v131_user(uuid,text) to public;

do $v131_test$
declare
  v_customer uuid:=gen_random_uuid();
  v_other uuid:=gen_random_uuid();
  v_first jsonb;
  v_replay jsonb;
  v_denied boolean:=false;
begin
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
  values
    ('00000000-0000-0000-0000-000000000000',v_customer,'authenticated','authenticated','sofia.v131@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_other,'authenticated','authenticated','other.v131@example.test','',now(),now(),now());

  perform pg_temp.as_v131_user(v_customer);
  begin
    perform public.request_account_deletion_v131('NO','v131-invalid-confirmation');
  exception when invalid_parameter_value then v_denied:=true;
  end;
  if not v_denied then raise exception 'V131 accepted missing DELETE confirmation';end if;

  v_denied:=false;
  begin
    perform public.request_account_deletion_v131('delete','v131-lowercase-confirmation');
  exception when invalid_parameter_value then v_denied:=true;
  end;
  if not v_denied then raise exception 'V131 accepted lowercase deletion confirmation';end if;

  v_denied:=false;
  begin
    perform public.request_account_deletion_v131(' DELETE ','v131-spaced-confirmation');
  exception when invalid_parameter_value then v_denied:=true;
  end;
  if not v_denied then raise exception 'V131 accepted whitespace-padded deletion confirmation';end if;

  v_first:=public.request_account_deletion_v131('DELETE','v131-lost-response-retry');
  v_replay:=public.request_account_deletion_v131('DELETE','v131-lost-response-retry');
  if v_first->>'request_id' is null or v_first->>'request_id'<>v_replay->>'request_id' then
    raise exception 'V131 did not replay the exact request';
  end if;
  v_replay:=public.request_account_deletion_v131('DELETE','v131-second-client-key');
  if v_first->>'request_id'<>v_replay->>'request_id' then
    raise exception 'V131 created a duplicate open request';
  end if;
  if (select count(*) from public.account_deletion_requests where subject_ref=v_customer)<>1 then
    raise exception 'V131 request count is not exactly one';
  end if;
  if (select response_due_at-requested_at from public.account_deletion_requests where subject_ref=v_customer)<>interval '30 days' then
    raise exception 'V131 response deadline is not exactly 30 days';
  end if;
  if (select count(*) from auth.users where id in(v_customer,v_other))<>2 then
    raise exception 'V131 request destructively changed auth users';
  end if;

  v_denied:=false;
  begin
    perform 1 from public.account_deletion_requests;
  exception when insufficient_privilege then v_denied:=true;
  end;
  if not v_denied then raise exception 'V131 exposed its private queue to browser table access';end if;
  reset role;

  perform pg_temp.as_v131_user(v_other);
  if public.get_account_deletion_request_v131() is not null then
    raise exception 'V131 exposed another subject request';
  end if;
  reset role;

  perform pg_temp.as_v131_user(null,'anon');
  v_denied:=false;
  begin
    perform public.request_account_deletion_v131('DELETE','v131-anon-request');
  exception when insufficient_privilege then v_denied:=true;
  end;
  reset role;
  if not v_denied then raise exception 'V131 allowed anonymous request intake';end if;
end
$v131_test$;

rollback;
