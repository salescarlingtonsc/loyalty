-- NESTLY v195 — a merge must not try to move immutable source lineage.
--
-- Caught on the first real production merge. v185 classified
-- sme_prospect_source_lineage as "working data" and reparented it to the
-- survivor, but the table is protected by app.v75_immutable_guard, so the
-- merge aborted with 23001. Nothing partially applied — the whole statement
-- rolled back — but the merge was unusable on any record that had lineage,
-- which is every record captured through import or the website.
--
-- The v185 fixture had no lineage rows, which is why the suite passed and
-- production did not. The v195 suite creates lineage on purpose.
--
-- The right classification was there all along: lineage records where THIS
-- record came from. That is provenance, not working data, and it belongs with
-- stage history, stage-entry evidence and the quality snapshots that already
-- stay on the source. Moving it would have claimed the survivor was imported
-- from a batch it never appeared in. The merge now leaves it in place and
-- reports the count it retained.

begin;

do $v195$
declare
  v_def text;
  v_old text;
  v_new text;
  v_hits integer;
begin
  v_def := pg_get_functiondef(to_regprocedure(
    'public.platform_merge_prospects_v184(uuid,uuid,text)'));
  if v_def is null then
    raise exception 'v195: platform_merge_prospects_v184 is missing';
  end if;
  if position('source_lineage_retained' in v_def) > 0 then
    raise exception 'v195: merge already retains source lineage';
  end if;

  v_old := '  update public.sme_prospect_source_lineage set prospect_id=p_target where prospect_id=p_source;
  get diagnostics v_count=row_count; v_moved:=v_moved||jsonb_build_object(''source_lineage'',v_count);';

  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'v195: expected one source-lineage move, found %', v_hits;
  end if;

  -- Count it, never move it.
  v_new := '  select count(*) into v_count from public.sme_prospect_source_lineage
   where prospect_id=p_source;
  v_moved:=v_moved||jsonb_build_object(''source_lineage_retained'',v_count);';

  execute replace(v_def, v_old, v_new);
end
$v195$;

commit;
