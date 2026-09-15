-- NESTLY v951 — a caller-supplied page size has a floor AND a ceiling.
--
-- THE DEFECT. Three SECURITY DEFINER readers clamped their page size like this:
--
--     limit greatest(coalesce(p_limit, <default>), 1)
--
-- greatest() floors at 1 and caps at NOTHING. p_limit arrives from the browser over PostgREST, so
-- any signed-in member of the business could ask for `p_limit: 1000000` and the function would
-- build a single json_agg of every row it can see and return it in one response. RLS does not
-- bound it — these run as the definer; the only gate is membership, which the caller already has.
-- On a Micro instance one such call is a memory and CPU spike that every other tenant on the box
-- pays for. It is not a data-exposure bug (the membership gate still holds, and no row crosses a
-- tenant), which is exactly why it survived: nothing it does is *forbidden*, only unbounded.
--
-- WHY THESE THREE AND NOT EVERY p_limit. A scan of every function in public and app taking a
-- p_limit puts them in four groups. Most already carry the house clamp
-- `least(greatest(coalesce(p_limit, d), 1), cap)` — that shape is the convention this migration
-- restores, not a new invention. A second group validates instead of clamping
-- (`if p_limit not between 1 and N then raise`), which is equally bounded. A third group is
-- floor-only like these but is NOT executable by anon or authenticated — cron and service_role
-- sweeps (app.run_whatsapp_reminder_sweep_v557, app.migrate_programme_pot_v312 and friends) where
-- p_limit is an operator's batch size and capping it would silently change how much work a sweep
-- does per run. Those are deliberately untouched. What is left is this group: floor-only AND
-- reachable by `authenticated`, i.e. by anybody holding a browser session. All three carry the
-- identical ACL {postgres=X, service_role=X, authenticated=X} and the identical defect shape.
--
-- There is a fourth group this migration does NOT close and which is recorded here so the next
-- reader does not conclude the estate is clean: a number of public readers pass `limit p_limit`
-- with no clamp and no validation at all, so a NULL page size means no limit whatsoever
-- (get_billing_reconciliation_v77, get_platform_billing_v77, platform_get_finance_v146,
-- platform_get_catalogue_affinity_v94, preview_growth_recommendation_v108,
-- business_list_media_cleanup_queue_v95, platform_get_subscription_operations_v156 and others).
-- Each of those needs a cap that is a product decision about how much that surface may page, not
-- a mechanical substitution, so they are left for a ruling rather than guessed at here.
--
-- THE CHANGE, and it is the only change. Each body is reproduced from the live definition
-- verbatim — same comments, same projection, same ordering, same membership gate, same
-- search_path, same volatility — with one expression rewritten:
--
--     greatest(coalesce(p_limit, d), 1)   ->   least(greatest(coalesce(p_limit, d), 1), cap)
--
-- Nothing else moves. The caps are set above each function's own default so no existing caller
-- changes behaviour: the app asks get_notifications for 30 and the cap is 200; the support thread
-- defaults to 200 and the cap is 500; the conversation list defaults to 100 and the cap is 200.
-- A caller asking for more than the cap now gets the cap instead of an error, which is what every
-- already-clamped sibling in this estate does.
--
-- GRANTS are restated verbatim from the live proacl. CREATE OR REPLACE preserves them, but the
-- pending-migration preflight demands the exact overload signature, and restating what the
-- function actually had is the point — none of these three has ever been executable by anon, and
-- this migration must not be the thing that gives it one.
--
-- ROLLBACK SUITE: db/tests/v951_bounded_read_limits.sql — proves each cap holds against the real
-- production estate inside one transaction that ends in rollback.

begin;

-- 1 -------------------------------------------------------------------------------------------
-- public.get_notifications — the bell. p_limit is sent by app/app.js loadNotifications() as 30.
CREATE OR REPLACE FUNCTION public.get_notifications(p_business uuid, p_limit integer DEFAULT 30)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare v_result json;
begin
  if not app.is_salon_member(p_business) then raise exception 'not authorized'; end if;
  select json_build_object(
    'unread', (select count(*) from public.notifications where business_id = p_business and read_at is null),
    'items', coalesce((select json_agg(row_to_json(t)) from (
        select id, kind, title, body, ref_table, ref_id, created_at, read_at
        from public.notifications where business_id = p_business
        order by created_at desc
        -- nestly_v951: floor AND ceiling. greatest() alone let a caller ask for every
        -- notification this business has ever had, in one json_agg.
        limit least(greatest(coalesce(p_limit,30), 1), 200)
      ) t), '[]'::json)
  ) into v_result;
  return v_result;
end $function$;

revoke all on function public.get_notifications(uuid, integer) from public, anon;
grant execute on function public.get_notifications(uuid, integer) to authenticated, service_role;

-- 2 -------------------------------------------------------------------------------------------
-- public.business_support_get_thread_v531 — one WhatsApp support conversation's messages.
CREATE OR REPLACE FUNCTION public.business_support_get_thread_v531(p_business uuid, p_conversation uuid, p_limit integer DEFAULT 200)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_conversation public.support_conversations_v530%rowtype;
  v_messages jsonb;
  v_can boolean := false;
  v_reason text := null;
  v_state jsonb;
begin
  if not app.can_module_read(p_business, 'support') then
    raise exception 'support module read access required' using errcode = '42501';
  end if;

  select * into v_conversation from public.support_conversations_v530
   where id = p_conversation and business_id = p_business;
  if not found then
    raise exception 'conversation not found' using errcode = 'P0002';
  end if;

  select coalesce(jsonb_agg(entry order by entry->>'occurred_at'), '[]'::jsonb)
    into v_messages
  from (
    select jsonb_build_object(
      'message_id', m.id,
      'direction', m.direction,
      -- Staff see what a human typed. rendered_body (with the server prefix) is
      -- evidence, not UI, and provider_message_id is PII and never projected.
      'body', m.body,
      'occurred_at', m.occurred_at,
      'status', m.status,
      'error_code', m.error_code,
      'authored_by_staff_id', m.authored_by_staff_id
    ) as entry
    from public.support_messages_v530 m
    where m.conversation_id = p_conversation and m.business_id = p_business
    order by m.occurred_at
    -- nestly_v951: floor AND ceiling, above this function's own 200 default.
    limit least(greatest(coalesce(p_limit, 200), 1), 500)
  ) rows;

  -- Same order as the chokepoint, so the UI's explanation matches the refusal
  -- the server would actually give.
  if not app.can_module_write(p_business, 'support') then v_reason := 'no_support_write_permission';
  elsif v_conversation.state <> 'open' then v_reason := 'conversation_closed';
  elsif v_conversation.service_window_expires_at is null
     or v_conversation.service_window_expires_at <= now() then v_reason := 'service_window_closed';
  elsif not app.platform_feature_enabled('whatsapp_outbound') then v_reason := 'outbound_not_enabled';
  else
    v_state := app.capability_state_v518(p_business, 'whatsapp_support_reply');
    if (v_state->>'allowed') = 'true' then v_can := true;
    else v_reason := coalesce(v_state->>'reason','capability_refused'); end if;
  end if;

  return jsonb_build_object(
    'conversation_id', v_conversation.id,
    'is_known_customer', v_conversation.client_id is not null,
    'client_id', v_conversation.client_id,
    'display_name', coalesce(
      (select nullif(btrim(c.full_name), '') from public.clients c where c.id = v_conversation.client_id),
      '+65 ' || substr(v_conversation.customer_phone_norm,1,4) || ' ' || substr(v_conversation.customer_phone_norm,5,4)),
    'state', v_conversation.state,
    'handoff_state', v_conversation.handoff_state,
    'assigned_staff_id', v_conversation.assigned_staff_id,
    'service_window_open', v_conversation.service_window_expires_at > now(),
    'service_window_expires_at', v_conversation.service_window_expires_at,
    'can_reply', v_can,
    'reply_disabled_reason', v_reason,
    'messages', v_messages);
end
$function$;

revoke all on function public.business_support_get_thread_v531(uuid, uuid, integer) from public, anon;
grant execute on function public.business_support_get_thread_v531(uuid, uuid, integer) to authenticated, service_role;

-- 3 -------------------------------------------------------------------------------------------
-- public.business_support_list_conversations_v531 — the support inbox list.
CREATE OR REPLACE FUNCTION public.business_support_list_conversations_v531(p_business uuid, p_state text DEFAULT 'open'::text, p_limit integer DEFAULT 100)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare v_rows jsonb;
begin
  if not app.can_module_read(p_business, 'support') then
    raise exception 'support module read access required' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(entry order by entry->>'last_inbound_at' desc), '[]'::jsonb)
    into v_rows
  from (
    select jsonb_build_object(
      'conversation_id', conversation.id,
      -- The customer's own number, which they chose to message this business
      -- from. Formatted for reading, never the raw provider value.
      'display_name', coalesce(nullif(btrim(client_row.full_name), ''),
                               '+65 ' || substr(conversation.customer_phone_norm,1,4)
                                      || ' ' || substr(conversation.customer_phone_norm,5,4)),
      'is_known_customer', conversation.client_id is not null,
      'client_id', conversation.client_id,
      'unread_count', conversation.unread_count,
      'last_message', (
        select left(coalesce(m.body, ''), 140) from public.support_messages_v530 m
         where m.conversation_id = conversation.id
         order by m.occurred_at desc limit 1),
      'last_inbound_at', conversation.last_inbound_at,
      'assigned_staff_id', conversation.assigned_staff_id,
      'assigned_staff_name', staff_row.full_name,
      'handoff_state', conversation.handoff_state,
      'state', conversation.state,
      'service_window_open', conversation.service_window_expires_at > now(),
      'service_window_expires_at', conversation.service_window_expires_at
    ) as entry
    from public.support_conversations_v530 conversation
    left join public.clients client_row on client_row.id = conversation.client_id
    left join public.staff staff_row on staff_row.id = conversation.assigned_staff_id
    where conversation.business_id = p_business
      and (p_state is null or conversation.state = p_state)
    order by conversation.last_inbound_at desc nulls last
    -- nestly_v951: floor AND ceiling, above this function's own 100 default.
    limit least(greatest(coalesce(p_limit, 100), 1), 200)
  ) rows;

  return jsonb_build_object('business_id', p_business, 'conversations', v_rows);
end
$function$;

revoke all on function public.business_support_list_conversations_v531(uuid, text, integer) from public, anon;
grant execute on function public.business_support_list_conversations_v531(uuid, text, integer) to authenticated, service_role;

commit;
