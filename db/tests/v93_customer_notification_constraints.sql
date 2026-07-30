begin;

do $v93_customer_notification_constraints_acceptance$
declare
  v_title_definition text;
  v_body_definition text;
begin
  select pg_get_constraintdef(c.oid)
    into v_title_definition
    from pg_constraint c
   where c.conrelid = 'public.customer_in_app_inbox_events'::regclass
     and c.conname = 'customer_in_app_inbox_events_title_check';
  select pg_get_constraintdef(c.oid)
    into v_body_definition
    from pg_constraint c
   where c.conrelid = 'public.customer_in_app_inbox_events'::regclass
     and c.conname = 'customer_in_app_inbox_events_body_check';

  if v_title_definition not like '%Points expire tomorrow%'
     or v_title_definition not like '%Appointment time changed%'
     or v_title_definition not like '%Stamps expire within 3 days%'
     or v_title_definition not like '%Reward unlocked!%'
     or v_title_definition not like '%Quest almost complete%'
     or v_title_definition not like '%Birthday surprise unlocked%'
     or v_body_definition not like '%Open this programme now to review your expiring points.%'
     or v_body_definition not like '%Open this business wallet to review your updated appointment.%'
     or v_body_definition not like '%Open this programme to view and redeem your reward.%' then
    raise exception 'v93 customer notification copy constraints are incomplete';
  end if;

end
$v93_customer_notification_constraints_acceptance$;

rollback;
