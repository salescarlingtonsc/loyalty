begin;

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
    select user_row.*
      from auth.users user_row
     where user_row.created_at >= now()-interval '30 days'
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
      end
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
         where user_row.created_at >= now()-interval '30 days'
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
  'V160 Super Admin read-only visibility for recent Auth-only business signups that have not yet created a business, self-serve onboarding row, or assisted application.';

commit;
