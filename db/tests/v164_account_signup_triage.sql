-- Rollback-only acceptance for V164 account-only business signup triage.
-- Run after the complete canonical chain on a disposable database.
begin;

do $v164_test$
begin
  if to_regclass('public.platform_account_signup_triage_v164') is null then
    raise exception 'V164 account signup triage table missing';
  end if;

  if not exists (
    select 1
      from pg_class c
      join pg_namespace n on n.oid=c.relnamespace
     where n.nspname='public'
       and c.relname='platform_account_signup_triage_v164'
       and c.relrowsecurity
  ) then
    raise exception 'V164 triage table must keep RLS enabled';
  end if;

  if has_table_privilege('anon','public.platform_account_signup_triage_v164','select')
     or has_table_privilege('authenticated','public.platform_account_signup_triage_v164','select')
     or has_table_privilege('authenticated','public.platform_account_signup_triage_v164','insert')
     or has_table_privilege('authenticated','public.platform_account_signup_triage_v164','update') then
    raise exception 'V164 triage table must not be directly exposed to browser roles';
  end if;

  if to_regprocedure('public.platform_record_account_signup_triage_v164(uuid,text,text,uuid)') is null then
    raise exception 'V164 account signup triage writer RPC missing';
  end if;

  if pg_get_functiondef('public.platform_record_account_signup_triage_v164(uuid,text,text,uuid)'::regprocedure)
       not like '%not app.is_super_admin()%' then
    raise exception 'V164 triage writer must be Super Admin only';
  end if;

  if pg_get_functiondef('public.platform_record_account_signup_triage_v164(uuid,text,text,uuid)'::regprocedure)
       like '%insert into public.staff%'
     or pg_get_functiondef('public.platform_record_account_signup_triage_v164(uuid,text,text,uuid)'::regprocedure)
       like '%billing_subscriptions%' then
    raise exception 'V164 triage writer must not create staff access or subscriptions';
  end if;

  if pg_get_functiondef('public.platform_list_account_signups_v160(text,integer)'::regprocedure)
       not like '%platform_account_signup_triage_v164%' then
    raise exception 'V164 account signup reader does not include triage state';
  end if;

  if pg_get_functiondef('public.platform_list_account_signups_v160(text,integer)'::regprocedure)
       not like '%coalesce(triage.triage_status,''new'') <> ''archived''%' then
    raise exception 'V164 account signup reader must hide archived triage rows by default';
  end if;
end
$v164_test$;

rollback;
