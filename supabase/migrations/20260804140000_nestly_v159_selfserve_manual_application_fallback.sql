begin;

create or replace function public.request_self_serve_manual_application_v159(
  p_contact_name text,
  p_contact_phone text,
  p_business_name text,
  p_sector_key text,
  p_registration_number text,
  p_locale text,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();
  v_email text;
  v_application jsonb;
begin
  if v_actor is null then
    raise exception 'authenticated owner account required'
      using errcode='28000';
  end if;

  select lower(email) into v_email
    from auth.users
   where id=v_actor
     and coalesce(email_confirmed_at,confirmed_at) is not null;

  if v_email is null then
    raise exception 'confirmed owner email required'
      using errcode='42501';
  end if;

  if exists(select 1 from public.staff where user_id=v_actor) then
    raise exception 'this account is already assigned to a business workspace'
      using errcode='42501';
  end if;

  v_application:=public.internal_submit_business_application_v95(
    p_contact_name,
    v_email,
    p_contact_phone,
    p_business_name,
    p_sector_key,
    p_registration_number,
    p_locale,
    p_idempotency_key
  );

  if coalesce((v_application->>'replayed')::boolean,false) is false then
    insert into public.audit_log(
      business_id,actor,action,entity,entity_id,detail
    ) values(
      null,v_actor,'SELF_SERVICE_MANUAL_APPLICATION_REQUESTED_V159',
      'business_applications_v95',(v_application->>'application_id')::uuid,
      jsonb_build_object(
        'source','self_serve_checkout_unavailable',
        'public_reference',v_application->>'public_reference',
        'replayed',false
      )
    );
  end if;

  return v_application||jsonb_build_object(
    'submitted_for_manual_help',true,
    'contact_email',v_email
  );
end
$$;

revoke all on function public.request_self_serve_manual_application_v159(
  text,text,text,text,text,text,uuid
) from public,anon,authenticated;
grant execute on function public.request_self_serve_manual_application_v159(
  text,text,text,text,text,text,uuid
) to authenticated;

comment on function public.request_self_serve_manual_application_v159(
  text,text,text,text,text,text,uuid
) is
  'V159 authenticated fallback: when Stripe checkout catalogue is unavailable or the owner needs bank/cash handling, capture one admin-visible assisted application without activating access.';

commit;
