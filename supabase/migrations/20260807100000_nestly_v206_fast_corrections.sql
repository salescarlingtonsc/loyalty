-- NESTLY v206 — a manual line can be a correction, and it does not need a paragraph.
--
-- Owner: "dont need reason when 'add item' - this is for over sold or ad hoc purchase that
-- need fast transactions (like negative transaction = minus points away, or positive
-- transactions (maybe due to under charge) that require fast record)."
--
-- Two changes to the custom-line rules in app.ps1c_plan_checkout, and nothing else:
--
--   1. amount_cents may be NEGATIVE. Only zero is refused, because a zero-value correction
--      says nothing. The firm's manual-price ceiling now applies to the SIZE of the
--      adjustment (abs), so a -$500 correction is bounded exactly like a +$500 one.
--
--   2. The reason is OPTIONAL (still capped at 200 characters). The description stays, and
--      v_entered_by still records WHO keyed the line — which is the half of the audit trail
--      that actually answers "who did this", where free text mostly answered "someone typed
--      the word adjustment".
--
-- WHAT DELIBERATELY DID NOT CHANGE: a checkout must still total more than zero. A negative
-- line can reduce a sale but can never zero it out or drive it below zero, so this cannot
-- become a back door for issuing money. Points follow the total, so a negative correction
-- reduces the points earned by construction rather than by a separate rule — which is what
-- the owner meant by "minus points away".
--
-- Applied to production by patching the live definition (pg_get_functiondef -> string
-- replace -> execute), so the deployed function is byte-identical to what ran before apart
-- from these three edits. Recorded here for the migration chain.

begin;

do $patch$
declare v_src text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='app' and p.proname='ps1c_plan_checkout';
  if v_src is null then raise exception 'app.ps1c_plan_checkout is missing'; end if;
  v_new := v_src;

  v_new := replace(v_new,
    'if v_camt <> trunc(v_camt) or v_camt < 1 then',
    'if v_camt <> trunc(v_camt) or v_camt = 0 then');
  v_new := replace(v_new,
    '''custom_line_invalid: amount_cents must be a whole number of at least 1 cent''',
    '''custom_line_invalid: amount_cents must be a whole number of cents and cannot be zero''');
  v_new := replace(v_new, 'if v_camt > v_limit then', 'if abs(v_camt) > v_limit then');
  v_new := replace(v_new,
'      if length(v_creason) < 3 or length(v_creason) > 200 then
        return jsonb_build_object(''status'', ''custom_line_invalid'', ''line'', v_ord,
          ''reason'', ''custom_line_invalid: a custom line needs a reason of 3 to 200 characters'');
      end if;',
'      if length(v_creason) > 200 then
        return jsonb_build_object(''status'', ''custom_line_invalid'', ''line'', v_ord,
          ''reason'', ''custom_line_invalid: a custom line reason cannot exceed 200 characters'');
      end if;');

  if position('abs(v_camt) > v_limit' in v_new) = 0
     or position('v_camt = 0 then' in v_new) = 0
     or position('reason cannot exceed 200 characters' in v_new) = 0 then
    raise exception 'v206 patch incomplete — refusing to install a half-edited planner';
  end if;
  execute v_new;
end
$patch$;

commit;
