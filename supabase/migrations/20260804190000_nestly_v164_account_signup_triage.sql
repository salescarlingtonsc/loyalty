begin;

create table if not exists public.platform_account_signup_triage_v164 (
  auth_user_id uuid primary key references auth.users(id) on delete cascade,
  triage_status text not null default 'new'
    check (triage_status in ('new','follow_up','contacted','archived')),
  note text,
  last_contacted_at timestamptz,
  archived_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id)
);

alter table public.platform_account_signup_triage_v164 enable row level security;

revoke all on table public.platform_account_signup_triage_v164 from public,anon,authenticated;

comment on table public.platform_account_signup_triage_v164 is
  'V164 platform-admin-only triage state for Auth-only business owner signups. This never creates a business, invoice, subscription, staff row, or entitlement.';

create or replace function public.platform_record_account_signup_triage_v164(
  p_user uuid,
  p_status text,
  p_note text default null,
  p_idempotency_key uuid default gen_random_uuid()
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();
  v_status text:=lower(nullif(btrim(coalesce(p_status,'')),''));
  v_note text:=nullif(btrim(coalesce(p_note,'')),'');
  v_row public.platform_account_signup_triage_v164%rowtype;
begin
  if v_actor is null or not app.is_super_admin() then
    raise exception 'super_admin_required' using errcode='42501';
  end if;
  if p_user is null or v_status not in ('new','follow_up','contacted','archived') then
    raise exception 'invalid account-signup triage request' using errcode='22023';
  end if;
  if v_note is not null and length(v_note)>1000 then
    raise exception 'triage note is too long' using errcode='22023';
  end if;
  if not exists(
    select 1
      from auth.users user_row
     where user_row.id=p_user
       and (
         user_row.raw_user_meta_data->>'account_type'='business_owner'
         or exists(
           select 1
             from app.business_account_legal_acceptances_v138 acceptance
            where acceptance.auth_user_id=user_row.id
              and acceptance.source='google_oauth_signup'
         )
       )
       and not exists(select 1 from public.staff staff_row where staff_row.user_id=user_row.id)
       and not exists(select 1 from public.self_serve_business_onboarding_v130 onboarding where onboarding.owner_user_id=user_row.id)
       and not exists(select 1 from public.business_applications_v95 application where lower(application.contact_email)=lower(user_row.email))
  ) then
    raise exception 'account-only business signup not found' using errcode='42501';
  end if;

  insert into public.platform_account_signup_triage_v164(
    auth_user_id,triage_status,note,last_contacted_at,archived_at,updated_at,updated_by
  ) values(
    p_user,v_status,v_note,
    case when v_status in ('contacted','follow_up') then now() else null end,
    case when v_status='archived' then now() else null end,
    now(),v_actor
  )
  on conflict(auth_user_id) do update set
    triage_status=excluded.triage_status,
    note=coalesce(excluded.note,public.platform_account_signup_triage_v164.note),
    last_contacted_at=case
      when excluded.triage_status in ('contacted','follow_up') then now()
      else public.platform_account_signup_triage_v164.last_contacted_at
    end,
    archived_at=case
      when excluded.triage_status='archived' then now()
      else null
    end,
    updated_at=now(),
    updated_by=v_actor
  returning * into v_row;

  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(null,v_actor,'PLATFORM_ACCOUNT_SIGNUP_TRIAGED_V164',
    'auth.users',p_user,jsonb_build_object(
      'status',v_status,
      'note_present',v_note is not null,
      'idempotency_key',p_idempotency_key
    ));

  return jsonb_build_object(
    'user_id',v_row.auth_user_id,
    'triage_status',v_row.triage_status,
    'note',v_row.note,
    'last_contacted_at',v_row.last_contacted_at,
    'archived_at',v_row.archived_at,
    'updated_at',v_row.updated_at
  );
end
$$;

revoke all on function public.platform_record_account_signup_triage_v164(
  uuid,text,text,uuid
) from public,anon,authenticated;
grant execute on function public.platform_record_account_signup_triage_v164(
  uuid,text,text,uuid
) to authenticated;

comment on function public.platform_record_account_signup_triage_v164(
  uuid,text,text,uuid
) is
  'V164 Super Admin triage for account-only business owner signups. Contacted/follow-up/archive actions are CRM evidence only and never activate access.';

create or replace function public.platform_list_account_signups_v160(
  p_search text default null,
  p_limit integer default 100
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_limit integer:=least(greatest(coalesce(p_limit,100),1),100);
  v_search text:=nullif(trim(coalesce(p_search,'')),'');
  v_items jsonb;
begin
  if auth.uid() is null or not app.is_super_admin() then
    raise exception 'super_admin_required' using errcode='42501';
  end if;

  with candidates as (
    select user_row.*,triage.triage_status,triage.note as triage_note,
           triage.last_contacted_at,triage.archived_at,triage.updated_at as triage_updated_at
      from auth.users user_row
      left join public.platform_account_signup_triage_v164 triage
        on triage.auth_user_id=user_row.id
     where user_row.created_at >= now()-interval '30 days'
       and coalesce(triage.triage_status,'new') <> 'archived'
       and (
         user_row.raw_user_meta_data->>'account_type'='business_owner'
         or exists(
           select 1
             from app.business_account_legal_acceptances_v138 acceptance
            where acceptance.auth_user_id=user_row.id
              and acceptance.source='google_oauth_signup'
         )
       )
       and not exists(select 1 from public.staff staff_row where staff_row.user_id=user_row.id)
       and not exists(select 1 from public.self_serve_business_onboarding_v130 onboarding where onboarding.owner_user_id=user_row.id)
       and not exists(select 1 from public.business_applications_v95 application where lower(application.contact_email)=lower(user_row.email))
       and (
         v_search is null
         or lower(coalesce(user_row.email,'')) like '%'||lower(v_search)||'%'
         or coalesce(user_row.phone,'') like '%'||v_search||'%'
         or lower(coalesce(triage.note,'')) like '%'||lower(v_search)||'%'
       )
     order by user_row.created_at desc,user_row.id desc
     limit v_limit+1
  ), limited as (
    select * from candidates
     order by created_at desc,id desc
     limit v_limit
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'user_id',limited.id,
      'email',lower(limited.email),
      'phone',limited.phone,
      'confirmed',coalesce(limited.email_confirmed_at,limited.confirmed_at) is not null,
      'created_at',limited.created_at,
      'last_sign_in_at',limited.last_sign_in_at,
      'status',case
        when coalesce(limited.email_confirmed_at,limited.confirmed_at) is null then 'email_unconfirmed'
        else 'needs_business_details'
      end,
      'triage_status',coalesce(limited.triage_status,'new'),
      'triage_note',limited.triage_note,
      'last_contacted_at',limited.last_contacted_at,
      'triage_updated_at',limited.triage_updated_at,
      'manageable',true
    ) order by limited.created_at desc,limited.id desc),'[]'::jsonb)
    into v_items
    from limited;

  return jsonb_build_object(
    'items',v_items,
    'count',jsonb_array_length(v_items),
    'window_days',30,
    'truncated',(
      select count(*)>v_limit from (
        select 1
          from auth.users user_row
          left join public.platform_account_signup_triage_v164 triage
            on triage.auth_user_id=user_row.id
         where user_row.created_at >= now()-interval '30 days'
           and coalesce(triage.triage_status,'new') <> 'archived'
           and (
             user_row.raw_user_meta_data->>'account_type'='business_owner'
             or exists(
               select 1
                 from app.business_account_legal_acceptances_v138 acceptance
                where acceptance.auth_user_id=user_row.id
                  and acceptance.source='google_oauth_signup'
             )
           )
           and not exists(select 1 from public.staff staff_row where staff_row.user_id=user_row.id)
           and not exists(select 1 from public.self_serve_business_onboarding_v130 onboarding where onboarding.owner_user_id=user_row.id)
           and not exists(select 1 from public.business_applications_v95 application where lower(application.contact_email)=lower(user_row.email))
           and (
             v_search is null
             or lower(coalesce(user_row.email,'')) like '%'||lower(v_search)||'%'
             or coalesce(user_row.phone,'') like '%'||v_search||'%'
             or lower(coalesce(triage.note,'')) like '%'||lower(v_search)||'%'
           )
         limit v_limit+1
      ) overflow_check
    )
  );
end
$$;

revoke all on function public.platform_list_account_signups_v160(text,integer)
  from public,anon,authenticated;
grant execute on function public.platform_list_account_signups_v160(text,integer)
  to authenticated;

comment on function public.platform_list_account_signups_v160(text,integer) is
  'V164 Super Admin visibility for recent Auth-only business signups, including platform triage status. Rows remain CRM leads only until a business setup, Stripe checkout, or assisted application exists.';

commit;
