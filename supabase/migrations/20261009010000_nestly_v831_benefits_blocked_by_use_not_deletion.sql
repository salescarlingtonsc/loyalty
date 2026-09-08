-- nestly_v831 — a joining benefit is blocked by USE, not by deletion.
--
-- OWNER, 2026-09-09: "example if customer used welcome rewards / birthday rewards / referral from
-- company A and did not use for company B. upon deletion and resign up > will not enjoy the same
-- benefit anymore for company A, while company B will still get to enjoy all benefits as yet to
-- use up. for birthday will be > not able to enjoy this year's birthday, subsequent years still
-- able to."
--
-- WHAT WAS LIVE, AND WHY IT IS WRONG. v751 (welcome + referral) and v764 (birthday) both key off
-- app.phone_recently_deleted_v751 — a hashed-phone mark written by the customer's own account
-- deletion, read for 365 days, per business. It answers "did this number delete here?", never
-- "did this number take anything?". Three consequences the owner's ruling overturns:
--
--   1. A customer joined to A and B who used the gift only at A lost it at BOTH for a year.
--      B was never consumed and must stay available (owner, above).
--   2. A gift granted and never redeemed was still burned by the deletion. "Yet to use up" means
--      still entitled.
--   3. BIRTHDAY, THE WORST CASE: the window is 365 days measured from the DELETION date, and the
--      next birthday anniversary is by definition always less than 365 days away — so EVERY
--      deletion always cost exactly one future birthday, used or not, and often the wrong one
--      (delete in September having already had an August birthday, and it is NEXT August that is
--      refused). The owner's rule is "this year's only, if this year's was used".
--
-- THE RE-KEY. The memory becomes the CONSUMPTION of a benefit, not the deletion of an account:
-- public.benefit_consumption_marks_v831 holds (business, sha256(normalised phone), benefit kind,
-- period key). Same privacy shape as v751 — a one-way hash, never the number, so the mark
-- survives the erasure that removes the name. Per business, so company B is untouched. The
-- period key is 'once' for the welcome gift and the referral bonus and the BIRTHDAY YEAR for the
-- birthday gift, which is what makes "this year no, next year yes" fall out for free.
--
-- WHEN A BENEFIT COUNTS AS CONSUMED (owner ruling 2026-09-09, and the one place it is not
-- uniform):
--   welcome gift            — when it is REDEEMED at the counter.
--   referral, points/stamps — the MOMENT THE POINTS LAND in the friend's balance. Owner's
--                             explicit choice: points are spendable the instant they are
--                             credited, so receiving them is enjoying them.
--   referral, voucher       — when the voucher is REDEEMED. A voucher is a promise you still have
--                             to walk in and claim, exactly like the welcome gift, so it follows
--                             the welcome gift's rule rather than the points rule.
--   birthday                — when that year's entitlement is REDEEMED.
--
-- WRITTEN BY TRIGGERS, NOT BY EDITING THE PAYOUT ROUTES. Four AFTER triggers on the four tables
-- that record consumption. This is deliberate: it catches every writer that exists today AND
-- every one added later (staff_confirm_birthday_free_item_v752, the reversal workflows, anything
-- future), instead of the six large settled bodies a per-route edit would have had to splice.
-- Reversing a redemption removes the mark, so a mis-scan does not cost the customer the benefit.
--
-- TWO BYPASSES CLOSED AT THE SAME TIME, both found while verifying this:
--   * public.staff_create_client wrote a 'pending' referral with NO new-customer test at all, and
--     app.on_sale_recorded() then paid it on the first sale without re-checking. Delete, get
--     re-added at the counter with any friend's code, paid again. It now asks the same question
--     every other route asks, and skips the referral instead of refusing the customer.
--   * public.erase_client_v290 (the shop-side erase) never wrote a v751 mark, so a shop-erased
--     customer got everything back immediately. Keying on consumption rather than deletion closes
--     this with no code: the mark was already written when the benefit was used.
--
-- app.phone_recently_deleted_v751 and its table are left in place but are no longer read by any
-- gate. They stay as the audit record of who deleted and when; nothing depends on them.
--
-- BACKFILL: from the actual payout records, not from status guesses — redeemed welcome gifts,
-- friend-side referral points already credited, friend-side referral vouchers already redeemed.
-- Customers erased before today cannot be backfilled: their numbers are already gone. Those are
-- the owner's own test accounts plus a handful of pilot rows.

begin;

-- ---------------------------------------------------------------------------------------------
-- 1. The record: one row per (business, phone, benefit, period) that was actually consumed.
-- ---------------------------------------------------------------------------------------------
create table if not exists public.benefit_consumption_marks_v831 (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  phone_hash text not null check (phone_hash ~ '^[0-9a-f]{64}$'),
  benefit_kind text not null check (benefit_kind in ('welcome','referral_friend','birthday')),
  period_key text not null check (length(period_key) between 1 and 32),
  source_kind text not null,
  source_id uuid,
  consumed_at timestamptz not null default now(),
  constraint benefit_consumption_marks_v831_once
    unique (business_id, phone_hash, benefit_kind, period_key)
);
create index if not exists benefit_consumption_marks_v831_source
  on public.benefit_consumption_marks_v831 (benefit_kind, source_id);
alter table public.benefit_consumption_marks_v831 enable row level security;
revoke all on table public.benefit_consumption_marks_v831 from public, anon, authenticated;
comment on table public.benefit_consumption_marks_v831 is
  'nestly_v831. One row per joining benefit a phone number has actually consumed at a business. '
  'Carries no PII: phone_hash is SHA-256 of app.norm_phone(). period_key is ''once'' for the '
  'welcome gift and the referral bonus, and the birthday year for the birthday gift. Read only by '
  'the benefit gates; written only by the four consumption triggers.';

-- ---------------------------------------------------------------------------------------------
-- 2. Write, unwrite, read.
-- ---------------------------------------------------------------------------------------------
create or replace function app.mark_benefit_consumed_v831(
  p_business uuid, p_client uuid, p_kind text, p_period text,
  p_source_kind text, p_source_id uuid)
returns void
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $function$
declare
  v_hash text;
begin
  if p_business is null or p_client is null or p_kind is null or p_period is null then
    return;
  end if;
  -- The hash is taken from the client row while it still HAS a number. A customer with no phone
  -- on file cannot be marked and cannot be recognised later; that is inherent, not a bug here.
  select app.v89_sha256(c.phone_norm) into v_hash
    from public.clients c
   where c.id = p_client and c.business_id = p_business and c.phone_norm is not null;
  if v_hash is null then
    return;
  end if;
  insert into public.benefit_consumption_marks_v831(
    business_id, phone_hash, benefit_kind, period_key, source_kind, source_id)
  values (p_business, v_hash, p_kind, p_period, p_source_kind, p_source_id)
  on conflict on constraint benefit_consumption_marks_v831_once do nothing;
end
$function$;
revoke all on function app.mark_benefit_consumed_v831(uuid, uuid, text, text, text, uuid)
  from public, anon, authenticated;
comment on function app.mark_benefit_consumed_v831(uuid, uuid, text, text, text, uuid) is
  'nestly_v831. Records that this client''s phone consumed this benefit at this business. '
  'Idempotent. Internal: called only by the consumption triggers.';

create or replace function app.unmark_benefit_consumed_v831(
  p_business uuid, p_kind text, p_source_id uuid)
returns void
language sql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $function$
  delete from public.benefit_consumption_marks_v831 m
   where m.business_id = p_business
     and m.benefit_kind = p_kind
     and p_source_id is not null
     and m.source_id = p_source_id;
$function$;
revoke all on function app.unmark_benefit_consumed_v831(uuid, text, uuid)
  from public, anon, authenticated;
comment on function app.unmark_benefit_consumed_v831(uuid, text, uuid) is
  'nestly_v831. Removes the mark a reversed redemption left. Scoped to the source row, so a mark '
  'written by a different consumption of the same benefit is deliberately left standing.';

create or replace function app.benefit_consumed_v831(
  p_business uuid, p_client uuid, p_kind text, p_period text)
returns boolean
language sql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $function$
  select exists (
    select 1
      from public.clients c
      join public.benefit_consumption_marks_v831 m
        on m.business_id = c.business_id
       and m.phone_hash = app.v89_sha256(c.phone_norm)
       and m.benefit_kind = p_kind
       and m.period_key = p_period
     where c.id = p_client
       and c.business_id = p_business
       and c.phone_norm is not null
  );
$function$;
revoke all on function app.benefit_consumed_v831(uuid, uuid, text, text)
  from public, anon, authenticated;
comment on function app.benefit_consumed_v831(uuid, uuid, text, text) is
  'nestly_v831. TRUE when this client''s phone already consumed this benefit at THIS business for '
  'this period. Replaces app.phone_recently_deleted_v751 in every benefit gate.';

-- ---------------------------------------------------------------------------------------------
-- 3. The four consumption triggers.
-- ---------------------------------------------------------------------------------------------
create or replace function app.trg_benefit_consumed_welcome_v831()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $function$
begin
  if new.status = 'redeemed' and old.status is distinct from 'redeemed' then
    perform app.mark_benefit_consumed_v831(new.business_id, new.client_id, 'welcome', 'once',
      'welcome_offer_grants_v215', new.id);
  elsif old.status = 'redeemed' and new.status is distinct from 'redeemed' then
    perform app.unmark_benefit_consumed_v831(new.business_id, 'welcome', new.id);
  end if;
  return null;
end
$function$;
drop trigger if exists trg_benefit_consumed_welcome_v831 on public.welcome_offer_grants_v215;
create trigger trg_benefit_consumed_welcome_v831
  after update of status on public.welcome_offer_grants_v215
  for each row execute function app.trg_benefit_consumed_welcome_v831();

create or replace function app.trg_benefit_consumed_referral_voucher_v831()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $function$
begin
  -- Only the FRIEND's side is a joining benefit. The referrer being paid says nothing about
  -- whether the person who joined has already taken theirs.
  if new.beneficiary is distinct from 'friend' then
    return null;
  end if;
  if new.status = 'redeemed' and old.status is distinct from 'redeemed' then
    perform app.mark_benefit_consumed_v831(new.business_id, new.client_id, 'referral_friend',
      'once', 'referral_grants_v420', new.id);
  elsif old.status = 'redeemed' and new.status is distinct from 'redeemed' then
    perform app.unmark_benefit_consumed_v831(new.business_id, 'referral_friend', new.id);
  end if;
  return null;
end
$function$;
drop trigger if exists trg_benefit_consumed_referral_voucher_v831 on public.referral_grants_v420;
create trigger trg_benefit_consumed_referral_voucher_v831
  after update of status on public.referral_grants_v420
  for each row execute function app.trg_benefit_consumed_referral_voucher_v831();

create or replace function app.trg_benefit_consumed_referral_points_v831()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $function$
begin
  -- Owner ruling 2026-09-09: points are consumed the moment they land. points_ledger is
  -- append-only, so there is no unmark here; a reversal is a compensating entry, and a business
  -- that reverses a referral payout has still had the number on its books.
  if new.entry_type = 'earn' and coalesce(new.points, 0) > 0 then
    perform app.mark_benefit_consumed_v831(new.business_id, new.client_id, 'referral_friend',
      'once', 'points_ledger', new.id);
  end if;
  return null;
end
$function$;
drop trigger if exists trg_benefit_consumed_referral_points_v831 on public.points_ledger;
create trigger trg_benefit_consumed_referral_points_v831
  after insert on public.points_ledger
  for each row when (new.referral_beneficiary = 'friend')
  execute function app.trg_benefit_consumed_referral_points_v831();

create or replace function app.trg_benefit_consumed_birthday_v831()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $function$
begin
  -- The period key is the birthday YEAR, which is the whole point: consuming 2026 says nothing
  -- about 2027.
  if new.status = 'redeemed' and old.status is distinct from 'redeemed' then
    perform app.mark_benefit_consumed_v831(new.business_id, new.client_id, 'birthday',
      new.birthday_year::text, 'customer_birthday_entitlements', new.id);
  elsif old.status = 'redeemed' and new.status is distinct from 'redeemed' then
    perform app.unmark_benefit_consumed_v831(new.business_id, 'birthday', new.id);
  end if;
  return null;
end
$function$;
drop trigger if exists trg_benefit_consumed_birthday_v831 on public.customer_birthday_entitlements;
create trigger trg_benefit_consumed_birthday_v831
  after update of status on public.customer_birthday_entitlements
  for each row execute function app.trg_benefit_consumed_birthday_v831();

-- ---------------------------------------------------------------------------------------------
-- 4. The gates. Each body is read live, the anchor must match EXACTLY once, and the result is
--    executed — the v513 method. Retyping a 5KB settled body to change one predicate is the
--    riskiest possible way to change one predicate.
-- ---------------------------------------------------------------------------------------------
do $splice$
declare
  v_def text;
  v_new text;
  v_spec jsonb;
  v_target text;
  v_anchor text;
  v_inject text;
  v_marker text;
  v_probe text;
  v_hits integer;
  v_specs jsonb := jsonb_build_array(

    -- (1) The welcome gift.
    jsonb_build_object(
      'fn', $t$app.issue_welcome_offer_v215(uuid,uuid)$t$,
      'marker', $t$benefit_consumed_v831$t$,
      'probe', $t$'welcome', 'once')$t$,
      'anchor', $t$  -- nestly_v751: a number that deleted its account here in the last year is a returning
  -- customer, not a new one. No welcome gift a second time.
  if app.phone_recently_deleted_v751(p_business, p_client) then
    return null;
  end if;$t$,
      'inject', $t$  -- nestly_v831: the question is no longer "did this number delete here" but "did this number
  -- already take the welcome gift here". A gift granted and never redeemed leaves no mark, so it
  -- is still owed on a rejoin.
  if app.benefit_consumed_v831(p_business, p_client, 'welcome', 'once') then
    return null;
  end if;$t$),

    -- (2) The referral "new customer" test.
    jsonb_build_object(
      'fn', $t$app.referral_referred_is_new_v683(uuid,uuid)$t$,
      'marker', $t$benefit_consumed_v831$t$,
      'probe', $t$'referral_friend', 'once');$t$,
      'anchor', $t$     -- nestly_v751: deleting and re-registering the same number does not make a new customer.
     and not app.phone_recently_deleted_v751(p_business, p_client);$t$,
      'inject', $t$     -- nestly_v831: a number already paid a friend's referral bonus here is not a new customer
     -- again, whoever's code is presented the second time. Referrer-agnostic by construction.
     and not app.benefit_consumed_v831(p_business, p_client, 'referral_friend', 'once');$t$),

    -- (3a) Birthday auto-grant: drop the deletion guard, which sat before the year was known.
    jsonb_build_object(
      'fn', $t$app.v753_birthday_evaluate_and_grant(uuid,uuid,uuid,date,timestamp with time zone)$t$,
      'marker', $t$benefit_consumed_v831$t$,
      'probe', $t$nestly_v831: the deleted-number guard$t$,
      'anchor', $t$  if app.phone_recently_deleted_v751(p_business_id, p_client_id) then
    return;
  end if;$t$,
      'inject', $t$  -- nestly_v831: the deleted-number guard that stood here is gone (the comment above it is
  -- stale, and words it as v763 on production and v764 in the repo — a pre-existing naming
  -- divergence this migration deliberately does not touch). A deletion decides nothing now; the
  -- year-scoped consumption check below decides.$t$),

    -- (3b) …and re-ask it per YEAR, once the window has resolved one.
    jsonb_build_object(
      'fn', $t$app.v753_birthday_evaluate_and_grant(uuid,uuid,uuid,date,timestamp with time zone)$t$,
      'marker', $t$benefit_consumed_v831$t$,
      'probe', $t$p_client_id, 'birthday',$t$,
      'anchor', $t$  if not found then
    -- Outside the current SG window: nothing to grant now. The live read path stays untouched
    -- and keeps showing any prior immutable promise as history.
    return;
  end if;$t$,
      'inject', $t$  if not found then
    -- Outside the current SG window: nothing to grant now. The live read path stays untouched
    -- and keeps showing any prior immutable promise as history.
    return;
  end if;

  -- nestly_v831: only THIS year's birthday is spent by having used THIS year's birthday. The old
  -- rule measured 365 days from a deletion, and the next anniversary is always inside 365 days,
  -- so every deletion cost a future birthday nobody had used.
  if app.benefit_consumed_v831(p_business_id, p_client_id, 'birthday',
       v_window.birthday_year::text) then
    return;
  end if;$t$),

    -- (4a) The explicit Activate tap: same move, drop the pre-window guard.
    jsonb_build_object(
      'fn', $t$public.customer_activate_birthday_benefit(text,uuid)$t$,
      'marker', $t$benefit_consumed_v831$t$,
      'probe', $t$nestly_v831: guard removed$t$,
      'anchor', $t$  if app.phone_recently_deleted_v751(v_context.business_id, v_context.client_id) then
    raise exception 'birthday benefits are unavailable' using errcode='42501';
  end if;$t$,
      'inject', $t$  -- nestly_v831: guard removed (the comment above it is stale) — the year-scoped consumption
  -- check below replaces it.$t$),

    -- (4b) …re-asked per year.
    jsonb_build_object(
      'fn', $t$public.customer_activate_birthday_benefit(text,uuid)$t$,
      'marker', $t$benefit_consumed_v831$t$,
      'probe', $t$v_context.client_id, 'birthday',$t$,
      'anchor', $t$  if not found then raise exception 'birthday benefits are unavailable' using errcode='42501'; end if;
  select * into v_entitlement from public.customer_birthday_entitlements$t$,
      'inject', $t$  if not found then raise exception 'birthday benefits are unavailable' using errcode='42501'; end if;
  -- nestly_v831: this year's birthday, already used by this number here, cannot be activated
  -- again. Next year is a different period key and is untouched.
  if app.benefit_consumed_v831(v_context.business_id, v_context.client_id, 'birthday',
       v_window.birthday_year::text) then
    raise exception 'birthday benefits are unavailable' using errcode='42501';
  end if;
  select * into v_entitlement from public.customer_birthday_entitlements$t$),

    -- (5) The preview must agree with the RPC, or it invites a tap the server then refuses.
    jsonb_build_object(
      'fn', $t$app.c45_customer_birthday_benefit_for_context(uuid,uuid,uuid,date,timestamp with time zone)$t$,
      'marker', $t$benefit_consumed_v831$t$,
      'probe', $t$p_client_id, 'birthday',$t$,
      'anchor', $t$      if coalesce(v_opted_in, false)
         and not app.phone_recently_deleted_v751(p_business_id, p_client_id) then$t$,
      'inject', $t$      if coalesce(v_opted_in, false)
         and not app.benefit_consumed_v831(p_business_id, p_client_id, 'birthday',
               v_window.birthday_year::text) then$t$),

    -- (6a) The staff bypass: a pending referral written with no test whatsoever.
    jsonb_build_object(
      'fn', $t$public.staff_create_client(uuid,uuid,text,text,text,date,text,boolean,text,text)$t$,
      'marker', $t$referral_referred_is_new_v683$t$,
      'probe', $t$if app.referral_referred_is_new_v683(p_business, v_client.id) then$t$,
      'anchor', $t$    insert into public.referrals (
      business_id, referrer_client_id, referred_client_id, status
    ) values (
      p_business, v_referrer, v_client.id, 'pending'
    ) returning id into v_referral_id;$t$,
      'inject', $t$    -- nestly_v831: the Customers form, till Quick add and onboarding all landed here and wrote
    -- this pending row with NO new-customer test at all; app.on_sale_recorded() then paid it on
    -- the first sale without re-checking. It now asks what every other referral route asks. The
    -- customer is still created either way — only the referral is skipped.
    if app.referral_referred_is_new_v683(p_business, v_client.id) then
      insert into public.referrals (
        business_id, referrer_client_id, referred_client_id, status
      ) values (
        p_business, v_referrer, v_client.id, 'pending'
      ) returning id into v_referral_id;
    end if;$t$),

    -- (7) The OTHER bypass, on the welcome side: nestly_v513 spliced the welcome issuer into
    -- every sign-up route there was, and then v767 added a NEW one — joining by a friend's
    -- referral link — which creates the client and never calls it. A real customer hit this on
    -- 2026-09-05: a clean number, joined Jess Salon by referral link, no gift. The issuer is
    -- fully self-gating, so calling it here is safe on the claim-an-existing-row branch too.
    jsonb_build_object(
      'fn', $t$public.customer_join_business_by_referral_v767(text,text,uuid)$t$,
      'marker', $t$issue_welcome_offer_v215$t$,
      'probe', $t$issue_welcome_offer_v215$t$,
      'anchor', $t$    perform set_config('app.customer_link_insert_id', '', true);
    v_response := jsonb_build_object('outcome','linked','business_id',v_business.id,$t$,
      'inject', $t$    perform set_config('app.customer_link_insert_id', '', true);
    -- nestly_v831: a referral-link join is a sign-up, and nestly_v513's rule is that a new
    -- customer gets the welcome gift however they signed up. Only this branch runs for a fresh
    -- link; the replay branch above has already returned.
    perform app.issue_welcome_offer_v215(v_business.id, v_client);
    v_response := jsonb_build_object('outcome','linked','business_id',v_business.id,$t$),

    -- (6b) …and say so, rather than silently attaching nothing.
    jsonb_build_object(
      'fn', $t$public.staff_create_client(uuid,uuid,text,text,text,date,text,boolean,text,text)$t$,
      'marker', $t$referral_skipped$t$,
      'probe', $t$'referral_skipped',$t$,
      'anchor', $t$    'consent_event_id', v_consent_id,
    'referral_id', v_referral_id
  );$t$,
      'inject', $t$    'consent_event_id', v_consent_id,
    'referral_id', v_referral_id,
    -- nestly_v831: tells the counter WHY a valid code attached no referral, instead of silence.
    'referral_skipped', case when v_referrer_code is not null and v_referral_id is null
                             then 'referral_benefit_already_used_here' end
  );$t$)
  );
begin
  for v_spec in select * from jsonb_array_elements(v_specs) loop
    v_target := v_spec->>'fn';
    v_anchor := v_spec->>'anchor';
    v_inject := v_spec->>'inject';
    v_marker := v_spec->>'marker';
    v_probe := coalesce(v_spec->>'probe', '');
    v_def := pg_get_functiondef(v_target::regprocedure);
    if v_def is null then
      raise exception 'nestly_v831: % could not be read', v_target using errcode='XX001';
    end if;

    -- Replay guard, two ways: the edit's own fingerprint is already in the body, or the body
    -- already carries v831 work and this anchor is gone. Either means this spec has landed.
    if (v_probe <> '' and position(v_probe in v_def) > 0)
       or (position(v_marker in v_def) > 0 and position(v_anchor in v_def) = 0) then
      raise notice 'nestly_v831: % already carries this edit, skipping', v_target;
      continue;
    end if;

    -- Drift guard: the anchor must appear EXACTLY once, or the splice would miss silently or
    -- land in the wrong branch.
    v_hits := (length(v_def) - length(replace(v_def, v_anchor, ''))) / nullif(length(v_anchor), 0);
    if v_hits is distinct from 1 then
      raise exception 'nestly_v831: anchor matched % time(s) in % — the body has drifted; re-derive the anchor',
        coalesce(v_hits, 0), v_target using errcode='XX001';
    end if;

    v_new := replace(v_def, v_anchor, v_inject);
    if v_new = v_def then
      raise exception 'nestly_v831: splice produced no change for %', v_target using errcode='XX001';
    end if;
    execute v_new;
    raise notice 'nestly_v831: % re-keyed', v_target;
  end loop;
end
$splice$;

-- Grants restated verbatim from the live proacl, per the preflight rule. CREATE OR REPLACE keeps
-- them; these lines are the declaration of intent, and they must not invent access.
revoke all on function app.issue_welcome_offer_v215(uuid, uuid) from public, anon, authenticated;
revoke all on function app.referral_referred_is_new_v683(uuid, uuid) from public, anon, authenticated;
revoke all on function app.v753_birthday_evaluate_and_grant(uuid, uuid, uuid, date, timestamp with time zone)
  from public, anon, authenticated;
revoke all on function app.c45_customer_birthday_benefit_for_context(uuid, uuid, uuid, date, timestamp with time zone)
  from public, anon, authenticated;
revoke all on function public.customer_activate_birthday_benefit(text, uuid) from public, anon;
grant execute on function public.customer_activate_birthday_benefit(text, uuid) to authenticated, service_role;
revoke all on function public.customer_join_business_by_referral_v767(text, text, uuid) from public, anon;
grant execute on function public.customer_join_business_by_referral_v767(text, text, uuid)
  to authenticated, service_role;
revoke all on function public.staff_create_client(uuid, uuid, text, text, text, date, text, boolean, text, text)
  from public, anon;
grant execute on function public.staff_create_client(uuid, uuid, text, text, text, date, text, boolean, text, text)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- 5. Backfill, from the payout records themselves rather than from a status guess. A customer
--    erased before today cannot be recovered: the number the hash needs is already gone.
-- ---------------------------------------------------------------------------------------------
insert into public.benefit_consumption_marks_v831(
  business_id, phone_hash, benefit_kind, period_key, source_kind, source_id, consumed_at)
select g.business_id, app.v89_sha256(c.phone_norm), 'welcome', 'once',
       'welcome_offer_grants_v215', g.id, coalesce(g.redeemed_at, now())
  from public.welcome_offer_grants_v215 g
  join public.clients c on c.id = g.client_id and c.business_id = g.business_id
 where g.status = 'redeemed' and c.phone_norm is not null
on conflict on constraint benefit_consumption_marks_v831_once do nothing;

insert into public.benefit_consumption_marks_v831(
  business_id, phone_hash, benefit_kind, period_key, source_kind, source_id, consumed_at)
select pl.business_id, app.v89_sha256(c.phone_norm), 'referral_friend', 'once',
       'points_ledger', pl.id, coalesce(pl.created_at, now())
  from public.points_ledger pl
  join public.clients c on c.id = pl.client_id and c.business_id = pl.business_id
 where pl.referral_beneficiary = 'friend' and pl.entry_type = 'earn'
   and coalesce(pl.points, 0) > 0 and c.phone_norm is not null
on conflict on constraint benefit_consumption_marks_v831_once do nothing;

insert into public.benefit_consumption_marks_v831(
  business_id, phone_hash, benefit_kind, period_key, source_kind, source_id, consumed_at)
select g.business_id, app.v89_sha256(c.phone_norm), 'referral_friend', 'once',
       'referral_grants_v420', g.id, coalesce(g.redeemed_at, now())
  from public.referral_grants_v420 g
  join public.clients c on c.id = g.client_id and c.business_id = g.business_id
 where g.beneficiary = 'friend' and g.status = 'redeemed' and c.phone_norm is not null
on conflict on constraint benefit_consumption_marks_v831_once do nothing;

insert into public.benefit_consumption_marks_v831(
  business_id, phone_hash, benefit_kind, period_key, source_kind, source_id, consumed_at)
select e.business_id, app.v89_sha256(c.phone_norm), 'birthday', e.birthday_year::text,
       'customer_birthday_entitlements', e.id, coalesce(e.updated_at, now())
  from public.customer_birthday_entitlements e
  join public.clients c on c.id = e.client_id and c.business_id = e.business_id
 where e.status = 'redeemed' and c.phone_norm is not null
on conflict on constraint benefit_consumption_marks_v831_once do nothing;

-- ---------------------------------------------------------------------------------------------
-- 6. Prove it took, in the same transaction.
-- ---------------------------------------------------------------------------------------------
do $verify$
declare
  v_bad text;
begin
  select string_agg(t.fn, ', ') into v_bad
    from (values
      ('app.issue_welcome_offer_v215(uuid,uuid)'),
      ('app.referral_referred_is_new_v683(uuid,uuid)'),
      ('app.v753_birthday_evaluate_and_grant(uuid,uuid,uuid,date,timestamp with time zone)'),
      ('public.customer_activate_birthday_benefit(text,uuid)'),
      ('app.c45_customer_birthday_benefit_for_context(uuid,uuid,uuid,date,timestamp with time zone)')
    ) as t(fn)
   where position('benefit_consumed_v831' in pg_get_functiondef(t.fn::regprocedure)) = 0;
  if v_bad is not null then
    raise exception 'nestly_v831: these gates were not re-keyed: %', v_bad using errcode='XX001';
  end if;

  select string_agg(t.fn, ', ') into v_bad
    from (values
      ('app.issue_welcome_offer_v215(uuid,uuid)'),
      ('app.referral_referred_is_new_v683(uuid,uuid)'),
      ('app.v753_birthday_evaluate_and_grant(uuid,uuid,uuid,date,timestamp with time zone)'),
      ('public.customer_activate_birthday_benefit(text,uuid)'),
      ('app.c45_customer_birthday_benefit_for_context(uuid,uuid,uuid,date,timestamp with time zone)')
    ) as t(fn)
   where position('phone_recently_deleted_v751' in pg_get_functiondef(t.fn::regprocedure)) > 0;
  if v_bad is not null then
    raise exception 'nestly_v831: these gates still read the deletion mark: %', v_bad using errcode='XX001';
  end if;

  if position('referral_referred_is_new_v683' in pg_get_functiondef(
       'public.staff_create_client(uuid,uuid,text,text,text,date,text,boolean,text,text)'::regprocedure)) = 0 then
    raise exception 'nestly_v831: staff_create_client still writes an ungated referral'
      using errcode='XX001';
  end if;

  if position('issue_welcome_offer_v215' in pg_get_functiondef(
       'public.customer_join_business_by_referral_v767(text,text,uuid)'::regprocedure)) = 0 then
    raise exception 'nestly_v831: a referral-link join still creates a customer with no welcome gift'
      using errcode='XX001';
  end if;

  select string_agg(t.tg, ', ') into v_bad
    from (values
      ('trg_benefit_consumed_welcome_v831'),
      ('trg_benefit_consumed_referral_voucher_v831'),
      ('trg_benefit_consumed_referral_points_v831'),
      ('trg_benefit_consumed_birthday_v831')
    ) as t(tg)
   where not exists (select 1 from pg_trigger g where g.tgname = t.tg and not g.tgisinternal);
  if v_bad is not null then
    raise exception 'nestly_v831: missing consumption triggers: %', v_bad using errcode='XX001';
  end if;
end
$verify$;

commit;
