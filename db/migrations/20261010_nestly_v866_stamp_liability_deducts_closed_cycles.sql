-- nestly_v866 — outstanding stamps are the stamps still ON cards, not the stamps ever earned.
--
-- WHAT THE BUG WAS
--   Two firm-level readers report a loyalty "outstanding" balance for the live pot and for each
--   retired pot:
--
--     app.v177_overview(uuid,uuid)                       -> platform_workspace_mirror_v177
--     app.v179_business_insights(uuid,date,date,date,date) -> app.v176_evidence_pack
--
--   Both computed it as `sum(points_ledger.points)` for the pot. For a POINTS pot that is right:
--   the ledger is the balance, because a redemption writes a negative row. For a STAMPS pot it is
--   wrong. Claiming the final milestone (or a card expiring, or a pot migration) does NOT write a
--   negative ledger row — it closes a cycle and records the slots it consumed in
--   public.stamp_cycles. So the readers were reporting LIFETIME stamps earned and calling it
--   outstanding liability, while the customer's own card — app.stamp_progress_v323, filled =
--   greatest(net - closed, 0) — had already deducted them. The owner and the customer were
--   looking at the same card and reading different numbers.
--
--   Measured read-only against production (2026-09-09), the two tenants whose live programme is
--   stamps, and the retired stamps pots elsewhere in the estate:
--
--     tenant                          live    reported   closed   true outstanding   overstated
--     QA Kaya Toast                   yes         1134      527                607        +87%
--     QA Kopi Lab (Bedok)             yes           43       30                 13       +231%
--     ÉLAN Wellness (retired pot)     no            37       30                  7       +429%
--     Cubbly SPA (retired pot)        no           814       20                794         +3%
--     Hougang ABC (retired pot)       no           347        0                347          0%
--
--   Per customer on QA Kaya Toast the corrected figure reproduces the customer's card exactly
--   (606 / 0 / 1 / 0, summing to 607), and on QA Kopi Lab (0 / 5 / 8, summing to 13). No POINTS
--   pot anywhere in the estate changes by a single unit.
--
-- THE FIX
--   One authority for the fact, app.programme_outstanding_v835(business, programme), asked by
--   both readers for both the active pot and each historical pot. It reproduces
--   app.stamp_progress_v323's model — so the owner's liability and the customer's card are the
--   same arithmetic, not two implementations that happen to agree today — and it leaves points
--   pots on the plain ledger sum they have always used.
--
--   The clamp is PER CUSTOMER, deliberately. `greatest(sum(net) - sum(closed), 0)` at firm level
--   would let one customer whose cycles closed more slots than their surviving ledger cancel
--   another customer's genuinely open card: on the acceptance fixture that mistake reads 6 where
--   the truth is 13.
--
--   A tenant with zero stamp cycles subtracts zero and is unchanged; there is no division
--   anywhere, so a mid-cycle customer and an empty tenant are both ordinary cases.
--
--   NOT fixed here, deliberately: whether a retired ("switched-off") pot's stamps should be
--   reported as outstanding at all. That is a separate scoping question, and the reader already
--   labels those figures `historical_programmes`. After this migration the estate still reports
--   794 + 347 + 7 = 1148 stamps parked in switched-off pots across three tenants; correcting the
--   arithmetic of that figure is not the same decision as deciding to stop showing it.
--
--   Both readers are patched by anchored replacement against their live bodies rather than
--   retyped: each anchor is asserted to occur EXACTLY ONCE before anything executes, and the
--   installed result is re-read afterwards, so a shape change upstream fails loudly here instead
--   of installing a half-patched reader. Nothing else in either function changes.
--
-- ACL: create-or-replace preserves grants. The live ACL of BOTH readers is {postgres=X/postgres}
-- — owner-only, no authenticated, no service_role, no anon, no PUBLIC — because each is reached
-- only from another SECURITY DEFINER function owned by postgres. The revoke below restates that
-- verbatim; there is deliberately no grant to restate. The new helper is created with the same
-- owner-only shape as its sibling authority app.stamp_progress_v323.

begin;

create or replace function app.programme_outstanding_v835(p_business uuid, p_programme uuid)
returns bigint
language sql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $v866$
  -- The outstanding balance of ONE pot, in that pot's own unit, for real customers only.
  --
  -- points: the ledger IS the balance -- a redemption is a negative row -- so the answer is the
  --         plain sum, byte-for-byte what the callers computed before nestly_v866.
  -- stamps: a claimed, expired or migrated cycle writes no negative ledger row; it records the
  --         slots it consumed in public.stamp_cycles. Lifetime stamps earned are therefore not
  --         outstanding stamps. This is app.stamp_progress_v323's model -- filled =
  --         greatest(net - closed, 0) -- summed per customer, so the owner's liability figure
  --         and the customer's card cannot disagree.
  --
  -- NULL programme returns NULL ("no pot is live"), matching what the callers reported before.
  select case when p_programme is null then null else coalesce((
    select sum(case when spine.kind = 'stamps'
                    then greatest(led.net - coalesce(cyc.closed, 0), 0)
                    else led.net end)
      from public.business_programmes spine
      cross join lateral (
        select entry.client_id, sum(entry.points) as net
          from public.points_ledger entry
          join public.clients entry_c on entry_c.id = entry.client_id
            and entry_c.business_id = entry.business_id
         where entry.business_id = p_business
           and entry.programme_id = spine.id
           and not entry_c.is_synthetic
         group by entry.client_id
      ) led
      left join lateral (
        select coalesce(sum(cycle.slots), 0) as closed
          from public.stamp_cycles cycle
         where cycle.business_id = p_business
           and cycle.programme_id = spine.id
           and cycle.client_id = led.client_id
      ) cyc on true
     where spine.id = p_programme
       and spine.business_id = p_business
  ), 0) end
$v866$;

do $patch$
declare
  v_target text;
  v_src    text;
  v_new    text;
  v_hits   int;
  c_active_anchor constant text :=
    '        ''outstanding'', case when app.live_balance_programme_v381(p_business) is null then null' || E'\n' ||
    '          else coalesce((select sum(entry.points) from public.points_ledger entry' || E'\n' ||
    '                          join public.clients entry_c on entry_c.id = entry.client_id' || E'\n' ||
    '                            and entry_c.business_id = entry.business_id' || E'\n' ||
    '                          where entry.business_id = p_business' || E'\n' ||
    '                            and entry.programme_id = app.live_balance_programme_v381(p_business)' || E'\n' ||
    '                            and not entry_c.is_synthetic), 0)' || E'\n' ||
    '          end';
  c_active_new constant text :=
    '        /* nestly_v866: lifetime stamps are not outstanding stamps. One authority for the' || E'\n' ||
    '           fact, shared with the customer''s own card (app.stamp_progress_v323). */' || E'\n' ||
    '        ''outstanding'', app.programme_outstanding_v835(' || E'\n' ||
    '                          p_business, app.live_balance_programme_v381(p_business))';
  c_hist_anchor constant text :=
    '            select entry.programme_id, sum(entry.points) as points' || E'\n';
  c_hist_new constant text :=
    '            select entry.programme_id,  /* nestly_v866 */' || E'\n' ||
    '                   app.programme_outstanding_v835(p_business, entry.programme_id) as points' || E'\n';
begin
  foreach v_target in array array[
    'app.v177_overview(uuid,uuid)',
    'app.v179_business_insights(uuid,date,date,date,date)'
  ] loop
    if to_regprocedure(v_target) is null then
      raise exception 'v866: % is missing', v_target;
    end if;
    v_src := pg_get_functiondef(v_target::regprocedure);

    if position('programme_outstanding_v835' in v_src) > 0 then
      raise notice 'v866: % already reads the outstanding authority; left as it is', v_target;
      continue;
    end if;

    v_hits := (length(v_src) - length(replace(v_src, c_active_anchor, '')))
              / length(c_active_anchor);
    if v_hits <> 1 then
      raise exception 'v866: the active-pot outstanding anchor occurs % times in %, expected exactly 1',
        v_hits, v_target;
    end if;

    v_hits := (length(v_src) - length(replace(v_src, c_hist_anchor, '')))
              / length(c_hist_anchor);
    if v_hits <> 1 then
      raise exception 'v866: the historical-pot outstanding anchor occurs % times in %, expected exactly 1',
        v_hits, v_target;
    end if;

    v_new := replace(v_src, c_active_anchor, c_active_new);
    v_new := replace(v_new, c_hist_anchor, c_hist_new);
    execute v_new;

    v_src := pg_get_functiondef(v_target::regprocedure);
    v_hits := (length(v_src) - length(replace(v_src, 'app.programme_outstanding_v835(', '')))
              / length('app.programme_outstanding_v835(');
    if v_hits <> 2 then
      raise exception 'v866: % took % of the 2 outstanding call sites', v_target, v_hits;
    end if;
  end loop;
end
$patch$;

revoke all on function app.programme_outstanding_v835(uuid, uuid) from public, anon;
revoke all on function app.v177_overview(uuid, uuid) from public, anon;
revoke all on function app.v179_business_insights(uuid, date, date, date, date) from public, anon;

commit;
