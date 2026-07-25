-- FRENLY v70 - LEGACY GIFT-CARD / CREDIT NON-OVERLAP (+ amount-specific acknowledgement)
--
-- Pinned contract: docs/design/ps2/PS2_LIVE_V70_LEGACY_NON_OVERLAP_CONTRACT.md. Forward-only;
-- v61-v69 are not rewritten except for the four surgical CREATE-OR-REPLACE replacements enumerated
-- in section 0 below. Builder base: the v69 freeze (fb2c5d5); this migration sits on 12df2ef.
--
-- WHAT THIS MIGRATION DOES AND DOES NOT DO. It (1) makes every legacy value-MINTING path refuse to
-- issue NEW legacy gift-card value once a business is 'live' on stored value, while leaving every
-- REDEMPTION path working; (2) ships an append-only, amount-specific acknowledgement mechanism so a
-- business that legitimately holds outstanding legacy gift cards can reconcile CLEAN against a zero
-- stored-value ledger, and re-dirty the moment the legacy balance drifts from the acknowledged
-- figure; (3) ships an inventory report RPC + a super-admin classification mechanism; and (4) leaves
-- ZZ-SYNTHETIC's structural marker to a sanctioned runtime act (section 4 explains why).
--
-- APPLYING v70 MOVES ZERO VALUE, DELETES/VOIDS/MIGRATES NO LEGACY ROW, ACTIVATES NOBODY, AND
-- PRE-SEEDS NO ACKNOWLEDGEMENT OR CLASSIFICATION. Two before/after censuses (section 1 + the
-- postcondition block) PROVE it: every sv_authority row is byte-unchanged, every gift_cards row is
-- byte-unchanged (so any outstanding pilot card - e.g. kopi tiam's active $50 card - is intact and
-- still redeemable), and the two new decision tables are empty on apply. The kopi-tiam 5000c
-- acknowledgement and every business classification are pilot-cutover-time runtime acts, gated on
-- v69 being applied and the pilot being designated - never data baked into this migration
-- (contract A2/section 6: data decisions stay outside the migration).
--
-- WHY NO MIGRATION OF LEGACY BALANCES INTO SV LOTS. Minting an SV lot from a legacy gift-card /
-- store-credit balance would create stored value with NO payment-evidence row, which v68a's
-- sv_no_payment_evidence cap exists to forbid, and it would double-count against the original cash
-- the legacy value already represents. Non-overlap is the safe relationship: existing legacy value
-- is honoured to extinction through the still-working redemption paths; new legacy value stops once
-- SV is live; the two pools never both mint for one business/asset. v70 migrates nothing.
--
-- =====================================================================================
-- SECTION 0  THE FOUR REPLACED FUNCTIONS AND THEIR EXACT DELTAS (house rule 1: latest prior
--            definition reproduced verbatim; only the stated delta added). NO pg_get_functiondef
--            splice is used anywhere in this migration.
--   1. public.issue_gift_card(uuid,integer,uuid,text,uuid)  (v41, the active 5-arg issuer) -
--      ADDED one line: `perform app.sv_legacy_issue_guard(p_business, 'gift_card');` placed AFTER
--      the idempotent-replay return branch and BEFORE any write, so a completed pre-live issuance
--      still replays its cached result and only genuinely NEW issuance is refused. ACL unchanged
--      (authenticated), restated for determinism.
--   2. public.issue_gift_card(uuid,integer,uuid,text)  (v9, the 4-arg overload; browser-REVOKED
--      since v41) - ADDED the same one line after the positive-amount check and before the mint.
--      ACL unchanged (revoked from every browser role since v41), restated for determinism: this
--      overload stays callable only by service_role / SQL, and is gated all the same.
--   3. public.run_sv_reconciliation(uuid)  (v69) - ADDED acknowledgement netting: the outstanding
--      legacy value flagged missing_in_studio is netted against the LATEST acknowledged amount; an
--      exact match nets to clean, any drift (a new card, a partial redemption) emits ONE
--      acknowledgement_drift discrepancy and re-blocks. Every other byte (both direction loops, the
--      never-downgrade-a-live-tenant predicate, the read-only gift_cards handling) is preserved.
--   4. public.get_sv_reconciliation(uuid)  (v62) - ADDED `acknowledged_cents` to the latest_snapshot
--      object so the netting is visible in the primary read path. Every other byte preserved.
--
-- =====================================================================================
-- SECTION 1  THE ENUMERATED LEGACY VALUE-MINTING PATHS (contract section 1). The builder grepped
--   the whole catalog for every function inserting into public.gift_cards or writing a POSITIVE
--   public.credit_ledger entry, then classified each by whether it MINTS new legacy value (an owner
--   act analogous to an SV top-up) or REDEEMS/earns already-owed value (must keep working):
--
--   GATED (mint new legacy gift-card value -> refuse when sv_authority.state='live'):
--     * public.issue_gift_card(uuid,integer,uuid,text,uuid)   [v41, active 5-arg]
--     * public.issue_gift_card(uuid,integer,uuid,text)        [v9,  4-arg, browser-revoked]
--   These are the ONLY direct "issue new legacy value" acts in the catalog: each creates a
--   gift_cards row AND a kind='gift_card' sale (a fresh liability), exactly the analog of a top-up,
--   and gift_cards is precisely what reconciliation compares SV against.
--
--   NOT GATED - redemption / earn / restitution of already-owed value (gating strands money or
--   breaks loyalty; contract's don't-strand-rows rule + redemption-must-work rule):
--     * public.record_credit_tender(...)          [v20] - MISCLASSIFIED BY THE MANDATE. This is a
--         store-credit SPEND (entry_type='spend', amount_cents = -x; it refuses when the client has
--         insufficient credit). It DESTROYS legacy value, it never mints. Gating it would strand a
--         customer's own store credit at the counter - a direct violation of the v14 don't-strand
--         rule and the contract's own "redemption must keep working". FLAGGED, deliberately NOT gated.
--     * public.redeem_gift_card(...) [v20] / public.redeem_gift_card_v41(...) [v41] - redemption of
--         an already-issued gift card into store credit (gift_card_load). Redemption; not gated.
--     * public.redeem_points / redeem_reward / redeem_reward_core / redeem_reward_at_context
--         [v23e/v24a/v27/v34/v41] - conversion of already-EARNED loyalty points into credit
--         (loyalty_earn). Customer-initiated redemption; gating breaks loyalty. Not gated.
--     * app.on_sale_recorded() [trigger; latest v37b] - the automatic loyalty / retention /
--         referral EARN engine (loyalty_earn / referral_reward) that fires on sale COMPLETION -
--         CLAUDE.md's universal earn signal. A system trigger, not an owner "issue" act; gating it
--         would kill all loyalty on a live business. Not gated.
--     * public.enroll_membership / enroll_membership_v41 / app.run_membership_renewals
--         [v20/v41] - membership_credit is a benefit of a PAID membership sale (the sale is the
--         funding). Not an ad-hoc issue; not gated.
--     * public.reverse_sale / public.reverse_loyalty_redemption [v34] - reversals/corrections
--         (manual_adjust). Restitution; not gated.
--   There is NO standalone "owner mints arbitrary store credit" RPC in the catalog: every positive
--   credit_ledger write is one of the redemption/earn/restitution paths above. So gift-card issuance
--   is the complete set of gated minting paths.
--
-- =====================================================================================
-- SECTION 2  AMOUNT-SPECIFIC ACKNOWLEDGEMENT (contract section 2 + A2). public.sv_legacy_acknowledgements
--   is append-only (immutable, no delete, browser DML revoked, RLS owner+super-admin read). An owner
--   or super-admin records the EXACT outstanding legacy cents that are known/accepted, with reason +
--   actor + timestamp. run_sv_reconciliation reads the LATEST acknowledgement and nets it against the
--   outstanding missing_in_studio total: exact match -> clean; drift (legacy grows OR a partial
--   redemption shrinks it, incl. to zero) -> ONE acknowledgement_drift discrepancy -> blocked again,
--   until re-acknowledged at the new amount. Never a blanket "ignore legacy" - always a statement
--   about a specific measured amount. The suite proves both directions with the exact 5000c figure.
--
-- =====================================================================================
-- SECTION 3  MEASURED INVENTORY (contract section 3), from prod ground truth pinned in the contract
--   (measured 2026-07-26; re-measure before any prod act). v70 DELETES / RESETS / MIGRATES NOTHING:
--
--     business                          is_synth  gift_cards(active/cents)  credit_cents  SV_cents  intended classification
--     kopi tiam (pilot candidate)       false     1 / 5000                  0             0         pilot         (honour to extinction)
--     QA Go-Live Cafe                   false     1 / 5000                  0             0         qa_reset      (candidate; no reset here)
--     QA Test Cafe                      false     0 / 0                     12000         0         qa_reset      (candidate; no reset here)
--     ZZ-SYNTHETIC PS1B1 UAT Journey    false*    0 / 0                     300           0         mark synthetic (section 4; runtime act)
--     ZZZ Stored-Value Shadow Canary    true      0 / 0                     0             5500      (canary; already structurally synthetic)
--   *name-only synthetic; structural is_synthetic=false today. Reconciliation compares SV against
--   gift_cards only, so QA Test Cafe (credit, no cards) already reconciles clean; kopi tiam and QA
--   Go-Live Cafe each hold one $50 card that reads missing_in_studio until acknowledged. Classification
--   is recorded at runtime through public.classify_legacy_business (super-admin only), never seeded
--   here; the machine-readable live inventory is public.get_legacy_value_inventory.
--
-- =====================================================================================
-- SECTION 4  ZZ-SYNTHETIC IS NOT STRUCTURALLY SYNTHETIC - v70 LEAVES IT UNMARKED, ON PURPOSE.
--   ZZ-SYNTHETIC PS1B1 UAT Journey carries is_synthetic=false yet 300c of legacy credit and a
--   synthetic name. The sanctioned fix is public.set_synthetic_marker (super-admin only, audited),
--   which v70 CANNOT call from inside a migration (it gates on auth.uid(), NULL under DDL). The
--   builder deliberately does NOT hand-roll a guarded in-migration UPDATE because:
--     (a) it is a per-tenant DATA decision naming one specific prod business, which contract A2/
--         section 6 keeps OUT of the migration (same rule that forbids pre-seeding the kopi-tiam ack);
--     (b) this migration must apply byte-identically on the rehearsal chain, where ZZ-SYNTHETIC does
--         not exist - a name-matched update would be untestable dead code there;
--     (c) marking it flips a HISTORICAL PROJECTION: v66's public.v_business_billing excludes
--         is_synthetic=true businesses, so ZZ-SYNTHETIC would drop out of billing. Whether that is
--         desired is an owner/super-admin call, flagged here rather than silently done inside a
--         value-non-overlap migration.
--   RECOMMENDATION (runbook, not migration): after apply, a super-admin runs
--     select public.set_synthetic_marker('<zz_business_id>', null, true,
--            'v70 section 4: ZZ-SYNTHETIC PS1B1 UAT Journey is structurally synthetic');
--   which writes the SV_SYNTHETIC_MARKER_SET audit row and corrects billing exclusion. The 300c of
--   legacy credit is untouched by that marker and remains honoured to extinction.
--
-- =====================================================================================
-- SECTION 5  GATES + NON-GOALS. No value moved; no legacy row deleted/voided/migrated; no cutover;
--   no activation; typed refusals mutate nothing. The postcondition block re-proves the censuses.

begin;

-- =====================================================================
-- 1. CENSUS BEFORE. Snapshot every authority state AND every gift-card balance so the postcondition
--    can PROVE that applying v70 moved no value and touched no legacy row. Held in TEMP tables
--    dropped at commit. (credit_ledger is a pure append-only ledger reconciliation never mutates;
--    the gift_cards + sv_authority censuses are the load-bearing pair.)
-- =====================================================================
create temporary table v70_authority_census_before on commit drop as
select business_id, asset, state from public.sv_authority;

create temporary table v70_giftcard_census_before on commit drop as
select id, business_id, code, initial_cents, balance_cents, status from public.gift_cards;

-- =====================================================================
-- 2. app.sv_legacy_issue_guard - the shared non-overlap refusal (section 1). Raises the typed
--    sv_live_legacy_issue_blocked ONLY when the business is 'live' on stored value. Reads one row;
--    mutates nothing. Called by the gated legacy-issuing paths.
-- =====================================================================
create or replace function app.sv_legacy_issue_guard(p_business uuid, p_kind text default 'gift_card')
returns void language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if exists (
    select 1 from public.sv_authority a
     where a.business_id = p_business
       and a.asset = 'stored_value'
       and a.state = 'live')
  then
    raise exception 'sv_live_legacy_issue_blocked: this business is live on stored value; issuing new legacy % value is blocked (one live value authority per asset - existing value is honoured to extinction and stays redeemable)', p_kind
      using errcode = '22023';
  end if;
end $$;
revoke all on function app.sv_legacy_issue_guard(uuid, text) from public, anon, authenticated;

-- =====================================================================
-- 3. REPLACED (v41): public.issue_gift_card 5-arg. Verbatim v41 body; the ONLY delta is the single
--    guard line marked `-- v70 section 1` below, placed after the idempotent-replay return and
--    before any write.
-- =====================================================================
create or replace function public.issue_gift_card(
  p_business uuid,
  p_amount integer,
  p_purchaser uuid,
  p_recipient_email text,
  p_idempotency_key uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_staff uuid;
  v_email text := nullif(lower(btrim(p_recipient_email)), '');
  v_payload jsonb;
  v_hash text;
  v_existing public.gift_card_issue_operations%rowtype;
  v_code text;
  v_card public.gift_cards%rowtype;
  v_sale public.sales%rowtype;
  v_result jsonb;
begin
  if v_actor is null
     or not app.can_module_write(p_business, 'giftcards')
     or not app.has_perm(p_business, 'create_sales') then
    raise exception 'active giftcards-module and create-sales authorization is required'
      using errcode = '42501';
  end if;
  select s.id into v_staff
    from public.staff s
   where s.business_id = p_business
     and s.user_id = v_actor
     and s.active
     and 'create_sales' = any (app.role_perms(s.role))
   order by case when s.role = 'owner' then 0 else 1 end, s.created_at
   limit 1
   for update;
  if not found then
    raise exception 'active staff authorization is required'
      using errcode = '42501';
  end if;
  if p_idempotency_key is null or p_amount is null or p_amount <= 0
     or p_amount > 100000000 or (v_email is not null and char_length(v_email) > 320) then
    raise exception 'invalid gift-card issuance request'
      using errcode = '22023';
  end if;
  if p_purchaser is not null and not exists (
    select 1 from public.clients c
     where c.id = p_purchaser and c.business_id = p_business
  ) then
    raise exception 'purchaser does not belong to this business'
      using errcode = '22023';
  end if;

  v_payload := jsonb_build_object(
    'amount_cents', p_amount,
    'business_id', p_business,
    'purchaser_client_id', p_purchaser,
    'recipient_email', v_email
  );
  v_hash := app.v41_request_hash(v_payload::text);
  perform pg_advisory_xact_lock(hashtextextended(
    'v41:gift-card:' || p_business::text || ':' || p_idempotency_key::text, 0));

  select * into v_existing
    from public.gift_card_issue_operations o
   where o.business_id = p_business
     and o.idempotency_key = p_idempotency_key
   for update;
  if found then
    if v_existing.actor is distinct from v_actor
       or v_existing.request_hash <> v_hash then
      raise exception 'idempotency key conflicts with another gift-card request'
        using errcode = '23505';
    end if;
    select * into v_card
      from public.gift_cards g
     where g.id = v_existing.gift_card_id
       and g.business_id = p_business
     for share;
    return jsonb_build_object(
      'status', 'completed',
      'gift_card_id', v_existing.gift_card_id,
      'sale_id', v_existing.sale_id,
      'code', v_card.code,
      'initial_cents', v_existing.amount_cents,
      'balance_cents', v_existing.amount_cents
    );
  end if;

  -- v70 section 1: non-overlap. A business live on stored value must not MINT new legacy gift-card
  -- value (existing cards are honoured to extinction and stay redeemable). A completed prior
  -- issuance replays above this guard, so only genuinely new issuance is refused; the refusal
  -- happens before every write, so it mutates nothing.
  perform app.sv_legacy_issue_guard(p_business, 'gift_card');

  if p_purchaser is not null then
    perform 1 from public.clients c
     where c.id = p_purchaser and c.business_id = p_business
     for share;
    if not found then
      raise exception 'purchaser does not belong to this business'
        using errcode = '22023';
    end if;
  end if;
  loop
    v_code := 'GC-' || upper(substr(md5(gen_random_uuid()::text || clock_timestamp()::text), 1, 12));
    exit when not exists (select 1 from public.gift_cards g where g.code = v_code);
  end loop;
  insert into public.gift_cards (
    business_id, code, initial_cents, balance_cents,
    purchaser_client_id, recipient_email
  ) values (
    p_business, v_code, p_amount, p_amount, p_purchaser, v_email
  ) returning * into v_card;
  insert into public.sales (
    business_id, client_id, kind, amount_cents, note, staff_id
  ) values (
    p_business, p_purchaser, 'gift_card', p_amount,
    'gift card liability issued', v_staff
  ) returning * into v_sale;

  v_result := jsonb_build_object(
    'status', 'completed',
    'gift_card_id', v_card.id,
    'sale_id', v_sale.id,
    'code', v_card.code,
    'initial_cents', v_card.initial_cents,
    'balance_cents', v_card.balance_cents
  );
  insert into public.gift_card_issue_operations (
    business_id, actor, idempotency_key, request_hash, status,
    amount_cents, gift_card_id, sale_id
  ) values (
    p_business, v_actor, p_idempotency_key, v_hash, 'completed',
    p_amount, v_card.id, v_sale.id
  );
  return v_result;
end
$$;
revoke all privileges on function public.issue_gift_card(uuid,integer,uuid,text,uuid)
  from public, anon, authenticated;
grant execute on function public.issue_gift_card(uuid,integer,uuid,text,uuid)
  to authenticated;

-- =====================================================================
-- 4. REPLACED (v9): public.issue_gift_card 4-arg overload. Verbatim v9 body with TWO deltas:
--    (a) the single non-overlap guard line; (b) its search_path is modernized from the pre-v21
--    `set search_path = public` to the canonical `pg_catalog, public, app, pg_temp` - required by
--    the pending-migration SECDEF search_path gate, and resolution is unchanged (public stays on the
--    path so gift_cards/sales still resolve; every app.* call is schema-qualified). This overload has
--    been browser-REVOKED since v41 and stays so (restated); it remains callable only by
--    service_role / SQL and is gated all the same.
-- =====================================================================
create or replace function public.issue_gift_card(
  p_business uuid, p_amount integer, p_purchaser uuid, p_recipient_email text)
returns json language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp' as $$
declare v_code text; gc gift_cards;
begin
  if not app.is_salon_member(p_business) then raise exception 'not a member of this business'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'amount must be positive'; end if;
  -- v70 section 1: non-overlap (see the 5-arg overload). Refuse minting new legacy value when live.
  perform app.sv_legacy_issue_guard(p_business, 'gift_card');
  loop
    v_code := 'GC-' || upper(substr(md5(random()::text || clock_timestamp()::text),1,8));
    exit when not exists (select 1 from gift_cards where code = v_code);
  end loop;
  insert into gift_cards (business_id, code, initial_cents, balance_cents,
                          purchaser_client_id, recipient_email)
  values (p_business, v_code, p_amount, p_amount, p_purchaser, p_recipient_email)
  returning * into gc;
  -- was 'retail' (v5) -> cash collected against a liability, never revenue at purchase.
  insert into sales (business_id, client_id, kind, amount_cents, note)
  values (p_business, p_purchaser, 'gift_card', p_amount, 'gift card sold: ' || v_code);
  return row_to_json(gc);
end $$;
-- 4-arg overload stays revoked from every browser role (v41 invariant); no authenticated grant.
revoke all privileges on function public.issue_gift_card(uuid,integer,uuid,text)
  from public, anon, authenticated;

-- =====================================================================
-- 5. public.sv_legacy_acknowledgements - append-only, amount-specific acknowledgement (section 2).
--    Immutable (no update/delete via app.sv_immutable_guard), RLS owner + super-admin read, every
--    browser privilege revoked. Latest row per (business, asset) is authoritative.
-- =====================================================================
-- seq is a monotonic identity so "latest acknowledgement wins" is deterministic even when several
-- appends share a transaction timestamp (now() is txn-constant); created_at ordering alone would
-- tie-break on a random uuid. Latest-by-seq is the authoritative current acknowledgement.
create table public.sv_legacy_acknowledgements (
  id uuid primary key default gen_random_uuid(),
  seq bigint not null generated always as identity,
  business_id uuid not null references public.businesses(id) on delete cascade,
  asset text not null default 'stored_value' check (asset = 'stored_value'),
  acknowledged_cents bigint not null check (acknowledged_cents >= 0),
  reason text not null check (char_length(btrim(reason)) >= 10),
  actor uuid,
  created_at timestamptz not null default now(),
  constraint sv_legacy_acknowledgements_id_business_uk unique (id, business_id)
);
create index sv_legacy_acknowledgements_business_idx
  on public.sv_legacy_acknowledgements (business_id, asset, seq desc);
create trigger sv_legacy_acknowledgements_immutable_guard
  before update or delete on public.sv_legacy_acknowledgements
  for each row execute function app.sv_immutable_guard();
alter table public.sv_legacy_acknowledgements enable row level security;
create policy sv_legacy_acknowledgements_owner_read on public.sv_legacy_acknowledgements
  for select to authenticated using (app.is_salon_owner(business_id));
create policy sv_legacy_acknowledgements_sa_read on public.sv_legacy_acknowledgements
  for select to authenticated using (app.is_super_admin());
revoke all on public.sv_legacy_acknowledgements from public, anon, authenticated;
grant select on public.sv_legacy_acknowledgements to authenticated;

-- =====================================================================
-- 6. public.acknowledge_legacy_value - owner or super-admin records an EXACT acknowledged cent
--    amount (section 2). Writes one append-only row + an audit entry; moves no value.
-- =====================================================================
create or replace function public.acknowledge_legacy_value(
  p_business uuid, p_asset text, p_acknowledged_cents bigint, p_reason text)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_asset text := coalesce(p_asset, 'stored_value');
  v_reason text := btrim(coalesce(p_reason, ''));
  v_id uuid := gen_random_uuid();
begin
  if not (app.is_salon_owner(p_business) or app.is_super_admin()) then
    raise exception 'owner or super-admin only' using errcode = '42501';
  end if;
  if v_asset <> 'stored_value' then
    raise exception 'only the stored_value asset is supported for legacy acknowledgement' using errcode = '22023';
  end if;
  if p_acknowledged_cents is null or p_acknowledged_cents < 0 then
    raise exception 'a legacy acknowledgement requires an amount of zero or more cents' using errcode = '22023';
  end if;
  if char_length(v_reason) < 10 then
    raise exception 'a legacy-value acknowledgement requires a reason of at least 10 characters' using errcode = '22023';
  end if;
  if not exists (select 1 from public.businesses b where b.id = p_business) then
    raise exception 'business not found' using errcode = '22023';
  end if;
  insert into public.sv_legacy_acknowledgements(id, business_id, asset, acknowledged_cents, reason, actor)
  values (v_id, p_business, v_asset, p_acknowledged_cents, v_reason, v_actor);
  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'SV_LEGACY_VALUE_ACKNOWLEDGED', 'sv_legacy_acknowledgements', v_id,
    jsonb_build_object('asset', v_asset, 'acknowledged_cents', p_acknowledged_cents, 'reason', v_reason));
  return jsonb_build_object('status', 'ok', 'business_id', p_business, 'asset', v_asset,
    'acknowledgement_id', v_id, 'acknowledged_cents', p_acknowledged_cents);
end $$;
revoke all on function public.acknowledge_legacy_value(uuid, text, bigint, text) from public, anon, authenticated;
grant execute on function public.acknowledge_legacy_value(uuid, text, bigint, text) to authenticated;

-- =====================================================================
-- 7. public.get_legacy_acknowledgements - owner/super-admin read of the acknowledgement history +
--    the current (latest) acknowledged amount.
-- =====================================================================
create or replace function public.get_legacy_acknowledgements(p_business uuid, p_asset text default 'stored_value')
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_asset text := coalesce(p_asset, 'stored_value');
  v_current bigint;
  v_history jsonb;
begin
  if not (app.is_salon_owner(p_business) or app.is_super_admin()) then
    raise exception 'not permitted to view legacy acknowledgements for this business' using errcode = '42501';
  end if;
  select acknowledged_cents into v_current from public.sv_legacy_acknowledgements
   where business_id = p_business and asset = v_asset
   order by seq desc limit 1;
  select coalesce(jsonb_agg(jsonb_build_object(
      'acknowledgement_id', a.id, 'acknowledged_cents', a.acknowledged_cents,
      'reason', a.reason, 'actor', a.actor, 'created_at', a.created_at)
      order by a.seq desc), '[]'::jsonb)
    into v_history
    from public.sv_legacy_acknowledgements a
   where a.business_id = p_business and a.asset = v_asset;
  return jsonb_build_object(
    'business_id', p_business, 'asset', v_asset,
    'current_acknowledged_cents', v_current, 'history', v_history);
end $$;
revoke all on function public.get_legacy_acknowledgements(uuid, text) from public, anon, authenticated;
grant execute on function public.get_legacy_acknowledgements(uuid, text) to authenticated;

-- =====================================================================
-- 8. public.sv_legacy_classifications - append-only owner-facing classification (section 3).
--    Immutable, RLS owner + super-admin read, browser DML revoked. Latest row per business is
--    authoritative. v70 seeds NO rows.
-- =====================================================================
create table public.sv_legacy_classifications (
  id uuid primary key default gen_random_uuid(),
  seq bigint not null generated always as identity,   -- monotonic latest-wins (see acknowledgements)
  business_id uuid not null references public.businesses(id) on delete cascade,
  classification text not null check (classification in ('pilot', 'qa_reset', 'retain_fixture')),
  reason text not null check (char_length(btrim(reason)) >= 10),
  actor uuid,
  created_at timestamptz not null default now(),
  constraint sv_legacy_classifications_id_business_uk unique (id, business_id)
);
create index sv_legacy_classifications_business_idx
  on public.sv_legacy_classifications (business_id, seq desc);
create trigger sv_legacy_classifications_immutable_guard
  before update or delete on public.sv_legacy_classifications
  for each row execute function app.sv_immutable_guard();
alter table public.sv_legacy_classifications enable row level security;
create policy sv_legacy_classifications_owner_read on public.sv_legacy_classifications
  for select to authenticated using (app.is_salon_owner(business_id));
create policy sv_legacy_classifications_sa_read on public.sv_legacy_classifications
  for select to authenticated using (app.is_super_admin());
revoke all on public.sv_legacy_classifications from public, anon, authenticated;
grant select on public.sv_legacy_classifications to authenticated;

-- =====================================================================
-- 9. public.classify_legacy_business - super-admin only (a firm cannot classify its own legacy data,
--    exactly as a firm cannot designate itself for cutover). Records a classification of record;
--    resets NOTHING (any actual reset is a separate owner-authorised act).
-- =====================================================================
create or replace function public.classify_legacy_business(
  p_business uuid, p_classification text, p_reason text)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_reason text := btrim(coalesce(p_reason, ''));
  v_id uuid := gen_random_uuid();
begin
  if not app.is_super_admin() then
    raise exception 'super-admin only: legacy classification is a platform decision' using errcode = '42501';
  end if;
  if p_classification is null or p_classification not in ('pilot', 'qa_reset', 'retain_fixture') then
    raise exception 'classification must be one of pilot / qa_reset / retain_fixture' using errcode = '22023';
  end if;
  if char_length(v_reason) < 10 then
    raise exception 'a legacy classification requires a reason of at least 10 characters' using errcode = '22023';
  end if;
  if not exists (select 1 from public.businesses b where b.id = p_business) then
    raise exception 'business not found' using errcode = '22023';
  end if;
  insert into public.sv_legacy_classifications(id, business_id, classification, reason, actor)
  values (v_id, p_business, p_classification, v_reason, v_actor);
  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'SV_LEGACY_BUSINESS_CLASSIFIED', 'sv_legacy_classifications', v_id,
    jsonb_build_object('classification', p_classification, 'reason', v_reason));
  return jsonb_build_object('status', 'ok', 'business_id', p_business,
    'classification', p_classification, 'classification_id', v_id);
end $$;
revoke all on function public.classify_legacy_business(uuid, text, text) from public, anon, authenticated;
grant execute on function public.classify_legacy_business(uuid, text, text) to authenticated;

-- =====================================================================
-- 10. public.get_legacy_value_inventory - machine-generated inventory of every outstanding legacy
--     value row (section 3). p_business null => platform-wide (super-admin only); a business id =>
--     that tenant (owner or super-admin). Reads only; moves nothing. gift_cards = outstanding
--     card balances; store_credit = per-client net credit_ledger balances (<> 0). Also surfaces the
--     latest classification + acknowledgement so the report reasons about non-overlap readiness.
-- =====================================================================
create or replace function public.get_legacy_value_inventory(p_business uuid default null)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_result jsonb;
begin
  if p_business is null then
    if not app.is_super_admin() then
      raise exception 'super-admin only for the platform-wide legacy value inventory' using errcode = '42501';
    end if;
  else
    if not (app.is_salon_owner(p_business) or app.is_super_admin()) then
      raise exception 'not permitted to view legacy value inventory for this business' using errcode = '42501';
    end if;
  end if;

  select coalesce(jsonb_agg(row order by (row->>'business_name')), '[]'::jsonb) into v_result
  from (
    select jsonb_build_object(
      'business_id', b.id,
      'business_name', b.name,
      'is_synthetic', b.is_synthetic,
      'authority_state', coalesce(sa.state, 'unbuilt'),
      'classification', cls.classification,
      'classification_reason', cls.reason,
      'latest_acknowledged_cents', ack.acknowledged_cents,
      'gift_card_total_cents', coalesce(gc.total, 0),
      'gift_cards', coalesce(gc.rows, '[]'::jsonb),
      'store_credit_total_cents', coalesce(cr.total, 0),
      'store_credit', coalesce(cr.rows, '[]'::jsonb)
    ) as row
    from public.businesses b
    left join lateral (
      select a.state from public.sv_authority a
       where a.business_id = b.id and a.asset = 'stored_value') sa on true
    left join lateral (
      select c.classification, c.reason from public.sv_legacy_classifications c
       where c.business_id = b.id order by c.seq desc limit 1) cls on true
    left join lateral (
      select k.acknowledged_cents from public.sv_legacy_acknowledgements k
       where k.business_id = b.id and k.asset = 'stored_value'
       order by k.seq desc limit 1) ack on true
    left join lateral (
      select sum(g.balance_cents)::bigint as total,
             jsonb_agg(jsonb_build_object(
               'gift_card_id', g.id, 'code_suffix', right(g.code, 4), 'cents', g.balance_cents,
               'status', g.status,
               'age_days', floor(extract(epoch from (now() - g.created_at)) / 86400)::int)
               order by g.created_at, g.id) as rows
        from public.gift_cards g
       where g.business_id = b.id and g.balance_cents <> 0) gc on true
    left join lateral (
      select sum(t.bal)::bigint as total,
             jsonb_agg(jsonb_build_object(
               'client_id', t.client_id, 'cents', t.bal,
               'age_days', floor(extract(epoch from (now() - t.first_at)) / 86400)::int)
               order by t.client_id) as rows
        from (select cl.client_id, sum(cl.amount_cents) as bal, min(cl.created_at) as first_at
                from public.credit_ledger cl
               where cl.business_id = b.id
               group by cl.client_id
              having sum(cl.amount_cents) <> 0) t) cr on true
    where p_business is null or b.id = p_business
  ) s;
  return v_result;
end $$;
revoke all on function public.get_legacy_value_inventory(uuid) from public, anon, authenticated;
grant execute on function public.get_legacy_value_inventory(uuid) to authenticated;

-- =====================================================================
-- 11. sv_reconciliation_snapshots gets a nullable acknowledged_cents column so the netting the
--     status/discrepancy_count reflect is persisted and auditable. Additive; existing rows keep
--     NULL; the immutable guard fires only on row UPDATE/DELETE, never on this DDL.
-- =====================================================================
alter table public.sv_reconciliation_snapshots
  add column acknowledged_cents bigint;

-- =====================================================================
-- 12. Widen the frozen reconciliation-discrepancy category vocabulary to add acknowledgement_drift
--     (catalog-resolved drop+add, the v69-sv_operations pattern; only WIDENS the accepted set).
-- =====================================================================
do $v70_discrepancy_category_vocab$
declare v_name text; v_def text;
begin
  select c.conname, pg_get_constraintdef(c.oid) into v_name, v_def
    from pg_constraint c
   where c.conrelid = 'public.sv_reconciliation_discrepancies'::regclass and c.contype = 'c'
     and pg_get_constraintdef(c.oid) like '%category%';
  if v_name is null then
    raise exception 'v70: the sv_reconciliation_discrepancies category CHECK constraint was not found';
  end if;
  if position('acknowledgement_drift' in v_def) > 0 then
    raise exception 'v70: sv_reconciliation_discrepancies already accepts acknowledgement_drift';
  end if;
  if position('missing_in_studio' in v_def) = 0 or position('missing_in_legacy' in v_def) = 0 then
    raise exception 'v70: unexpected sv_reconciliation_discrepancies category CHECK definition: %', v_def;
  end if;
  execute format('alter table public.sv_reconciliation_discrepancies drop constraint %I', v_name);
end
$v70_discrepancy_category_vocab$;

alter table public.sv_reconciliation_discrepancies
  add constraint sv_reconciliation_discrepancies_category_check check (category in
    ('missing_in_studio', 'missing_in_legacy', 'amount_mismatch', 'orphan_legacy_record',
     'duplicate_legacy_event', 'invalid_legacy_balance', 'acknowledgement_drift'));

-- =====================================================================
-- 13. REPLACED (v69): public.run_sv_reconciliation. Verbatim v69 body; the ONLY deltas are the
--     acknowledgement lookup, the netting block (marked `-- v70`), and the acknowledged_cents that
--     is now recorded in the snapshot, the return object and the audit entry. The gift_cards read
--     stays read-only; the never-downgrade-a-live-tenant predicate is preserved byte-for-byte.
-- =====================================================================
create or replace function public.run_sv_reconciliation(p_business uuid)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_asset text := 'stored_value';
  v_run uuid := gen_random_uuid();
  v_snapshot uuid := gen_random_uuid();
  v_authority text;
  gc record;
  v_legacy_ref text;
  v_studio integer;
  v_legacy_total bigint := 0;
  v_studio_total bigint := 0;
  v_disc integer;
  v_status text;
  v_category text;
  v_dup boolean;
  v_discrepancies jsonb := '[]'::jsonb;
  v_ack_cents bigint;       -- v70: latest acknowledged outstanding legacy amount (null = none)
  v_missing_total bigint;   -- v70: outstanding legacy value flagged missing_in_studio
  v_net bigint;             -- v70: missing_total - acknowledged (0 = clean; != 0 = drift)
begin
  if not (app.is_salon_owner(p_business) or app.sv_automation_context()) then
    raise exception 'owner only' using errcode = '42501';
  end if;
  select state into v_authority from public.sv_authority
   where business_id = p_business and asset = v_asset;
  if v_authority is null then
    raise exception 'stored-value authority is not initialised for this business' using errcode = '22023';
  end if;

  -- v70: the LATEST amount-specific acknowledgement for this (business, asset). NULL => behave
  -- exactly as v69 (every outstanding card reads missing_in_studio). Never a blanket ignore.
  select acknowledged_cents into v_ack_cents from public.sv_legacy_acknowledgements
   where business_id = p_business and asset = v_asset
   order by seq desc limit 1;

  -- Direction 1: legacy (gift_cards, READ-ONLY) -> studio projection. No migration linkage
  -- exists in PS-2A, so the studio value attributable to any legacy gift card is 0.
  for gc in
    select id, code, balance_cents, status, purchaser_client_id
      from public.gift_cards
     where business_id = p_business
     order by id
  loop
    v_legacy_ref := 'legacy:giftcard:' || gc.id::text;
    v_studio := 0;
    v_legacy_total := v_legacy_total + coalesce(gc.balance_cents, 0);
    v_studio_total := v_studio_total + v_studio;

    -- Shadow evaluation: the would-be mint projection of this legacy balance into the studio
    -- ledger. Writing it moves NO value (append-only shadow log only).
    perform app.sv_write_shadow_evaluation(
      p_business, null, v_asset, 'topup',
      jsonb_build_array(jsonb_build_object('class', 'paid', 'kind', 'issue', 'cents', coalesce(gc.balance_cents, 0))),
      coalesce(gc.balance_cents, 0), v_legacy_ref, 'reconcile_projection');

    select count(*) > 1 into v_dup from public.gift_cards g
     where g.business_id = p_business and g.code = gc.code;

    v_category := null;
    if gc.balance_cents is null or gc.balance_cents < 0 then
      v_category := 'invalid_legacy_balance';
    elsif v_dup then
      v_category := 'duplicate_legacy_event';
    elsif gc.status in ('void', 'redeemed') and gc.balance_cents > 0 then
      v_category := 'orphan_legacy_record';
    elsif gc.balance_cents > 0 and v_studio = 0 then
      v_category := 'missing_in_studio';
    elsif gc.balance_cents <> v_studio then
      v_category := 'amount_mismatch';
    else
      v_category := null;   -- balance 0 (or exact match) -> clean, no discrepancy row
    end if;

    if v_category is not null then
      v_discrepancies := v_discrepancies || jsonb_build_object(
        'category', v_category,
        'legacy_ref', v_legacy_ref,
        'client_id', gc.purchaser_client_id,
        'legacy_cents', gc.balance_cents,
        'studio_cents', v_studio,
        'delta_cents', case when gc.balance_cents is null then null else gc.balance_cents - v_studio end,
        'detail', jsonb_build_object('code', gc.code, 'status', gc.status, 'source', 'gift_cards'));
    end if;
  end loop;

  -- Direction 2: a studio record claiming a legacy gift-card origin (a prior shadow
  -- evaluation's legacy_ref) whose gift card has vanished -> missing_in_legacy. Empty on a
  -- fresh tenant (every current card exists); DISTINCT so each vanished ref is one row.
  for v_legacy_ref in
    select distinct se.legacy_ref
      from public.sv_shadow_evaluations se
     where se.business_id = p_business
       and se.legacy_ref like 'legacy:giftcard:%'
       and not exists (
         select 1 from public.gift_cards g
          where g.business_id = p_business
            and 'legacy:giftcard:' || g.id::text = se.legacy_ref)
     order by se.legacy_ref
  loop
    v_discrepancies := v_discrepancies || jsonb_build_object(
      'category', 'missing_in_legacy',
      'legacy_ref', v_legacy_ref,
      'client_id', null,
      'legacy_cents', null,
      'studio_cents', 0,
      'delta_cents', null,
      'detail', jsonb_build_object('source', 'studio_shadow_origin'));
  end loop;

  -- v70: amount-specific acknowledgement netting (contract section 2). The outstanding legacy value
  -- flagged missing_in_studio is netted against the LATEST acknowledged amount. Exact match nets to
  -- clean (the missing_in_studio rows are removed); any drift - a new card grows the total, or a
  -- partial redemption (incl. to zero) shrinks it below the acknowledgement - re-blocks as ONE
  -- acknowledgement_drift row, until re-acknowledged at the new amount. Only missing_in_studio is
  -- subject to acknowledgement; data-integrity categories (invalid/duplicate/orphan/amount_mismatch/
  -- missing_in_legacy) are never papered over. When v_ack_cents is NULL this block is a no-op.
  if v_ack_cents is not null then
    select coalesce(sum((d->>'legacy_cents')::bigint), 0) into v_missing_total
      from jsonb_array_elements(v_discrepancies) d
     where d->>'category' = 'missing_in_studio';
    select coalesce(jsonb_agg(d), '[]'::jsonb) into v_discrepancies
      from jsonb_array_elements(v_discrepancies) d
     where d->>'category' <> 'missing_in_studio';
    v_net := v_missing_total - v_ack_cents;
    if v_net <> 0 then
      v_discrepancies := v_discrepancies || jsonb_build_object(
        'category', 'acknowledgement_drift',
        'legacy_ref', 'legacy:acknowledgement:' || v_asset,
        'client_id', null,
        'legacy_cents', v_missing_total,
        'studio_cents', v_ack_cents,
        'delta_cents', v_net,
        'detail', jsonb_build_object(
          'source', 'legacy_acknowledgement',
          'acknowledged_cents', v_ack_cents,
          'outstanding_missing_cents', v_missing_total,
          'direction', case when v_net > 0 then 'legacy_exceeds_acknowledgement'
                            else 'acknowledgement_exceeds_legacy' end));
    end if;
  end if;

  v_disc := jsonb_array_length(v_discrepancies);
  v_status := case when v_disc = 0 then 'clean' else 'blocked' end;

  -- Snapshot FIRST (the discrepancy rows carry a composite FK to it). v70: acknowledged_cents.
  insert into public.sv_reconciliation_snapshots(
    id, business_id, run_id, asset, source, actor,
    legacy_total_cents, studio_total_cents, discrepancy_count, status, acknowledged_cents)
  values (v_snapshot, p_business, v_run, v_asset, 'gift_cards', v_actor,
    v_legacy_total, v_studio_total, v_disc, v_status, v_ack_cents);

  insert into public.sv_reconciliation_discrepancies(
    business_id, run_id, snapshot_id, category, legacy_ref, client_id,
    legacy_cents, studio_cents, delta_cents, detail)
  select p_business, v_run, v_snapshot,
    d->>'category', d->>'legacy_ref', nullif(d->>'client_id', '')::uuid,
    (d->>'legacy_cents')::integer, (d->>'studio_cents')::integer, (d->>'delta_cents')::integer,
    coalesce(d->'detail', '{}'::jsonb)
  from jsonb_array_elements(v_discrepancies) d;

  -- Any open discrepancy blocks cutover (drives 'reconciliation_blocked' via the INTERNAL
  -- state path). NEVER auto-corrects, NEVER writes a legacy row.
  -- v69 (ADDED PREDICATE): a LIVE tenant is NEVER downgraded by this run. The discrepancy is
  -- still captured in the snapshot, the discrepancy rows and the audit entry; the owner control
  -- is sv_pause (§5). The state is re-read here rather than reusing the entry-time value so a
  -- cutover committed mid-run cannot be undone by a stale read.
  if v_disc > 0 and coalesce((select state from public.sv_authority
                               where business_id = p_business and asset = v_asset), '') <> 'live' then
    perform app.sv_apply_authority_state(
      p_business, v_asset, 'reconciliation_blocked', 'open stored-value reconciliation discrepancies', v_actor);
  end if;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'SV_RECONCILIATION_RUN', 'sv_reconciliation_snapshots', v_snapshot, jsonb_build_object(
    'run_id', v_run, 'status', v_status, 'discrepancy_count', v_disc,
    'legacy_total_cents', v_legacy_total, 'studio_total_cents', v_studio_total,
    'acknowledged_cents', v_ack_cents));

  return jsonb_build_object(
    'status', 'ok',
    'run_id', v_run,
    'snapshot_id', v_snapshot,
    'source', 'gift_cards',
    'reconciliation_status', v_status,
    'discrepancy_count', v_disc,
    'legacy_total_cents', v_legacy_total,
    'studio_total_cents', v_studio_total,
    'acknowledged_cents', v_ack_cents,
    'authority_state', (select state from public.sv_authority where business_id = p_business and asset = v_asset));
end $$;
revoke all on function public.run_sv_reconciliation(uuid) from public, anon, authenticated;
grant execute on function public.run_sv_reconciliation(uuid) to authenticated;

-- =====================================================================
-- 14. REPLACED (v62): public.get_sv_reconciliation. Verbatim v62 body; the ONLY delta is the
--     acknowledged_cents field ADDED to the latest_snapshot object so the netting is visible.
-- =====================================================================
create or replace function public.get_sv_reconciliation(p_business uuid)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_asset text := 'stored_value';
  v_authority text;
  v_snapshot public.sv_reconciliation_snapshots%rowtype;
  v_discrepancies jsonb;
begin
  if not (app.is_salon_owner(p_business) or app.is_super_admin()) then
    raise exception 'not permitted to view stored-value reconciliation for this business' using errcode = '42501';
  end if;

  select coalesce(state, 'unbuilt') into v_authority from public.sv_authority
   where business_id = p_business and asset = v_asset;
  v_authority := coalesce(v_authority, 'unbuilt');   -- fail closed if no authority row

  select * into v_snapshot from public.sv_reconciliation_snapshots
   where business_id = p_business and asset = v_asset
   order by captured_at desc, id desc limit 1;

  if not found then
    return jsonb_build_object(
      'business_id', p_business,
      'asset', v_asset,
      'authority_state', v_authority,
      'has_run', false,
      'latest_snapshot', null,
      'discrepancies', '[]'::jsonb);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'discrepancy_id', d.id, 'category', d.category, 'legacy_ref', d.legacy_ref,
      'client_id', d.client_id, 'legacy_cents', d.legacy_cents, 'studio_cents', d.studio_cents,
      'delta_cents', d.delta_cents, 'detail', d.detail) order by d.category, d.legacy_ref), '[]'::jsonb)
    into v_discrepancies
    from public.sv_reconciliation_discrepancies d
   where d.business_id = p_business and d.run_id = v_snapshot.run_id;

  return jsonb_build_object(
    'business_id', p_business,
    'asset', v_asset,
    'authority_state', v_authority,
    'has_run', true,
    'latest_snapshot', jsonb_build_object(
      'snapshot_id', v_snapshot.id, 'run_id', v_snapshot.run_id, 'captured_at', v_snapshot.captured_at,
      'source', v_snapshot.source, 'status', v_snapshot.status,
      'legacy_total_cents', v_snapshot.legacy_total_cents, 'studio_total_cents', v_snapshot.studio_total_cents,
      'acknowledged_cents', v_snapshot.acknowledged_cents,
      'discrepancy_count', v_snapshot.discrepancy_count),
    'discrepancies', v_discrepancies);
end $$;
revoke all on function public.get_sv_reconciliation(uuid) from public, anon, authenticated;
grant execute on function public.get_sv_reconciliation(uuid) to authenticated;

-- =====================================================================
-- 15. POSTCONDITIONS. The load-bearing pair: applying v70 moved no value, touched no legacy row,
--     activated nobody, and pre-seeded no decision row.
-- =====================================================================
do $v70_postconditions$
declare
  v_before integer;
  v_after integer;
  v_drift integer;
  v_live integer;
  v_def text;
begin
  -- (1) sv_authority is byte-unchanged (row-for-row): v70 activated nobody.
  select count(*) into v_before from v70_authority_census_before;
  select count(*) into v_after from public.sv_authority;
  if v_before <> v_after then
    raise exception 'v70: the sv_authority row count changed during apply (% -> %)', v_before, v_after;
  end if;
  select count(*) into v_drift
    from public.sv_authority a
    full join v70_authority_census_before b
      on b.business_id = a.business_id and b.asset = a.asset
   where a.business_id is null or b.business_id is null or a.state is distinct from b.state;
  if v_drift <> 0 then
    raise exception 'v70: % sv_authority row(s) changed during apply - v70 must activate nobody', v_drift;
  end if;
  select count(*) into v_live from public.sv_authority where state = 'live';
  raise notice 'v70: % business(es) live after apply (unchanged by v70)', v_live;

  -- (2) gift_cards is byte-unchanged: v70 issued, voided, redeemed or migrated NO card. This is the
  --     "kopi tiam's active $50 card is intact" proof, generalised to every card on the chain.
  select count(*) into v_before from v70_giftcard_census_before;
  select count(*) into v_after from public.gift_cards;
  if v_before <> v_after then
    raise exception 'v70: the gift_cards row count changed during apply (% -> %)', v_before, v_after;
  end if;
  select count(*) into v_drift
    from public.gift_cards g
    full join v70_giftcard_census_before b on b.id = g.id
   where g.id is null or b.id is null
      or g.balance_cents is distinct from b.balance_cents
      or g.initial_cents is distinct from b.initial_cents
      or g.status is distinct from b.status;
  if v_drift <> 0 then
    raise exception 'v70: % gift_cards row(s) changed during apply - v70 must move no legacy value', v_drift;
  end if;

  -- (3) v70 pre-seeded NO acknowledgement and NO classification (data decisions stay runtime).
  if exists (select 1 from public.sv_legacy_acknowledgements) then
    raise exception 'v70: an acknowledgement row exists after apply (must be a runtime act)';
  end if;
  if exists (select 1 from public.sv_legacy_classifications) then
    raise exception 'v70: a classification row exists after apply (must be a runtime act)';
  end if;

  -- (4) Both issue_gift_card overloads carry the non-overlap guard.
  v_def := pg_get_functiondef('public.issue_gift_card(uuid,integer,uuid,text,uuid)'::regprocedure);
  if position('sv_legacy_issue_guard' in v_def) = 0 then
    raise exception 'v70: the 5-arg issue_gift_card lost its non-overlap guard';
  end if;
  v_def := pg_get_functiondef('public.issue_gift_card(uuid,integer,uuid,text)'::regprocedure);
  if position('sv_legacy_issue_guard' in v_def) = 0 then
    raise exception 'v70: the 4-arg issue_gift_card lost its non-overlap guard';
  end if;

  -- (5) run_sv_reconciliation nets the acknowledgement and stays gift_cards-read-only.
  v_def := pg_get_functiondef('public.run_sv_reconciliation(uuid)'::regprocedure);
  if position('sv_legacy_acknowledgements' in v_def) = 0 or position('acknowledgement_drift' in v_def) = 0 then
    raise exception 'v70: run_sv_reconciliation does not net the legacy acknowledgement';
  end if;

  -- (6) Browser ACLs on the two new tables + the new authenticated RPCs.
  if has_table_privilege('anon', 'public.sv_legacy_acknowledgements', 'select')
     or has_table_privilege('authenticated', 'public.sv_legacy_acknowledgements', 'insert')
     or has_table_privilege('authenticated', 'public.sv_legacy_classifications', 'insert') then
    raise exception 'v70: a new legacy table has a browser write privilege';
  end if;
  if has_function_privilege('anon', 'public.acknowledge_legacy_value(uuid,text,bigint,text)', 'execute')
     or has_function_privilege('anon', 'public.classify_legacy_business(uuid,text,text)', 'execute')
     or has_function_privilege('authenticated', 'app.sv_legacy_issue_guard(uuid,text)', 'execute')
     or has_function_privilege('authenticated', 'public.issue_gift_card(uuid,integer,uuid,text)', 'execute') then
    raise exception 'v70: a v70 function has the wrong browser-role ACL';
  end if;
end
$v70_postconditions$;

commit;
