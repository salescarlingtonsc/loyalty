/* nestly_v688 — opening a WhatsApp conversation clears its unread count.

   Audit finding F101 (P2, confirmed read-only against production on 2026-09-02).

   THE DEFECT — a counter with no way down that does not also send a message.
     public.support_conversations_v530.unread_count is incremented by the inbound webhook and is
     set back to 0 in exactly one place: app.support_reply_v535, as a side effect of SENDING an
     outbound reply. The table carries a single SELECT-only RLS policy
     (support_conversations_v530_tenant_read) and no UPDATE policy at all, so no client can write
     the column directly either. The consequence is that a conversation which needs no reply —
     "thanks!", a delivery confirmation, an enquiry answered in the shop — keeps its "N new" pill
     forever, and the inbox stops meaning anything because everything in it looks unread.

     The browser could not fix this on its own: hiding the pill in one tab would leave every
     other staff member still seeing it, because the count is shared tenant state, not a
     per-viewer flag.

   THE FIX — one narrow SECURITY DEFINER route that clears the counter and does nothing else.
     public.business_support_mark_read_v688(p_business, p_conversation) asserts the SAME guard
     app.support_reply_v535 asserts before it touches anything — the workspace must be open
     (app.business_workspace_open_v94) and the caller must hold support WRITE
     (app.can_module_write(p_business,'support')) — then checks the conversation belongs to this
     business and sets unread_count = 0, updated_at = now().

     Deliberate choices:
     · WRITE, not read, is the gate. Copying v535's guard verbatim is the point: marking a thread
       read is a change to shared tenant state and a read-only viewer must not be able to erase a
       colleague's queue. can_module_write already refuses read-only staff, non-staff and other
       tenants' staff, so a customer or a neighbouring business gets 42501 and touches nothing.
     · The refusals RAISE (42501 / 42704) rather than returning a refusal object as v535 does.
       v535's soft refusals exist because a refused SEND has a message to explain to the
       operator; this call is invisible housekeeping whose only consumer logs and moves on, and
       raising keeps it consistent with the other v66x/v68x business_* RPCs.
     · The UPDATE is guarded by `unread_count > 0`, so opening an already-read thread writes no
       row and does not churn updated_at (which the inbox sorts and the realtime signal watches).
       The return says which happened: {status:'ok', cleared:<n>} where cleared is the number the
       counter held before it was zeroed, and 0 means there was nothing to clear.
     · Nothing else on the row moves. handoff_state and assigned_staff_id stay where they are:
       reading a thread is not taking ownership of it, and v535 remains the only place that
       assigns.

   Client: app/app.js supportInboxPageV531 calls this on a successful thread load (replacing the
   F101 gap note left there) and records the cleared conversation locally, so
   supportRenderListV531 renders no "N new" pill for it even before the list is re-fetched. The
   call is fail-soft — an error is logged and the thread still renders.

   Rollback suite: db/tests/v688_support_mark_read.sql */
begin;

create or replace function public.business_support_mark_read_v688(
  p_business uuid, p_conversation uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_unread integer;
begin
  /* The guard, copied from app.support_reply_v535 steps (1) and (2). */
  if not app.business_workspace_open_v94(p_business) then
    raise exception 'this workspace is not active' using errcode = '42501';
  end if;
  if not app.can_module_write(p_business, 'support') then
    raise exception 'support write access is required' using errcode = '42501';
  end if;

  /* business_id is in the predicate, so guessing another tenant's conversation id matches
     nothing — the same shape as v535 step (4). */
  select unread_count into v_unread
    from public.support_conversations_v530
   where id = p_conversation and business_id = p_business
   for update;
  if not found then
    raise exception 'conversation not found in this business' using errcode = '42704';
  end if;

  v_unread := greatest(0, coalesce(v_unread, 0));
  if v_unread > 0 then
    update public.support_conversations_v530
       set unread_count = 0, updated_at = now()
     where id = p_conversation and business_id = p_business;
  end if;

  return jsonb_build_object('status', 'ok', 'cleared', v_unread);
end
$function$;

revoke all on function public.business_support_mark_read_v688(uuid, uuid) from public, anon;
grant execute on function public.business_support_mark_read_v688(uuid, uuid) to authenticated;

-- =============================================================================================
-- Prove the route exists with the guard and the reach it is supposed to have, in the same
-- transaction that created it.
-- =============================================================================================
do $verify$
declare
  v_def text := pg_get_functiondef(
    'public.business_support_mark_read_v688(uuid,uuid)'::regprocedure);
begin
  if position('can_module_write' in v_def) = 0
     or position('business_workspace_open_v94' in v_def) = 0 then
    raise exception 'nestly_v688: the mark-read RPC does not carry the support_reply_v535 guard'
      using errcode = 'XX001';
  end if;
  if position('unread_count = 0' in v_def) = 0 then
    raise exception 'nestly_v688: the mark-read RPC does not clear unread_count'
      using errcode = 'XX001';
  end if;
  if exists (select 1 from information_schema.routine_privileges
              where routine_schema = 'public'
                and routine_name = 'business_support_mark_read_v688'
                and grantee in ('anon','PUBLIC')) then
    raise exception 'nestly_v688: the mark-read RPC is reachable anonymously' using errcode = 'XX001';
  end if;
  if not exists (select 1 from information_schema.routine_privileges
                  where routine_schema = 'public'
                    and routine_name = 'business_support_mark_read_v688'
                    and grantee = 'authenticated') then
    raise exception 'nestly_v688: the mark-read RPC is not reachable by signed-in staff'
      using errcode = 'XX001';
  end if;
end
$verify$;

commit;
