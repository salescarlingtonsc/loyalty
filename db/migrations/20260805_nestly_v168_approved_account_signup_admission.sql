begin;

create or replace function public.complete_business_google_oauth_v138(
  p_intent text,
  p_attempt_token text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();
  v_token_hash text;
  v_attempt app.business_google_oauth_attempts_v138%rowtype;
begin
  if v_actor is null or p_intent not in ('signin','signup') then
    raise exception 'authenticated Google OAuth admission required' using errcode='28000';
  end if;
  if not exists(select 1 from auth.identities identity_row
      where identity_row.user_id=v_actor and identity_row.provider='google') then
    raise exception 'Google identity required' using errcode='42501';
  end if;
  if p_intent='signin' then
    if exists(select 1 from public.staff staff_row
        where staff_row.user_id=v_actor and staff_row.active) then
      return jsonb_build_object('admitted',true,'intent','signin',
        'legal_recorded',false,'replayed',false);
    end if;

    if exists(
      select 1
        from public.platform_account_signup_triage_v164 triage
        join auth.users user_row on user_row.id=triage.auth_user_id
       where triage.auth_user_id=v_actor
         and triage.triage_status='contacted'
         and (
           coalesce(user_row.raw_user_meta_data->>'account_type','')='business_owner'
           or exists(
             select 1
               from app.business_account_legal_acceptances_v138 acceptance
              where acceptance.auth_user_id=v_actor
                and acceptance.source='google_oauth_signup'
           )
         )
         and not exists(select 1 from public.staff staff_row
           where staff_row.user_id=v_actor and staff_row.active)
         and not exists(select 1 from public.self_serve_business_onboarding_v130 onboarding
           where onboarding.owner_user_id=v_actor)
         and not exists(select 1 from public.business_applications_v95 application
           where lower(application.owner_email)=lower(coalesce(user_row.email,'')))
    ) then
      return jsonb_build_object('admitted',true,'intent','signin',
        'legal_recorded',false,'replayed',false,
        'requires_business_setup',true,
        'reason','platform_account_signup_approved');
    end if;

    raise exception 'existing active business account or approved setup request required'
      using errcode='42501';
  end if;
  if lower(btrim(coalesce(p_attempt_token,'')))
       !~'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' then
    raise exception 'server-recorded Google signup consent required' using errcode='42501';
  end if;
  v_token_hash:=app.v31_sha256_hex(lower(btrim(p_attempt_token)));
  select * into v_attempt from app.business_google_oauth_attempts_v138
   where token_sha256=v_token_hash for update;
  if not found then
    raise exception 'server-recorded Google signup consent required' using errcode='42501';
  end if;
  if v_attempt.consumed_by is not null then
    if v_attempt.consumed_by<>v_actor or not exists(
      select 1 from app.business_account_legal_acceptances_v138 acceptance
       where acceptance.source='google_oauth_signup'
         and acceptance.auth_user_id=v_actor
         and acceptance.idempotency_key=v_attempt.idempotency_key
         and acceptance.request_sha256=v_attempt.request_sha256
    ) then
      raise exception 'Google signup consent attempt was already consumed'
        using errcode='42501';
    end if;
    return jsonb_build_object('admitted',true,'intent','signup',
      'legal_recorded',true,'replayed',true);
  end if;
  if v_attempt.expires_at<=now() then
    raise exception 'Google signup consent attempt expired' using errcode='42501';
  end if;
  if not exists(select 1 from app.customer_legal_documents document
      where document.document_key='terms' and document.active
        and document.document_version=v_attempt.terms_version
        and document.document_sha256=v_attempt.terms_sha256)
     or not exists(select 1 from app.customer_legal_documents document
      where document.document_key='privacy' and document.active
        and document.document_version=v_attempt.privacy_version
        and document.document_sha256=v_attempt.privacy_sha256) then
    raise exception 'accepted legal documents are no longer current' using errcode='42501';
  end if;
  update app.business_google_oauth_attempts_v138
     set consumed_by=v_actor,consumed_at=now()
   where token_sha256=v_token_hash and consumed_by is null;
  if not found then
    raise exception 'Google signup consent attempt could not be consumed'
      using errcode='40001';
  end if;
  insert into app.business_account_legal_acceptances_v138(
    auth_user_id,source,terms_version,terms_sha256,
    privacy_version,privacy_sha256,accepted_at,idempotency_key,request_sha256
  ) values(
    v_actor,'google_oauth_signup',v_attempt.terms_version,v_attempt.terms_sha256,
    v_attempt.privacy_version,v_attempt.privacy_sha256,v_attempt.accepted_at,
    v_attempt.idempotency_key,v_attempt.request_sha256
  );
  return jsonb_build_object('admitted',true,'intent','signup',
    'legal_recorded',true,'replayed',false);
end
$$;

revoke all on function public.complete_business_google_oauth_v138(text,text)
  from public,anon;
grant execute on function public.complete_business_google_oauth_v138(text,text)
  to authenticated;

comment on function public.complete_business_google_oauth_v138(text,text) is
  'V168 authenticated Google-only admission: active staff may sign in; platform-approved account-only business signups may sign in to continue setup; signup consumes one server-recorded legal acceptance.';

commit;
