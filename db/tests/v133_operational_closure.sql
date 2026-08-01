-- Rollback-only acceptance for V133 privacy-operator lifecycle.
-- Run after the complete canonical chain on a disposable database.
begin;

create or replace function pg_temp.as_v133_user(
  p_uid uuid,
  p_role text default 'authenticated'
) returns void language plpgsql as $$
begin
  execute format('set local role %I',p_role);
  perform set_config('request.jwt.claim.sub',coalesce(p_uid::text,''),true);
  perform set_config('request.jwt.claims',json_build_object('sub',p_uid,'role',p_role)::text,true);
end
$$;
grant execute on function pg_temp.as_v133_user(uuid,text) to public;

do $v133_test$
declare
  v_operator uuid:=gen_random_uuid();
  v_operator_two uuid:=gen_random_uuid();
  v_outsider uuid:=gen_random_uuid();
  v_customer uuid:=gen_random_uuid();
  v_retained_customer uuid:=gen_random_uuid();
  v_request uuid;
  v_retained_request uuid;
  v_claim jsonb;
  v_replay jsonb;
  v_resolved jsonb;
  v_reviewed jsonb;
  v_retained_resolved jsonb;
  v_retained_until timestamptz:=now()+interval '5 years';
  v_review_until timestamptz:=now()+interval '2 years';
  v_denied boolean:=false;
begin
  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,
    email_confirmed_at,created_at,updated_at
  ) values
    ('00000000-0000-0000-0000-000000000000',v_operator,'authenticated','authenticated','operator.v133@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_operator_two,'authenticated','authenticated','operator.two.v133@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_outsider,'authenticated','authenticated','outsider.v133@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_customer,'authenticated','authenticated','customer.v133@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_retained_customer,'authenticated','authenticated','retained.v133@example.test','',now(),now(),now());
  insert into public.super_admins(user_id,email,note) values
    (v_operator,'operator.v133@example.test','V133 synthetic privacy operator'),
    (v_operator_two,'operator.two.v133@example.test','V133 synthetic backup privacy operator');

  perform pg_temp.as_v133_user(v_customer);
  v_request:=(public.request_account_deletion_v131('DELETE','v133-customer-request')->>'request_id')::uuid;
  reset role;

  perform pg_temp.as_v133_user(v_outsider);
  begin
    perform public.platform_list_account_deletion_requests_v133(null,100);
  exception when insufficient_privilege then v_denied:=true;
  end;
  reset role;
  if not v_denied then raise exception 'V133 exposed the operator queue to a non-super-admin';end if;

  perform pg_temp.as_v133_user(v_operator);
  if (select count(*) from public.platform_list_account_deletion_requests_v133('pending',100)
       where request_id=v_request)<>1 then
    raise exception 'V133 operator queue did not return the pending request';
  end if;

  v_claim:=public.platform_transition_account_deletion_request_v133(
    v_request,'claim','Accepted for controlled privacy review',null,null,null,'v133-claim-request'
  );
  v_replay:=public.platform_transition_account_deletion_request_v133(
    v_request,'claim','Accepted for controlled privacy review',null,null,null,'v133-claim-request'
  );
  if v_claim<>v_replay or v_claim->>'status'<>'processing' then
    raise exception 'V133 claim did not replay exactly';
  end if;
  v_denied:=false;
  begin
    perform public.platform_transition_account_deletion_request_v133(
      v_request,'claim','Changed claim reason is forbidden',null,null,null,'v133-claim-request'
    );
  exception when invalid_parameter_value then v_denied:=true;
  end;
  if not v_denied then raise exception 'V133 accepted changed payload under a used key';end if;

  v_denied:=false;
  begin
    perform public.platform_transition_account_deletion_request_v133(
      v_request,'resolve','Retention without a future deadline','retained_legal',null,'PRIVACY-CASE-001','v133-invalid-retention'
    );
  exception when invalid_parameter_value then v_denied:=true;
  end;
  if not v_denied then raise exception 'V133 accepted legal retention without a deadline';end if;

  reset role;
  perform pg_temp.as_v133_user(v_operator_two);
  v_resolved:=public.platform_transition_account_deletion_request_v133(
    v_request,'resolve','Identity and controlled deletion steps completed',
    'deleted_where_permitted',null,'PRIVACY-CASE-001','v133-resolve-request'
  );
  v_replay:=public.platform_transition_account_deletion_request_v133(
    v_request,'resolve','Identity and controlled deletion steps completed',
    'deleted_where_permitted',null,'PRIVACY-CASE-001','v133-resolve-request'
  );
  if v_resolved<>v_replay or v_resolved->>'status'<>'completed'
     or v_resolved->>'resolution_code'<>'deleted_where_permitted' then
    raise exception 'V133 resolution did not replay exactly';
  end if;
  reset role;

  perform pg_temp.as_v133_user(v_operator);
  v_replay:=public.platform_transition_account_deletion_request_v133(
    v_request,'claim','Accepted for controlled privacy review',null,null,null,'v133-claim-request'
  );
  reset role;
  if v_replay<>v_claim or v_replay->>'status'<>'processing' then
    raise exception 'V133 claim replay changed after a later resolution';
  end if;

  if (select count(*) from public.account_deletion_request_events where request_id=v_request)<>2 then
    raise exception 'V133 did not append exactly one claim and one resolution event';
  end if;
  if (select count(*) from auth.users where id in(v_operator,v_operator_two,v_outsider,v_customer,v_retained_customer))<>5 then
    raise exception 'V133 operator receipt destructively changed Auth users';
  end if;

  v_denied:=false;
  begin
    update public.account_deletion_request_events set reason='Rewritten evidence is forbidden'
     where request_id=v_request;
  exception when insufficient_privilege then v_denied:=true;
  end;
  if not v_denied then raise exception 'V133 allowed privileged evidence rewriting';end if;
  v_denied:=false;
  begin
    delete from public.account_deletion_request_events where request_id=v_request;
  exception when insufficient_privilege then v_denied:=true;
  end;
  if not v_denied then raise exception 'V133 allowed privileged evidence deletion';end if;
  v_denied:=false;
  begin
    truncate public.account_deletion_request_events;
  exception when insufficient_privilege then v_denied:=true;
  end;
  if not v_denied then raise exception 'V133 allowed privileged evidence truncation';end if;

  perform pg_temp.as_v133_user(v_outsider,'service_role');
  v_denied:=false;
  begin
    update public.account_deletion_request_events set reason='Service rewrite is forbidden'
     where request_id=v_request;
  exception when insufficient_privilege then v_denied:=true;
  end;
  reset role;
  if not v_denied then raise exception 'V133 allowed service-role evidence rewriting';end if;

  perform pg_temp.as_v133_user(v_customer);
  if (public.get_account_deletion_request_v131()->>'resolution_code')<>'deleted_where_permitted' then
    raise exception 'V133 subject projection did not expose the reviewed disposition';
  end if;
  v_denied:=false;
  begin
    perform 1 from public.account_deletion_request_events;
  exception when insufficient_privilege then v_denied:=true;
  end;
  reset role;
  if not v_denied then raise exception 'V133 exposed private operator events to the subject';end if;

  insert into public.account_deletion_requests(subject_ref,idempotency_key)
  select gen_random_uuid(),'v133-page-'||page_number::text
    from generate_series(1,101) page_number;
  perform pg_temp.as_v133_user(v_operator);
  if (select count(*) from public.platform_list_account_deletion_requests_v133('pending',100,0))<>100
     or (select min(total_count) from public.platform_list_account_deletion_requests_v133('pending',100,0))<>101
     or (select count(*) from public.platform_list_account_deletion_requests_v133('pending',100,100))<>1 then
    raise exception 'V133 pagination hid an actionable request beyond the first 100';
  end if;
  reset role;

  perform pg_temp.as_v133_user(v_retained_customer);
  v_retained_request:=(public.request_account_deletion_v131('DELETE','v133-retained-request')->>'request_id')::uuid;
  reset role;
  perform pg_temp.as_v133_user(v_operator);
  perform public.platform_transition_account_deletion_request_v133(
    v_retained_request,'claim','Accepted for legal retention review',null,null,null,'v133-claim-retained'
  );
  v_retained_resolved:=public.platform_transition_account_deletion_request_v133(
    v_retained_request,'resolve','Financial records retained under documented obligation',
    'retained_legal',v_retained_until,'PRIVACY-CASE-002','v133-resolve-retained'
  );
  reset role;

  update public.account_deletion_requests
     set retention_until=now()-interval '1 minute'
   where id=v_retained_request;
  perform pg_temp.as_v133_user(v_operator);
  v_replay:=public.platform_transition_account_deletion_request_v133(
    v_retained_request,'resolve','Financial records retained under documented obligation',
    'retained_legal',v_retained_until,'PRIVACY-CASE-002','v133-resolve-retained'
  );
  reset role;
  if v_replay<>v_retained_resolved then
    raise exception 'V133 retained resolution failed exact replay after its deadline';
  end if;
  perform pg_temp.as_v133_user(v_operator_two);
  if (select count(*) from public.platform_list_account_deletion_requests_v133(null,100)
       where request_id=v_retained_request and is_overdue)<>1 then
    raise exception 'V133 did not surface expired legal retention as due';
  end if;
  v_reviewed:=public.platform_transition_account_deletion_request_v133(
    v_retained_request,'retention_review','Legal obligation revalidated against the current schedule',
    'retained_legal',v_review_until,'PRIVACY-CASE-003','v133-review-retained'
  );
  v_replay:=public.platform_transition_account_deletion_request_v133(
    v_retained_request,'retention_review','Legal obligation revalidated against the current schedule',
    'retained_legal',v_review_until,'PRIVACY-CASE-003','v133-review-retained'
  );
  reset role;
  if v_reviewed<>v_replay or v_reviewed->>'resolution_code'<>'retained_legal' then
    raise exception 'V133 retention review did not replay exactly';
  end if;
  if not exists(
    select 1 from public.account_deletion_requests
     where id=v_retained_request and status='completed'
       and resolution_code='retained_legal' and retention_until>now()
  ) then raise exception 'V133 did not persist the bounded legal-retention outcome';end if;
  if (select count(*) from public.account_deletion_request_events where request_id=v_retained_request)<>3 then
    raise exception 'V133 did not append the retention-review evidence';
  end if;
end
$v133_test$;

rollback;
