-- Rollback-only acceptance for V168 approved account-only signup admission.
-- Run after the complete canonical chain on a disposable database.
begin;

do $v168_test$
declare
  v_function text;
begin
  if to_regprocedure('public.complete_business_google_oauth_v138(text,text)') is null then
    raise exception 'V168 business Google OAuth admission RPC missing';
  end if;

  select pg_get_functiondef('public.complete_business_google_oauth_v138(text,text)'::regprocedure)
    into v_function;

  if v_function not like '%platform_account_signup_triage_v164%' then
    raise exception 'V168 sign-in admission must inspect approved platform triage';
  end if;

  if v_function not like '%triage.triage_status=''contacted''%' then
    raise exception 'V168 sign-in admission must only admit Super Admin approved account-only signups';
  end if;

  if v_function not like '%platform_account_signup_approved%' then
    raise exception 'V168 approved setup reason marker missing';
  end if;

  if v_function not like '%requires_business_setup'',true%' then
    raise exception 'V168 approved setup admission must tell the client to continue business setup';
  end if;

  if v_function like '%insert into public.staff%' or v_function like '%insert into public.businesses%' then
    raise exception 'V168 account-only admission must not create workspace or staff access';
  end if;

  if v_function not like '%existing active business account or approved setup request required%' then
    raise exception 'V168 unapproved sign-in denial wording missing';
  end if;
end
$v168_test$;

rollback;
