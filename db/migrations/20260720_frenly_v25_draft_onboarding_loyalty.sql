-- FRENLY v25 - ONBOARDING LOYALTY IS A DRAFT, NEVER AUTO-ACTIVE
-- Local review candidate. Do not apply until the phase release gate is accepted.

begin;

alter table public.loyalty_programs
  add column if not exists configuration_status text,
  add column if not exists recommendation_source text;

-- Every pre-v25 row was deliberately configured under the old model; preserve that state.
update public.loyalty_programs
   set configuration_status = 'published'
 where configuration_status is null;

alter table public.loyalty_programs
  alter column configuration_status set default 'draft',
  alter column configuration_status set not null;

alter table public.loyalty_programs
  drop constraint if exists loyalty_programs_configuration_status_check;
alter table public.loyalty_programs
  add constraint loyalty_programs_configuration_status_check
  check (
    configuration_status in ('draft', 'published')
    and (configuration_status <> 'draft' or not active)
  );

comment on column public.loyalty_programs.configuration_status is
  'draft = editable recommendation that has no earn/redeem effect; published = owner accepted.';
comment on column public.loyalty_programs.recommendation_source is
  'Provenance for a generated draft, for example onboarding_preset or imported_data_rules_v1.';

create or replace function public.create_business(
  p_name text,
  p_slug text,
  p_industry text,
  p_modules text[]
)
returns json
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_uid uuid := auth.uid();
  v_business public.businesses%rowtype;
  v_staff uuid;
  v_branch uuid;
begin
  if v_uid is null then raise exception 'sign in required' using errcode = '42501'; end if;
  if p_name is null or length(btrim(p_name)) < 2 then raise exception 'business name required'; end if;

  insert into public.businesses (name, slug, industry, enabled_modules)
  values (
    btrim(p_name), p_slug, coalesce(p_industry, 'other'),
    coalesce(p_modules, array['dashboard','clients','sales','loyalty','retention','referrals'])
  ) returning * into v_business;

  insert into public.staff (business_id, user_id, role, full_name)
  values (v_business.id, v_uid, 'owner', coalesce(auth.jwt()->>'email', 'Owner'))
  returning id into v_staff;

  insert into public.branches (business_id, name, is_default, active)
  values (v_business.id, btrim(p_name), true, true)
  returning id into v_branch;
  insert into public.staff_branches (business_id, staff_id, branch_id)
  values (v_business.id, v_staff, v_branch);

  -- A neutral, simple starting point for the editor. It cannot affect customer balances until
  -- the owner reviews and publishes it; later rule-based recommendations replace this source.
  insert into public.loyalty_programs (
    business_id, kind, earn_points_per_dollar, redeem_points,
    reward_credit_cents, active, loyalty_model, configuration_status,
    recommendation_source
  ) values (
    v_business.id, 'points', 1, 800, 2000, false, 'classic', 'draft',
    'onboarding_preset'
  );

  -- Preserve the v14 onboarding side effect from the deployed function. The
  -- loyalty draft change must not silently create an unsubscribed workspace.
  insert into public.subscriptions (business_id) values (v_business.id)
  on conflict (business_id) do nothing;

  insert into public.audit_log (business_id, actor, action, entity, entity_id, detail)
  values (
    v_business.id, v_uid, 'ONBOARD', 'businesses', v_business.id,
    json_build_object(
      'name', v_business.name, 'industry', v_business.industry,
      'loyalty_configuration_status', 'draft'
    )::jsonb
  );
  return row_to_json(v_business);
end $$;

revoke all on function public.create_business(text, text, text, text[]) from public, anon;
grant execute on function public.create_business(text, text, text, text[]) to authenticated;

commit;
