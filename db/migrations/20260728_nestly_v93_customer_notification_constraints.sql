-- NESTLY v93 - CUSTOMER NOTIFICATION CONSTRAINT REPAIR
--
-- v91 introduced truthful urgent-window and game notification copy while the
-- deployed v48 table still allowed only its finite copy. This
-- forward-only repair advances that exact predecessor constraint state. It is
-- idempotent only for the reviewed predecessor and final definitions and
-- refuses unknown drift.

begin;

lock table public.customer_in_app_inbox_events in share row exclusive mode;

do $v93_customer_notification_constraints$
declare
  v_title_definition text;
  v_body_definition text;
  v_title_values text[];
  v_body_values text[];
  v_predecessor_titles constant text[] := array[
    'A reward is ready', 'Appointment request received', 'Appointment time changed',
    'Birthday benefit ready', 'One visit to go', 'Points expire soon', 'Stamps expire soon'
  ];
  v_final_titles constant text[] := array[
    'A reward is ready', 'Appointment request received', 'Appointment time changed',
    'Birthday benefit ready',
    'Birthday surprise unlocked', 'One visit to go', 'Points expire soon',
    'Points expire tomorrow', 'Points expire within 3 days', 'Quest almost complete',
    'Reward unlocked!', 'Stamps expire soon', 'Stamps expire tomorrow',
    'Stamps expire within 3 days'
  ];
  v_predecessor_bodies constant text[] := array[
    'One qualifying visit remains before your next reward.',
    'Open this business wallet to review your appointment request.',
    'Open this business wallet to review your points.',
    'Open this business wallet to review your stamps.',
    'Open this business wallet to review your updated appointment.',
    'Open this business wallet to view the available reward.',
    'Open this business wallet to view your birthday benefit.'
  ];
  v_final_bodies constant text[] := array[
    'One qualifying visit remains before your next reward.',
    'Open this business wallet to review your appointment request.',
    'Open this business wallet to review your points.',
    'Open this business wallet to review your stamps.',
    'Open this business wallet to review your updated appointment.',
    'Open this business wallet to view the available reward.',
    'Open this business wallet to view your birthday benefit.',
    'Open this programme now to review your expiring points.',
    'Open this programme now to review your expiring stamps.',
    'Open this programme to view and redeem your reward.',
    'Open this programme to view your birthday benefit.'
  ];
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

  if v_title_definition is null or v_body_definition is null then
    raise exception 'customer inbox copy constraints are missing'
      using errcode = '23514';
  end if;

  if v_title_definition !~ '^CHECK \(\(title = ANY \(ARRAY\['
     or v_title_definition !~ '\]\)\)\)$'
     or v_body_definition !~ '^CHECK \(\(body = ANY \(ARRAY\['
     or v_body_definition !~ '\]\)\)\)$'
     or v_title_definition ~* '\m(or|and|select|case)\M'
     or v_body_definition ~* '\m(or|and|select|case)\M' then
    raise exception 'customer inbox copy constraints have an unexpected expression shape'
      using errcode = '23505';
  end if;

  select array_agg(m[1] order by m[1])
    into v_title_values
    from regexp_matches(v_title_definition, '''([^'']*)''(?:::text)?', 'g') m;
  select array_agg(m[1] order by m[1])
    into v_body_values
    from regexp_matches(v_body_definition, '''([^'']*)''(?:::text)?', 'g') m;

  if v_title_values = v_final_titles and v_body_values = v_final_bodies then
    return;
  end if;

  if v_title_values <> v_predecessor_titles
     or v_body_values <> v_predecessor_bodies then
    raise exception 'customer inbox copy constraints do not match the reviewed v48 predecessor'
      using errcode = '23505';
  end if;

  alter table public.customer_in_app_inbox_events
    drop constraint customer_in_app_inbox_events_title_check,
    drop constraint customer_in_app_inbox_events_body_check,
    add constraint customer_in_app_inbox_events_title_check check (title in (
      'Points expire soon', 'Stamps expire soon', 'A reward is ready', 'One visit to go',
      'Birthday benefit ready', 'Appointment request received',
      'Appointment time changed',
      'Points expire tomorrow', 'Stamps expire tomorrow',
      'Points expire within 3 days', 'Stamps expire within 3 days',
      'Reward unlocked!', 'Quest almost complete', 'Birthday surprise unlocked'
    )),
    add constraint customer_in_app_inbox_events_body_check check (body in (
      'Open this business wallet to review your points.',
      'Open this business wallet to review your stamps.',
      'Open this business wallet to view the available reward.',
      'One qualifying visit remains before your next reward.',
      'Open this business wallet to view your birthday benefit.',
      'Open this business wallet to review your appointment request.',
      'Open this business wallet to review your updated appointment.',
      'Open this programme now to review your expiring points.',
      'Open this programme now to review your expiring stamps.',
      'Open this programme to view and redeem your reward.',
      'Open this programme to view your birthday benefit.'
    ));
end
$v93_customer_notification_constraints$;

commit;
