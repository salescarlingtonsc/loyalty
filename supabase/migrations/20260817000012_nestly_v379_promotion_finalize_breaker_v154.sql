-- nestly_v379 — the same promotion circuit breaker on v154, which is the one actually being hit.
--
-- v378 wrapped business_finalize_promotion_v155, the RPC the CURRENT client calls. It captured
-- nothing and the rollback rate barely moved, because the runaway client is a stale one and stale
-- clients call the OLDER api: business_finalize_promotion_v154. The two have identical 26-argument
-- signatures, so the request is indistinguishable in pg_stat_activity — whose query text is also
-- truncated before the function name, which is why this took a second pass to see.
--
-- v154 keeps its own pipeline exactly (app.save_promotion_scope_v154, and no v280 version sync);
-- only the breaker is added, sharing v378's refusal table.

begin;

create or replace function public.business_finalize_promotion_v154(
  p_business uuid, p_promotion_id uuid, p_scope_mode text, p_branch_ids uuid[],
  p_operational_branch uuid, p_name text, p_tagline text, p_description text, p_terms text,
  p_starts_at timestamp with time zone, p_ends_at timestamp with time zone,
  p_display_order integer, p_cta_kind text, p_cta_label text, p_offer_facts text,
  p_occasion text, p_publish boolean, p_object_path text, p_mime_type text,
  p_width_px integer, p_height_px integer, p_alt_en text,
  p_expected_content_version integer, p_expected_copy_version integer,
  p_expected_target_media_version integer, p_attempt_key uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_result   jsonb;
  v_scope    jsonb;
  v_failures integer;
  v_reason   text;
  v_state    text;
  v_actor    uuid := auth.uid();
  /* Three sends of one receipt, matching the client-side ceiling in v373. */
  c_max constant integer := 3;
  /* Every refusal business_finalize_promotion_v104 raises by name. Anything not in this list is
     not ours and must keep raising. */
  c_definitive constant text[] := array[
    'promotion_version_conflict',
    'promotion_copy_version_conflict',
    'promotion_target_media_version_conflict',
    'valid_promotion_attempt_identity_required',
    'valid_promotion_finalize_fields_required',
    'verified_storage_object_required',
    'promotion_not_found',
    'promotion_image_required',
    'promotion_publish_limit_reached',
    'promotion_publishing_window_closed',
    'owner_required',
    'promotion_receipt_replay_forbidden',
    'promotion_attempt_key_reused',
    'authenticated_session_required'
  ];
begin
  select refusal.failures, refusal.last_reason
    into v_failures, v_reason
    from public.promotion_finalize_refusals_v378 refusal
   where refusal.business_id  = p_business
     and refusal.promotion_id = p_promotion_id
     and refusal.attempt_key  = p_attempt_key;

  /* Past the ceiling nothing is executed: one indexed lookup answers, and the finalize pipeline —
     the version reads, the storage verification, the scope write — never runs. */
  if coalesce(v_failures, 0) >= c_max then
    return jsonb_build_object(
      'ok', false, 'blocked', true,
      'code', 'promotion_finalize_rejected',
      'reason', v_reason,
      'attempt_key', p_attempt_key,
      'promotion_id', p_promotion_id,
      'failures', v_failures);
  end if;

  begin
    v_result := public.business_finalize_promotion_v104(
      p_business,p_promotion_id,null,p_name,p_tagline,p_description,p_terms,
      p_starts_at,p_ends_at,p_display_order,p_cta_kind,p_cta_label,
      p_offer_facts,p_occasion,p_publish,p_object_path,p_mime_type,
      p_width_px,p_height_px,p_alt_en,p_expected_content_version,
      p_expected_copy_version,p_expected_target_media_version,p_attempt_key
    );
    v_scope := app.save_promotion_scope_v154(
      p_business,p_promotion_id,p_scope_mode,p_branch_ids,p_operational_branch
    );
  exception when others then
    get stacked diagnostics v_reason = message_text, v_state = returned_sqlstate;
    /* Not one of ours: re-raise unchanged. A deadlock, a real serialization failure or a bug must
       never be reported to a caller as a handled refusal. */
    if not (v_reason = any(c_definitive)) then
      raise;
    end if;
    /* The subtransaction above has rolled back; this write is in the OUTER transaction and so it
       commits with the refusal we return. That is the whole point — the abort used to erase both
       the evidence and any chance of counting the attempt. */
    insert into public.promotion_finalize_refusals_v378 as refusal
      (business_id, promotion_id, attempt_key, actor, failures, last_reason, last_sqlstate)
    values
      (p_business, p_promotion_id, p_attempt_key, v_actor, 1, v_reason, v_state)
    on conflict (business_id, promotion_id, attempt_key) do update
      set failures       = refusal.failures + 1,
          last_reason    = excluded.last_reason,
          last_sqlstate  = excluded.last_sqlstate,
          last_failed_at = now(),
          actor          = coalesce(refusal.actor, excluded.actor);
    return jsonb_build_object(
      'ok', false, 'blocked', true,
      'code', 'promotion_finalize_rejected',
      'reason', v_reason,
      'attempt_key', p_attempt_key,
      'promotion_id', p_promotion_id);
  end;

  /* A success releases the key: the same promotion may be edited and published again afterwards
     without inheriting a count from an earlier failed attempt. */
  delete from public.promotion_finalize_refusals_v378
   where business_id  = p_business
     and promotion_id = p_promotion_id
     and attempt_key  = p_attempt_key;

  return v_result || jsonb_build_object('branch_scope', v_scope);
end
$function$;


-- Restate the ACLs captured from production before the replace (a replace re-grants PUBLIC).
revoke all on function public.business_finalize_promotion_v154(
  uuid,uuid,text,uuid[],uuid,text,text,text,text,timestamptz,timestamptz,integer,text,text,text,
  text,boolean,text,text,integer,integer,text,integer,integer,integer,uuid) from public, anon;
grant execute on function public.business_finalize_promotion_v154(
  uuid,uuid,text,uuid[],uuid,text,text,text,text,timestamptz,timestamptz,integer,text,text,text,
  text,boolean,text,text,integer,integer,text,integer,integer,integer,uuid)
  to postgres, service_role, authenticated;

commit;
