-- nestly_v463 — the longest stamp card a firm may set is 15, not 100.
--
-- OWNER RULING R3(a), 2026-08-23: "business editor maximum = 15 stamps (input max, steppers, and
-- the server write guard for NEW writes; existing values are not mutated)."
--
-- WHAT CHANGES. public.business_set_stamp_card_length_v414 opens with
--
--   if p_stamps is null or p_stamps < 1 or p_stamps > 100 then
--     raise exception 'a stamp card must be between 1 and 100 stamps long' using errcode='22023';
--
-- and that 100 is the number the workspace editor mirrors in its input's max attribute, both
-- steppers and the typed field's commit guard. This lowers the server's half of that pair to 15.
-- Nothing else in the function moves: the same owner-write gate, the same version-split begin/
-- commit through app.stamp_config_edit_begin_v433 / app.stamp_config_edit_commit_v433, the same
-- stranded-gift refusal that names the gift in the way, the same audit row, the same return shape.
--
-- EXISTING DATA IS NOT TOUCHED. The ruling is explicit, and this file contains no UPDATE. The
-- guard is a bound on NEW writes only, which is why it lives in the write path and not in a check
-- constraint: a constraint would make every unrelated update to a longer card fail, and there is
-- no owner instruction to shorten anybody's card.
--
-- WHOSE CARDS WOULD THAT BE? Scanned read-only against production gadpooereceldfpfxsod on
-- 2026-08-23, before writing this:
--
--   loyalty_programs.stamp_target > 15       ->  0 rows.
--   loyalty_program_versions.stamp_target > 15 ->  3 rows, all on kopi-tiam-tyeh (8492e8d6-…),
--     holding 16, 17 and 16. All three are SUPERSEDED config versions; that firm's
--     businesses.active_config_version_id resolves to stamp_target 10 and its spine row agrees.
--
-- So no business is running a card longer than 15 today, and the highest in force anywhere is 15
-- (qa-kaya-toast). The three historic rows are immutable published versions belonging to customers
-- who collected under them (nestly_v416 / v433: a card keeps the setup it was started under), and
-- rewriting them would rewrite what those customers were promised. They are left exactly as they
-- are. The editor draws a card at its REAL stored length for the same reason — see
-- GROW_STAMPS_RENDER_CAP_V463 in app/app.js: clamping the drawing to 15 would be nestly_v445's
-- phantom-length defect with the sign reversed, showing 15 over a stored 40 and writing the lie
-- back on the first tap.
--
-- METHOD: extract-and-patch against the deployed definition, the v213 / v454 / v460 pattern,
-- rather than retyping a 70-line SECURITY DEFINER body that is currently correct. Both anchors
-- were counted against production first and occur EXACTLY ONCE, in exactly one function in
-- schemas public and app:
--
--   'p_stamps is null or p_stamps < 1 or p_stamps > 100'          -> 1 occurrence
--   'a stamp card must be between 1 and 100 stamps long'          -> 1 occurrence
--
-- The block below re-counts both before it replaces anything and refuses to install a partial
-- patch. It is idempotent: a body that no longer carries the old bound is left alone, and either
-- way the installed definition is re-read and required to carry the new one and not the old.
--
-- WHY BOTH ANCHORS AND NOT JUST THE COMPARISON. Patching the test without patching the message
-- would leave the function refusing 16 while telling the owner cards may be 100 long — the class
-- of defect nestly_v453 was spent on. The message is owner-facing text shown verbatim by the
-- editor (growStampsSetLengthV422 renders ownerErrorText(error) unmodified, deliberately, because
-- v414's refusals name the gift that is in the way).
--
-- ACL: create-or-replace preserves grants. The live ACL is
-- {postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres} — PUBLIC and anon already
-- hold nothing. The revoke/grant pair below restates that verbatim; it is a no-op reassertion, not
-- a privilege change.
--
-- Guard suite: db/tests/v463_stamp_card_max_length.sql — executing checks against a fixture tenant
-- built and rolled back in one transaction, with a negative control that reproduces the pre-patch
-- acceptance of 16.

begin;

do $patch$
declare
  v_src text;
  v_new text;
  v_old_test constant text := 'p_stamps is null or p_stamps < 1 or p_stamps > 100';
  v_new_test constant text := 'p_stamps is null or p_stamps < 1 or p_stamps > 15';
  v_old_msg  constant text := 'a stamp card must be between 1 and 100 stamps long';
  v_new_msg  constant text := 'a stamp card must be between 1 and 15 stamps long';
  v_hits int;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'business_set_stamp_card_length_v414';
  if v_src is null then
    raise exception 'v463: public.business_set_stamp_card_length_v414 is missing';
  end if;

  if position(v_old_test in v_src) = 0 and position(v_old_msg in v_src) = 0 then
    raise notice 'v463: the 100-stamp bound is already gone; left as it is';
  else
    -- Half a patch is worse than none: the comparison and the sentence must move together.
    v_hits := (length(v_src) - length(replace(v_src, v_old_test, ''))) / length(v_old_test);
    if v_hits <> 1 then
      raise exception 'v463: expected exactly 1 occurrence of the length test, found %', v_hits;
    end if;
    v_hits := (length(v_src) - length(replace(v_src, v_old_msg, ''))) / length(v_old_msg);
    if v_hits <> 1 then
      raise exception 'v463: expected exactly 1 occurrence of the refusal message, found %', v_hits;
    end if;

    v_new := replace(replace(v_src, v_old_test, v_new_test), v_old_msg, v_new_msg);
    if v_new = v_src then
      raise exception 'v463: the replacement did not take';
    end if;
    execute v_new;
  end if;

  -- Whatever branch we took, what is deployed now must carry the new bound and not the old one.
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'business_set_stamp_card_length_v414';
  if position(v_old_test in v_src) > 0 or position(v_old_msg in v_src) > 0 then
    raise exception 'v463: the 100-stamp bound survived the patch';
  end if;
  if position(v_new_test in v_src) = 0 or position(v_new_msg in v_src) = 0 then
    raise exception 'v463: the 15-stamp bound is not in the installed definition';
  end if;
  -- And the parts of the function this migration must NOT have touched are still there.
  if position('app.c45_owner_loyalty_write(p_business)' in v_src) = 0
     or position('app.stamp_config_edit_begin_v433(p_business)' in v_src) = 0
     or position('app.stamp_config_edit_commit_v433(p_business, v_target)' in v_src) = 0
     or position('Move or remove that gift first.' in v_src) = 0 then
    raise exception 'v463: the patched body lost a guard it must keep';
  end if;

  raise notice 'v463: business_set_stamp_card_length_v414 now caps new writes at 15 stamps';
end
$patch$;

revoke all on function public.business_set_stamp_card_length_v414(uuid, integer) from public, anon;
grant execute on function public.business_set_stamp_card_length_v414(uuid, integer) to authenticated, service_role;

commit;
