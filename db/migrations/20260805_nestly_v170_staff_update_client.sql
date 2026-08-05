-- V170: owners/staff with clients write access can correct a customer's details.
-- Closes the review blocker "a customer's name, phone or email can never be corrected".
-- APPLIED TO PRODUCTION 2026-08-05 via MCP apply_migration (nestly_v170_staff_update_client),
-- after a rolled-back anon-denial check. Authorization mirrors public.staff_create_client:
-- active staff row + clients-module write at the business. Consent transitions write a
-- consents event, matching the create path. Every change is audited with before/after values.
begin;

create or replace function public.staff_update_client_v170(
  p_business uuid,
  p_client uuid,
  p_full_name text,
  p_phone text default null,
  p_email text default null,
  p_birth_date date default null,
  p_gender text default null,
  p_marketing_consent boolean default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_name text := nullif(btrim(p_full_name), '');
  v_phone text := nullif(btrim(p_phone), '');
  v_email text := nullif(lower(btrim(p_email)), '');
  v_gender text := nullif(lower(btrim(p_gender)), '');
  v_before public.clients%rowtype;
  v_client public.clients%rowtype;
  v_consent boolean;
begin
  if v_actor is null or not app.can_module_write(p_business, 'clients') then
    raise exception 'active clients-module write authorization is required'
      using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.staff s
     where s.business_id = p_business and s.user_id = v_actor and s.active
  ) then
    raise exception 'active staff authorization is required' using errcode = '42501';
  end if;
  if p_client is null or v_name is null or char_length(v_name) < 2
     or char_length(v_name) > 200
     or (v_gender is not null and v_gender not in ('female','male','other'))
     or (v_phone is not null and char_length(v_phone) > 80)
     or (v_email is not null and char_length(v_email) > 320) then
    raise exception 'invalid customer request' using errcode = '22023';
  end if;

  select * into v_before from public.clients c
   where c.id = p_client and c.business_id = p_business
   for update;
  if not found then
    raise exception 'customer_not_found' using errcode = '22023';
  end if;

  v_consent := coalesce(p_marketing_consent, v_before.marketing_consent);

  begin
    update public.clients
       set full_name = v_name,
           phone = v_phone,
           email = v_email,
           birth_date = p_birth_date,
           gender = v_gender,
           marketing_consent = v_consent
     where id = p_client and business_id = p_business
     returning * into v_client;
  exception when unique_violation then
    raise exception 'phone_already_used_by_another_customer' using errcode = '23505';
  end;

  if v_consent is distinct from v_before.marketing_consent then
    insert into public.consents (business_id, client_id, channel, action, source, actor)
    values (p_business, p_client, 'marketing',
      case when v_consent then 'granted' else 'withdrawn' end,
      'staff customer edit', v_actor);
  end if;

  insert into public.audit_log (business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'CLIENT_UPDATED_V170', 'clients', p_client,
    jsonb_build_object(
      'before', jsonb_build_object('full_name', v_before.full_name, 'phone', v_before.phone,
        'email', v_before.email, 'birth_date', v_before.birth_date, 'gender', v_before.gender,
        'marketing_consent', v_before.marketing_consent),
      'after', jsonb_build_object('full_name', v_client.full_name, 'phone', v_client.phone,
        'email', v_client.email, 'birth_date', v_client.birth_date, 'gender', v_client.gender,
        'marketing_consent', v_client.marketing_consent)));

  return jsonb_build_object(
    'status', 'completed', 'client_id', v_client.id,
    'full_name', v_client.full_name, 'phone', v_client.phone, 'email', v_client.email,
    'birth_date', v_client.birth_date, 'gender', v_client.gender,
    'marketing_consent', v_client.marketing_consent);
end
$$;

revoke all on function public.staff_update_client_v170(uuid,uuid,text,text,text,date,text,boolean)
  from public, anon;
grant execute on function public.staff_update_client_v170(uuid,uuid,text,text,text,date,text,boolean)
  to authenticated;

comment on function public.staff_update_client_v170(uuid,uuid,text,text,text,date,text,boolean) is
  'V170: staff with clients write access correct a customer record; consent transitions write a consents event; before/after audited. Closes the "customer can never be edited" blocker.';

commit;
