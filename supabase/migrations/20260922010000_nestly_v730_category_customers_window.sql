-- NESTLY v730 -- period validation on public.get_ci_category_customers_v1 (check 98 /
-- docs/qa/CI-100-CHECKLIST.md): a refuter proved this reader, deliberately left out of scope
-- by nestly_v726 ("does NOT touch get_ci_category_customers_v1"), still accepts p_to < p_from
-- and returns a normal-looking, empty-or-partial payload instead of an error -- an inverted
-- [from, to] window silently reads as "no rows in range" rather than "malformed request",
-- indistinguishable from a genuinely quiet period at the call site.
--
-- THE FIX. Re-emits public.get_ci_category_customers_v1 to call the ALREADY-SHIPPED
-- app.ci_period_validate_v726(p_from date, p_to date) (nestly_v726) immediately after the
-- existing app.ci_access_gate_v667(p_business, p_branch) call. No new shared authority --
-- v726's guard is reused verbatim, closing the one reader v726 explicitly deferred.
--
-- PLACEMENT: the call sits immediately AFTER app.ci_access_gate_v667(p_business, p_branch)
-- and nothing else -- same rule v726 applied to the other 13 readers. A refused caller must
-- still learn they lack access (42501) before learning anything about the shape of their
-- request (22023); swapping the order would leak "your window is malformed" to a caller who
-- was never entitled to ask, and would change the error a legitimately-refused caller sees
-- for no reason.
--
-- Re-emits ONLY public.get_ci_category_customers_v1. Does NOT touch
-- get_customer_intelligence_v83, app.ci_period_validate_v726, app.ci_access_gate_v667,
-- app.ci_envelope_v680, or any of the 13 readers v726 already patched -- all deliberately
-- left alone.
--
-- Anchored, comment-free replace-equality edit of the LIVE body (pg_get_functiondef captured
-- at apply time), verified to round-trip back to the exact live original once the intended
-- edit is reversed -- same discipline as v668/v690/v706/v726, never a hand-retyped guess at
-- the base text. Base body is v725's re-emit of this same function (top-level time_basis in
-- both payload sites) -- this migration touches only the gate/period-guard preamble and
-- leaves v725's time_basis edits untouched.
--
-- Proven by db/tests/executed/v730_corpus_category_customers_window.sql.

begin;

-- -------------------------------------------------------------------------------------------
-- public.get_ci_category_customers_v1
-- -------------------------------------------------------------------------------------------
do $patch_category_customers$
declare
  v_def text;
  v_count integer;
  v_expected text;
  v_after text;
  v_roundtrip text;
begin
  select pg_get_functiondef(to_regprocedure(
    'public.get_ci_category_customers_v1(uuid,text,date,date,integer,uuid,timestamptz)'
  )) into v_def;
  if v_def is null then
    raise exception 'v730: public.get_ci_category_customers_v1(uuid,text,date,date,integer,uuid,timestamptz) not found';
  end if;
  v_count := (length(v_def) - length(replace(v_def, $v730a$  perform app.ci_access_gate_v667(p_business, p_branch);
$v730a$, ''))) / greatest(length($v730b$  perform app.ci_access_gate_v667(p_business, p_branch);
$v730b$), 1);
  if v_count <> 1 then
    raise exception 'v730: category_customers.gate anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_expected := replace(v_def, $v730c$  perform app.ci_access_gate_v667(p_business, p_branch);$v730c$, $v730d$  perform app.ci_access_gate_v667(p_business, p_branch);
  perform app.ci_period_validate_v726(p_from, p_to);$v730d$);
  execute v_expected;

  select pg_get_functiondef(to_regprocedure(
    'public.get_ci_category_customers_v1(uuid,text,date,date,integer,uuid,timestamptz)'
  )) into v_after;

  v_roundtrip := replace(v_after, $v730e$  perform app.ci_access_gate_v667(p_business, p_branch);
  perform app.ci_period_validate_v726(p_from, p_to);$v730e$, $v730f$  perform app.ci_access_gate_v667(p_business, p_branch);$v730f$);
  if v_roundtrip <> v_def then
    raise exception
      'v730: get_ci_category_customers_v1 changed by more than the 1 intended edit [gate+period]. Before:%  %After (reversed):%  %',
      E'\n', v_def, E'\n', v_roundtrip;
  end if;
end
$patch_category_customers$;
-- ACL restated verbatim from the live proacl (unchanged by this migration -- same argument list).
revoke all on function public.get_ci_category_customers_v1(uuid,text,date,date,integer,uuid,timestamptz) from public, anon;
grant execute on function public.get_ci_category_customers_v1(uuid,text,date,date,integer,uuid,timestamptz) to authenticated, service_role;

commit;
