-- NESTLY v85 — repair the v79 polymorphic conversion/activation trigger.
--
-- v79 installed one trigger function on businesses and branches. Its ELSIF
-- expression dereferenced OLD.active before PostgreSQL could safely narrow the
-- trigger record to branches, so an ordinary businesses UPDATE raised
-- `record "old" has no field "active"`. Keep the original controls unchanged,
-- but branch explicitly on TG_TABLE_NAME before reading table-specific fields.

begin;

create or replace function app.guard_converted_workspace_activation_v79()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if coalesce(current_setting('app.v79_system_transition', true), '') = 'on' then
    return new;
  end if;

  if tg_table_name = 'businesses' then
    if old.source_prospect_id is not null and (
      new.source_prospect_id is distinct from old.source_prospect_id
      or new.onboarding_started_at is distinct from old.onboarding_started_at
      or new.activated_at is distinct from old.activated_at
      or new.legal_name is distinct from old.legal_name
      or new.registration_number is distinct from old.registration_number
    ) then
      raise exception 'converted workspace identity and activation are controlled by v79'
        using errcode = '42501';
    end if;
  elsif tg_table_name = 'branches' then
    if old.active = false
       and new.active = true
       and exists (
         select 1
           from public.businesses business
          where business.id = new.business_id
            and business.source_prospect_id is not null
       ) then
      raise exception 'converted workspace branch activation is controlled by v79'
        using errcode = '42501';
    end if;
  else
    raise exception 'v79 conversion guard is attached to an unexpected relation'
      using errcode = '55000';
  end if;

  return new;
end
$$;

revoke all on function app.guard_converted_workspace_activation_v79()
  from public, anon, authenticated;

commit;
