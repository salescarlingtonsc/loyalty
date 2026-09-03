-- nestly_v753 -- the birthday gift reaches a customer who signs up inside the window.
--
-- OWNER RULING, 2026-09-04 (photo 3 of the batch, the Birthday gift editor's window fields
-- "Days before 182 / Days after 182"): "When a window period for the birthday gift (or the
-- birthday-month gift) is allocated, NEW sign-ups whose birthday falls within the reward period
-- must receive the birthday reward as well. Example: birthday is August 30 -- it is within 182
-- days before today -- so they receive the reward, as set, once the account is registered."
--
-- THE DEFECT. nestly_v560 (2026-08-27) made sure an EXISTING customer's birthday benefit is
-- computed live -- app.c45_customer_birthday_benefit_for_context already tells an opted-in
-- customer whose birthday falls inside the live programme's window that their gift is
-- 'ready_to_activate' the instant they open their wallet. What it does NOT do is remove the
-- "activate" tap: the immutable promise (a row in public.customer_birthday_entitlements) is
-- created only when the customer calls public.customer_activate_birthday_benefit -- nothing
-- writes it for them. For a customer who becomes a member of a business (their link goes
-- straight to 'verified' -- app.v31_link_immutable_guard refuses any other insert shape) while
-- already inside that business's birthday window, the reward should be theirs "once the account
-- is registered", not gated behind a tap the owner never asked for and the customer may never
-- make. Welcome offers already work this way (business_set_welcome_offer_v215 auto-issues a
-- grant, no customer action); the birthday benefit never got the same treatment.
--
-- THE FIX is additive: two new AFTER triggers reuse the EXISTING v560/v424 primitives
-- (app.c45_birthday_window, app.c45_benefit_snapshot) to write the SAME entitlement row
-- customer_activate_birthday_benefit would write, the moment the two facts a birthday
-- evaluation needs both become true:
--
--   (a) customer_links AFTER INSERT -- a customer becomes a member of a business. Every insert
--       into customer_links is already forced to state='verified' by the pre-existing
--       app.v31_link_immutable_guard (there is no 'pending'->'verified' UPDATE path in this
--       schema), so every row this trigger sees is a fresh, real membership. It looks up the
--       identity's birth date (public.customer_profiles, keyed by identity_id -- the SAME
--       source app.c45_customer_birthday_context reads for the customer-facing RPCs) and
--       evaluates.
--   (b) customer_profiles AFTER INSERT OR UPDATE OF birth_date -- the moment a birth date
--       becomes known (registration) or, if it is ever a separate event in future, changes. In
--       this codebase today birth_date is written exactly once, at registration
--       (public.customer_register_verified_phone), strictly BEFORE any customer_links row for
--       that identity can exist -- a customer must hold a platform identity before joining a
--       business. Leg (a) is therefore the one that actually fires for every real signup; leg
--       (b) exists because the owner ruling names DOB-becomes-known as its own trigger event,
--       and because it is what makes this correct if a future DOB editor is ever added (the one
--       existing exception, nestly_v749's self-erasure sentinel date '1900-01-01', can never
--       resolve inside a real window, so it is harmless here).
--
-- CONSENT IS NOT BYPASSED. Both existing readers of this benefit --
-- app.c45_customer_birthday_benefit_for_context (the live wallet read) and
-- public.customer_activate_birthday_benefit (the explicit-tap RPC) -- refuse to show or grant
-- anything unless public.customer_birthday_participation.opted_in is true for the identity, a
-- separate PDPA-shaped consent toggle the customer sets themselves in-app ("Birthday benefits...
-- Turn on"), OFF by default and never touched by registration. This migration enforces the
-- IDENTICAL gate inside app.v753_birthday_evaluate_and_grant. A customer who has not opted in
-- gets nothing here either -- exactly the status quo -- and the moment they do opt in, the
-- PRE-EXISTING live read (unchanged by this migration) already shows 'ready_to_activate'
-- without a sweep. What this migration removes is only the extra "activate" tap for a customer
-- who HAS already opted in and lands inside their window at membership/DOB time.
--
-- ONE-PER-WINDOW/YEAR. public.customer_birthday_entitlements carries
-- constraint customer_birthday_entitlements_customer_year_uk unique (business_id, client_id,
-- birthday_year) -- the exact rule the daily/on-demand path already relies on. Both new trigger
-- paths call app.v753_birthday_evaluate_and_grant, which inserts ON CONFLICT (business_id,
-- client_id, birthday_year) DO NOTHING, so a second link event, a DOB write that resolves to
-- the same value, or a race between the two triggers can never create a second grant for the
-- same customer/business/year, and never touches an entitlement that already exists (an
-- existing immutable promise keeps its own terms and clock, exactly as the v560 welcome-offer
-- backfill treats an existing grant).
--
-- FAIL-SOFT. A birthday evaluation must never break a signup or a link. Both new trigger
-- functions wrap their evaluation call in its own BEGIN/EXCEPTION block and RAISE WARNING
-- instead of letting any error propagate -- the customer_links insert or the customer_profiles
-- write always succeeds regardless of what the birthday evaluation does.
--
-- PROGRAMME OFF / MODULE OFF. app.v753_birthday_evaluate_and_grant reuses the exact
-- birthday_program_versions/businesses join nestly_v560 patched into the read path (no
-- loyalty_program_versions.active join -- see that migration's header) and the same
-- 'loyalty' = any(enabled_modules) gate customer_activate_birthday_benefit enforces. No live,
-- active, module-enabled birthday programme means nothing is found and nothing is written.
--
-- NOTHING ELSE CHANGES. No existing function is replaced, no ACL is touched, no column is
-- added. This migration only adds new functions and new triggers.
--
-- VERIFIED in a rolled-back transaction -- db/tests/v753_birthday_reaches_new_signups.sql /
-- db/tests/executed/v753_corpus_birthday_new_signups.sql.
--
-- ROLLBACK: drop all four new triggers and their four trigger functions, then drop
-- app.v753_birthday_evaluate_and_grant. No data written by this migration itself beyond the
-- amendment's own auto-participation rows (see below), and only from this point forward.
--
-- AMENDMENT, OWNER RULING 2026-09-04: "Giving a date of birth at signup = participating."
-- A customer who has never made an explicit birthday-participation choice should not have to
-- ALSO find and tap a separate "Birthday benefits: Turn on" switch before the window logic
-- above can ever apply to them -- supplying a DOB at all is itself the opt-in. This does not
-- weaken consent: it only removes a redundant second step for a customer who has never said
-- anything either way, and it NEVER touches a customer who has explicitly chosen opted_in=false
-- (that row is never created if one already exists, and the auto-insert below is
-- ON CONFLICT (identity_id) DO NOTHING, so an explicit opt-out can never be flipped back on).
--
-- Three changes:
--   (c) app.v753_birthday_grant_on_profile_dob_set (leg (b) above) now ALSO ensures a
--       customer_birthday_participation row exists, opted_in=true, the moment a DOB is written
--       and no row exists yet for that identity -- with a matching, replay-safe
--       customer_birthday_participation_operations receipt (actor = the customer, the same
--       idempotency/request-hash shape public.customer_set_birthday_participation writes for an
--       explicit toggle) -- BEFORE its own per-link evaluation loop runs, so the very first
--       evaluation already sees the new participation row.
--   (d) A THIRD trigger, trg_v753_birthday_grant_on_participation_opted_in (AFTER INSERT OR
--       UPDATE OF opted_in on customer_birthday_participation), fires whenever opted_in becomes
--       true -- covering a customer who explicitly turns birthday participation ON later, in
--       Profile -> Birthday benefits (via the pre-existing public.customer_set_birthday_
--       participation), independently of the auto-opt-in in (c).
--   The customer app's signup date-of-birth field now tells the customer plainly what their DOB
--   is used for and that they can turn it off any time (app/app.js, near
--   birthDatePickerHtmlV663('customerSignupDob', ...)).
--
-- VERIFIED (amendment): db/tests/v753_birthday_reaches_new_signups.sql E7 (signup with no prior
-- participation row, DOB inside window -> participation auto-created true + grant exists), E8
-- (a customer who had EXPLICITLY set opted_in=false, then saves/re-saves a DOB -> stays false,
-- nothing granted), E9 (opted_in flipped true later, via customer_set_birthday_participation ->
-- the in-window grant appears at that moment, no separate action needed).

begin;

CREATE OR REPLACE FUNCTION app.v753_birthday_evaluate_and_grant(
  p_business_id uuid,
  p_client_id uuid,
  p_identity_id uuid,
  p_birth_date date,
  p_as_of timestamp with time zone
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_opted_in boolean;
  v_program public.birthday_program_versions%rowtype;
  v_window record;
begin
  if p_birth_date is null then
    return;
  end if;

  -- Same consent gate the live read (app.c45_customer_birthday_benefit_for_context) and the
  -- explicit activate RPC (public.customer_activate_birthday_benefit) both enforce. This
  -- function only removes the extra "activate" tap for a customer who HAS already opted in --
  -- it never grants anything to a customer who has not.
  select coalesce(p.opted_in, false) into v_opted_in
    from (select 1) one
    left join public.customer_birthday_participation p on p.identity_id = p_identity_id;
  if not coalesce(v_opted_in, false) then
    return;
  end if;

  -- Same programme resolution nestly_v560 patched into the read path: the accruing programme's
  -- loyalty_program_versions.active draft-snapshot flag is deliberately NOT consulted here --
  -- the birthday benefit is its own programme.
  select bpv.* into v_program
    from public.businesses b
    join public.birthday_program_versions bpv
      on bpv.config_version_id = b.active_config_version_id
     and bpv.business_id = b.id and bpv.active
   where b.id = p_business_id
     and 'loyalty' = any(coalesce(b.enabled_modules, '{}'::text[]))
   order by bpv.sort, bpv.program_id
   limit 1;
  if not found then
    return;
  end if;

  select * into v_window
    from app.c45_birthday_window(p_birth_date, v_program.window_days_before,
      v_program.window_days_after, p_as_of, v_program.window_mode);
  if not found then
    -- Outside the current SG window: nothing to grant now. The live read path stays untouched
    -- and keeps showing any prior immutable promise as history.
    return;
  end if;

  -- The (business_id, client_id, birthday_year) unique constraint is the one-per-window/year
  -- rule; ON CONFLICT DO NOTHING makes this call idempotent no matter how many times either
  -- trigger below re-fires it for the same customer (a second link event, a DOB write that
  -- resolves to the same value, or a race between the two triggers). An existing entitlement,
  -- whether written by this function or by the customer's own "activate" tap, is left exactly
  -- as it is.
  insert into public.customer_birthday_entitlements(
    business_id, client_id, identity_id, config_version_id, birthday_program_version_id,
    birthday_year, status, valid_from, valid_until, benefit_snapshot
  ) values (
    p_business_id, p_client_id, p_identity_id, v_program.config_version_id, v_program.id,
    v_window.birthday_year, 'available', v_window.valid_from, v_window.valid_until,
    app.c45_benefit_snapshot(v_program)
  )
  on conflict (business_id, client_id, birthday_year) do nothing;
end
$function$;

revoke all on function app.v753_birthday_evaluate_and_grant(uuid,uuid,uuid,date,timestamptz)
  from public, anon, authenticated;

-- --------------------------------------------------------------------------------------- (a)
-- A customer becomes a member of a business. app.v31_link_immutable_guard already refuses any
-- customer_links insert whose state is not 'verified' with verified_at set, so every row this
-- trigger sees is a real, fresh membership -- there is no separate 'pending'->'verified' UPDATE
-- path in this schema to also hook.
CREATE OR REPLACE FUNCTION app.v753_birthday_grant_on_link_verified()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_birth_date date;
begin
  begin
    select cp.birth_date into v_birth_date
      from public.customer_profiles cp
     where cp.identity_id = new.identity_id;
    if v_birth_date is not null then
      perform app.v753_birthday_evaluate_and_grant(
        new.business_id, new.client_id, new.identity_id, v_birth_date, statement_timestamp());
    end if;
  exception when others then
    -- Fail-soft: a birthday evaluation must never break a customer's join/link.
    raise warning 'v753: birthday evaluation failed for customer_links.id=% (business=%, client=%): %',
      new.id, new.business_id, new.client_id, sqlerrm;
  end;
  return new;
end
$function$;

revoke all on function app.v753_birthday_grant_on_link_verified()
  from public, anon, authenticated;

create trigger trg_v753_birthday_grant_on_link_verified
  after insert on public.customer_links
  for each row execute function app.v753_birthday_grant_on_link_verified();

-- --------------------------------------------------------------------------------------- (b)
-- A customer's date of birth becomes known, or (if this schema ever gains a second writer)
-- changes. In this codebase today birth_date is written exactly once, at registration
-- (public.customer_register_verified_phone), strictly BEFORE any customer_links row for that
-- identity can exist, so leg (a) above is the one that fires for every real signup; this leg
-- covers the DOB-becomes-known event the owner ruling names explicitly, re-evaluating every
-- verified membership the identity already holds. (The one other existing writer of this
-- column, nestly_v749's self-erasure, sets the sentinel date '1900-01-01', which can never
-- resolve inside a real window.)
CREATE OR REPLACE FUNCTION app.v753_birthday_grant_on_profile_dob_set()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_link record;
  v_participation_created boolean := false;
  v_idempotency_key uuid;
  v_request_hash text;
begin
  if tg_op = 'UPDATE' and new.birth_date is not distinct from old.birth_date then
    return new;
  end if;
  if new.birth_date is null then
    return new;
  end if;

  -- AMENDMENT, owner ruling 2026-09-04: "Giving a date of birth at signup = participating." A
  -- customer who has never made an explicit birthday-participation choice is opted in the
  -- moment their DOB is known. ON CONFLICT (identity_id) DO NOTHING means a customer who has
  -- EXPLICITLY set opted_in=false (a row already exists) is NEVER touched by this -- their
  -- choice stands regardless of how many times their DOB is subsequently written. Order matters:
  -- this runs BEFORE the evaluation loop below, so the very first evaluation already sees it.
  begin
    insert into public.customer_birthday_participation(identity_id, auth_user_id, opted_in, updated_at)
    values (new.identity_id, new.auth_user_id, true, now())
    on conflict (identity_id) do nothing;
    v_participation_created := found;
  exception when others then
    -- Fail-soft: an auto-participation defect must never stop the profile write.
    raise warning 'v753: auto-participation insert failed for identity=%: %', new.identity_id, sqlerrm;
  end;

  if v_participation_created then
    begin
      -- The same replay-safe receipt shape public.customer_set_birthday_participation writes
      -- for an explicit toggle (customer_birthday_participation_operations: actor, idempotency
      -- key, request hash, the opted_in value recorded). The key is deterministic per identity
      -- (this auto-opt-in can only ever happen once per identity, since a second DOB write finds
      -- the row already present and takes the ON CONFLICT DO NOTHING branch above), so a retried
      -- trigger firing is itself idempotent against customer_birthday_participation_operations'
      -- own unique (identity_id, idempotency_key).
      v_idempotency_key := md5('v753-auto-birthday-participation:' || new.identity_id::text)::uuid;
      v_request_hash := app.c45_hash(jsonb_build_object(
        'opted_in', true, 'source', 'v753_auto_dob_set', 'identity_id', new.identity_id
      )::text);
      insert into public.customer_birthday_participation_operations(
        identity_id, actor_auth_user_id, idempotency_key, request_hash, opted_in
      ) values (new.identity_id, new.auth_user_id, v_idempotency_key, v_request_hash, true)
      on conflict (identity_id, idempotency_key) do nothing;
    exception when others then
      raise warning 'v753: auto-participation receipt failed for identity=%: %', new.identity_id, sqlerrm;
    end;
  end if;

  for v_link in
    select cl.business_id, cl.client_id
      from public.customer_links cl
     where cl.identity_id = new.identity_id and cl.state = 'verified'
  loop
    begin
      perform app.v753_birthday_evaluate_and_grant(
        v_link.business_id, v_link.client_id, new.identity_id, new.birth_date, statement_timestamp());
    exception when others then
      -- Fail-soft, per membership: one business's evaluation failing must never stop the
      -- profile write, and must never stop this identity's OTHER memberships from being
      -- evaluated.
      raise warning 'v753: birthday evaluation failed for identity=% business=% on profile DOB change: %',
        new.identity_id, v_link.business_id, sqlerrm;
    end;
  end loop;
  return new;
end
$function$;

revoke all on function app.v753_birthday_grant_on_profile_dob_set()
  from public, anon, authenticated;

create trigger trg_v753_birthday_grant_on_profile_dob_set
  after insert or update of birth_date on public.customer_profiles
  for each row execute function app.v753_birthday_grant_on_profile_dob_set();

-- --------------------------------------------------------------------------------------- (d)
-- AMENDMENT, owner ruling 2026-09-04: a customer who explicitly turns birthday participation ON
-- later (Profile -> Birthday benefits, via the pre-existing public.customer_set_birthday_
-- participation) must see the in-window reward immediately, not wait for their next wallet
-- visit or a sweep. Fires whenever opted_in becomes true, whether by a fresh row (the auto
-- opt-in above also lands here, harmlessly re-evaluating the same idempotent grant) or an
-- UPDATE that flips an existing false row to true. A false row, or an UPDATE that leaves
-- opted_in unchanged, does nothing.
CREATE OR REPLACE FUNCTION app.v753_birthday_grant_on_participation_opted_in()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_birth_date date;
  v_link record;
begin
  if new.opted_in is not true then
    return new;
  end if;
  if tg_op = 'UPDATE' and old.opted_in is not distinct from new.opted_in then
    return new;
  end if;
  begin
    select cp.birth_date into v_birth_date
      from public.customer_profiles cp
     where cp.identity_id = new.identity_id;
  exception when others then
    raise warning 'v753: birth_date lookup failed for identity=% on participation opt-in: %',
      new.identity_id, sqlerrm;
    return new;
  end;
  if v_birth_date is null then
    return new;
  end if;
  for v_link in
    select cl.business_id, cl.client_id
      from public.customer_links cl
     where cl.identity_id = new.identity_id and cl.state = 'verified'
  loop
    begin
      perform app.v753_birthday_evaluate_and_grant(
        v_link.business_id, v_link.client_id, new.identity_id, v_birth_date, statement_timestamp());
    exception when others then
      raise warning 'v753: birthday evaluation failed for identity=% business=% on participation opt-in: %',
        new.identity_id, v_link.business_id, sqlerrm;
    end;
  end loop;
  return new;
end
$function$;

revoke all on function app.v753_birthday_grant_on_participation_opted_in()
  from public, anon, authenticated;

create trigger trg_v753_birthday_grant_on_participation_opted_in
  after insert or update of opted_in on public.customer_birthday_participation
  for each row execute function app.v753_birthday_grant_on_participation_opted_in();

commit;
