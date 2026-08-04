-- Rollback-only acceptance for V163 signup lead management and customer consent.
-- Run after the complete canonical chain on a disposable database.
begin;

do $v163_test$
begin
  if not exists (
    select 1
      from information_schema.columns
     where table_schema='public'
       and table_name='customer_profiles'
       and column_name='gender'
       and data_type='text'
  ) then
    raise exception 'V163 customer_profiles.gender column missing';
  end if;

  if to_regprocedure('public.customer_register_verified_phone(text,date,text,boolean,boolean,boolean,text)') is not null then
    raise exception 'V163 left the no-gender customer registration overload callable';
  end if;

  if to_regprocedure('public.customer_register_verified_phone(text,date,text,text,boolean,boolean,boolean,text)') is null then
    raise exception 'V163 gender-aware customer registration RPC missing';
  end if;

  if pg_get_functiondef('public.customer_register_verified_phone(text,date,text,text,boolean,boolean,boolean,text)'::regprocedure)
       not like '%v_gender not in (''female'',''male'')%' then
    raise exception 'V163 registration RPC does not enforce female/male gender only';
  end if;

  if pg_get_functiondef('public.customer_register_verified_phone(text,date,text,text,boolean,boolean,boolean,text)'::regprocedure)
       not like '%p_birth_date > (timezone(''Asia/Singapore'', now()))::date%' then
    raise exception 'V163 registration RPC must preserve Singapore-date DOB validation';
  end if;

  if pg_get_functiondef('public.customer_register_verified_phone(text,date,text,text,boolean,boolean,boolean,text)'::regprocedure)
       not like '%identity_id, auth_user_id, full_name, birth_date, gender, preferred_language%' then
    raise exception 'V163 registration RPC does not persist gender with the private profile snapshot';
  end if;

  if pg_get_functiondef('public.customer_get_profile()'::regprocedure)
       not like '%''gender'', p.gender%' then
    raise exception 'V163 customer profile reader does not return the customer-owned gender value';
  end if;
end
$v163_test$;

rollback;
