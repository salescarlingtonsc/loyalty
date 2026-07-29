begin;

create table if not exists public.workspace_locale_preferences_v97 (
  auth_user_id uuid primary key references auth.users(id) on delete cascade,
  locale text not null default 'en'
    check (locale in ('en','zh-CN','ms')),
  version bigint not null default 1 check (version > 0),
  updated_at timestamptz not null default now()
);

alter table public.workspace_locale_preferences_v97 enable row level security;
revoke all on table public.workspace_locale_preferences_v97 from public,anon,authenticated;

create or replace function public.get_workspace_locale_preference_v97()
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog,public,app,pg_temp
as $$
declare
  v_user uuid:=auth.uid();
  v_row public.workspace_locale_preferences_v97%rowtype;
begin
  if v_user is null then
    raise exception using errcode='42501',message='authentication required';
  end if;
  select * into v_row
    from public.workspace_locale_preferences_v97
   where auth_user_id=v_user;
  return jsonb_build_object(
    'locale',coalesce(v_row.locale,'en'),
    'version',coalesce(v_row.version,0)
  );
end
$$;

create or replace function public.set_workspace_locale_preference_v97(
  p_locale text,p_expected_version bigint
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog,public,app,pg_temp
as $$
declare
  v_user uuid:=auth.uid();
  v_row public.workspace_locale_preferences_v97%rowtype;
begin
  if v_user is null then
    raise exception using errcode='42501',message='authentication required';
  end if;
  if p_locale is null or p_locale not in ('en','zh-CN','ms')
     or p_expected_version is null or p_expected_version < 0 then
    raise exception using errcode='22023',message='invalid locale preference';
  end if;

  insert into public.workspace_locale_preferences_v97(
    auth_user_id,locale,version,updated_at
  ) values(v_user,p_locale,1,now())
  on conflict(auth_user_id) do update
    set locale=excluded.locale,
        version=public.workspace_locale_preferences_v97.version+1,
        updated_at=now()
    where public.workspace_locale_preferences_v97.version=p_expected_version
  returning * into v_row;

  if v_row.auth_user_id is null then
    raise exception using errcode='40001',message='workspace locale preference changed; refresh and retry';
  end if;
  if p_expected_version<>0 and v_row.version<>p_expected_version+1 then
    raise exception using errcode='40001',message='workspace locale preference changed; refresh and retry';
  end if;
  return jsonb_build_object('locale',v_row.locale,'version',v_row.version);
end
$$;

revoke all on function public.get_workspace_locale_preference_v97() from public;
revoke all on function public.set_workspace_locale_preference_v97(text,bigint) from public;
grant execute on function public.get_workspace_locale_preference_v97() to authenticated;
grant execute on function public.set_workspace_locale_preference_v97(text,bigint) to authenticated;

alter table public.business_applications_v95
  drop constraint if exists business_applications_v95_preferred_locale_check;
alter table public.business_applications_v95
  add constraint business_applications_v95_preferred_locale_check
  check(preferred_locale in ('en','zh-CN','ms'));

create or replace function public.internal_submit_business_application_v95(
  p_contact_name text,p_contact_email text,p_contact_phone text,
  p_business_name text,p_sector_key text,p_registration_number text,
  p_locale text,p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_email text:=lower(btrim(coalesce(p_contact_email,'')));
  v_hash text;
  v_application public.business_applications_v95%rowtype;
begin
  if p_idempotency_key is null
     or length(btrim(coalesce(p_contact_name,''))) not between 2 and 120
     or v_email!~'^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
     or coalesce(p_contact_phone,'')!~'^\+[1-9][0-9]{7,14}$'
     or length(btrim(coalesce(p_business_name,''))) not between 2 and 160
     or coalesce(p_locale,'') not in ('en','zh-CN','ms')
  then raise exception 'valid business application fields are required'
    using errcode='22023';end if;
  if not exists(
    select 1 from public.sector_bundle_versions bundle
    where bundle.sector_key=p_sector_key and bundle.status='published'
  ) then raise exception 'published_sector_required' using errcode='22023';end if;
  v_hash:=app.v95_sha256(concat_ws('|',
    btrim(p_contact_name),v_email,p_contact_phone,btrim(p_business_name),
    p_sector_key,btrim(coalesce(p_registration_number,'')),p_locale
  ));
  select * into v_application from public.business_applications_v95
  where idempotency_key=p_idempotency_key;
  if found then
    if v_application.request_hash<>v_hash then
      raise exception 'application_idempotency_conflict' using errcode='22023';
    end if;
    return jsonb_build_object(
      'application_id',v_application.id,
      'public_reference',v_application.public_reference,
      'status',v_application.status,'version',v_application.version,
      'replayed',true
    );
  end if;
  if exists(
    select 1 from public.business_applications_v95 application
    where application.contact_email=v_email
      and application.status in ('submitted','approved')
  ) then
    raise exception 'open_application_already_exists' using errcode='23505';
  end if;
  insert into public.business_applications_v95(
    idempotency_key,request_hash,contact_name,contact_email,contact_phone,
    business_name,sector_key,registration_number,preferred_locale
  ) values(
    p_idempotency_key,v_hash,btrim(p_contact_name),v_email,p_contact_phone,
    btrim(p_business_name),p_sector_key,
    nullif(btrim(coalesce(p_registration_number,'')),''),
    p_locale
  ) returning * into v_application;
  insert into public.business_application_audit_v95(
    application_id,event_type,new_status,reason,detail
  ) values(
    v_application.id,'submitted','submitted',
    'public pre-auth business application submitted',
    jsonb_build_object('sector_key',p_sector_key,'preferred_locale',p_locale)
  );
  return jsonb_build_object(
    'application_id',v_application.id,
    'public_reference',v_application.public_reference,
    'status','submitted','version',1,'replayed',false
  );
end
$$;
revoke all on function public.internal_submit_business_application_v95(
  text,text,text,text,text,text,text,uuid
) from public,anon,authenticated;
grant execute on function public.internal_submit_business_application_v95(
  text,text,text,text,text,text,text,uuid
) to service_role;

commit;
