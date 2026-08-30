-- nestly_v641 — mark-all-read goes through the per-event RPC, because the database insists.
--
-- Owner report: "mark all read - does not work". It never could. v632 wrote
-- public.customer_in_app_inbox_state with a set-based INSERT ... ON CONFLICT, and that table
-- carries app.c46_inbox_state_guard, a BEFORE ROW trigger that refuses ANY write whose row does
-- not match the `app.c46_inbox_state_event` setting:
--
--     if v_write_event is distinct from new.event_id::text then
--       raise exception 'customer inbox state may only be changed through its operation RPC'
--
-- One statement cannot carry a different setting per row, so the guard rejected the first row
-- every time and the customer saw "Those messages could not be marked read."
--
-- The guard is right and this function was wrong. Its whole purpose is that inbox state has ONE
-- writer — customer_set_in_app_inbox_state, which sets that marker, honours dismissal as terminal,
-- and records an operations row. So this is now a loop that calls it, once per eligible event,
-- with a key DERIVED from the batch key so a replayed batch replays each event rather than
-- minting a second history. Nothing about what "read" means, or what evidence it leaves, lives
-- here any more.
--
-- The selection is unchanged and still lifted clause-for-clause from
-- customer_get_in_app_inbox_global_count, so the button and the badge cannot disagree about what
-- is unread. The business slug joins the read because the per-event RPC is addressed by slug.
--
-- WHY THIS WAS NOT CAUGHT: v632's suite proved the function's SHAPE and proved that a caller with
-- no customer identity is refused — but it never executed the happy path against a real identity.
-- v641's suite does, and that is the check that would have caught this on the day.
--
-- ROLLBACK: db/tests/v641_inbox_mark_all_read.sql

begin;

do $pre$
begin
  if to_regprocedure('public.customer_set_in_app_inbox_state(text,uuid,text,uuid)') is null then
    raise exception 'v635: customer_set_in_app_inbox_state is missing — the one writer this delegates to';
  end if;
  if not exists(
    select 1 from pg_trigger t join pg_class c on c.oid=t.tgrelid
    where c.relname='customer_in_app_inbox_state' and t.tgname='customer_in_app_inbox_state_guard'
  ) then
    raise exception 'v635: the inbox state guard is gone — this delegation exists because of it';
  end if;
end
$pre$;

create or replace function public.customer_mark_in_app_inbox_read_all_v632(
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $function$
declare
  v_context record;
  v_actionable_source_available boolean;
  v_marked integer := 0;
  v_event record;
begin
  if not app.platform_feature_enabled('customer_in_app_inbox') then
    raise exception 'customer in-app inbox is not enabled' using errcode='0A000';
  end if;
  if p_idempotency_key is null then
    raise exception 'invalid inbox state operation' using errcode='22023';
  end if;
  -- Raises for anyone who is not a verified customer identity; this function never decides who
  -- the caller is by itself.
  select * into v_context from app.c46_customer_inbox_global_context();
  v_actionable_source_available := app.platform_feature_enabled('customer_actionable_wallet');

  /* Every clause below is one customer_get_in_app_inbox_global_count applies, so the button
     clears exactly what the badge counts. The rows are read into a loop rather than written in
     one statement because app.c46_inbox_state_guard demands a per-event marker that only
     customer_set_in_app_inbox_state sets — see the header. */
  for v_event in
    select e.id as event_id, business.slug as business_slug
    from public.customer_in_app_inbox_events e
    join public.customer_links cl
      on cl.id = e.link_id and cl.business_id = e.business_id
     and cl.client_id = e.client_id and cl.identity_id = e.identity_id
     and cl.auth_user_id = v_context.auth_user_id and cl.state = 'verified'
    join public.businesses business on business.id = e.business_id
    left join public.customer_in_app_inbox_state s on s.event_id = e.id
    left join public.customer_in_app_inbox_resolutions r on r.event_id = e.id
    where e.identity_id = v_context.identity_id
      and e.auth_user_id = v_context.auth_user_id
      and r.id is null
      and s.dismissed_at is null
      and s.read_at is null
      and app.c46_inbox_source_available(e.source_kind, v_actionable_source_available)
    order by e.id
  loop
    perform public.customer_set_in_app_inbox_state(
      v_event.business_slug,
      v_event.event_id,
      'read',
      -- Derived from the batch key, so replaying the same batch replays each event's own
      -- recorded operation instead of writing a second one.
      md5(p_idempotency_key::text||':'||v_event.event_id::text)::uuid
    );
    v_marked := v_marked + 1;
  end loop;

  return jsonb_build_object('status','ok','marked',v_marked);
end
$function$;

revoke all on function public.customer_mark_in_app_inbox_read_all_v632(uuid) from public, anon;
grant execute on function public.customer_mark_in_app_inbox_read_all_v632(uuid)
  to postgres, service_role, authenticated;

commit;
