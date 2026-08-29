-- nestly_v599 -- the browser roles lose the writes nothing in the product uses.
--
-- Source: docs/qa/SECURITY-CRON-FOLLOWUP-2026-08-29.md sections 3, 3.3 and 5.4, and
-- docs/qa/audit-artifacts/v590-v592-reward-grants-and-policy-scan.md. Every fact restated
-- below was re-verified read-only against production (gadpooereceldfpfxsod) before writing.
--
-- Four boundaries, one theme: a REST-reachable role holds a write privilege that no sanctioned
-- code path in Peekaa exercises. Removing it changes no working behaviour and removes the
-- forgery surface.
--
-- ===========================================================================================
-- 1. reward_grants (SEC-01) -- a member could rewrite the reward ledger's state column
-- ===========================================================================================
-- Live exposure: `authenticated` table UPDATE plus policy grants_update
-- USING (app.is_salon_member(business_id)) with a NULL WITH CHECK. The snapshot guard
-- app.reward_grant_snapshot_guard() rejects a change to every column EXCEPT `status`, which
-- is constrained only to granted/redeemed/expired. So any approved teammate of any tenant
-- could mark that tenant's grants redeemed or expired straight over /rest/v1/reward_grants,
-- unaudited -- trg_audit_grants fires on INSERT only.
--
-- Nothing legitimate uses it. Re-verified live: zero functions in public or app contain an
-- UPDATE against reward_grants; the only INSERT writer is SECURITY DEFINER
-- public.issue_campaign_offer(...), which needs no browser grant; no Edge Function and none of
-- the 35 active cron commands writes the table (v361 writes bringback_grants_v361 instead);
-- and no browser INSERT/UPDATE/DELETE path exists in app/. RLS already had no INSERT and no
-- DELETE policy, so those two grants were dead privilege already.
--
-- When redemption or expiry state transitions are needed, they arrive as narrow SECURITY
-- DEFINER RPCs that bind auth.uid(), lock the row, are idempotent and write an audit event --
-- not as a direct table grant. The snapshot guard stays in place underneath them.
--
-- SELECT is untouched: grants_select and reward_grants_sa_read remain exactly as they are.
--
-- ===========================================================================================
-- 2. notifications -- DESIGN DECISION: drop the policy, revoke UPDATE, no column grant
-- ===========================================================================================
-- The brief offered two shapes: (a) column-level UPDATE on the read-state column with a
-- recipient-scoped policy, or (b) revoke browser UPDATE entirely because every read-state
-- change already flows through SECURITY DEFINER RPCs. The evidence chooses (b), on two
-- independent grounds:
--
--   (i) There is no recipient. public.notifications has exactly nine columns --
--       id, business_id, kind, title, body, ref_table, ref_id, created_at, read_at. There is
--       no user_id, staff_id or recipient column, and read_at is a single business-wide flag:
--       get_notifications() counts unread per BUSINESS, and mark_all_notifications_read(p_business)
--       clears them per BUSINESS. A "scope the update to the legitimate recipient" policy is
--       therefore not expressible on this schema -- the only honest recipient predicate is
--       app.is_salon_member(business_id), which is precisely the predicate being removed.
--       A column-level grant on read_at alone would leave every member able to flip every one
--       of the tenant's notifications, i.e. exactly today's read-state exposure minus the
--       title/body/ref forgery -- strictly weaker than (b) for no gain.
--
--  (ii) All three sanctioned paths are already SECURITY DEFINER and independent of the grant:
--       public.get_notifications(uuid,integer)      -- member-gated read
--       public.mark_notification_read(uuid)         -- sets read_at, gated on is_salon_member
--       public.mark_all_notifications_read(uuid)    -- sets read_at, gated on is_salon_member
--       app/app.js and app/app-business.js call exactly these two RPCs to mark read (the bell
--       panel item click and the "mark all" button); no from('notifications') write exists
--       anywhere in the browser bundle. Definer functions run as their owner, so revoking the
--       browser grant cannot affect them.
--
-- What the current grant additionally allowed, and what stops here: rewriting `title`, `body`,
-- `kind`, `ref_table` and `ref_id` of any notification in the tenant. That is a real integrity
-- hazard -- notification click-through routes off ref_table/ref_id (v206), so a forged
-- reference redirects a colleague's approve/reject action at a record of the forger's choosing.
--
-- INSERT and DELETE are revoked with it: notifications has never had an INSERT or a DELETE
-- policy, so both were already unreachable -- this only removes the dead privilege.
-- notifications_select and notifications_sa_read are untouched.
--
-- ===========================================================================================
-- 3. resources -- the last member-wide permissive ALL, replaced with the v572 shape
-- ===========================================================================================
-- resources_all granted every active member INSERT/UPDATE/DELETE/SELECT on the tenant's
-- resources (id, business_id, name, active -- 4 rows live). Split the v572 way: an unchanged
-- member SELECT plus per-command write policies.
--
-- Writes are OWNER-scoped, copying service_branches_*_v572 verbatim rather than the
-- can_module_write() shape used for services/waitlist, for a stated reason: `resources` has no
-- module key in the module registry, so can_module_write(business_id,'resources') would gate on
-- a module that does not exist (the failure mode recorded for 'promotions'). Production has no
-- manager-class helper either -- app exposes is_salon_member, is_salon_owner and is_super_admin
-- and nothing between them -- and inventing one here would put a new authorization primitive
-- into a hardening migration. Owner-only is the strictly-safer subset of the requested
-- owner/manager scope and is the exact precedent v572 set for the sibling configuration table.
-- Resource scheduling has no browser UI yet (no app/ code references public.resources at all),
-- so no working screen loses a write. If the feature ships with a manager-editable surface, it
-- widens the policy deliberately, with its feature.
--
-- resources also carries stray `anon` INSERT/UPDATE/DELETE table grants (RLS refuses anon
-- because is_salon_member is false for it, but the grant should not exist). They go too.
-- resources_sa_read is untouched.
--
-- ===========================================================================================
-- 4. SEC-09 -- seven unnecessary anonymous EXECUTE grants
-- ===========================================================================================
-- All seven live with proacl {postgres=X, anon=X, authenticated=X, service_role=X} and all
-- seven reject unauthenticated use internally, so this is surface reduction, not a demonstrated
-- bypass. Only `anon` is removed; authenticated and service_role EXECUTE are re-granted
-- explicitly so the resulting ACL is stated rather than inferred. The five with live browser
-- callers (both locale functions, catalogue media versions, reward create and reward update)
-- keep working because those callers are authenticated.
--
-- Every signature was matched against live pg_proc before writing; all seven matched exactly.
--
-- ===========================================================================================
-- 5. SEC-09 -- four server/internal functions that never needed browser EXECUTE
-- ===========================================================================================
-- The audit's "server/internal-but-exposed" class (followup section 5.4), confirmed orphaned by
-- a separate read-only caller audit. None has an `anon` grant; `authenticated` is removed and
-- postgres/service_role are left exactly as they are.
--
--   public.create_business(text,text,text,text[])
--       A legacy DENIAL STUB: its whole body is
--       `raise exception 'approved_business_invitation_required' using errcode='42501'`.
--       Zero .rpc('create_business') call sites in any served bundle or edge function;
--       onboarding moved to the Turnstile-gated edge gateway, which runs as service_role and is
--       unaffected. (tests/phase2-config/draft-onboarding.test.mjs still asserts the ORIGINAL
--       v4 migration text granted authenticated -- that historical file is untouched, and the
--       assertion is about that file, not about the live ACL.)
--   app.staff_free_for_appointment_v120_base(uuid,uuid,uuid,uuid,timestamptz,timestamptz,uuid)
--       Alive server-side through its nested SECURITY DEFINER v120 callers, which do not need
--       an end-user grant to call it.
--   app.live_balance_programme_v381(uuid)
--       A nested server-side pot resolver. The browser deliberately reimplements the rule in JS
--       (liveBalanceProgrammeIdV461) and never calls it.
--   app.c46_inbox_promotion_ref_v579(uuid,text,text,uuid)
--       An internal backfill helper.
--
-- The three app.* functions are not PostgREST-exposed in the first place (only `public` is), so
-- for those this is defense in depth rather than a reachable surface.
--
-- ROLLBACK SUITE: db/tests/v599_browser_write_boundaries.sql

begin;

do $pre$
declare
  v_missing text;
  v_fn text;
begin
  select string_agg(t, ', ') into v_missing
  from unnest(array['reward_grants','notifications','resources']) t
  where to_regclass('public.'||t) is null;
  if v_missing is not null then
    raise exception 'v599: expected tables are absent: %', v_missing;
  end if;

  if to_regprocedure('app.is_salon_owner(uuid)') is null
     or to_regprocedure('app.is_salon_member(uuid)') is null then
    raise exception 'v599: the tenant authorization helpers this migration delegates to are missing';
  end if;

  -- the seven SEC-09 signatures must exist exactly as audited; a mismatch means the audit is
  -- stale and the revoke would silently target nothing.
  foreach v_fn in array array[
    'public.get_workspace_locale_preference_v97()',
    'public.set_workspace_locale_preference_v97(text,bigint)',
    'public.business_get_catalogue_media_versions_v158(uuid)',
    'public.business_update_reward_v326(uuid,uuid,text,integer,text,integer,text,boolean,timestamptz,boolean,text,integer,boolean)',
    'public.business_create_reward_v326(uuid,uuid,text,integer,integer,text,text,timestamptz,text,integer)',
    'public.business_request_manual_payment_v542(uuid,uuid,text,text)',
    'public.business_get_manual_payment_request_v542(uuid)'
  ] loop
    if to_regprocedure(v_fn) is null then
      raise exception 'v599: SEC-09 signature does not exist live: %', v_fn;
    end if;
  end loop;

  foreach v_fn in array array[
    'public.create_business(text,text,text,text[])',
    'app.staff_free_for_appointment_v120_base(uuid,uuid,uuid,uuid,timestamptz,timestamptz,uuid)',
    'app.live_balance_programme_v381(uuid)',
    'app.c46_inbox_promotion_ref_v579(uuid,text,text,uuid)'
  ] loop
    if to_regprocedure(v_fn) is null then
      raise exception 'v599: server-internal signature does not exist live: %', v_fn;
    end if;
  end loop;

  -- the sanctioned notification read-state path must exist before its direct alternative is removed
  if to_regprocedure('public.mark_notification_read(uuid)') is null
     or to_regprocedure('public.mark_all_notifications_read(uuid)') is null then
    raise exception 'v599: the notification read-state RPCs are missing -- revoking UPDATE would strand the bell';
  end if;
end
$pre$;

-- ---------------------------------------------------------------------------- 1. reward_grants
drop policy if exists grants_update on public.reward_grants;

revoke insert, update, delete, truncate on public.reward_grants from anon;
revoke insert, update, delete, truncate on public.reward_grants from authenticated;

-- ---------------------------------------------------------------------------- 2. notifications
drop policy if exists notifications_update on public.notifications;

revoke insert, update, delete, truncate on public.notifications from anon;
revoke insert, update, delete, truncate on public.notifications from authenticated;

-- --------------------------------------------------------------------------------- 3. resources
drop policy if exists resources_all on public.resources;
drop policy if exists resources_select_v599 on public.resources;
drop policy if exists resources_insert_v599 on public.resources;
drop policy if exists resources_update_v599 on public.resources;
drop policy if exists resources_delete_v599 on public.resources;

create policy resources_select_v599 on public.resources
  for select to authenticated using (app.is_salon_member(business_id));

create policy resources_insert_v599 on public.resources
  for insert to authenticated with check (app.is_salon_owner(business_id));

create policy resources_update_v599 on public.resources
  for update to authenticated using (app.is_salon_owner(business_id))
  with check (app.is_salon_owner(business_id));

create policy resources_delete_v599 on public.resources
  for delete to authenticated using (app.is_salon_owner(business_id));

revoke insert, update, delete, truncate on public.resources from anon;
revoke select on public.resources from anon;

-- ------------------------------------------------------------------- 4. SEC-09 anon EXECUTE
revoke execute on function public.get_workspace_locale_preference_v97() from public, anon;
grant execute on function public.get_workspace_locale_preference_v97() to authenticated, service_role;

revoke execute on function public.set_workspace_locale_preference_v97(text,bigint) from public, anon;
grant execute on function public.set_workspace_locale_preference_v97(text,bigint) to authenticated, service_role;

revoke execute on function public.business_get_catalogue_media_versions_v158(uuid) from public, anon;
grant execute on function public.business_get_catalogue_media_versions_v158(uuid) to authenticated, service_role;

revoke execute on function public.business_update_reward_v326(uuid,uuid,text,integer,text,integer,text,boolean,timestamptz,boolean,text,integer,boolean) from public, anon;
grant execute on function public.business_update_reward_v326(uuid,uuid,text,integer,text,integer,text,boolean,timestamptz,boolean,text,integer,boolean) to authenticated, service_role;

revoke execute on function public.business_create_reward_v326(uuid,uuid,text,integer,integer,text,text,timestamptz,text,integer) from public, anon;
grant execute on function public.business_create_reward_v326(uuid,uuid,text,integer,integer,text,text,timestamptz,text,integer) to authenticated, service_role;

revoke execute on function public.business_request_manual_payment_v542(uuid,uuid,text,text) from public, anon;
grant execute on function public.business_request_manual_payment_v542(uuid,uuid,text,text) to authenticated, service_role;

revoke execute on function public.business_get_manual_payment_request_v542(uuid) from public, anon;
grant execute on function public.business_get_manual_payment_request_v542(uuid) to authenticated, service_role;

-- ------------------------------------------- 5. SEC-09 server/internal authenticated EXECUTE
revoke execute on function public.create_business(text,text,text,text[]) from public, anon, authenticated;

revoke execute on function app.staff_free_for_appointment_v120_base(uuid,uuid,uuid,uuid,timestamptz,timestamptz,uuid) from public, anon, authenticated;

revoke execute on function app.live_balance_programme_v381(uuid) from public, anon, authenticated;

revoke execute on function app.c46_inbox_promotion_ref_v579(uuid,text,text,uuid) from public, anon, authenticated;

do $post$
declare
  v_bad text;
begin
  if has_table_privilege('authenticated','public.reward_grants','UPDATE') then
    raise exception 'v599: authenticated still holds UPDATE on reward_grants';
  end if;
  if has_table_privilege('authenticated','public.notifications','UPDATE') then
    raise exception 'v599: authenticated still holds UPDATE on notifications';
  end if;
  if not has_table_privilege('authenticated','public.reward_grants','SELECT')
     or not has_table_privilege('authenticated','public.notifications','SELECT')
     or not has_table_privilege('authenticated','public.resources','SELECT') then
    raise exception 'v599: a SELECT grant that must survive was removed';
  end if;

  select string_agg(f, ', ') into v_bad
  from unnest(array[
    'public.get_workspace_locale_preference_v97()',
    'public.set_workspace_locale_preference_v97(text,bigint)',
    'public.business_get_catalogue_media_versions_v158(uuid)',
    'public.business_update_reward_v326(uuid,uuid,text,integer,text,integer,text,boolean,timestamptz,boolean,text,integer,boolean)',
    'public.business_create_reward_v326(uuid,uuid,text,integer,integer,text,text,timestamptz,text,integer)',
    'public.business_request_manual_payment_v542(uuid,uuid,text,text)',
    'public.business_get_manual_payment_request_v542(uuid)'
  ]) f
  where has_function_privilege('anon', f, 'EXECUTE')
     or not has_function_privilege('authenticated', f, 'EXECUTE');
  if v_bad is not null then
    raise exception 'v599: SEC-09 ACL is wrong for: %', v_bad;
  end if;

  select string_agg(f, ', ') into v_bad
  from unnest(array[
    'public.create_business(text,text,text,text[])',
    'app.staff_free_for_appointment_v120_base(uuid,uuid,uuid,uuid,timestamptz,timestamptz,uuid)',
    'app.live_balance_programme_v381(uuid)',
    'app.c46_inbox_promotion_ref_v579(uuid,text,text,uuid)'
  ]) f
  where has_function_privilege('anon', f, 'EXECUTE')
     or has_function_privilege('authenticated', f, 'EXECUTE')
     or not has_function_privilege('service_role', f, 'EXECUTE');
  if v_bad is not null then
    raise exception 'v599: server-internal ACL is wrong for: %', v_bad;
  end if;
end
$post$;

commit;
