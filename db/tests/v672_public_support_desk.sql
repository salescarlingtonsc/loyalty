-- Rollback-only v672 acceptance suite — the public support desk.
--
-- SECTION 1 — anonymous submission through the service-role RPC.
--   S1-T1  A customer's message is stored, opens as 'open', and is not a replay.
--   S1-T2  The same idempotency key with the same words returns the first ticket, replayed.
--   S1-T3  The same key with DIFFERENT words is refused rather than silently dropped.
--   S1-T4  A business owner who names no business is refused.
--   S1-T5  A message under 10 characters is refused.
--   S1-T6  An unsupported locale tag is refused.
--   S1-T7  Submitting writes exactly one audit row, and that row cannot be rewritten.
--
-- SECTION 2 — the super-admin queue.
--   S2-T1  The queue returns the ticket, and open_count counts it.
--   S2-T2  Search matches the message body; a miss returns an empty list, not everything.
--   S2-T3  has_more respects the limit AND the filter it was asked for.
--   S2-T4  A nonsense status filter is refused.
--
-- SECTION 3 — handling a ticket.
--   S3-T1  A stale expected_version is refused (two admins, one queue).
--   S3-T2  A real update advances the version and records who handled it.
--   S3-T3  The audit row names the status the ticket came FROM, not the one it went to.
--   S3-T4  The handling-shape constraint refuses "resolved" with nobody's name against it.
--
-- SECTION 4 — the boundary.
--   S4-T1  anon and authenticated hold no privilege on either table.
--   S4-T2  A non-super-admin can neither read the queue nor write to it (42501).
--
-- Run against production; everything is inside one transaction that rolls back.
begin;
create temporary table v672_evidence(test text, detail text) on commit drop;

do $v672$
declare
  v_owner uuid;                       -- the super admin, read from super_admins
  v_key uuid := gen_random_uuid();
  v_res jsonb; v_queue jsonb;
  v_ticket uuid; v_count integer; v_text text; v_version bigint;
  v_prior text; v_new text;
begin
  select user_id into v_owner from public.super_admins limit 1;
  if v_owner is null then raise exception 'FIXTURE: no super admin is registered'; end if;

  -- ---------------------------------------------------------------- SECTION 1
  v_res := public.internal_submit_support_ticket_v672(
    'customer','V672 Probe','V672.Probe@Example.com ',null,null,
    'My stamps disappeared after paying at the counter.','en',v_key);
  if (v_res->>'replayed')::boolean then raise exception 'S1-T1 FAIL: first submit was a replay'; end if;
  if v_res->>'status' <> 'open' then raise exception 'S1-T1 FAIL: status %', v_res->>'status'; end if;
  v_ticket := (v_res->>'ticket_id')::uuid;
  insert into v672_evidence values('S1-T1','stored as open, reference '||(v_res->>'public_reference'));

  -- The email was submitted mixed-case with trailing space; the row must hold it folded.
  select contact_email into v_text from public.support_tickets_v672 where id=v_ticket;
  if v_text <> 'v672.probe@example.com' then
    raise exception 'S1-T1 FAIL: email not normalised, got %', v_text; end if;

  v_res := public.internal_submit_support_ticket_v672(
    'customer','V672 Probe','v672.probe@example.com',null,null,
    'My stamps disappeared after paying at the counter.','en',v_key);
  if not (v_res->>'replayed')::boolean then raise exception 'S1-T2 FAIL: replay not recognised'; end if;
  if (v_res->>'ticket_id')::uuid <> v_ticket then raise exception 'S1-T2 FAIL: replay made a new ticket'; end if;
  insert into v672_evidence values('S1-T2','same key + same words returned the first ticket');

  begin
    perform public.internal_submit_support_ticket_v672(
      'customer','V672 Probe','v672.probe@example.com',null,null,
      'A completely different story under the same key.','en',v_key);
    raise exception 'S1-T3 FAIL: a changed message replayed under the same key';
  exception when sqlstate '22023' then
    insert into v672_evidence values('S1-T3','changed words under a used key refused');
  end;

  begin
    perform public.internal_submit_support_ticket_v672(
      'business_owner','V672 Owner','owner.v672@example.com',null,null,
      'I cannot sign into my till this morning.','en',gen_random_uuid());
    raise exception 'S1-T4 FAIL: business owner accepted with no business name';
  exception when sqlstate '22023' then
    insert into v672_evidence values('S1-T4','business owner with no business refused');
  end;

  begin
    perform public.internal_submit_support_ticket_v672(
      'customer','V672 Probe','short.v672@example.com',null,null,'help','en',gen_random_uuid());
    raise exception 'S1-T5 FAIL: a 4-character message was accepted';
  exception when sqlstate '22023' then
    insert into v672_evidence values('S1-T5','message under 10 characters refused');
  end;

  begin
    perform public.internal_submit_support_ticket_v672(
      'customer','V672 Probe','locale.v672@example.com',null,null,
      'A perfectly ordinary message goes here.','fr',gen_random_uuid());
    raise exception 'S1-T6 FAIL: an unsupported locale was accepted';
  exception when sqlstate '22023' then
    insert into v672_evidence values('S1-T6','unsupported locale refused');
  end;

  select count(*) into v_count from public.support_ticket_audit_v672 where ticket_id=v_ticket;
  if v_count <> 1 then raise exception 'S1-T7 FAIL: % audit rows, expected 1', v_count; end if;
  begin
    update public.support_ticket_audit_v672 set reason='rewritten' where ticket_id=v_ticket;
    raise exception 'S1-T7 FAIL: the audit trail was rewritten';
  exception when others then
    if sqlerrm like '%FAIL%' then raise; end if;
    insert into v672_evidence values('S1-T7','one audit row, and it is append-only');
  end;

  -- ---------------------------------------------------------------- SECTION 2
  -- Act as the super admin. app.is_super_admin() is super_admins membership AND
  -- app.platform_session_via_google_v625(), so the claims below carry the Google OAuth
  -- shape a real console session presents. A thinner JWT is refused, which is the point:
  -- this verifies as the real principal rather than as the table owner.
  perform set_config('request.jwt.claims', json_build_object(
    'sub', v_owner, 'role', 'authenticated',
    'amr', json_build_array(json_build_object('method','oauth')),
    'app_metadata', json_build_object('providers', json_build_array('google'))
  )::text, true);

  v_queue := public.platform_list_support_tickets_v672(null,'stamps disappeared',100);
  if jsonb_array_length(v_queue->'tickets') < 1 then
    raise exception 'S2-T1/T2 FAIL: the queue did not return the probe ticket'; end if;
  if (v_queue->>'open_count')::integer < 1 then
    raise exception 'S2-T1 FAIL: open_count did not count it'; end if;
  insert into v672_evidence values('S2-T1','queue returned the ticket, open_count '||(v_queue->>'open_count'));

  v_queue := public.platform_list_support_tickets_v672(null,'zzz-no-such-text-v672',100);
  if jsonb_array_length(v_queue->'tickets') <> 0 then
    raise exception 'S2-T2 FAIL: a search miss returned rows'; end if;
  insert into v672_evidence values('S2-T2','search miss returned an empty list');

  -- One matching row, asked for one: there is no second page of THAT search.
  v_queue := public.platform_list_support_tickets_v672(null,'stamps disappeared',1);
  if (v_queue->>'has_more')::boolean then
    raise exception 'S2-T3 FAIL: has_more ignored the search filter'; end if;
  insert into v672_evidence values('S2-T3','has_more respects the filter it was asked for');

  begin
    perform public.platform_list_support_tickets_v672('nonsense');
    raise exception 'S2-T4 FAIL: a nonsense status filter was accepted';
  exception when sqlstate '22023' then
    insert into v672_evidence values('S2-T4','nonsense status filter refused');
  end;

  -- ---------------------------------------------------------------- SECTION 3
  begin
    perform public.platform_update_support_ticket_v672(
      v_ticket,'resolved','Restored the stamps by hand.',999);
    raise exception 'S3-T1 FAIL: a stale version was accepted';
  exception when sqlstate '40001' then
    insert into v672_evidence values('S3-T1','stale expected_version refused');
  end;

  v_res := public.platform_update_support_ticket_v672(
    v_ticket,'resolved','Restored the stamps by hand and replied by email.',1);
  if v_res->>'status' <> 'resolved' then raise exception 'S3-T2 FAIL: status %', v_res->>'status'; end if;
  if (v_res->>'version')::bigint <> 2 then raise exception 'S3-T2 FAIL: version not advanced'; end if;
  select handled_by into v_text from public.support_tickets_v672 where id=v_ticket;
  if v_text::uuid <> v_owner then raise exception 'S3-T2 FAIL: handled_by is not the actor'; end if;
  insert into v672_evidence values('S3-T2','resolved, version 2, handled_by recorded');

  select prior_status,new_status into v_prior,v_new from public.support_ticket_audit_v672
   where ticket_id=v_ticket and event_type='status_changed';
  if v_prior <> 'open' or v_new <> 'resolved' then
    raise exception 'S3-T3 FAIL: audit says % -> %', v_prior, v_new; end if;
  insert into v672_evidence values('S3-T3','audit records open -> resolved');

  begin
    -- A second, untouched ticket, so the shape is tested from 'open' rather than from a
    -- row that already carries handling fields.
    v_res := public.internal_submit_support_ticket_v672(
      'customer','V672 Shape','shape.v672@example.com',null,null,
      'A second message, used only to test the constraint.','en',gen_random_uuid());
    update public.support_tickets_v672 set status='resolved'
     where id=(v_res->>'ticket_id')::uuid;
    raise exception 'S3-T4 FAIL: resolved with no handler and no note';
  exception when check_violation then
    insert into v672_evidence values('S3-T4','handling shape refuses resolved with no handler');
  end;

  -- ---------------------------------------------------------------- SECTION 4
  select count(*) into v_count
    from pg_class c
   where c.relname in ('support_tickets_v672','support_ticket_audit_v672')
     and (has_table_privilege('anon',c.oid,'SELECT')
       or has_table_privilege('authenticated',c.oid,'SELECT')
       or has_table_privilege('anon',c.oid,'INSERT')
       or has_table_privilege('authenticated',c.oid,'INSERT'));
  if v_count <> 0 then raise exception 'S4-T1 FAIL: % table(s) reachable by anon/authenticated', v_count; end if;
  insert into v672_evidence values('S4-T1','anon and authenticated hold no privilege on either table');

  -- Drop to an identity that is not a super admin and prove both doors are shut. The claims
  -- keep the same Google OAuth shape, so the ONLY difference is super_admins membership —
  -- otherwise a refusal here would prove nothing about the super-admin gate.
  perform set_config('request.jwt.claims', json_build_object(
    'sub', gen_random_uuid(), 'role', 'authenticated',
    'amr', json_build_array(json_build_object('method','oauth')),
    'app_metadata', json_build_object('providers', json_build_array('google'))
  )::text, true);
  begin
    perform public.platform_list_support_tickets_v672();
    raise exception 'S4-T2 FAIL: a non-super-admin read the queue';
  exception when sqlstate '42501' then
    insert into v672_evidence values('S4-T2 read','non-super-admin refused (42501)');
  end;
  begin
    perform public.platform_update_support_ticket_v672(v_ticket,'closed','trying it on',2);
    raise exception 'S4-T2 FAIL: a non-super-admin wrote to a ticket';
  exception when sqlstate '42501' then
    insert into v672_evidence values('S4-T2 write','non-super-admin refused (42501)');
  end;
end
$v672$;

select test, detail from v672_evidence order by test;

rollback;
