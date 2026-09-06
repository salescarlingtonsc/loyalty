/* nestly_v690 — a stamp gift can be un-redeemed, and the wallet home card reads the card the
   customer is actually holding.

   Audit findings F059 (P2) and F128 (P2), both confirmed read-only against production on
   2026-09-02 by reading the live definitions with pg_get_functiondef.

   Audit finding F056 (the gift QR that could not be reopened for 15 minutes) is NOT in this
   migration: the live public.customer_create_gift_intent_v515 already carries the reopen branch
   nestly_v676 added earlier in this same audit wave — it takes a per-gift advisory lock, looks
   up a still-pending unexpired intent for the same (business, gift_kind, target, client), and
   returns it with a token re-derived from the STORED row. Re-proved against production before
   this migration was written; there is nothing left to fix and nothing here touches it.

   ============================================================================================
   F059 — a stamp gift redemption could never be reversed.
   ============================================================================================
   app.redeem_reward_core has two arms. For a POINTS programme it writes a points_ledger row, a
   set of loyalty_redemption_batch_drains, and provenance carrying that ledger id. For a STAMPS
   programme it writes NEITHER: consumes_balance is false, provenance.points_ledger_id is null,
   there are no drains, and the value moves as a public.stamp_milestone_claims row plus — when
   the gift sits at the end of the card — a 'claimed' public.stamp_cycles row that closes it.

   public.reverse_loyalty_redemption_v34_base only knows the first arm. It requires a
   points_ledger row at prov.points_ledger_id and drains summing to points_spent, so every
   stamp gift was permanently irreversible, and public.staff_get_reversal_workflows agreed with
   it: can_reverse=false, refusal_reason 'Original points-ledger provenance is incomplete.' A
   cashier who redeemed the 10th-stamp free coffee for the wrong customer had no way back —
   the claim kept blocking a re-claim on that cycle and the card stayed closed.

   THE SHAPE OF THE FIX. A stamp reversal has to REMOVE the claim, because the claim IS the
   balance: there is no stamp_batches table to credit back the way the points arm credits
   points_batches. Both stamp tables are guarded append-only by app.v34_immutable_evidence_guard,
   which raises on every DELETE and UPDATE without exception.

   So the two stamp tables get their own guard, app.v690_stamp_evidence_guard, and the shared
   v34 guard is left exactly as it is for the six other evidence tables that use it. The new
   guard refuses everything the old one refused, with the same message and the same SQLSTATE,
   except one case: a DELETE of a row whose redemption_id is NOT NULL and equals the
   transaction-local GUC app.v690_stamp_reversal_redemption_id. That GUC is set for the width of
   two DELETE statements inside reverse_loyalty_redemption_v34_base and cleared immediately, the
   same pattern app.credit_ledger_write_scope and app.points_ledger_insert_id already use for
   the two append-only ledgers.

   What that deliberately does NOT open:
     · A stamp_cycles row with a NULL redemption_id — every 'expired' and 'completed' card — can
       never be deleted, because the guard requires a redemption to name.
     · UPDATE stays refused on both tables in every case. A claim is removed or it stands.
     · The GUC is unreachable from a client. Neither table carries a DELETE policy, so RLS
       refuses a direct API delete before the trigger is ever consulted, and PostgREST exposes
       no way to call set_config. The only door is a SECURITY DEFINER function in this schema.
     · Evidence is not lost. public.loyalty_redemptions, its provenance row and the new
       public.loyalty_redemption_reversals row all survive and still describe what happened; it
       is the CLAIM — the thing that occupies a slot on a live card — that goes.

   public.loyalty_redemption_reversals.restored_points_ledger_id drops its NOT NULL for the same
   reason. A stamp reversal restores no points, and inserting a zero-point points_ledger row to
   satisfy a column would put a meaningless entry in the customer's own activity feed and invite
   every future reader to treat a stamp reversal as a points event. The points arm is unchanged
   and still always writes it; the column is now null exactly when consumes_balance is false.

   public.staff_get_reversal_workflows learns the same rule, so the control tells the truth
   instead of offering a Reverse button that always refuses (or, worse, refusing one that would
   now work).

   F059(b) — THE STAMP ARM ALONE IS NOT ENOUGH, and this was found by building the acceptance
   suite rather than by reading. Three checks run BEFORE either arm and refuse a pinned stamp
   claim outright:

     public.reverse_loyalty_redemption      'redemption exact provenance is missing or inconsistent'
     ..._v34_base                           'redemption configuration provenance is inconsistent'
     public.staff_get_reversal_workflows    'Configuration provenance is inconsistent.'

   All three compare loyalty_redemption_provenance.config_version_id with
   loyalty_redemptions.config_version_id, and for a stamp claim those two legitimately differ.
   app.redeem_reward_core writes the provenance with the version the claim was JUDGED against —
   app.stamp_cycle_version_v416, the customer's pinned card. The redemption row does not get to
   choose: trigger trg_loyalty_redemptions_config_version (app.stamp_config_version) overwrites
   it with app.active_config_version(business). The moment a firm publishes any stamp edit —
   which nestly_v433 makes unconditional and version-forward — every mid-card claim is written
   with the two columns disagreeing, and stays irreversible even with the arm above.

   Measured read-only against production on 2026-09-02: 3 of 36 stamp redemptions are already in
   that state (QA Kopi Lab, QA Kaya Toast x2). In all three the provenance is the RIGHT one — its
   config matches both the reward version the redemption names and the claim row it created — and
   the redemption's own copy is the odd one out. So the comparison is not detecting corruption,
   it is misreading a pin.

   app.v690_config_provenance_ok is the one place that now decides it, and all three callers ask
   it. It still demands exact equality for a points redemption, and for a stamp redemption it
   accepts the divergence ONLY on evidence: consumes_balance false, and the provenance's config
   version is the one carried by BOTH the redemption's own reward_version row and the
   stamp_milestone_claims row that redemption created. Anything missing — no provenance, no
   claim, a reward version from a different config — returns false, so the guard fails closed
   exactly where it used to.

   ============================================================================================
   F128 — the wallet home card showed the reward from the WRONG config version.
   ============================================================================================
   app.c45_base_actionable_wallet_card's reward_candidate CTE resolved the customer's next
   reward by joining public.loyalty_reward_versions on b.active_config_version_id — the
   business's CURRENT published version. Every other stamp reader (customer_get_stamp_card_v323,
   app.reward_availability_v432, app.redeem_reward_core) resolves through
   app.stamp_cycle_version_v416, the version the customer's own open card is PINNED to.

   nestly_v433 made every stamp-reward edit unconditionally version-forward, so the two diverge
   on the very next edit: rename the final gift and a mid-card customer's Rewards tab keeps
   showing the gift they were promised while Home starts showing the new one, with a
   "X stamps to reward" count computed from the new cost. reward_candidate now resolves a STAMP
   programme's reward through the pin and leaves a POINTS programme on the active version, which
   is correct for points — a points balance is not pinned to a cycle and has nothing to pin to.

   Touches loyalty configuration and redemption: run `npm run tenant-gate` and
   `npm run certify-tenant` after applying.

   Rollback suite: db/tests/v690_stamp_gift_reversal_and_pin.sql */
begin;

-- =============================================================================================
-- 1. The two stamp evidence tables get their own guard. Same refusal, one named exception.
-- =============================================================================================
create or replace function app.v690_stamp_evidence_guard()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
begin
  /* The ONE opening: the reversal of the exact redemption that created this row, announced by a
     transaction-local GUC that only a SECURITY DEFINER function in this schema can set. */
  if tg_op = 'DELETE'
     and old.redemption_id is not null
     and nullif(current_setting('app.v690_stamp_reversal_redemption_id', true), '')
         = old.redemption_id::text then
    return old;
  end if;
  raise exception 'v34 financial provenance is append-only' using errcode = 'restrict_violation';
end
$function$;
revoke all privileges on function app.v690_stamp_evidence_guard() from public, anon, authenticated;

drop trigger if exists trg_stamp_milestone_claims_immutable on public.stamp_milestone_claims;
create trigger trg_stamp_milestone_claims_immutable
  before delete or update on public.stamp_milestone_claims
  for each row execute function app.v690_stamp_evidence_guard();

drop trigger if exists trg_stamp_cycles_immutable on public.stamp_cycles;
create trigger trg_stamp_cycles_immutable
  before delete or update on public.stamp_cycles
  for each row execute function app.v690_stamp_evidence_guard();

-- =============================================================================================
-- 2. A reversal that restores no points may say so.
-- =============================================================================================
alter table public.loyalty_redemption_reversals
  alter column restored_points_ledger_id drop not null;

-- =============================================================================================
-- 3. The one authority on whether a redemption's configuration provenance hangs together.
--    Exact equality for points; for a stamp claim, the pin is accepted only when the claim row
--    and the reward version both carry the provenance's version. No evidence, no pass.
-- =============================================================================================
create or replace function app.v690_config_provenance_ok(p_business uuid, p_redemption uuid)
returns boolean
language sql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
  select coalesce(bool_or(
    prov.config_version_id is not distinct from lr.config_version_id
    or (
      not coalesce(prov.consumes_balance, true)
      and prov.config_version_id is not null
      and exists (
        select 1 from public.loyalty_reward_versions rv
         where rv.id = lr.reward_version_id
           and rv.business_id = lr.business_id
           and rv.config_version_id = prov.config_version_id
      )
      and exists (
        select 1 from public.stamp_milestone_claims claim
         where claim.business_id = lr.business_id
           and claim.redemption_id = lr.id
           and claim.config_version_id = prov.config_version_id
      )
    )
  ), false)
  from public.loyalty_redemptions lr
  join public.loyalty_redemption_provenance prov
    on prov.redemption_id = lr.id and prov.business_id = lr.business_id
 where lr.id = p_redemption and lr.business_id = p_business;
$function$;
revoke all privileges on function app.v690_config_provenance_ok(uuid,uuid)
  from public, anon, authenticated;

-- =============================================================================================
-- 4. The reversal engine grows its stamp arm. One comment-free splice; the points arm below it
--    is byte-identical to the live definition.
-- =============================================================================================
do $v690_reverse$
declare
  v_def text; v_new text;
  v_anchor constant text :=
'  perform 1 from public.points_ledger pl
   where pl.id=v_provenance.points_ledger_id and pl.business_id=p_business';
  v_inject constant text :=
'  if not coalesce(v_provenance.consumes_balance, true) then
    if v_redemption.points_spent <> 0 then
      raise exception ''stamp redemption provenance does not reconcile'';
    end if;
    if exists (select 1 from public.loyalty_redemption_batch_drains
                where provenance_id=v_provenance.id) then
      raise exception ''stamp redemption provenance carries points batch drains'';
    end if;
    select * into v_claim from public.stamp_milestone_claims claim
     where claim.business_id=p_business and claim.redemption_id=p_redemption
       and claim.client_id=v_redemption.client_id
     for update;
    if not found then
      raise exception ''original stamp claim provenance is incomplete'';
    end if;
    if v_provenance.credit_ledger_id is not null then
      select * into v_source_credit from public.credit_ledger cl
       where cl.id=v_provenance.credit_ledger_id and cl.business_id=p_business
         and cl.client_id=v_redemption.client_id and cl.entry_type=''loyalty_earn''
         and cl.amount_cents=v_redemption.credit_cents
         and cl.config_version_id=v_redemption.config_version_id for share;
      if not found then raise exception ''original credit ledger provenance is incomplete''; end if;
      if exists (
        select 1 from public.credit_ledger spend
         where spend.business_id=p_business and spend.client_id=v_redemption.client_id
           and spend.amount_cents<0 and spend.created_at>=v_source_credit.created_at
      ) then
        raise exception ''reward credit may have been spent; exact source credit is no longer reversible'';
      end if;
      v_credit_id:=gen_random_uuid();
      perform set_config(''app.credit_ledger_insert_id'',v_credit_id::text,true);
      perform set_config(''app.credit_ledger_write_scope'',''redemption_reversal'',true);
      insert into public.credit_ledger(id,business_id,client_id,entry_type,amount_cents,reference,actor,idempotency_key,config_version_id)
      values(v_credit_id,p_business,v_redemption.client_id,''manual_adjust'',-v_redemption.credit_cents,
        ''loyalty redemption reversal of credit entry ''||v_source_credit.id,v_actor,
        ''v34:''||btrim(p_idempotency_key),v_redemption.config_version_id);
      perform set_config(''app.credit_ledger_insert_id'','''',true);
      perform set_config(''app.credit_ledger_write_scope'','''',true);
    end if;
    perform set_config(''app.v690_stamp_reversal_redemption_id'',p_redemption::text,true);
    delete from public.stamp_cycles
     where business_id=p_business and redemption_id=p_redemption and origin=''claimed'';
    get diagnostics v_cycles_reopened = row_count;
    delete from public.stamp_milestone_claims
     where business_id=p_business and redemption_id=p_redemption;
    get diagnostics v_claims_removed = row_count;
    perform set_config(''app.v690_stamp_reversal_redemption_id'','''',true);
    if v_claims_removed <> 1 then
      raise exception ''stamp claim reversal removed % claim rows'', v_claims_removed
        using errcode=''XX001'';
    end if;
    v_result:=jsonb_build_object(''redemption_id'',p_redemption,''restored_points'',0,
      ''restored_stamp_claims'',v_claims_removed,''reopened_stamp_cards'',v_cycles_reopened,
      ''reversed_credit_cents'',case when v_credit_id is null then 0 else v_redemption.credit_cents end,
      ''replayed'',false);
    insert into public.loyalty_redemption_reversals
      (business_id,redemption_id,provenance_id,client_id,actor,idempotency_key,request_payload,
       request_hash,restored_points_ledger_id,reversed_credit_ledger_id,result)
    values(p_business,p_redemption,v_provenance.id,v_redemption.client_id,v_actor,
      btrim(p_idempotency_key),v_payload,v_request_hash,null,v_credit_id,v_result);
    return v_result::json;
  end if;
  perform 1 from public.points_ledger pl
   where pl.id=v_provenance.points_ledger_id and pl.business_id=p_business';
  v_decl constant text :=
'  v_restore_programme uuid; v_restore_programmes integer;';
  v_decl_new constant text :=
'  v_restore_programme uuid; v_restore_programmes integer;
  v_claim public.stamp_milestone_claims%rowtype;
  v_claims_removed integer := 0; v_cycles_reopened integer := 0;';
begin
  v_def := pg_get_functiondef(
    'public.reverse_loyalty_redemption_v34_base(uuid,uuid,text,text)'::regprocedure);
  if position('v690_stamp_reversal_redemption_id' in v_def) > 0 then
    raise notice 'nestly_v690: the reversal engine already has its stamp arm, skipping';
  else
    if (length(v_def) - length(replace(v_def, v_anchor, ''))) / nullif(length(v_anchor),0) <> 1
       or (length(v_def) - length(replace(v_def, v_decl, ''))) / nullif(length(v_decl),0) <> 1 then
      raise exception 'nestly_v690: a reversal anchor did not match exactly once — body drifted'
        using errcode = 'XX001';
    end if;
    v_new := replace(replace(v_def, v_decl, v_decl_new), v_anchor, v_inject);
    if v_new = v_def then
      raise exception 'nestly_v690: the reversal splice produced no change' using errcode = 'XX001';
    end if;
    execute v_new;
  end if;
end
$v690_reverse$;
revoke all on function public.reverse_loyalty_redemption_v34_base(uuid,uuid,text,text) from public, anon;
grant execute on function public.reverse_loyalty_redemption_v34_base(uuid,uuid,text,text)
  to authenticated, service_role;

-- =============================================================================================
-- 5. The two reversal entry points ask the new authority instead of comparing columns.
-- =============================================================================================
do $v690_config_gate$
declare
  v_def text; v_new text;
  v_base constant text :=
'  if v_provenance.config_version_id is distinct from v_redemption.config_version_id then
    raise exception ''redemption configuration provenance is inconsistent'';
  end if;';
  v_base_new constant text :=
'  if not app.v690_config_provenance_ok(p_business, p_redemption) then
    raise exception ''redemption configuration provenance is inconsistent'';
  end if;';
  v_wrap constant text :=
'  if not found or v_provenance.config_version_id is distinct from v_redemption.config_version_id then
    raise exception ''redemption exact provenance is missing or inconsistent'';
  end if;';
  v_wrap_new constant text :=
'  if not found or not app.v690_config_provenance_ok(p_business, p_redemption) then
    raise exception ''redemption exact provenance is missing or inconsistent'';
  end if;';
begin
  v_def := pg_get_functiondef(
    'public.reverse_loyalty_redemption_v34_base(uuid,uuid,text,text)'::regprocedure);
  if position('v690_config_provenance_ok' in v_def) > 0 then
    raise notice 'nestly_v690: the reversal engine already asks the config authority, skipping';
  else
    if (length(v_def) - length(replace(v_def, v_base, ''))) / nullif(length(v_base),0) <> 1 then
      raise exception 'nestly_v690: the base config anchor did not match exactly once'
        using errcode = 'XX001';
    end if;
    v_new := replace(v_def, v_base, v_base_new);
    if v_new = v_def then
      raise exception 'nestly_v690: the base config splice produced no change' using errcode = 'XX001';
    end if;
    execute v_new;
  end if;

  v_def := pg_get_functiondef(
    'public.reverse_loyalty_redemption(uuid,uuid,text,text)'::regprocedure);
  if position('v690_config_provenance_ok' in v_def) > 0 then
    raise notice 'nestly_v690: the reversal wrapper already asks the config authority, skipping';
  else
    if (length(v_def) - length(replace(v_def, v_wrap, ''))) / nullif(length(v_wrap),0) <> 1 then
      raise exception 'nestly_v690: the wrapper config anchor did not match exactly once'
        using errcode = 'XX001';
    end if;
    v_new := replace(v_def, v_wrap, v_wrap_new);
    if v_new = v_def then
      raise exception 'nestly_v690: the wrapper config splice produced no change' using errcode = 'XX001';
    end if;
    execute v_new;
  end if;
end
$v690_config_gate$;
revoke all on function public.reverse_loyalty_redemption(uuid,uuid,text,text) from public, anon;
grant execute on function public.reverse_loyalty_redemption(uuid,uuid,text,text)
  to authenticated, service_role;

-- =============================================================================================
-- 6. The Reverse control tells the truth about a stamp gift.
-- =============================================================================================
do $v690_workflows$
declare
  v_def text; v_new text;
  v_lateral constant text :=
'        ) points_ok on true';
  v_lateral_new constant text :=
'        ) points_ok on true
        left join lateral (
          select (not coalesce(prov.consumes_balance, true)) and exists (
            select 1 from public.stamp_milestone_claims claim
             where claim.business_id = lr.business_id
               and claim.redemption_id = lr.id
               and claim.client_id = lr.client_id
          ) as proven
        ) stamp_ok on true';
  v_exact constant text :=
'                 and points_ok.proven
                 and credit_state.proven,';
  v_exact_new constant text :=
'                 and (points_ok.proven or coalesce(stamp_ok.proven, false))
                 and credit_state.proven,';
  v_can constant text :=
'                 and points_ok.proven
                 and credit_state.proven
                 and not coalesce(credit_state.may_be_spent, false),';
  v_can_new constant text :=
'                 and (points_ok.proven or coalesce(stamp_ok.proven, false))
                 and credit_state.proven
                 and not coalesce(credit_state.may_be_spent, false),';
  v_refuse constant text :=
'                 when not coalesce(points_ok.proven, false) then ''Original points-ledger provenance is incomplete.''';
  v_refuse_new constant text :=
'                 when not (coalesce(points_ok.proven, false) or coalesce(stamp_ok.proven, false))
                   then case when coalesce(prov.consumes_balance, true)
                     then ''Original points-ledger provenance is incomplete.''
                     else ''Stamp-claim provenance for this gift is incomplete.'' end';
  v_cfg_ok constant text :=
'prov.config_version_id is not distinct from lr.config_version_id';
  v_cfg_ok_new constant text :=
'app.v690_config_provenance_ok(lr.business_id, lr.id)';
  v_cfg_bad constant text :=
'prov.config_version_id is distinct from lr.config_version_id';
  v_cfg_bad_new constant text :=
'not app.v690_config_provenance_ok(lr.business_id, lr.id)';
begin
  v_def := pg_get_functiondef(
    'public.staff_get_reversal_workflows(uuid,uuid,integer,text)'::regprocedure);
  if position('stamp_ok' in v_def) > 0 then
    raise notice 'nestly_v690: the reversal workflow reader already knows stamps, skipping';
  else
    if (length(v_def) - length(replace(v_def, v_lateral, ''))) / nullif(length(v_lateral),0) <> 1
       or (length(v_def) - length(replace(v_def, v_exact, ''))) / nullif(length(v_exact),0) <> 1
       or (length(v_def) - length(replace(v_def, v_can, ''))) / nullif(length(v_can),0) <> 1
       or (length(v_def) - length(replace(v_def, v_refuse, ''))) / nullif(length(v_refuse),0) <> 1
       or (length(v_def) - length(replace(v_def, v_cfg_ok, ''))) / nullif(length(v_cfg_ok),0) <> 2
       or (length(v_def) - length(replace(v_def, v_cfg_bad, ''))) / nullif(length(v_cfg_bad),0) <> 1 then
      raise exception 'nestly_v690: a workflow-reader anchor did not match the expected count'
        using errcode = 'XX001';
    end if;
    v_new := replace(v_def, v_lateral, v_lateral_new);
    v_new := replace(v_new, v_exact, v_exact_new);
    v_new := replace(v_new, v_can, v_can_new);
    v_new := replace(v_new, v_refuse, v_refuse_new);
    v_new := replace(v_new, v_cfg_ok, v_cfg_ok_new);
    v_new := replace(v_new, v_cfg_bad, v_cfg_bad_new);
    if v_new = v_def then
      raise exception 'nestly_v690: the workflow-reader splice produced no change' using errcode = 'XX001';
    end if;
    execute v_new;
  end if;
end
$v690_workflows$;
revoke all on function public.staff_get_reversal_workflows(uuid,uuid,integer,text) from public, anon;
grant execute on function public.staff_get_reversal_workflows(uuid,uuid,integer,text)
  to authenticated, service_role;

-- =============================================================================================
-- 7. F128 — the wallet home card follows the customer's pinned stamp version.
-- =============================================================================================
do $v690_wallet$
declare
  v_def text; v_new text;
  v_anchor constant text :=
'      join public.loyalty_reward_versions rv
        on rv.business_id = b.id
       and rv.config_version_id = b.active_config_version_id
       and rv.active';
  v_inject constant text :=
'      join public.loyalty_reward_versions rv
        on rv.business_id = b.id
       and rv.config_version_id = case
             when exists (
               select 1 from public.business_programmes stamp_spine
                where stamp_spine.id = rv.programme_id
                  and stamp_spine.business_id = b.id
                  and stamp_spine.kind = ''stamps''
             )
             then app.stamp_cycle_version_v416(b.id, p_client_id, rv.programme_id)
             else b.active_config_version_id
           end
       and rv.active';
begin
  v_def := pg_get_functiondef(
    'app.c45_base_actionable_wallet_card(uuid,uuid,text,text,text,text,text[],timestamptz)'::regprocedure);
  if position('stamp_cycle_version_v416' in v_def) > 0 then
    raise notice 'nestly_v690: the wallet card already follows the pinned version, skipping';
  else
    if (length(v_def) - length(replace(v_def, v_anchor, ''))) / nullif(length(v_anchor),0) <> 1 then
      raise exception 'nestly_v690: the wallet-card anchor did not match exactly once'
        using errcode = 'XX001';
    end if;
    v_new := replace(v_def, v_anchor, v_inject);
    if v_new = v_def then
      raise exception 'nestly_v690: the wallet-card splice produced no change' using errcode = 'XX001';
    end if;
    execute v_new;
  end if;
end
$v690_wallet$;
revoke all privileges on function
  app.c45_base_actionable_wallet_card(uuid,uuid,text,text,text,text,text[],timestamptz)
  from public, anon, authenticated;

-- =============================================================================================
-- 8. Prove every change took, in the transaction that made it.
-- =============================================================================================
do $verify$
declare
  v_guard text := pg_get_functiondef('app.v690_stamp_evidence_guard()'::regprocedure);
  v_reverse text := pg_get_functiondef(
    'public.reverse_loyalty_redemption_v34_base(uuid,uuid,text,text)'::regprocedure);
  v_workflows text := pg_get_functiondef(
    'public.staff_get_reversal_workflows(uuid,uuid,integer,text)'::regprocedure);
  v_wrapper text := pg_get_functiondef(
    'public.reverse_loyalty_redemption(uuid,uuid,text,text)'::regprocedure);
  v_wallet text := pg_get_functiondef(
    'app.c45_base_actionable_wallet_card(uuid,uuid,text,text,text,text,text[],timestamptz)'::regprocedure);
begin
  if position('append-only' in v_guard) = 0
     or position('tg_op = ''DELETE''' in v_guard) = 0 then
    raise exception 'nestly_v690: the stamp evidence guard is not append-only-by-default'
      using errcode = 'XX001';
  end if;
  if 2 <> (select count(*) from pg_trigger t
            join pg_proc p on p.oid = t.tgfoid
           where not t.tgisinternal
             and p.proname = 'v690_stamp_evidence_guard'
             and t.tgrelid in ('public.stamp_milestone_claims'::regclass,
                               'public.stamp_cycles'::regclass)) then
    raise exception 'nestly_v690: the stamp tables are not both on the new guard'
      using errcode = 'XX001';
  end if;
  if exists (select 1 from pg_trigger t
              join pg_proc p on p.oid = t.tgfoid
             where not t.tgisinternal
               and p.proname = 'v34_immutable_evidence_guard'
               and t.tgrelid in ('public.stamp_milestone_claims'::regclass,
                                 'public.stamp_cycles'::regclass)) then
    raise exception 'nestly_v690: a stamp table is still on the shared v34 guard as well'
      using errcode = 'XX001';
  end if;
  if not exists (select 1 from pg_trigger t
                  join pg_proc p on p.oid = t.tgfoid
                 where not t.tgisinternal
                   and p.proname = 'v34_immutable_evidence_guard'
                   and t.tgrelid = 'public.loyalty_redemption_provenance'::regclass) then
    raise exception 'nestly_v690: the shared v34 guard was disturbed on another table'
      using errcode = 'XX001';
  end if;
  if exists (select 1 from information_schema.columns
              where table_schema = 'public'
                and table_name = 'loyalty_redemption_reversals'
                and column_name = 'restored_points_ledger_id'
                and is_nullable = 'NO') then
    raise exception 'nestly_v690: a stamp reversal still has to invent a points ledger row'
      using errcode = 'XX001';
  end if;
  if position('v690_stamp_reversal_redemption_id' in v_reverse) = 0
     or position('original stamp claim provenance is incomplete' in v_reverse) = 0 then
    raise exception 'nestly_v690 (F059): the reversal engine still has no stamp arm'
      using errcode = 'XX001';
  end if;
  if position('stamp_ok' in v_workflows) = 0
     or position('Stamp-claim provenance for this gift is incomplete.' in v_workflows) = 0 then
    raise exception 'nestly_v690 (F059): the Reverse control still refuses every stamp gift'
      using errcode = 'XX001';
  end if;
  if position('v690_config_provenance_ok' in v_reverse) = 0
     or position('v690_config_provenance_ok' in v_wrapper) = 0
     or position('v690_config_provenance_ok' in v_workflows) = 0 then
    raise exception 'nestly_v690 (F059b): a pinned stamp claim is still refused before either arm'
      using errcode = 'XX001';
  end if;
  if position('prov.config_version_id is distinct from lr.config_version_id' in v_workflows) > 0
     or position('v_provenance.config_version_id is distinct from v_redemption.config_version_id'
                 in v_reverse) > 0
     or position('v_provenance.config_version_id is distinct from v_redemption.config_version_id'
                 in v_wrapper) > 0 then
    raise exception 'nestly_v690 (F059b): a raw config-column comparison survives somewhere'
      using errcode = 'XX001';
  end if;
  if app.v690_config_provenance_ok(gen_random_uuid(), gen_random_uuid()) then
    raise exception 'nestly_v690 (F059b): the config authority does not fail closed on no evidence'
      using errcode = 'XX001';
  end if;
  if position('stamp_cycle_version_v416' in v_wallet) = 0 then
    raise exception 'nestly_v690 (F128): the wallet card still reads the active version'
      using errcode = 'XX001';
  end if;
end
$verify$;

commit;
