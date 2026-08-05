-- Rollback-only acceptance for V167 direct Super Admin approval activation.
-- Run after the complete canonical chain on a disposable database.
begin;

do $v167_test$
declare
  v_function text;
begin
  if to_regprocedure('public.platform_decide_business_application_v105(uuid,text,text,bigint,uuid)') is null then
    raise exception 'V167 platform decision RPC missing';
  end if;

  select pg_get_functiondef('public.platform_decide_business_application_v105(uuid,text,text,bigint,uuid)'::regprocedure)
    into v_function;

  if v_function not like '%DIRECT_APPLICATION_APPROVED_ACTIVATED_V167%' then
    raise exception 'V167 approval activation audit marker missing';
  end if;

  if v_function not like '%insert into public.businesses%' then
    raise exception 'V167 approval must create a business workspace for an approved application';
  end if;

  if v_function not like '%insert into public.staff%' or v_function not like '%''owner''%' then
    raise exception 'V167 approval must create the matching owner staff access';
  end if;

  if v_function not like '%status=''consumed''%' then
    raise exception 'V167 approval must consume the application after workspace activation';
  end if;

  if v_function not like '%workspace_access'',true%' then
    raise exception 'V167 approval response must report workspace access after activation';
  end if;
end
$v167_test$;

rollback;
