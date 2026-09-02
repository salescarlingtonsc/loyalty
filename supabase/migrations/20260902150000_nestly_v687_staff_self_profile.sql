/* nestly_v687 — a staff member can save their own display name, and the app stops
   claiming a save that RLS threw away.

   Audit finding F131 (P2, confirmed read-only against production gadpooereceldfpfxsod on
   2026-09-02).

   THE DEFECT — a write nobody was allowed to make, reported as a success.
     The account menu's "Your display name" form (app/app.js, profileNameFormV158) is rendered
     for EVERY signed-in staff member, not just the owner. On submit it did two writes:

       const {data,error} = await sb.auth.updateUser({data:{full_name:name,name}});
       if(error) throw error;
       await sb.from('staff').update({full_name:name})
               .eq('business_id',S.biz.id).eq('user_id',S.user.id);   <-- result discarded
       status.textContent = 'Name saved.';

     The first write is the caller's own auth.users row and always succeeds. The second is the
     mirror into public.staff.full_name — the name every OTHER person in the firm reads (the Team
     roster, the till's staff-attribution picker, the sales/commission report, appointments and
     the calendar). Its result was not even assigned to a variable, so the `error` PostgREST
     returns was unreadable, and the handler unconditionally printed "Name saved.".

     Policy staff_update is `for update to authenticated using (app.is_salon_owner(business_id))`
     — there is no self-row predicate on public.staff for UPDATE at all. So for every non-owner
     role (manager, staff, frontdesk, bookkeeper — the majority of a real team) the statement
     matched ZERO rows. PostgREST reports a zero-row UPDATE as a 204, not an error, so nothing
     was ever thrown. The staff member saw "Name saved.", their auth metadata changed, and the
     name everyone else in the business sees never moved. Live proof, rolled back, run as the
     real principal (RLS never applies to the table owner, so `set local role authenticated` plus
     a request.jwt.claims sub is the only honest way to ask):

       non-owner frontdesk uid renaming their OWN row  -> rows_updated = 0
         (the same uid can SELECT that row: rows_visible_to_self = 1, so it is the UPDATE
          policy and not row visibility)
       owner uid renaming their own row                -> rows_updated = 1
       owner uid renaming the frontdesk's row          -> rows_updated = 1

     Exactly one variable changed between the refused and the permitted statement: who was
     asking.

   THE FIX — a narrow SECURITY DEFINER route for the one column, not a wider policy.
     public.staff_update_my_profile_v687(p_business, p_name) updates full_name and nothing else,
     on the caller's OWN row and nothing else. Deliberately NOT done by widening staff_update
     with a `user_id = auth.uid()` alternative: an UPDATE policy is per-ROW, not per-column, so a
     self-row policy would also let any staff member set their own `role` to 'owner', their own
     `modules` to the full allowlist, or flip their own `access_state` to 'approved'. That is a
     privilege-escalation hole, and it is presumably why v14's author narrowed staff writes to
     the owner in the first place. The column list is the authorisation here.

     Authorisation, in order:
       · auth.uid() must exist — no anon caller has a staff row to rename.
       · app.is_salon_member(p_business) — the canonical membership predicate, the SAME one that
         governs staff_select, so the function can never reach a business the caller could not
         already read. It carries the open-workspace and approved+active tests with it, so a
         paused or unapproved workspace refuses here exactly as it refuses everywhere else.
       · the UPDATE itself is keyed on user_id = auth.uid() and active, so membership in the
         business is not enough to touch a colleague's row.
     A refusal raises 42501, the code the client already handles for a denied write.

     Validation matches the form: btrim, 2..120 characters (the input carries maxlength=120 and
     the handler refuses under 2), and no non-printable control characters — the same shape
     app.support_reply_v535 uses for a body, newlines and tabs excluded here because a display
     name is one line.

     The write is audited (public.audit_log, action 'staff.rename_self') like every other
     sensitive write. audit_log's payload column is `detail`; it has never been `meta`.

   NOT CHANGED, deliberately:
     · Policy staff_update. The owner remains the only principal who can write a colleague's row
       through PostgREST, including their role, modules and access_state. Nothing is widened.
     · auth.users. The client still calls sb.auth.updateUser first — that row is the caller's own
       and was never the broken half.
     · Every other staff column. The function names full_name and updated_at and no others; a
       future column is not silently writable by adding it to the table.

   Client: app/app.js profileNameFormV158 now calls the RPC, reads its error, and shows the
   server's message instead of "Name saved." when the server refuses.

   Rollback suite: db/tests/v687_staff_self_profile.sql */
begin;

create or replace function public.staff_update_my_profile_v687(
  p_business uuid,
  p_name text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $fn$
declare
  v_uid  uuid := auth.uid();
  v_name text := btrim(coalesce(p_name, ''));
  v_row  public.staff%rowtype;
begin
  if v_uid is null then
    raise exception 'sign in to change your display name' using errcode = '42501';
  end if;
  if p_business is null then
    raise exception 'a business is required' using errcode = '22023';
  end if;
  if char_length(v_name) < 2 or char_length(v_name) > 120 then
    raise exception 'a display name is between 2 and 120 characters' using errcode = '22023';
  end if;
  -- One line, printable. A display name is rendered inside rosters, pickers and reports.
  if v_name ~ '[^[:print:]]' then
    raise exception 'a display name cannot contain control characters' using errcode = '22023';
  end if;

  -- The same membership predicate that governs staff_select, so this function can never reach a
  -- business the caller could not already read.
  if not app.is_salon_member(p_business) then
    raise exception 'you are not a member of this business' using errcode = '42501';
  end if;

  update public.staff
     set full_name = v_name
   where business_id = p_business
     and user_id = v_uid
     and active
  returning * into v_row;

  if not found then
    raise exception 'no active staff record for you in this business' using errcode = '42501';
  end if;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_uid, 'staff.rename_self', 'staff', v_row.id,
          jsonb_build_object('full_name', v_name));

  return jsonb_build_object('status', 'ok', 'staff_id', v_row.id, 'full_name', v_row.full_name);
end
$fn$;

/* The browser is the only intended caller; anon has no staff row to rename. service_role is
   granted for parity with every other business RPC (the dispatcher and the test harness). */
revoke all on function public.staff_update_my_profile_v687(uuid, text) from public, anon;
grant execute on function public.staff_update_my_profile_v687(uuid, text) to authenticated, service_role;

comment on function public.staff_update_my_profile_v687(uuid, text) is
  'nestly_v687 the ONLY route by which a non-owner staff member writes public.staff. It sets full_name on the caller''s own active row in a business they are an approved member of, and no other column and no other row. Policy staff_update stays owner-only on purpose: an UPDATE policy is per-row, so a self-row policy would also hand every staff member their own role, modules and access_state.';

-- =============================================================================================
-- Prove the change took, in the same transaction that made it.
-- =============================================================================================
do $verify$
declare
  v_def text := pg_get_functiondef('public.staff_update_my_profile_v687(uuid,text)'::regprocedure);
begin
  if position('is_salon_member' in v_def) = 0 then
    raise exception 'nestly_v687: the profile RPC does not check business membership'
      using errcode = 'XX001';
  end if;
  if position('user_id = v_uid' in v_def) = 0 then
    raise exception 'nestly_v687: the profile RPC does not pin the update to the caller''s own row'
      using errcode = 'XX001';
  end if;
  /* full_name must be the ONLY assignment in the update. If a second `set` column ever appears
     this fires, because the whole point of the RPC is the column list. */
  if (length(v_def) - length(replace(v_def, 'set full_name = v_name', '')))
     / length('set full_name = v_name') <> 1 then
    raise exception 'nestly_v687: the profile RPC no longer writes exactly one column'
      using errcode = 'XX001';
  end if;
  if exists (select 1 from information_schema.routine_privileges
              where routine_schema = 'public'
                and routine_name = 'staff_update_my_profile_v687'
                and grantee in ('anon','PUBLIC')) then
    raise exception 'nestly_v687: the profile RPC is reachable anonymously' using errcode = 'XX001';
  end if;
  /* staff_update must still be owner-only — this migration adds a route, it does not widen one. */
  if not exists (select 1 from pg_policies
                  where schemaname = 'public' and tablename = 'staff'
                    and policyname = 'staff_update' and qual = 'app.is_salon_owner(business_id)') then
    raise exception 'nestly_v687: policy staff_update is no longer the owner-only policy this migration assumes'
      using errcode = 'XX001';
  end if;
end
$verify$;

commit;
