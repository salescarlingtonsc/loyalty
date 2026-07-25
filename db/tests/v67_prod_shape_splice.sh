#!/bin/sh
# v67 PRODUCTION-SHAPE splice parity harness.
#
# WHY THIS EXISTS (v67 rev-4 -> rev-5). §11b patches public.sv_reverse_spend with the v49a
# pg_get_functiondef splice idiom: read the APPLIED definition, find a single-occurrence needle,
# re-execute the definition with the gate spliced in. The rev-4 needle anchored on the over-reversal
# bound's OWN `-- BOUND:` comment lines. That needle occurs exactly once in a rehearsal cluster and
# ZERO times in production, because the two environments are built differently:
#
#   * REHEARSAL replays db/migrations/*.sql through psql, which preserves comments verbatim.
#   * PRODUCTION was built through the Supabase MCP `apply_migration`, which CONDENSES full-line
#     `--` comments out of large function bodies (observed on v66's record_sv_topup_sale and across
#     the v60 wave; prod's live sv_reverse_spend body retains exactly the 2 TRAILING `--` markers
#     and none of the 10 full-line ones).
#
# So the rehearsal DB is NOT byte-faithful to prod for function bodies, a comment-anchored needle
# passes every local gate, and the migration then fails against prod with
# `unexpected sv_reverse_spend predecessor definition (needle occurrences: 0)`, rolling the ENTIRE
# migration back. No amount of ordinary rehearsal catches that. This harness does: it rewrites the
# predecessor into the PRODUCTION SHAPE (full-line `--` comments stripped, every code byte
# preserved) BEFORE applying v67, and then asserts the splice still lands and still behaves.
#
# It is a shell harness rather than a case in db/tests/v67_ps2live_checkout_tender.sql because it
# has to mutate the predecessor and then apply a whole migration (which carries its own
# begin;/commit;) — neither fits that suite's rollback-only, already-applied-chain model.
#
# USAGE: DATABASE_URL must point at a DISPOSABLE database replayed through v66b with v67 NOT yet
# applied. The harness commits (it applies a migration), so never point it at anything real.
set -eu
if [ "${V67_CONFIRM_DISPOSABLE_DB:-}" != "YES" ]; then echo "set V67_CONFIRM_DISPOSABLE_DB=YES for a disposable DB." >&2; exit 2; fi
if [ -z "${DATABASE_URL:-}" ]; then echo "DATABASE_URL required." >&2; exit 2; fi
if [ -z "${PGPASSWORD:-}" ]; then echo "PGPASSWORD required." >&2; exit 2; fi
export PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-10}"
here="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
repo="$(CDPATH= cd -- "$here/../.." && pwd)"
MIGRATION="${V67_MIGRATION:-$repo/db/migrations/20260724_frenly_v67_ps2live_checkout_tender.sql}"
SUITE="${V67_SUITE:-$here/v67_ps2live_checkout_tender.sql}"
[ -f "$MIGRATION" ] || { echo "migration not found: $MIGRATION" >&2; exit 2; }
[ -f "$SUITE" ] || { echo "suite not found: $SUITE" >&2; exit 2; }

q() { psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 "$@"; }
fail=0
chk() { # chk <label> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "  ok   $1 = $3"; else echo "  FAIL $1: expected $2, got $3" >&2; fail=1; fi
}

# The two needles, as SQL literals. NEW = rev-5, comment-free (the last two lines of the completed
# over-reversal construct). OLD = rev-4, comment-anchored — kept so this harness PROVES the defect.
needle_new="E'    raise exception ''stored-value spend operation is already reversed (over-reversal refused)'' using errcode = ''22023'';\n  end if;'"
needle_old="E'  -- BOUND: a spend op is reversed at most once. Any prior reverse of THIS spend op (under a\n  -- different key) is over-reversal -> fail.\n  if exists ('"
occ() { # occ <needle-literal>  -> occurrences in the live sv_reverse_spend definition
  q -c "select (length(d) - length(replace(d, n, ''))) / length(n)
          from (select pg_get_functiondef('public.sv_reverse_spend(uuid,uuid,uuid)'::regprocedure) d, $1 n) s;"
}

echo "v67 prod-shape splice parity harness"
echo "step 0 — preconditions (chain at v66b, v67 NOT applied)"
chk "checkout_sv_tenders absent" "" "$(q -c "select coalesce(to_regclass('public.checkout_sv_tenders')::text,'')")"
chk "sv_reverse_spend present" "1" "$(q -c "select count(*) from pg_proc where oid='public.sv_reverse_spend(uuid,uuid,uuid)'::regprocedure")"

echo "step 1 — rehearsal (comment-preserving) shape"
chk "rev-5 comment-free needle occurrences" "1" "$(occ "$needle_new")"
chk "rev-4 comment-anchored needle occurrences" "1" "$(occ "$needle_old")"
chk "full-line -- comment lines in body" "10" "$(q -c "select count(*) from regexp_matches(pg_get_functiondef('public.sv_reverse_spend(uuid,uuid,uuid)'::regprocedure), '^[ \t]*--[^\n]*\$', 'gn')")"

echo "step 2 — rewrite the predecessor into PRODUCTION shape (strip full-line -- comments only)"
# Derived from the live catalog via pg_get_functiondef, so every CODE byte is preserved verbatim;
# only whole comment lines are removed. This is exactly the transformation the MCP apply performs
# (prod keeps the 2 trailing `--` markers and loses all 10 full-line comments).
q <<'SQL' >/dev/null
do $prodshape$
declare v_def text; v_out text;
begin
  select pg_get_functiondef('public.sv_reverse_spend(uuid,uuid,uuid)'::regprocedure) into strict v_def;
  v_out := regexp_replace(v_def, '^[ \t]*--[^\n]*\n', '', 'gn');
  if v_out = v_def then
    raise exception 'prod-shape rewrite stripped nothing; the predecessor already has no full-line comments';
  end if;
  execute v_out;
end
$prodshape$;
SQL
chk "full-line -- comment lines after rewrite" "0" "$(q -c "select count(*) from regexp_matches(pg_get_functiondef('public.sv_reverse_spend(uuid,uuid,uuid)'::regprocedure), '^[ \t]*--[^\n]*\$', 'gn')")"
chk "trailing -- markers survive (prod reports 2)" "2" "$(q -c "select (length(d) - length(replace(d,'--',''))) / 2 from (select pg_get_functiondef('public.sv_reverse_spend(uuid,uuid,uuid)'::regprocedure) d) s")"
# THE BLOCKER, reproduced: the rev-4 needle is now invisible; the rev-5 needle is untouched.
chk "rev-4 comment-anchored needle occurrences (prod shape)" "0" "$(occ "$needle_old")"
chk "rev-5 comment-free needle occurrences (prod shape)" "1" "$(occ "$needle_new")"
if [ "$fail" != "0" ]; then echo "prod-shape harness: FAIL (setup)" >&2; exit 1; fi

echo "step 3 — apply v67 against the production-shaped predecessor"
if ! psql "$DATABASE_URL" -X -q -v ON_ERROR_STOP=1 -f "$MIGRATION" >/tmp/v67_prodshape_apply.out 2>&1; then
  echo "  FAIL v67 did not apply to a production-shaped chain:" >&2; tail -20 /tmp/v67_prodshape_apply.out >&2; exit 1
fi
echo "  ok   v67 applied"
chk "gate installed" "1" "$(q -c "select case when position('sv_tendered_spend_unsupported' in pg_get_functiondef('public.sv_reverse_spend(uuid,uuid,uuid)'::regprocedure)) > 0 then 1 else 0 end")"
chk "gate reads the tender table" "1" "$(q -c "select case when position('checkout_sv_tenders' in pg_get_functiondef('public.sv_reverse_spend(uuid,uuid,uuid)'::regprocedure)) > 0 then 1 else 0 end")"
# The gate must still be BEFORE the first write (the sv_operations insert) and AFTER the
# over-reversal bound it was spliced behind.
chk "gate sits after the over-reversal bound and before the first write" "1" "$(q -c "
  select case when position('sv_tendered_spend_unsupported' in d) > position('over-reversal refused' in d)
              and position('sv_tendered_spend_unsupported' in d) < position('insert into public.sv_operations' in d)
         then 1 else 0 end
    from (select pg_get_functiondef('public.sv_reverse_spend(uuid,uuid,uuid)'::regprocedure) d) s")"
chk "search_path still v21-canonical" "search_path=pg_catalog, public, app, pg_temp" "$(q -c "select array_to_string(proconfig,',') from pg_proc where oid='public.sv_reverse_spend(uuid,uuid,uuid)'::regprocedure")"
chk "still SECURITY DEFINER" "t" "$(q -c "select prosecdef from pg_proc where oid='public.sv_reverse_spend(uuid,uuid,uuid)'::regprocedure")"
chk "authenticated keeps EXECUTE" "t" "$(q -c "select has_function_privilege('authenticated','public.sv_reverse_spend(uuid,uuid,uuid)','execute')")"
chk "anon still has none" "f" "$(q -c "select has_function_privilege('anon','public.sv_reverse_spend(uuid,uuid,uuid)','execute')")"
# The splice must not have rebuilt the body from an older source: v64's pause gate and v63's
# restore-then-expire core have to be byte-present in the patched definition.
chk "v64 pause gate preserved" "1" "$(q -c "select case when position('sv_pause_active' in pg_get_functiondef('public.sv_reverse_spend(uuid,uuid,uuid)'::regprocedure)) > 0 then 1 else 0 end")"
chk "v63 restore-then-expire core preserved" "1" "$(q -c "select case when position('re_expired_cents' in pg_get_functiondef('public.sv_reverse_spend(uuid,uuid,uuid)'::regprocedure)) > 0 then 1 else 0 end")"

echo "step 4 — the §11b behavioural assertions against the production-shaped chain"
# The full v67 suite (rollback-only) carries them: settlement-spend refusal is typed 22023 +
# sv_tendered_spend_unsupported:, mutates nothing, leaves sale_balance/get_revenue_summary intact,
# and a plain non-checkout sv_spend stays reversible (no over-refusal).
if ! psql "$DATABASE_URL" -X -q -v ON_ERROR_STOP=1 -f "$SUITE" >/tmp/v67_prodshape_suite.out 2>&1; then
  echo "  FAIL the v67 suite failed on a production-shaped chain:" >&2; tail -30 /tmp/v67_prodshape_suite.out >&2; exit 1
fi
if ! grep -q 'V67 SUITE PASS' /tmp/v67_prodshape_suite.out; then
  echo "  FAIL the v67 suite did not report V67 SUITE PASS:" >&2; tail -30 /tmp/v67_prodshape_suite.out >&2; exit 1
fi
echo "  ok   V67 SUITE PASS on the production-shaped chain"

rm -f /tmp/v67_prodshape_apply.out /tmp/v67_prodshape_suite.out
if [ "$fail" = "0" ]; then
  echo "v67 prod-shape splice parity: PASS (rev-4 needle -> 0 occurrences in prod shape; rev-5 needle -> 1; gate installed, pre-write, behaviour intact)"
else exit 1; fi
