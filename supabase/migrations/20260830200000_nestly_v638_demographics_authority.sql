-- NESTLY v638 — Phase A, M12 (A15/D4): one authority for customer demographics.
-- Two independently-captured DOB/gender pairs exist (business-side clients.* vs the
-- wallet's customer_profiles.*) with mismatched gender enums, and they can silently
-- diverge. Owner ruling D4: where a VERIFIED customer link exists, the customer's own
-- attested wallet values win for analytics; merchants consume a derived AGE BAND, never
-- the raw wallet birth date; gender is optional with first-class "prefer not to say";
-- staff never guess. Conflicts are surfaced, never silently merged.
--
-- Enum reconciliation (additive only — no existing value is rewritten):
--   clients.gender:            female|male|other            -> + prefer_not_to_say
--   customer_profiles.gender:  female|male                  -> + other, prefer_not_to_say
begin;

alter table public.clients drop constraint clients_gender_check;
alter table public.clients add constraint clients_gender_check
  check (gender = any (array['female'::text,'male'::text,'other'::text,'prefer_not_to_say'::text]));

alter table public.customer_profiles drop constraint customer_profiles_gender_check;
alter table public.customer_profiles add constraint customer_profiles_gender_check
  check (gender = any (array['female'::text,'male'::text,'other'::text,'prefer_not_to_say'::text]));

-- The authority. Returns band + gender + provenance; NEVER a raw wallet birth date.
-- Bands: under_20, 20_24, 25_30, 31_40, 41_50, 51_plus (the blueprint's segmentation grain).
create or replace function app.customer_demographics_v1(p_business uuid, p_client uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_client public.clients%rowtype;
  v_wallet_birth date;
  v_wallet_gender text;
  v_birth date;
  v_gender text;
  v_source text;
  v_conflict boolean := false;
  v_age integer;
  v_band text;
begin
  if auth.uid() is null
     or not (app.is_salon_member(p_business) or app.is_super_admin()) then
    raise exception 'business membership is required' using errcode = '42501';
  end if;
  select * into v_client from public.clients
   where id = p_client and business_id = p_business;
  if not found then
    raise exception 'client not found' using errcode = '22023';
  end if;

  select cp.birth_date, cp.gender
    into v_wallet_birth, v_wallet_gender
    from public.customer_links cl
    join public.customer_profiles cp on cp.identity_id = cl.identity_id
   where cl.business_id = p_business
     and cl.client_id = p_client
     and cl.state = 'verified'
   limit 1;

  if v_wallet_birth is not null or v_wallet_gender is not null then
    v_birth := coalesce(v_wallet_birth, v_client.birth_date);
    v_gender := coalesce(v_wallet_gender, v_client.gender);
    v_source := 'customer_attested';
    v_conflict :=
      (v_wallet_birth is not null and v_client.birth_date is not null
        and v_wallet_birth <> v_client.birth_date)
      or (v_wallet_gender is not null and v_client.gender is not null
        and v_wallet_gender <> v_client.gender);
  else
    v_birth := v_client.birth_date;
    v_gender := v_client.gender;
    v_source := case when v_birth is null and v_gender is null
                     then 'none' else 'staff_entered' end;
  end if;

  if v_birth is not null then
    v_age := date_part('year', age(current_date, v_birth))::integer;
    v_band := case
      when v_age < 20 then 'under_20'
      when v_age <= 24 then '20_24'
      when v_age <= 30 then '25_30'
      when v_age <= 40 then '31_40'
      when v_age <= 50 then '41_50'
      else '51_plus' end;
  end if;

  return jsonb_build_object(
    'age_band', v_band,
    'gender', case when v_gender = 'prefer_not_to_say' then null else v_gender end,
    'gender_declared', v_gender is not null,
    'source', v_source,
    'conflict', v_conflict
  );
end;
$$;
revoke all on function app.customer_demographics_v1(uuid,uuid) from public, anon;
grant execute on function app.customer_demographics_v1(uuid,uuid) to authenticated, service_role;

commit;
