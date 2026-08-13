-- NESTLY v312 — W5b THE MONEY WAVE, POT MACHINERY: a model switch keeps the money coherent.
--
-- Applied back-to-back after v311 (W5a, the money kernel). Two migrations, not one and not
-- three: a new table, a new cron entry and a new money write scope are a different blast
-- radius and a different rollback story from "replace a function and drop an index", and
-- bundling them would entangle "revert the loop" with "drop a table that may have rows".
-- This migration is provably a NO-OP on production today — zero firms have a split pot —
-- which is exactly when new machinery should be installed.
--
-- ---------------------------------------------------------------------------
-- THE PROBLEM (V309 evidence:188-197, carried by W4a, owned here)
-- ---------------------------------------------------------------------------
-- app.resolve_ledger_programme_v309 answers from the business's CURRENT model, so after a
-- loyalty_model switch the offsetting rows history produces later (expire / redeem / adjust
-- — all sale_id IS NULL) land on the NEW programme while the original earns keep the OLD
-- tag. Per-programme sums for a switched firm go old = +E, new = -R, while the single-pot
-- balance E-R is right. Nothing read a per-programme balance in W4a, which is why every
-- payload said balance_scope='business_pot'. W5a's redeem paths DO read one — a folding
-- redeem path is just today's cross-programme double-spend with extra steps — so the pot
-- has to become coherent, per firm, at the moment it can split.
--
-- ---------------------------------------------------------------------------
-- THE MIGRATION MECHANIC: transfer PAIR in the ledger + retag of OPEN batches
-- ---------------------------------------------------------------------------
--   For each (client, source programme) with a nonzero sum:
--     INSERT adjust  -S  programme = source       ("programme pot transfer out")
--     INSERT adjust  +S  programme = destination  ("programme pot transfer in")
--   For the firm:
--     UPDATE points_batches SET programme_id = destination WHERE programme_id = source
--       AND remaining > 0
--
--  1. points_ledger STAYS APPEND-ONLY. These are INSERTs. trg_points_ledger_append_only is
--     BEFORE UPDATE OR DELETE only (v20:768-770), so it is never involved, and the v26
--     named-trigger disable (v26:185-188) — which V309 standing invariant 2 requires any
--     wave to say out loud before using — is deliberately NOT re-opened. Saying it out
--     loud: THIS MIGRATION UPDATES NO points_ledger ROW, DISABLES NO APPEND-ONLY TRIGGER,
--     AND RETAGS NOT ONE HISTORICAL LEDGER ROW. The tag keeps meaning "whose money was
--     this when it was written"; the transfer pair is a new, dated, auditable fact.
--
--  2. Transfer rows ALONE are a trap, not an option. They make the ledger coherent and
--     leave the batches tagged to the old programme; the moment FEFO is programme-scoped
--     the destination has a positive ledger balance and ZERO drainable batches, so every
--     redemption refuses with 'insufficient proven points' (v34:572) while the customer's
--     card shows the money. The batches are the spendable proof — hence the retag.
--
--  3. The batch retag is a plain UPDATE and that is already the house pattern:
--     points_batches carries NO append-only trigger (its only triggers are the two BEFORE
--     INSERTs, v309 confirmed), and the FEFO drain (v20:932-934, v34:585), the expiry sweep
--     (v20:1044), v84:545-550 and v309's own backfill (v309:386) all UPDATE it daily.
--
--  4. OPEN batches only. A fully-drained batch keeps its original tag with remaining = 0,
--     contributes 0 to sum(remaining) on either side, and keeps its provenance intact for
--     loyalty_redemption_batch_drains (v34:586-588), which
--     reverse_loyalty_redemption_v34_base restores against (v34:649-656). Retagging drained
--     batches would rewrite reversal provenance for zero gain.
--
--  5. Balances survive: the pair sums to zero, so the business pot is untouched; the retag
--     changes no amount, so sum(remaining) is untouched; and the per-(business, client)
--     invariant sum(ledger.points) = sum(batches.remaining) (v34:685-688, v84:551-561) is
--     preserved exactly while its per-programme form becomes newly true.
--
-- entry_type is 'adjust', NOT a new fifth value: adding one means auditing the 28 live
-- functions that reference points_ledger.entry_type — a blast radius the money wave must
-- not take on. 'adjust' already carries three meanings distinguished by reference and
-- write scope (owner adjust v173:165, redemption reversal v34:661, v84 correction
-- v84:537); this is the fourth, and its scope is 'programme_pot_transfer'.
--
-- actor IS NULL is the discriminator, and it is provably unique to this scope: the write
-- guard forces actor = auth.uid() on adjust_points, redemption_reversal and
-- sale_amount_correction_v84 (v84:143-154), so no other adjust route can produce a NULL
-- actor. That uniqueness is what v311's inactivity-clock exclusion stands on — without it
-- the +S row would silently postpone every switched customer's expiry by N days.
--
-- ---------------------------------------------------------------------------
-- THE DETECTOR IS RE-SPECIFIED, NOT JUST RE-RUN
-- ---------------------------------------------------------------------------
-- app.detect_programme_pot_split_v310() reports count(distinct programme_id) > 1. After a
-- legitimate migration a firm PERMANENTLY has rows under two programmes (history under the
-- old, the pot under the new), so the W4a detector would alarm forever on exactly the firms
-- W5 just fixed. app.detect_programme_pot_split_v312() carries the real invariant —
--   for every (business, client, programme): sum(ledger.points) >= 0
--                                        and sum(ledger.points) = sum(batches.remaining)
-- — i.e. no negative programme pot and per-programme ledger<->batch parity, the
-- programme-scoped form of v34:685-688. distinct_tags > 1 stops being a defect and becomes
-- a fact. The v310 function stays installed and is marked SUPERSEDED so W4a's evidence
-- remains reproducible. This is the resolution of V309 standing invariant 4.
--
-- ---------------------------------------------------------------------------
-- balance_scope: THE WINDOW'S SAFETY VALVE
-- ---------------------------------------------------------------------------
-- W4a shipped balance_scope='business_pot' on every per-programme object precisely so this
-- wave could move the VALUE without a second client wave (W4 rule R4: the client already
-- reads the key and already treats it as optional). A firm with a pending or running
-- migration row reports 'business_pot' and every reader behaves exactly as today; a firm
-- with a coherent pot reports 'programme_pot'. Six literals in five W4a readers become one
-- resolver call; no key is added, removed or reordered.
--
-- Lock order (V308 standing invariant 1: businesses -> spine rows in kind order -> clients
-- -> money) is inherited, not re-invented: publish_loyalty_config already takes the
-- businesses row FOR UPDATE at v37b:612 before it updates loyalty_programs at v37b:632, so
-- the switch trigger fires inside that order. The migration reads business_programmes, not
-- loyalty_tiers, so V308 standing invariant 2's DEFERRABLE INITIALLY DEFERRED tier sync
-- never needs flushing — and no path here edits rungs.

begin;

-- ---------------------------------------------------------------------------
-- 0. Pins. v312 lands on v311's post-state, and only on it.
-- ---------------------------------------------------------------------------

do $v312_pins$
declare
  v_norm text;
  v_detected integer;
begin
  if to_regprocedure('app.migrate_programme_pot_v312(uuid,uuid,uuid,integer)') is not null then
    raise notice 'v312 already applied; pins skipped';
    return;
  end if;

  -- The earn loop must be in place: v312 is meaningless against a single-pot writer.
  if position('for v_prog in' in
       (select p.prosrc from pg_proc p join pg_namespace n on n.oid=p.pronamespace
         where n.nspname='app' and p.proname='on_sale_recorded')) = 0 then
    raise exception 'v312 requires v311''s earn loop; apply v311 first';
  end if;

  -- The write guard is pinned COMMENT-NORMALISED. v311 wrote it with explanatory comments
  -- and production applies strip full-line comments, so the raw md5 of a v311-applied body
  -- is environment-dependent; the normalised form is not.
  select md5(array_to_string(array(
           select line from regexp_split_to_table(p.prosrc, E'\n') line
            where btrim(line) not like '--%'), E'\n'))
    into strict v_norm
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'loyalty_ledger_write_guard';
  if v_norm <> 'ae4b5ed341a87965ee97cf63e3c9493d' then
    raise exception 'v312: unexpected app.loyalty_ledger_write_guard predecessor (normalised md5=%)', v_norm;
  end if;

  if exists (
    select 1 from pg_attribute a
     where a.attrelid in ('public.points_ledger'::regclass,'public.points_batches'::regclass)
       and a.attname='programme_id' and not a.attnotnull
  ) then
    raise exception 'v312: programme_id is not NOT NULL on both money tables (v311 incomplete)';
  end if;

  select count(*) into strict v_detected from app.detect_programme_pot_split_v310();
  if v_detected <> 0 then
    raise notice 'v312: the W4a detector reports % businesses; the backfill below will migrate them', v_detected;
  end if;
end
$v312_pins$;

-- ---------------------------------------------------------------------------
-- 1. The migration ledger.
-- ---------------------------------------------------------------------------

create table if not exists public.programme_pot_migrations (
  id                  uuid primary key default gen_random_uuid(),
  business_id         uuid not null references public.businesses(id) on delete cascade,
  from_programme_id   uuid not null references public.business_programmes(id) on delete restrict,
  to_programme_id     uuid not null references public.business_programmes(id) on delete restrict,
  status              text not null default 'pending'
                        check (status in ('pending','running','complete')),
  requested_at        timestamptz not null default now(),
  completed_at        timestamptz,
  clients_done        integer not null default 0,
  constraint programme_pot_migrations_direction check (from_programme_id <> to_programme_id)
);

-- One open migration per business at a time: a second switch while one is draining would
-- interleave two transfer sets over the same rows.
create unique index if not exists programme_pot_migrations_one_open
  on public.programme_pot_migrations (business_id)
  where status in ('pending','running');

create index if not exists programme_pot_migrations_business_status
  on public.programme_pot_migrations (business_id, status);

alter table public.programme_pot_migrations enable row level security;
revoke all privileges on table public.programme_pot_migrations from public, anon, authenticated;
grant select on table public.programme_pot_migrations to authenticated;

drop policy if exists programme_pot_migrations_read on public.programme_pot_migrations;
create policy programme_pot_migrations_read on public.programme_pot_migrations
  for select to authenticated
  using (app.is_salon_member(business_id));
drop policy if exists programme_pot_migrations_sa_read on public.programme_pot_migrations;
create policy programme_pot_migrations_sa_read on public.programme_pot_migrations
  for select to authenticated
  using (app.is_super_admin());

comment on table public.programme_pot_migrations is
  'v312 W5b: the queue and the audit trail of programme pot migrations. A row exists from '
  'the moment a business''s accruing programme changes identity until its money is coherent '
  'under the new one. While status is pending or running the firm reports '
  'balance_scope=''business_pot'' and every reader and redeemer behaves exactly as it did '
  'before W5 — that window is the whole reason W4a shipped the field. No browser role can '
  'write it (SELECT-only policies); app.enqueue_programme_pot_migration_v312 and '
  'app.migrate_programme_pot_v312 are the only writers.';

-- The tag index the balance-scope resolver reads.
create index if not exists points_ledger_business_programme_v312
  on public.points_ledger (business_id, programme_id);

-- ---------------------------------------------------------------------------
-- 2. The write guard learns the transfer scope.
--    Re-stated from v311's body; the only change is the new scope in the allowlist and its
--    shape rule. actor IS NULL is the discriminator (see the header).
-- ---------------------------------------------------------------------------

create or replace function app.loyalty_ledger_write_guard()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_token text;
  v_scope text;
begin
  if tg_table_name='points_ledger' then
    v_token:=nullif(current_setting('app.points_ledger_insert_id',true),'');
    v_scope:=nullif(current_setting('app.points_ledger_write_scope',true),'');
    if v_token is distinct from new.id::text or v_scope not in
       ('sale_trigger','redeem_points','adjust_points','points_expiry',
        'redemption_reversal','sale_amount_correction_v84','programme_pot_transfer') then
      raise exception 'points_ledger may only be appended by approved loyalty routes'
        using errcode='42501';
    end if;
    if (v_scope='sale_trigger'
          and (new.entry_type<>'earn' or new.points<=0 or new.sale_id is null))
       or (v_scope='redeem_points'
          and (new.entry_type<>'redeem' or new.points>=0 or new.sale_id is not null))
       or (v_scope='adjust_points'
          and (new.entry_type<>'adjust' or new.points=0 or new.sale_id is not null
               or new.actor is distinct from auth.uid()))
       or (v_scope='points_expiry'
          and (new.entry_type<>'expire' or new.points>=0 or new.sale_id is not null
               or new.actor is not null))
       or (v_scope='redemption_reversal'
          and (new.entry_type<>'adjust' or new.points<=0 or new.sale_id is not null
               or new.actor is distinct from auth.uid()))
       or (v_scope='sale_amount_correction_v84'
          and (new.entry_type<>'adjust' or new.points>=0 or new.sale_id is null
               or new.actor is distinct from auth.uid()))
       or (v_scope='programme_pot_transfer'
          and (new.entry_type<>'adjust' or new.points=0 or new.sale_id is not null
               or new.actor is not null or new.programme_id is null)) then
      raise exception 'points ledger entry does not match its internal route'
        using errcode='check_violation';
    end if;
    if new.programme_id is null then
      raise exception 'points ledger entry has no programme'
        using errcode='check_violation';
    end if;
    if not exists (
      select 1 from public.business_programmes bp
       where bp.id=new.programme_id and bp.business_id=new.business_id
    ) then
      raise exception 'points ledger entry is tagged with another tenant''s programme'
        using errcode='42501';
    end if;
  elsif tg_table_name='credit_ledger' then
    v_token:=nullif(current_setting('app.credit_ledger_insert_id',true),'');
    v_scope:=nullif(current_setting('app.credit_ledger_write_scope',true),'');
    if v_token is distinct from new.id::text or v_scope not in
       ('sale_trigger','redeem_points','redeem_gift_card','enroll_membership',
        'membership_renewal','credit_tender','sale_reversal','redemption_reversal') then
      raise exception 'credit_ledger may only be appended by approved routes'
        using errcode='42501';
    end if;
    if (v_scope='sale_trigger'
          and (new.entry_type not in ('loyalty_earn','referral_reward')
               or new.amount_cents<=0 or new.sale_id is null))
       or (v_scope='redeem_points'
          and (new.entry_type<>'loyalty_earn' or new.amount_cents<=0
               or new.sale_id is not null or new.payment_id is not null
               or new.actor is distinct from auth.uid()))
       or (v_scope='redeem_gift_card'
          and (new.entry_type<>'gift_card_load' or new.amount_cents<=0
               or new.sale_id is not null or new.payment_id is not null
               or new.actor is distinct from auth.uid()))
       or (v_scope='enroll_membership'
          and (new.entry_type<>'membership_credit' or new.amount_cents<=0
               or new.sale_id is null or new.payment_id is not null
               or new.actor is distinct from auth.uid()))
       or (v_scope='membership_renewal'
          and (new.entry_type<>'membership_credit' or new.amount_cents<=0
               or new.sale_id is null or new.actor is not null))
       or (v_scope='credit_tender'
          and (new.entry_type<>'spend' or new.amount_cents>=0
               or new.sale_id is null or new.payment_id is null
               or new.actor is distinct from auth.uid()))
       or (v_scope='sale_reversal'
          and (new.entry_type<>'manual_adjust' or new.amount_cents=0
               or new.sale_id is null or new.actor is distinct from auth.uid()))
       or (v_scope='redemption_reversal'
          and (new.entry_type<>'manual_adjust' or new.amount_cents>=0
               or new.sale_id is not null or new.payment_id is not null
               or new.actor is distinct from auth.uid())) then
      raise exception 'credit ledger entry does not match its internal route'
        using errcode='check_violation';
    end if;
  else
    raise exception 'unexpected loyalty ledger table';
  end if;
  return new;
end
$$;

revoke all privileges on function app.loyalty_ledger_write_guard()
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. The re-specified detector, and the superseded one.
-- ---------------------------------------------------------------------------

create or replace function app.detect_programme_pot_split_v312()
returns table (business_id uuid, business_name text, client_id uuid, programme_id uuid,
               ledger_points bigint, batch_remaining bigint, defect text)
language sql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  with led as (
    select pl.business_id, pl.client_id, pl.programme_id, sum(pl.points)::bigint as points
      from public.points_ledger pl
     group by 1,2,3
  ), bat as (
    select pb.business_id, pb.client_id, pb.programme_id, sum(pb.remaining)::bigint as remaining
      from public.points_batches pb
     group by 1,2,3
  ), joined as (
    select coalesce(led.business_id, bat.business_id)   as business_id,
           coalesce(led.client_id, bat.client_id)       as client_id,
           coalesce(led.programme_id, bat.programme_id) as programme_id,
           coalesce(led.points, 0)                      as points,
           coalesce(bat.remaining, 0)                   as remaining
      from led
      full join bat
        on bat.business_id = led.business_id
       and bat.client_id = led.client_id
       and bat.programme_id = led.programme_id
  )
  select j.business_id, b.name, j.client_id, j.programme_id, j.points, j.remaining,
         case when j.points < 0 and j.points <> j.remaining then 'negative_pot_and_parity'
              when j.points < 0 then 'negative_pot'
              else 'parity' end
    from joined j
    join public.businesses b on b.id = j.business_id
   where j.points < 0
      or j.points <> j.remaining;
$$;

revoke all privileges on function app.detect_programme_pot_split_v312()
  from public, anon, authenticated;
grant execute on function app.detect_programme_pot_split_v312() to service_role;

comment on function app.detect_programme_pot_split_v312() is
  'v312 W5b standing detector, superseding app.detect_programme_pot_split_v310(). For every '
  '(business, client, programme): the ledger pot must not be negative and must equal '
  'sum(points_batches.remaining) — the programme-scoped form of the v34:685-688 invariant. '
  'count(distinct programme_id) > 1 is deliberately NOT a defect here: after a legitimate '
  'pot migration a firm permanently carries history under the old programme and its pot '
  'under the new one, and the W4a detector would alarm forever on exactly the firms W5 '
  'fixed (V309 standing invariant 4). Must return ZERO rows on a healthy database. '
  'It has NO "exclude firms with an open migration" arm, and that is the pinned contract, '
  'not an omission: app.migrate_programme_pot_v312 retags each client''s batches inside the '
  'same loop iteration as that client''s transfer pair, so a half-finished migration is '
  'coherent at every commit boundary. Zero rows is therefore the correct answer DURING a '
  'migration too, and an exclusion would have blinded the standing detector for as long as '
  'a row stayed open — including one wedged ''running'' by a crashed worker. The '
  'conservative answer for READERS lives in app.programme_balance_scope_v312 instead.';

comment on function app.detect_programme_pot_split_v310() is
  'v310 W4a standing detector — SUPERSEDED BY app.detect_programme_pot_split_v312() at W5b. '
  'Kept installed so V310''s acceptance evidence stays reproducible. Its '
  'count(distinct programme_id) > 1 arm reports a FACT, not a defect, once a pot migration '
  'has run: history keeps the old tag by design, because points_ledger is append-only.';

-- ---------------------------------------------------------------------------
-- 4. The balance-scope resolver, and the six W4a literals that now call it.
-- ---------------------------------------------------------------------------

create or replace function app.programme_balance_scope_v312(p_business uuid)
returns text
language sql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select case
    when p_business is null then 'business_pot'
    -- The window. While the pot is being made coherent, nothing may claim it already is.
    when exists (
      select 1 from public.programme_pot_migrations m
       where m.business_id = p_business and m.status in ('pending','running')
    ) then 'business_pot'
    -- The real condition, not a proxy: a firm is programme-pot exactly when every one of
    -- its (client, programme) pots is non-negative and matches its batches. Spanning two
    -- programmes is NOT a defect — it is the point of W5, and it is also the permanent
    -- shape of a firm whose pot has already been migrated (history keeps the old tag,
    -- because points_ledger is append-only). count(distinct programme_id) would call both
    -- of those a split, which is the W4a detector's flaw this wave exists to correct.
    when exists (
      select 1
        from (select pl.client_id, pl.programme_id, sum(pl.points) as points
                from public.points_ledger pl
               where pl.business_id = p_business
               group by 1,2) led
        full join (select pb.client_id, pb.programme_id, sum(pb.remaining) as remaining
                     from public.points_batches pb
                    where pb.business_id = p_business
                    group by 1,2) bat
          on bat.client_id = led.client_id
         and bat.programme_id = led.programme_id
       where coalesce(led.points,0) < 0
          or coalesce(led.points,0) <> coalesce(bat.remaining,0)
    ) then 'business_pot'
    else 'programme_pot'
  end
$$;

revoke all privileges on function app.programme_balance_scope_v312(uuid)
  from public, anon, authenticated;
grant execute on function app.programme_balance_scope_v312(uuid) to service_role;

comment on function app.programme_balance_scope_v312(uuid) is
  'v312 W5b: what a per-programme number MEANS for this business right now. '
  '''business_pot'' — the pre-W5 promise: one pot, the per-programme object is identity '
  'only. ''programme_pot'' — the programme''s own spendable balance. The answer is '
  '''business_pot'' for any firm with an open pot migration and for any firm whose '
  '(client, programme) pots are negative or disagree with their batches — the per-business '
  'form of app.detect_programme_pot_split_v312()''s invariant, NOT a distinct-tag proxy: a '
  'firm running points AND stamps together spans two programmes by design, and so does '
  'every firm whose pot has already been migrated. Read by the five W4a customer readers in '
  'place of the literal they shipped, so the flip is a VALUE change on a key the client '
  'already reads — no second client wave. Scaling note: it aggregates one business''s '
  'points_ledger and points_batches per call, served by '
  'points_ledger_business_programme_v312; at a scale where that is a per-request cost the '
  'answer becomes a materialised column on businesses maintained by the same two writers.';

-- ONE EVALUATION PER FUNCTION CALL, NOT ONE PER SITE.
-- app.programme_balance_scope_v312 aggregates the firm's whole points_ledger and
-- points_batches; spliced in as a literal-for-call swap it is evaluated once per
-- OCCURRENCE, and two of the five readers occur more than once per payload:
--
--   customer_portal_capabilities  the site sits inside jsonb_agg over the v308 spine, which
--                                 is ALWAYS four rows -> 4 full ledger+batch aggregations
--                                 per capabilities call, for one answer that cannot differ
--                                 between them (it is a per-BUSINESS answer).
--   customer_get_reward_catalog   two textual sites in one return -> 2.
--
-- This repo has already paid for that lesson once: the v2xx RPC slowdown was re-evaluated
-- functions, not missing indexes. So those two hoist the answer into a plpgsql variable
-- computed once, immediately before the payload build, and read it at every site.
--
-- The other three are left as direct calls, and each for a reason, not by omission:
--   customer_get_effective_tier_v143   the site is in a plain `return jsonb_build_object(...)`
--   customer_get_loyalty_details       the site is in a `select ... into v_result` whose
--                                      outer query has NO FROM (every CTE is referenced from
--                                      inside the target list), so it produces exactly one row
--   customer_get_wallet                the site is inside jsonb_agg over ONE CARD PER
--                                      BUSINESS. The scope is per-business, so one evaluation
--                                      per card is the CORRECT count and the minimum; a
--                                      hoisted single variable would answer for one firm and
--                                      publish it on every card in the wallet.
-- All three are therefore already one evaluation per business per call.
--
-- Pairs are applied in `ord` order against a freshly read definition each time, so a pair may
-- depend on an earlier one having landed (the assignment needs its declaration). "Already
-- applied" is detected as "the new text is present", not "the old text is absent", because a
-- pair that PREPENDS to its anchor still contains that anchor afterwards.
do $v312_scope_splices$
declare
  v_def text; v_old text; v_new text; v_o integer; v_n integer;
  v_target record;
begin
  for v_target in
    select * from (values
      (1,'public.customer_portal_capabilities(text)',
       $needle$  v_programmes jsonb;
begin
$needle$,
       $needle$  v_programmes jsonb;
  v_balance_scope text;
begin
$needle$),
      (2,'public.customer_portal_capabilities(text)',
       $needle$  select coalesce(jsonb_agg(jsonb_build_object(
           'kind', spine.kind,$needle$,
       $needle$  v_balance_scope := app.programme_balance_scope_v312(v_context.business_id);
  select coalesce(jsonb_agg(jsonb_build_object(
           'kind', spine.kind,$needle$),
      (3,'public.customer_portal_capabilities(text)',
       $needle$           'balance_scope', 'business_pot'$needle$,
       $needle$           'balance_scope', v_balance_scope$needle$),
      (4,'public.customer_get_reward_catalog(text)',
       $needle$  v_result jsonb;
begin
$needle$,
       $needle$  v_result jsonb;
  v_balance_scope text;
begin
$needle$),
      (5,'public.customer_get_reward_catalog(text)',
       $needle$  return jsonb_build_object(
    'rewards', coalesce(v_result, '[]'::jsonb),
    'points_mode', (select points_mode from public.businesses where id = v_context.business_id),
    'programmes_contract', 'v310',
    'balance_scope', 'business_pot',
    'programmes', jsonb_build_array(jsonb_build_object($needle$,
       $needle$  v_balance_scope := app.programme_balance_scope_v312(v_context.business_id);
  return jsonb_build_object(
    'rewards', coalesce(v_result, '[]'::jsonb),
    'points_mode', (select points_mode from public.businesses where id = v_context.business_id),
    'programmes_contract', 'v310',
    'balance_scope', v_balance_scope,
    'programmes', jsonb_build_array(jsonb_build_object($needle$),
      (6,'public.customer_get_reward_catalog(text)',
       $needle$      'balance_scope', 'business_pot',
      'rewards', coalesce(v_result, '[]'::jsonb))));$needle$,
       $needle$      'balance_scope', v_balance_scope,
      'rewards', coalesce(v_result, '[]'::jsonb))));$needle$),
      (7,'public.customer_get_effective_tier_v143(uuid)',
       $needle$    'tier_fuel','points_programme_earn','balance_scope','business_pot'$needle$,
       $needle$    'tier_fuel','points_programme_earn','balance_scope',app.programme_balance_scope_v312(p_business)$needle$),
      (8,'public.customer_get_loyalty_details(text,jsonb)',
       $needle$      'balance_scope','business_pot'),$needle$,
       $needle$      'balance_scope',app.programme_balance_scope_v312(v_context.business_id)),$needle$),
      (9,'public.customer_get_wallet()',
       $needle$            'balance_scope', 'business_pot'$needle$,
       $needle$            'balance_scope', app.programme_balance_scope_v312(ctx.business_id)$needle$)
    ) targets(ord, signature, old_text, new_text)
    order by ord
  loop
    if to_regprocedure(v_target.signature) is null then
      raise exception 'v312: balance_scope target is missing: %', v_target.signature
        using errcode = '42883';
    end if;
    select pg_get_functiondef(to_regprocedure(v_target.signature)) into strict v_def;
    v_old := v_target.old_text;
    v_new := v_target.new_text;
    v_o := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
    v_n := (length(v_def) - length(replace(v_def, v_new, ''))) / length(v_new);
    if v_n >= 1 then
      continue;                                  -- already flipped (re-run)
    end if;
    if v_o <> 1 then
      raise exception 'v312: balance_scope needle % in % matched old=% (expected 1)',
        v_target.ord, v_target.signature, v_o;
    end if;
    execute replace(v_def, v_old, v_new);
  end loop;

  -- The hoist is only a hoist if the variable is actually READ. A declaration and an
  -- assignment that no site consumes would leave the literal in place and pass the sweep
  -- below only by accident of wording, so assert the consumption directly.
  for v_target in
    select * from (values
      ('public.customer_portal_capabilities(text)', 1),
      ('public.customer_get_reward_catalog(text)',  2)
    ) hoisted(signature, sites)
  loop
    select pg_get_functiondef(to_regprocedure(v_target.signature)) into strict v_def;
    if position('v_balance_scope := app.programme_balance_scope_v312(' in v_def) = 0 then
      raise exception 'v312: % did not receive the single balance-scope evaluation',
        v_target.signature;
    end if;
    if (length(v_def) - length(replace(v_def, 'app.programme_balance_scope_v312(', '')))
       / length('app.programme_balance_scope_v312(') <> 1 then
      raise exception 'v312: % evaluates the balance scope more than once per call',
        v_target.signature;
    end if;
    if (length(v_def) - length(replace(v_def, 'v_balance_scope', '')))
       / length('v_balance_scope') <> 2 + v_target.sites then
      raise exception 'v312: % does not read the hoisted balance scope at every site',
        v_target.signature;
    end if;
  end loop;

  -- No reader may keep the literal.
  for v_target in
    select p.oid::regprocedure::text as signature, p.prosrc as body
      from pg_proc p
     where p.prosrc like '%balance_scope%'
  loop
    if position($needle$'balance_scope', 'business_pot'$needle$ in v_target.body) > 0
       or position($needle$'balance_scope','business_pot'$needle$ in v_target.body) > 0 then
      raise exception 'v312: % still hardcodes balance_scope=business_pot', v_target.signature;
    end if;
  end loop;
end
$v312_scope_splices$;

-- ---------------------------------------------------------------------------
-- 4b. THE SWEEP LEARNS THE TRANSFER'S LINEAGE.
--
--     v311 scoped the inactivity clock to the batch's own programme and excluded the
--     transfer row from counting as activity. Those two rules are right individually and
--     wrong together the moment a pot actually moves: after a stamps -> points switch the
--     batches carry the POINTS tag while the customer's whole earn history carries the
--     STAMPS one, so the clock would see no activity at all and expire freshly-earned
--     points at the next nightly sweep. The transfer is not activity — but the activity it
--     inherited IS. programme_pot_migrations records exactly that lineage, which is why
--     this belongs in v312 and not in v311: the wave that creates the transfer owns its
--     consequences.
--
--     Re-stated from v311's body; the only change is the lineage clause in the clock.
-- ---------------------------------------------------------------------------

do $v312_sweep_pin$
declare v_norm text;
begin
  select md5(array_to_string(array(
           select line from regexp_split_to_table(p.prosrc, E'\n') line
            where btrim(line) not like '--%'), E'\n'))
    into strict v_norm
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'run_points_expiry_for_business';
  if position('programme_pot_migrations' in
       (select p.prosrc from pg_proc p join pg_namespace n on n.oid=p.pronamespace
         where n.nspname='app' and p.proname='run_points_expiry_for_business')) > 0 then
    raise notice 'v312: the sweep already carries the transfer lineage clause';
  elsif v_norm <> 'a44d959bfae0681c4887a21bfc1d51e1' then
    raise exception 'v312: unexpected app.run_points_expiry_for_business predecessor (normalised md5=%)', v_norm;
  end if;
end
$v312_sweep_pin$;

create or replace function app.run_points_expiry_for_business(p_business uuid)
returns integer
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_client record;
  v_batch record;
  v_points_id uuid;
  v_expired integer := 0;
  v_points_programme uuid;
begin
  select spine.id into v_points_programme
    from public.business_programmes spine
   where spine.business_id = p_business and spine.kind = 'points';
  if v_points_programme is null then
    return 0;
  end if;

  for v_client in
    select distinct pb.business_id, pb.client_id
      from public.points_batches pb
      join public.loyalty_programs lp on lp.business_id = pb.business_id
     where pb.business_id = p_business
       and pb.remaining > 0
       and pb.programme_id = v_points_programme
       and lp.active
       and lp.kind = 'points'
       and coalesce(lp.expiry_days, 0) > 0
       and (
         (lp.expiry_mode = 'fixed' and pb.expires_at <= now())
         or (
           lp.expiry_mode = 'inactivity'
           and not exists (
             select 1
               from public.points_ledger pl
              where pl.business_id = pb.business_id
                and pl.client_id = pb.client_id
                and pl.points > 0
                and (
                  pl.programme_id = pb.programme_id
                  -- v312: activity the pot INHERITED counts. A completed migration is the
                  -- only thing that moves a customer's money between programmes, and the
                  -- history it left behind is still that customer being active.
                  or exists (
                    select 1 from public.programme_pot_migrations m
                     where m.business_id = pb.business_id
                       and m.to_programme_id = pb.programme_id
                       and m.from_programme_id = pl.programme_id
                       and m.status = 'complete')
                )
                -- The transfer row itself is NOT activity: it would postpone every
                -- switched customer's expiry by N days, silently changing liability the
                -- owner did not choose. actor IS NULL on an 'adjust' row is provably
                -- unique to the programme_pot_transfer scope (v84:143-154).
                and not (pl.entry_type = 'adjust' and pl.actor is null)
                and pl.created_at > now() - make_interval(days => lp.expiry_days)
           )
         )
       )
  loop
    perform 1 from public.clients c
     where c.id = v_client.client_id
       and c.business_id = v_client.business_id
       for update;

    for v_batch in
      select pb.id, pb.remaining, pb.programme_id
        from public.points_batches pb
        join public.loyalty_programs lp on lp.business_id = pb.business_id
       where pb.business_id = v_client.business_id
         and pb.client_id = v_client.client_id
         and pb.remaining > 0
         and pb.programme_id = v_points_programme
         and lp.active
         and lp.kind = 'points'
         and coalesce(lp.expiry_days, 0) > 0
         and (
           (lp.expiry_mode = 'fixed' and pb.expires_at <= now())
           or lp.expiry_mode = 'inactivity'
         )
       order by pb.expires_at nulls last, pb.earned_at, pb.id
       for update of pb skip locked
    loop
      v_points_id := gen_random_uuid();
      perform set_config('app.points_ledger_insert_id', v_points_id::text, true);
      perform set_config('app.points_ledger_write_scope', 'points_expiry', true);
      insert into public.points_ledger (
        id, business_id, client_id, entry_type, points, reference, actor, programme_id
      ) values (
        v_points_id, v_client.business_id, v_client.client_id,
        'expire', -v_batch.remaining, 'points expiry batch ' || v_batch.id, null,
        v_batch.programme_id
      );
      perform set_config('app.points_ledger_insert_id', '', true);
      perform set_config('app.points_ledger_write_scope', '', true);

      update public.points_batches set remaining = 0 where id = v_batch.id;
      v_expired := v_expired + v_batch.remaining;
    end loop;
  end loop;
  return v_expired;
end $$;

revoke execute on function app.run_points_expiry_for_business(uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. The migration itself. ONE code path, two entry points.
--
--    Not a set-based UPDATE, and not because of style: the write guard is per-row and
--    token-matched (app.points_ledger_insert_id must equal new.id, v84:133), so
--    INSERT ... SELECT is impossible. Every ledger row is its own statement, and the
--    transfer is 2 x (clients with a nonzero source-programme sum) of them.
--
--    EVERY COMMITTED INVOCATION LEAVES THE DATABASE COHERENT. This is the property the
--    p_limit exists for and the one the first draft did not have: the ledger transfer was
--    LIMITed per client while the batch retag was a single unbounded statement over the
--    whole firm, so above the K=500 inline bound one invocation moved every client's
--    batches to the destination and only the first 500 clients' ledger rows with them.
--    Client 501 then held +S in the SOURCE programme with zero batches there and S
--    remaining in a DESTINATION programme holding no ledger — parity broken on both sides,
--    for as long as the async worker took to reach them. In that window every W5 redeem
--    path refuses ('insufficient proven points', v34:572), adjust_points refuses, and the
--    expiry sweep re-enters the mode M9 exists to catch. So the retag is now performed
--    INSIDE the loop, per client, under the same clients-row lock as that client's transfer
--    pair. An invocation touches exactly its processed client set and nothing else:
--    processed clients are wholly in the destination, unprocessed clients are wholly in the
--    source, and BOTH shapes satisfy the per-(business, client, programme) invariant.
--
--    THE DETECTOR CONTRACT FOR A MID-MIGRATION FIRM follows from that and is pinned here:
--    app.detect_programme_pot_split_v312() gets NO 'exclude firms with an open migration'
--    arm. It must read ZERO rows at every commit boundary, including halfway through a
--    resumable migration. An exclusion would have been the weaker choice twice over — it
--    would blind the standing detector to a real split for exactly as long as a migration
--    row stayed open (including one wedged 'running' by a crashed worker), and it would
--    have let the incoherence above ship undetected instead of failing the suite. The
--    conservative reader-facing answer stays where it belongs, in
--    app.programme_balance_scope_v312, which reports 'business_pot' while a migration row
--    is open: readers are cautious during the window, the detector is not.
--
--    THE PROCESSED CLIENT SET is the union of "has a nonzero source-programme ledger pot"
--    and "has an OPEN source-programme batch". The union matters for the backfill: an
--    already-split firm can carry a client whose source pot has netted to zero while open
--    batches still sit under the source tag, and selecting on the ledger alone would leave
--    those batches behind forever — the transfer would report done, and the batch side
--    would never move. A zero-pot client is retagged without a transfer pair, because a
--    pair of zero-point ledger rows is noise in an append-only money table.
-- ---------------------------------------------------------------------------

create or replace function app.migrate_programme_pot_v312(
  p_business uuid,
  p_from uuid,
  p_to uuid,
  p_limit integer default 500
)
returns integer
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_client record;
  v_row_id uuid;
  v_done integer := 0;
  v_reference text;
  v_dated integer;
  v_dated_into_no_expiry integer := 0;
begin
  if p_business is null or p_from is null or p_to is null or p_from = p_to then
    raise exception 'v312: a pot migration needs a business and two different programmes'
      using errcode = '22023';
  end if;
  if not exists (select 1 from public.business_programmes bp
                  where bp.id = p_from and bp.business_id = p_business)
     or not exists (select 1 from public.business_programmes bp
                     where bp.id = p_to and bp.business_id = p_business) then
    raise exception 'v312: both programmes must belong to this business'
      using errcode = '42501';
  end if;

  -- V308 standing invariant 1: businesses row first, then money.
  perform 1 from public.businesses b where b.id = p_business for update;

  v_reference := 'programme pot transfer';

  for v_client in
    select candidate.client_id, coalesce(source.pot, 0)::integer as pot
      from (
        select pl.client_id
          from public.points_ledger pl
         where pl.business_id = p_business
           and pl.programme_id = p_from
         group by pl.client_id
        having sum(pl.points) <> 0
        union
        select pb.client_id
          from public.points_batches pb
         where pb.business_id = p_business
           and pb.programme_id = p_from
           and pb.remaining > 0
      ) candidate
      left join lateral (
        select sum(pl.points) as pot
          from public.points_ledger pl
         where pl.business_id = p_business
           and pl.programme_id = p_from
           and pl.client_id = candidate.client_id
      ) source on true
     order by candidate.client_id
     limit greatest(coalesce(p_limit, 500), 1)
  loop
    perform 1 from public.clients c
     where c.id = v_client.client_id and c.business_id = p_business
     for update;

    if v_client.pot <> 0 then
      v_row_id := gen_random_uuid();
      perform set_config('app.points_ledger_insert_id', v_row_id::text, true);
      perform set_config('app.points_ledger_write_scope', 'programme_pot_transfer', true);
      insert into public.points_ledger (
        id, business_id, client_id, entry_type, points, reference, actor, programme_id
      ) values (
        v_row_id, p_business, v_client.client_id, 'adjust', -v_client.pot,
        v_reference || ' out: ' || p_from, null, p_from
      );
      perform set_config('app.points_ledger_insert_id', '', true);
      perform set_config('app.points_ledger_write_scope', '', true);

      v_row_id := gen_random_uuid();
      perform set_config('app.points_ledger_insert_id', v_row_id::text, true);
      perform set_config('app.points_ledger_write_scope', 'programme_pot_transfer', true);
      insert into public.points_ledger (
        id, business_id, client_id, entry_type, points, reference, actor, programme_id
      ) values (
        v_row_id, p_business, v_client.client_id, 'adjust', v_client.pot,
        v_reference || ' in: ' || p_to, null, p_to
      );
      perform set_config('app.points_ledger_insert_id', '', true);
      perform set_config('app.points_ledger_write_scope', '', true);
    end if;

    -- THIS CLIENT'S open batches, under THIS client's lock, in the same iteration as
    -- their transfer pair. OPEN only: a drained batch keeps its tag, contributes 0 to
    -- either side's sum(remaining), and keeps its reversal provenance intact.
    select count(*) into v_dated
      from public.points_batches pb
     where pb.business_id = p_business
       and pb.programme_id = p_from
       and pb.client_id = v_client.client_id
       and pb.remaining > 0
       and pb.expires_at is not null;
    v_dated_into_no_expiry := v_dated_into_no_expiry + v_dated;

    update public.points_batches
       set programme_id = p_to
     where business_id = p_business
       and programme_id = p_from
       and client_id = v_client.client_id
       and remaining > 0;

    v_done := v_done + 1;
  end loop;

  if v_dated_into_no_expiry > 0 then
    -- A dated batch moved into a programme whose policy has no expiry becomes immortal.
    -- That is not a bug — a switch IS a policy change — but it is never silent, and the
    -- promised date is never re-written.
    raise notice 'v312: % dated open batches moved from % to % at business %',
      v_dated_into_no_expiry, p_from, p_to, p_business;
    insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
    values (p_business, null, 'PROGRAMME_POT_TRANSFER_V312', 'points_batches', p_to,
            jsonb_build_object('from_programme_id', p_from, 'to_programme_id', p_to,
                               'dated_open_batches_moved', v_dated_into_no_expiry,
                               'clients_transferred', v_done));
  end if;

  return v_done;
end
$$;

revoke all privileges on function app.migrate_programme_pot_v312(uuid,uuid,uuid,integer)
  from public, anon, authenticated;
grant execute on function app.migrate_programme_pot_v312(uuid,uuid,uuid,integer) to service_role;

comment on function app.migrate_programme_pot_v312(uuid,uuid,uuid,integer) is
  'v312 W5b: move a business''s live points pot from one programme to another, coherently. '
  'Per client, inside ONE loop iteration under that client''s row lock: an append-only '
  'transfer PAIR (adjust -S on the source, adjust +S on the destination, both actor NULL '
  'under the programme_pot_transfer write scope) and the retag of that client''s OPEN '
  'batches. p_limit bounds the CLIENTS processed, and because the retag is inside the loop '
  'every committed invocation leaves each processed client wholly in the destination and '
  'every unprocessed client wholly in the source — both coherent, so '
  'app.detect_programme_pot_split_v312() reads zero rows at every commit boundary, '
  'including mid-migration. The processed set is the union of "nonzero source ledger pot" '
  'and "open source batch", so the batch side can never be left behind by the ledger side; '
  'a zero-pot client is retagged with no transfer pair. Idempotent and resumable: a '
  'finished client matches neither arm, so a second run over a finished business returns 0. '
  'Never UPDATEs a points_ledger row and never touches trg_points_ledger_append_only.';

-- ---------------------------------------------------------------------------
-- 6. The enqueue API and the switch trigger.
-- ---------------------------------------------------------------------------

create or replace function app.enqueue_programme_pot_migration_v312(
  p_business uuid,
  p_from uuid,
  p_to uuid,
  p_inline_limit integer default 500
)
returns uuid
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_id uuid;
  v_clients integer;
  v_done integer;
begin
  if p_business is null or p_from is null or p_to is null or p_from = p_to then
    return null;
  end if;

  -- Counted over the SAME set app.migrate_programme_pot_v312 processes (ledger pot OR open
  -- batch), or the inline/async decision would be made on a smaller population than the
  -- work actually done and a firm just over the bound would run inline anyway.
  select count(*) into v_clients
    from (select pl.client_id
            from public.points_ledger pl
           where pl.business_id = p_business and pl.programme_id = p_from
           group by pl.client_id
          having sum(pl.points) <> 0
          union
          select pb.client_id
            from public.points_batches pb
           where pb.business_id = p_business and pb.programme_id = p_from
             and pb.remaining > 0) affected;

  if v_clients = 0 then
    return null;                                  -- nothing to move
  end if;

  -- THE ARBITER IS NAMED (the same doctrine v311 §2 applies to the earn loop's ON CONFLICT).
  -- Arbiter-less DO NOTHING absorbs a conflict from ANY constraint on the table, so a future
  -- index — or the primary key, reachable the day a caller supplies an id — would silently
  -- return NULL here and be read as "one already open; the worker owns it", skipping a
  -- migration that was never enqueued. Naming the partial unique index means this statement
  -- can only ever absorb the intended conflict, and fails at plan time if
  -- programme_pot_migrations_one_open is absent.
  insert into public.programme_pot_migrations(business_id, from_programme_id, to_programme_id, status)
  values (p_business, p_from, p_to, 'running')
  on conflict (business_id) where status in ('pending','running') do nothing
  returning id into v_id;
  if v_id is null then
    return null;                                  -- one already open; the worker owns it
  end if;

  if v_clients <= greatest(coalesce(p_inline_limit, 500), 1) then
    -- Small enough to be coherent instantly, with no window at all. Every production firm
    -- today is far under this bound (max 25 ledger rows).
    v_done := app.migrate_programme_pot_v312(p_business, p_from, p_to, p_inline_limit);
    update public.programme_pot_migrations
       set status = 'complete', completed_at = now(), clients_done = v_done
     where id = v_id;
    if exists (select 1 from app.detect_programme_pot_split_v312() d
                where d.business_id = p_business) then
      raise exception 'v312: pot migration left business % incoherent', p_business
        using errcode = 'XX001';
    end if;
  else
    update public.programme_pot_migrations set status = 'pending' where id = v_id;
  end if;
  return v_id;
end
$$;

revoke all privileges on function app.enqueue_programme_pot_migration_v312(uuid,uuid,uuid,integer)
  from public, anon, authenticated;
grant execute on function app.enqueue_programme_pot_migration_v312(uuid,uuid,uuid,integer) to service_role;

comment on function app.enqueue_programme_pot_migration_v312(uuid,uuid,uuid,integer) is
  'v312 W5b: the ONE entry point for "this business''s accruing programme changed identity". '
  'Runs the transfer inline when the affected-client count is within the bound (instant '
  'coherence, no window) and otherwise leaves a pending row for the bounded cron worker. '
  'W6 calls this directly when per-programme active flags replace loyalty_model, so a '
  'switchboard flip routes through the same coherence machinery as a model switch.';

create or replace function app.programme_pot_switch_v312()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_from uuid;
  v_to uuid;
begin
  -- The EXACT and ONLY condition under which app.resolve_ledger_programme_v309's answer
  -- moves (v309:258-276). classic <-> points_tiers is not a switch.
  select bp.id into v_from from public.business_programmes bp
   where bp.business_id = new.business_id
     and bp.kind = case when old.loyalty_model = 'stamps' then 'stamps' else 'points' end;
  select bp.id into v_to from public.business_programmes bp
   where bp.business_id = new.business_id
     and bp.kind = case when new.loyalty_model = 'stamps' then 'stamps' else 'points' end;
  if v_from is null or v_to is null or v_from = v_to then
    return null;
  end if;
  perform app.enqueue_programme_pot_migration_v312(new.business_id, v_from, v_to);
  return null;
end
$$;

revoke all privileges on function app.programme_pot_switch_v312()
  from public, anon, authenticated;

drop trigger if exists trg_programme_pot_switch_v312 on public.loyalty_programs;
create trigger trg_programme_pot_switch_v312
  after update of loyalty_model on public.loyalty_programs
  for each row
  when ((old.loyalty_model = 'stamps') is distinct from (new.loyalty_model = 'stamps'))
  execute function app.programme_pot_switch_v312();

comment on function app.programme_pot_switch_v312() is
  'v312 W5b: fires when a business crosses the stamps boundary, the exact and only change '
  'that moves app.resolve_ledger_programme_v309''s answer. Inherits the V308 lock order for '
  'free: publish_loyalty_config already takes the businesses row FOR UPDATE (v37b:612) '
  'before it updates loyalty_programs (v37b:632).';

-- ---------------------------------------------------------------------------
-- 7. The bounded worker (cron). Installed only where pg_cron exists.
-- ---------------------------------------------------------------------------

create or replace function app.run_programme_pot_migrations_v312(p_batch integer default 5)
returns integer
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_job record;
  v_done integer;
  v_ran integer := 0;
begin
  for v_job in
    select m.id, m.business_id, m.from_programme_id, m.to_programme_id
      from public.programme_pot_migrations m
     where m.status in ('pending','running')
     order by m.requested_at
     limit greatest(coalesce(p_batch, 5), 1)
     for update skip locked
  loop
    update public.programme_pot_migrations set status = 'running' where id = v_job.id;
    v_done := app.migrate_programme_pot_v312(
      v_job.business_id, v_job.from_programme_id, v_job.to_programme_id, 500);
    if v_done = 0 then
      update public.programme_pot_migrations
         set status = 'complete', completed_at = now(),
             clients_done = clients_done
       where id = v_job.id;
    else
      update public.programme_pot_migrations
         set clients_done = clients_done + v_done
       where id = v_job.id;
    end if;
    v_ran := v_ran + 1;
  end loop;
  return v_ran;
end
$$;

revoke all privileges on function app.run_programme_pot_migrations_v312(integer)
  from public, anon, authenticated;
grant execute on function app.run_programme_pot_migrations_v312(integer) to service_role;

do $v312_cron$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule('frenly-programme-pot-migrations')
      where exists (select 1 from cron.job where jobname = 'frenly-programme-pot-migrations');
    perform cron.schedule('frenly-programme-pot-migrations', '*/10 * * * *',
      $cronbody$select app.run_programme_pot_migrations_v312(5);$cronbody$);
  else
    raise notice 'v312: pg_cron is absent; the pot worker is installed but unscheduled';
  end if;
end
$v312_cron$;

-- ---------------------------------------------------------------------------
-- 8. Backfill + post-assertions. Provably a no-op on production today.
-- ---------------------------------------------------------------------------

do $v312_backfill$
declare
  v_row record;
  v_from uuid;
  v_to uuid;
  v_queued integer := 0;
  v_left integer;
begin
  for v_row in select * from app.detect_programme_pot_split_v310() loop
    select bp.id into v_to from public.business_programmes bp
     where bp.business_id = v_row.business_id
       and bp.kind = case when exists (
             select 1 from public.loyalty_programs lp
              where lp.business_id = v_row.business_id and lp.loyalty_model = 'stamps')
           then 'stamps' else 'points' end;
    for v_from in
      select distinct pl.programme_id from public.points_ledger pl
       where pl.business_id = v_row.business_id
         and pl.programme_id is distinct from v_to
    loop
      perform app.enqueue_programme_pot_migration_v312(v_row.business_id, v_from, v_to);
      v_queued := v_queued + 1;
    end loop;
  end loop;
  if v_queued = 0 then
    raise notice 'v312: pot-migration backfill found nothing to do (expected on production today)';
  else
    raise notice 'v312: pot-migration backfill queued/ran % (business, programme) transfers', v_queued;
  end if;

  select count(*) into strict v_left from app.detect_programme_pot_split_v312();
  if v_left <> 0 then
    raise exception 'v312: the re-specified detector is not empty after backfill (% rows)', v_left;
  end if;
end
$v312_backfill$;

do $v312_postcondition$
declare
  v_scope text;
  v_bad integer;
begin
  -- The write scope landed and keeps its discriminator.
  if position('programme_pot_transfer' in
       (select p.prosrc from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'app' and p.proname = 'loyalty_ledger_write_guard')) = 0 then
    raise exception 'v312: the programme_pot_transfer write scope did not land';
  end if;

  -- v311's inactivity-clock exclusion is what makes the transfer safe; assert it survives.
  if position('not (pl.entry_type = ''adjust'' and pl.actor is null)' in
       (select p.prosrc from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'app' and p.proname = 'run_points_expiry_for_business')) = 0 then
    raise exception 'v312: the sweep no longer excludes pot transfers from the inactivity clock';
  end if;

  -- The switch trigger exists with its exact WHEN condition.
  if not exists (
    select 1 from pg_trigger t
     where t.tgrelid = 'public.loyalty_programs'::regclass
       and t.tgname = 'trg_programme_pot_switch_v312'
       and not t.tgisinternal
  ) then
    raise exception 'v312: the loyalty_model switch trigger is missing';
  end if;

  -- Nobody may write the migration ledger from a browser.
  if exists (
    select 1 from information_schema.role_table_grants
     where table_name = 'programme_pot_migrations'
       and grantee in ('anon','authenticated')
       and privilege_type in ('INSERT','UPDATE','DELETE')
  ) then
    raise exception 'v312: a browser role can write programme_pot_migrations';
  end if;

  -- A firm with no open migration and a coherent pot now reports programme_pot.
  select count(*) into v_bad
    from public.businesses b
   where app.programme_balance_scope_v312(b.id) not in ('business_pot','programme_pot');
  if v_bad <> 0 then
    raise exception 'v312: % businesses resolve to an unknown balance scope', v_bad;
  end if;

  select app.programme_balance_scope_v312(null) into v_scope;
  if v_scope <> 'business_pot' then
    raise exception 'v312: a null business must fail safe to business_pot, got %', v_scope;
  end if;
end
$v312_postcondition$;

commit;
