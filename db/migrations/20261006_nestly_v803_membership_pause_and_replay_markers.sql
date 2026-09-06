/* nestly_v803 — pausing a membership stops its billing clock, and three idempotent RPCs stop
   reporting a replay as a fresh write.

   Audit findings F088 (P3), F089 (P2), F134 (P2), all confirmed read-only against production on
   2026-09-02 by reading the live definitions with pg_get_functiondef.

   ============================================================================================
   F088 — resuming a paused membership billed for every month it was paused.
   ============================================================================================
   public.set_membership_status writes ONE column: status. Pausing therefore freezes
   memberships.current_period_end at whatever it already held, and the daily cron
   app.run_membership_renewals correctly skips the row while it says 'paused' — but the moment
   it says 'active' again, the cron sees a current_period_end months in the past and its
   catch-up while-loop (capped at 12) fires once per elapsed period. Each iteration inserts a
   kind='membership' sale, which app.sale_policy_defaults marks counts_as_revenue, and — when
   the plan carries credit — one 'membership_credit' row on the append-only credit ledger.

   A four-month pause on an $80/mo plan with $60 of credit therefore books $320 of revenue that
   nobody paid and drops $240 of spendable credit on the customer, in one overnight run, with no
   owner action. The idempotency keys differ per period, so nothing dedupes it.

   THE FIX — the pause stops the clock, and the resume gives back exactly the time that was
   held. memberships.paused_at records when the pause began. On the way back out, the elapsed
   pause is ADDED to both current_period_start and current_period_end, so the customer keeps
   the unused remainder of the period they had already paid for and the cron finds nothing due.
   No period is ever skipped or invented: the shift is exact, and a period that was ALREADY
   overdue when the pause started stays overdue by the same amount afterwards.

   A row paused before this migration existed has no paused_at, and is deliberately left with
   today's behaviour rather than guessed at: coalesce(paused_at, now()) makes the shift zero
   instead of inventing a pause length from a column that was never written. Production holds
   two memberships, both 'active', so there is nothing to repair.

   The Memberships screen is still switched off for every role by UNVERIFIED_MODULES_V466, so
   this is armed-but-unreachable today. That is exactly why it is worth closing now: the defect
   is one un-gating away from being live money, and the un-gate will not remember this.

   ============================================================================================
   F089 / F134 — three RPCs that can never report a replay.
   ============================================================================================
   The house pattern for a keyed idempotent RPC is to return the cached result with
   `|| jsonb_build_object('replayed', true)` overlaid on the cache-hit branch — the shape
   public.issue_gift_card_at_branch_v117 and public.redeem_gift_card_at_branch_v117 use — so
   the client's isReplayResult(data) can tell a genuine first success from a retry of one whose
   HTTP response was lost. Three RPCs break it:

     · public.enroll_membership_v41 (4-arg) returns `v_existing.result::json` verbatim, and the
       underlying 3-arg returns row_to_json(memberships-row), which carries no marker either.
       isReplayResult is therefore false on EVERY call, and "Already enrolled — no duplicate
       created" is unreachable dead code. Both ends are fixed: the fresh result now carries
       'replayed' false, and the cache hit overlays true.
     · public.sell_package_v102 and public.use_package_session_v102 bake 'replayed', false into
       the result at creation time and then return that same cached jsonb verbatim on the replay
       branch, so `data.replayed` is structurally incapable of being true. A second scan of an
       already-consumed package-session QR shows the identical "Redemption confirmed" toast and
       receipt as the first, giving staff no way to tell a harmless repeat scan from a real one.

   In all three cases the LEDGER was already correct — no second charge, no second decrement.
   Only the answer was wrong.

   Rollback suite: db/tests/v803_membership_pause_and_replay_markers.sql */
begin;

-- =============================================================================================
-- F088 — the pause clock.
-- =============================================================================================
alter table public.memberships
  add column if not exists paused_at timestamptz;

comment on column public.memberships.paused_at is
  'nestly_v803: when the current pause began. Non-null exactly while status = ''paused''; the '
  'resume adds the elapsed pause to both period columns so app.run_membership_renewals has no '
  'retroactive catch-up to bill.';

CREATE OR REPLACE FUNCTION public.set_membership_status(p_business uuid, p_membership uuid, p_status text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_actor uuid := auth.uid();
  v_staff uuid;
  v_membership public.memberships%rowtype;
  v_paused_for interval := interval '0';
begin
  if v_actor is null or not app.can_module_write(p_business, 'memberships') then
    raise exception 'active memberships-module write authorization is required'
      using errcode='42501';
  end if;
  select s.id into v_staff from public.staff s
   where s.business_id=p_business and s.user_id=v_actor and s.active
   order by case when s.role='owner' then 0 else 1 end,s.created_at limit 1 for update;
  if not found then raise exception 'active staff authorization is required' using errcode='42501'; end if;
  if p_status not in ('active','paused','cancel_at_period_end','cancelled') then
    raise exception 'invalid membership status' using errcode='22023';
  end if;
  select * into v_membership from public.memberships m
   where m.id=p_membership and m.business_id=p_business for update;
  if not found then raise exception 'membership does not belong to this business' using errcode='22023'; end if;

  if p_status = 'paused' and v_membership.status is distinct from 'paused' then
    -- Going in: remember when, and touch nothing else. The cron already skips 'paused'.
    update public.memberships
       set status = p_status, paused_at = now()
     where id=p_membership and business_id=p_business returning * into v_membership;
  elsif p_status <> 'paused' and v_membership.status = 'paused' then
    -- Coming out: give back exactly the time that was held. Without this the very next cron
    -- run bills one sale and one credit drop per period that elapsed while nothing was owed.
    v_paused_for := greatest(now() - coalesce(v_membership.paused_at, now()), interval '0');
    update public.memberships
       set status = p_status,
           paused_at = null,
           current_period_start = current_period_start + v_paused_for,
           current_period_end = current_period_end + v_paused_for
     where id=p_membership and business_id=p_business returning * into v_membership;
  else
    update public.memberships set status=p_status
     where id=p_membership and business_id=p_business returning * into v_membership;
  end if;

  return jsonb_build_object('status','completed','membership_id',v_membership.id,
    'membership_status',v_membership.status,
    'paused_at',v_membership.paused_at,
    'paused_days_returned',round((extract(epoch from v_paused_for)/86400.0)::numeric,3),
    'current_period_end',v_membership.current_period_end);
end
$function$;
revoke all privileges on function public.set_membership_status(uuid,uuid,text) from public, anon;
grant execute on function public.set_membership_status(uuid,uuid,text) to authenticated, service_role;

-- =============================================================================================
-- F089 — a membership enrollment replay says so.
-- =============================================================================================
do $v803_enroll$
declare
  v_def text; v_new text;
  v_hit constant text :=
'      raise exception ''idempotency key conflicts with another membership enrollment''
        using errcode = ''23505'';
    end if;
    return v_existing.result::json;';
  v_hit_new constant text :=
'      raise exception ''idempotency key conflicts with another membership enrollment''
        using errcode = ''23505'';
    end if;
    return (v_existing.result || jsonb_build_object(''replayed'', true))::json;';
  v_fresh constant text :=
'  v_result := public.enroll_membership_v41(p_business, p_client, p_plan);';
  v_fresh_new constant text :=
'  v_result := public.enroll_membership_v41(p_business, p_client, p_plan);
  v_result := (v_result::jsonb || jsonb_build_object(''replayed'', false))::json;';
begin
  v_def := pg_get_functiondef('public.enroll_membership_v41(uuid,uuid,uuid,uuid)'::regprocedure);
  if position('replayed' in v_def) > 0 then
    raise notice 'nestly_v803: enroll_membership_v41 already marks a replay, skipping';
  else
    if (length(v_def) - length(replace(v_def, v_hit, ''))) / nullif(length(v_hit),0) <> 1
       or (length(v_def) - length(replace(v_def, v_fresh, ''))) / nullif(length(v_fresh),0) <> 1 then
      raise exception 'nestly_v803: an enroll anchor did not match exactly once — body drifted'
        using errcode = 'XX001';
    end if;
    v_new := replace(replace(v_def, v_hit, v_hit_new), v_fresh, v_fresh_new);
    if v_new = v_def then
      raise exception 'nestly_v803: the enroll splice produced no change' using errcode = 'XX001';
    end if;
    execute v_new;
  end if;
end
$v803_enroll$;
revoke all privileges on function public.enroll_membership_v41(uuid,uuid,uuid,uuid) from public, anon;
grant execute on function public.enroll_membership_v41(uuid,uuid,uuid,uuid) to authenticated, service_role;

-- =============================================================================================
-- F134 — a package sale and a package session replay say so.
-- =============================================================================================
do $v803_packages$
declare
  v_def text; v_new text;
  v_sale constant text :=
'      raise exception ''package sale idempotency key conflict'' using errcode=''23505'';
    end if;
    return v_existing.result;';
  v_sale_new constant text :=
'      raise exception ''package sale idempotency key conflict'' using errcode=''23505'';
    end if;
    return v_existing.result || jsonb_build_object(''replayed'', true);';
  v_session constant text :=
'      raise exception ''package session idempotency key conflict'' using errcode=''23505'';
    end if;
    return v_existing.result;';
  v_session_new constant text :=
'      raise exception ''package session idempotency key conflict'' using errcode=''23505'';
    end if;
    return v_existing.result || jsonb_build_object(''replayed'', true);';
begin
  v_def := pg_get_functiondef('public.sell_package_v102(uuid,uuid,uuid,uuid,uuid)'::regprocedure);
  if position('jsonb_build_object(''replayed'', true)' in v_def) > 0 then
    raise notice 'nestly_v803: sell_package_v102 already marks a replay, skipping';
  else
    if (length(v_def) - length(replace(v_def, v_sale, ''))) / nullif(length(v_sale),0) <> 1 then
      raise exception 'nestly_v803: the sell_package anchor did not match exactly once'
        using errcode = 'XX001';
    end if;
    v_new := replace(v_def, v_sale, v_sale_new);
    if v_new = v_def then
      raise exception 'nestly_v803: the sell_package splice produced no change' using errcode = 'XX001';
    end if;
    execute v_new;
  end if;

  v_def := pg_get_functiondef('public.use_package_session_v102(uuid,uuid,uuid,text)'::regprocedure);
  if position('jsonb_build_object(''replayed'', true)' in v_def) > 0 then
    raise notice 'nestly_v803: use_package_session_v102 already marks a replay, skipping';
  else
    if (length(v_def) - length(replace(v_def, v_session, ''))) / nullif(length(v_session),0) <> 1 then
      raise exception 'nestly_v803: the use_package_session anchor did not match exactly once'
        using errcode = 'XX001';
    end if;
    v_new := replace(v_def, v_session, v_session_new);
    if v_new = v_def then
      raise exception 'nestly_v803: the use_package_session splice produced no change'
        using errcode = 'XX001';
    end if;
    execute v_new;
  end if;
end
$v803_packages$;
revoke all privileges on function public.sell_package_v102(uuid,uuid,uuid,uuid,uuid) from public, anon;
grant execute on function public.sell_package_v102(uuid,uuid,uuid,uuid,uuid) to authenticated, service_role;
revoke all privileges on function public.use_package_session_v102(uuid,uuid,uuid,text) from public, anon;
grant execute on function public.use_package_session_v102(uuid,uuid,uuid,text) to authenticated, service_role;

-- =============================================================================================
-- Prove every change took, in the transaction that made it.
-- =============================================================================================
do $verify$
declare
  v_status text := pg_get_functiondef('public.set_membership_status(uuid,uuid,text)'::regprocedure);
  v_enroll text := pg_get_functiondef('public.enroll_membership_v41(uuid,uuid,uuid,uuid)'::regprocedure);
  v_sale text := pg_get_functiondef('public.sell_package_v102(uuid,uuid,uuid,uuid,uuid)'::regprocedure);
  v_session text := pg_get_functiondef('public.use_package_session_v102(uuid,uuid,uuid,text)'::regprocedure);
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='memberships'
                    and column_name='paused_at') then
    raise exception 'nestly_v803 (F088): memberships has no pause clock' using errcode='XX001';
  end if;
  if position('paused_at = now()' in v_status) = 0
     or position('current_period_end + v_paused_for' in v_status) = 0 then
    raise exception 'nestly_v803 (F088): the pause still leaves the billing clock running'
      using errcode='XX001';
  end if;
  if position('jsonb_build_object(''replayed'', true)' in v_enroll) = 0
     or position('jsonb_build_object(''replayed'', false)' in v_enroll) = 0 then
    raise exception 'nestly_v803 (F089): a membership enrollment replay is still indistinguishable'
      using errcode='XX001';
  end if;
  if position('jsonb_build_object(''replayed'', true)' in v_sale) = 0 then
    raise exception 'nestly_v803 (F134): a package sale replay is still indistinguishable'
      using errcode='XX001';
  end if;
  if position('jsonb_build_object(''replayed'', true)' in v_session) = 0 then
    raise exception 'nestly_v803 (F134): a package session replay is still indistinguishable'
      using errcode='XX001';
  end if;
end
$verify$;

commit;
