-- NESTLY v202a — a branch becomes usable when its billing command completes, and not before.
--
-- Deliberately a TRIGGER rather than an edit to apply_stripe_billing_event_v77 or
-- complete_billing_command_v77. Both of those are on the live payment path for every
-- existing command type; reshaping them to teach them about branches would put unrelated
-- billing at risk for a feature that only needs to observe one status transition.
-- This fires on exactly that transition and touches nothing else.

begin;

create or replace function app.activate_branch_on_paid_command_v202()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
begin
  if new.requested_branch_id is not null
     and new.status = 'completed'
     and coalesce(old.status,'') is distinct from 'completed' then
    update public.branches
       set billing_state = 'active', active = true, updated_at = now()
     where id = new.requested_branch_id
       and business_id = new.business_id
       and billing_state = 'pending_payment';
  end if;
  return new;
end
$$;

drop trigger if exists activate_branch_on_paid_command_v202 on public.billing_commands;
create trigger activate_branch_on_paid_command_v202
  after update of status on public.billing_commands
  for each row
  execute function app.activate_branch_on_paid_command_v202();

commit;
