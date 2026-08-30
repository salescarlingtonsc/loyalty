-- nestly_v632 — one control marks the whole inbox read.
--
-- Owner ruling (photo 7, "Mark Read All" written into the Messages filter row). The gear moved to
-- the page head in v613; this is the control the owner drew in the space it left.
--
-- Why a server function rather than a loop in the browser:
--   • The page holds ONE page of the inbox. A client loop could only mark what it had fetched, so
--     "mark all read" would leave the badge showing a number the customer could not reach.
--   • It would be one round trip per message, and the customer whose inbox is worth clearing is
--     exactly the customer with the most of them.
--
-- Scope is the GLOBAL inbox, because that is the page the control sits on. Every clause here is
-- lifted from customer_get_in_app_inbox_global_count so the button and the badge can never
-- disagree about what "unread" means: the same identity, the same verified links, resolutions and
-- dismissals excluded, and the same source-availability gate.
--
-- Dismissal stays terminal, as customer_set_in_app_inbox_state established: a dismissed row is
-- skipped rather than being quietly re-read. And every event marked here still writes its own
-- operations row — the evidence trail does not get an exemption for being a bulk action. Those
-- rows carry a key DERIVED from the batch key, so a replayed batch collides with itself and
-- writes nothing new instead of minting a second history for the same act.
--
-- ROLLBACK: db/tests/v632_inbox_mark_all_read.sql

begin;

do $pre$
begin
  if to_regprocedure('app.c46_customer_inbox_global_context()') is null then
    raise exception 'v632: app.c46_customer_inbox_global_context() is missing — the identity scope this reuses';
  end if;
  if to_regprocedure('app.c46_inbox_source_available(text,boolean)') is null then
    raise exception 'v632: app.c46_inbox_source_available is missing — the availability gate the badge applies';
  end if;
  if to_regclass('public.customer_in_app_inbox_state') is null
     or to_regclass('public.customer_in_app_inbox_state_operations') is null then
    raise exception 'v632: the inbox state tables are absent';
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
  v_now timestamptz := statement_timestamp();
  v_actionable_source_available boolean;
  v_marked integer := 0;
begin
  if not app.platform_feature_enabled('customer_in_app_inbox') then
    raise exception 'customer in-app inbox is not enabled' using errcode='0A000';
  end if;
  if p_idempotency_key is null then
    raise exception 'invalid inbox state operation' using errcode='22023';
  end if;
  -- Raises for anyone who is not a verified customer identity; this function never resolves who
  -- the caller is by itself.
  select * into v_context from app.c46_customer_inbox_global_context();
  v_actionable_source_available := app.platform_feature_enabled('customer_actionable_wallet');

  perform pg_advisory_xact_lock(hashtextextended(
    'v632:inbox-read-all:'||v_context.identity_id::text||':'||p_idempotency_key::text,0
  ));

  with eligible as (
    select e.id, e.business_id, e.identity_id, e.auth_user_id, e.link_id, e.client_id
    from public.customer_in_app_inbox_events e
    join public.customer_links cl
      on cl.id = e.link_id and cl.business_id = e.business_id
     and cl.client_id = e.client_id and cl.identity_id = e.identity_id
     and cl.auth_user_id = v_context.auth_user_id and cl.state = 'verified'
    left join public.customer_in_app_inbox_state s on s.event_id = e.id
    left join public.customer_in_app_inbox_resolutions r on r.event_id = e.id
    where e.identity_id = v_context.identity_id
      and e.auth_user_id = v_context.auth_user_id
      and r.id is null
      and s.dismissed_at is null
      and s.read_at is null
      and app.c46_inbox_source_available(e.source_kind, v_actionable_source_available)
  ), marked as (
    insert into public.customer_in_app_inbox_state(
      event_id,business_id,identity_id,auth_user_id,link_id,client_id,read_at,dismissed_at
    )
    select e.id,e.business_id,e.identity_id,e.auth_user_id,e.link_id,e.client_id,v_now,null
    from eligible e
    -- A row can exist and still be unread (it was marked unread again), so the conflict arm is
    -- reachable. Dismissal remains terminal: a dismissed row is left exactly as it is.
    on conflict (event_id) do update
      set read_at = coalesce(public.customer_in_app_inbox_state.read_at, v_now)
      where public.customer_in_app_inbox_state.dismissed_at is null
    returning event_id,business_id,identity_id,auth_user_id,link_id,client_id
  ), evidence as (
    insert into public.customer_in_app_inbox_state_operations(
      event_id,business_id,identity_id,auth_user_id,link_id,client_id,
      operation,idempotency_key,request_hash,response
    )
    select m.event_id,m.business_id,m.identity_id,m.auth_user_id,m.link_id,m.client_id,
      'read',
      -- Derived, so replaying the SAME batch key collides with the rows it already wrote.
      md5(p_idempotency_key::text||':'||m.event_id::text)::uuid,
      app.c46_sha256_hex(jsonb_build_object(
        'batch',p_idempotency_key,'event_id',m.event_id,'operation','read'
      )::text),
      jsonb_build_object('event_id',m.event_id,'state','read')
    from marked m
    on conflict (identity_id,idempotency_key) do nothing
    returning 1
  )
  select count(*)::integer into v_marked from marked;

  return jsonb_build_object('status','ok','marked',v_marked);
end
$function$;

revoke all on function public.customer_mark_in_app_inbox_read_all_v632(uuid) from public, anon;
grant execute on function public.customer_mark_in_app_inbox_read_all_v632(uuid)
  to postgres, service_role, authenticated;

commit;
