-- nestly_v899 — Meta's answer gets written down.
--
-- OWNER, 2026-09-14: "yes do the reconciling write too - ensure it is completed."
--
-- THE DEFECT CLASS v898 NAMED AND DID NOT CLOSE. whatsapp_template_registry_v551 is the gate the
-- sender checks, and nothing kept it true. whatsapp-admin-templates could already ASK Meta for
-- template statuses — its 'status' action has read the Graph API since v557 — and then returned
-- the answer to whoever called it and recorded nothing. So every approval after the first had to
-- be noticed by a human and typed in, and twice it was not: v898 found peekaa_appt_reminder_today
-- and peekaa_appt_updated still reading 'submitted' seventeen days after Meta approved them, which
-- meant Peekaa's own gate was refusing two templates Meta was perfectly happy to send.
--
-- A read with no writer is how that happens. This is the writer.
--
-- WHAT IT WILL AND WILL NOT DO.
--   * It NEVER inserts. A template Meta knows about that this registry does not is ignored. The
--     definition authority is the TEMPLATES array in whatsapp-admin-templates plus the migrations
--     that register each key — not whatever happens to exist in the WABA. Otherwise anyone with
--     access to Business Manager could add a row to Peekaa's send gate by creating a template.
--   * It NEVER promotes on its own judgement. 'approved' is written only where the caller observed
--     Meta's APPROVED; every other Meta answer maps to a status the sender refuses. The mapping
--     lives in _shared/whatsapp-template-status-boundaries.mjs and is covered by v899 tests.
--   * It NEVER touches body_text, category, language or parameter_descriptors. Those are the
--     contract the sender binds parameters against; Meta's list is not the authority for them and
--     a "reconcile" that quietly rewrote a body would be a far worse bug than the one being fixed.
--   * It is idempotent and reports what it changed, so running it twice is a no-op with an empty
--     changed[] rather than a second round of churn.
--
-- NO CRON. This is callable, not scheduled. v824 was written because a machine was found running
-- that nobody had switched on, and the honest close of that ruling is not to add another timer
-- without being asked. Wiring this to pg_cron is a one-line follow-up whenever the owner wants it.

begin;

create or replace function public.internal_whatsapp_template_reconcile_v899(
  p_observations jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_changed jsonb := '[]'::jsonb;
  v_unknown jsonb := '[]'::jsonb;
  v_row record;
begin
  if p_observations is null or jsonb_typeof(p_observations) <> 'array' then
    return jsonb_build_object('ok', false, 'reason', 'observations_invalid');
  end if;

  for v_row in
    select
      obs->>'meta_name'         as meta_name,
      obs->>'status'            as status,
      nullif(obs->>'meta_template_id', '') as meta_template_id
    from jsonb_array_elements(p_observations) as obs
  loop
    -- The five the registry's own CHECK allows. A caller that invents a sixth is refused here
    -- rather than blocked by the constraint halfway through the batch.
    if v_row.status is null or v_row.status not in ('draft', 'submitted', 'approved', 'rejected', 'paused') then
      v_unknown := v_unknown || jsonb_build_object('meta_name', v_row.meta_name, 'status', v_row.status);
      continue;
    end if;

    -- No insert, by design: only a meta_name this registry already holds can be written.
    update public.whatsapp_template_registry_v551 as r
       set status = v_row.status,
           meta_template_id = coalesce(v_row.meta_template_id, r.meta_template_id),
           updated_at = now()
     where r.meta_name = v_row.meta_name
       and (r.status is distinct from v_row.status
            or (r.meta_template_id is null and v_row.meta_template_id is not null));

    if found then
      v_changed := v_changed || jsonb_build_object(
        'meta_name', v_row.meta_name,
        'status', v_row.status
      );
    end if;
  end loop;

  return jsonb_build_object(
    'ok', true,
    'changed', v_changed,
    'changed_count', jsonb_array_length(v_changed),
    'unmappable', v_unknown
  );
end;
$$;

comment on function public.internal_whatsapp_template_reconcile_v899(jsonb) is
  'nestly_v899: records Meta template statuses into whatsapp_template_registry_v551. Updates only; never inserts; never touches body_text or the parameter contract.';

-- service_role only, the internal_* convention verbatim. The browser has no path here, and the
-- only caller is whatsapp-admin-templates, which is itself behind the dispatch secret.
revoke all on function public.internal_whatsapp_template_reconcile_v899(jsonb)
  from public, anon, authenticated;
grant execute on function public.internal_whatsapp_template_reconcile_v899(jsonb) to service_role;

commit;
