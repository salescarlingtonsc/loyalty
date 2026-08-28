begin;

/* nestly_v577 — publishing a loyalty config must not destroy tier identity.

   OWNER REPORT (photo 7): the Birthday gift dialog refuses every save with "That change couldn't
   be saved. Check the details and try again." — "why cannot on".

   ROOT CAUSE, reproduced against production as the real owner role in a rolled-back transaction:

     ERROR 23503: update or delete on table "tier_benefits_v365" violates foreign key constraint
     "customer_gift_intents_v515_benefit_id_fkey" on table "customer_gift_intents_v515"
     CONTEXT: SQL statement "delete from public.loyalty_tiers where business_id=..."
              PL/pgSQL function publish_loyalty_config(uuid) line 155

   publish_loyalty_config republishes the live tier rows by DELETING every tier for the business
   and re-INSERTing them from loyalty_tier_versions — re-using the same tier_id, so the delete
   never changed a single tier's identity in the first place. It was pure churn. But it is not
   harmless churn, because two things hang off a tier row:

     loyalty_tiers --CASCADE--> tier_benefits_v365 --RESTRICT--> customer_gift_intents_v515

   So the delete has two failure modes, and production had both:

     1. SILENT DATA LOSS, every tenant, every publish. There is no tier_benefit_versions table —
        tier_benefits_v365 is live-only, with no snapshot to be restored from. The CASCADE
        therefore deleted every structured tier benefit (the v369 typed benefits) on every single
        publish, and nothing ever put them back.

     2. TOTAL PUBLISH FAILURE the moment one customer holds a gift intent against a benefit. The
        RESTRICT blocks the CASCADE, the delete raises 23503, and the whole transaction rolls
        back. This is not confined to the birthday gift the owner happened to be editing:
        publish_loyalty_config is the single publish path, so points, the stamp card, tiers, the
        welcome offer, bring-back, business_save_birthday_program_v424,
        business_delete_retention_program_v332 and set_studio_rule_active ALL become unsaveable
        for that tenant at once. Cubbly SPA had exactly one such intent, and that one row was
        bricking its entire programme stack.

   THE FIX: stop deleting rows that are being immediately re-created. The insert already carries
   the stable tier_id, so an upsert on the primary key expresses what this code always meant —
   "make the live tiers match this version" — without ever destroying a tier's dependents.

   A tier the new version genuinely no longer carries is still retired, and retiring it keeps the
   previous behaviour (hard delete) whenever nothing depends on it. It is soft-retired instead —
   paused, with deleted_at set — only when a customer holds an outstanding gift intent against one
   of its benefits, because silently destroying a gift a customer has already been promised is a
   worse outcome than keeping a dead tier row. Soft-retired tiers grant nothing (nestly_v394), and
   this is the mechanism the table already uses; production carries 12 such rows today.

   The paused / deleted_at carry-forward that surrounded the old delete is deleted with it: those
   columns are no longer in any write here, so a surviving row simply keeps the values it had,
   which is what the carry block existed to simulate.

   The function is patched by textual substitution on its own live source rather than restated in
   full. publish_loyalty_config is ~16KB of validation logic accreted over ~20 revisions, and
   re-typing it to change eleven lines is how a transcription error gets shipped into the one
   function every programme write in the product goes through. The substitution asserts the old
   block is present exactly once before it runs and that the new one is present after, so it
   cannot half-apply or apply twice. */

do $migration$
declare
  v_src   text;
  v_def   text;
  v_old   text;
  v_new   text;
  v_count integer;
begin
  select p.prosrc into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace and n.nspname = 'public'
   where p.proname = 'publish_loyalty_config'
     and pg_get_function_identity_arguments(p.oid) = 'p_version uuid';

  if v_src is null then
    raise exception 'nestly_v577: public.publish_loyalty_config(uuid) not found';
  end if;

  v_old :=
E'  select array_agg(id), array_agg(paused), array_agg(deleted_at)\n'
'    into v_tier_carry_ids, v_tier_carry_paused, v_tier_carry_deleted\n'
'    from public.loyalty_tiers\n'
'   where business_id=v_header.business_id and (paused or deleted_at is not null);\n'
'  delete from public.loyalty_tiers where business_id=v_header.business_id;\n'
'  insert into public.loyalty_tiers(id,business_id,name,threshold,points_multiplier,perk_note,sort,effective_from,expires_at) select tier_id,business_id,name,threshold,points_multiplier,perk_note,sort,effective_from,expires_at from public.loyalty_tier_versions where config_version_id=p_version and business_id=v_header.business_id and active;\n'
'  if v_tier_carry_ids is not null then\n'
'    update public.loyalty_tiers t set paused=c.paused,deleted_at=c.deleted_at\n'
'      from (select unnest(v_tier_carry_ids) as id, unnest(v_tier_carry_paused) as paused, unnest(v_tier_carry_deleted) as deleted_at) c\n'
'     where c.id=t.id and t.business_id=v_header.business_id;\n'
'  end if;\n';

  v_new :=
E'  -- nestly_v577: upsert on the primary key instead of delete-then-insert. The insert always\n'
'  -- carried the stable tier_id, so this makes the live tiers match the version exactly as before\n'
'  -- while never destroying a tier row -- and therefore never cascading into tier_benefits_v365,\n'
'  -- which has no version table to be restored from. paused / deleted_at are deliberately absent\n'
'  -- from the update list: a surviving tier keeps the values it already had.\n'
'  insert into public.loyalty_tiers(id,business_id,name,threshold,points_multiplier,perk_note,sort,effective_from,expires_at)\n'
'  select tier_id,business_id,name,threshold,points_multiplier,perk_note,sort,effective_from,expires_at\n'
'    from public.loyalty_tier_versions\n'
'   where config_version_id=p_version and business_id=v_header.business_id and active\n'
'  on conflict (id) do update set\n'
'    name=excluded.name, threshold=excluded.threshold, points_multiplier=excluded.points_multiplier,\n'
'    perk_note=excluded.perk_note, sort=excluded.sort,\n'
'    effective_from=excluded.effective_from, expires_at=excluded.expires_at;\n'
'  -- A tier this version no longer carries, and which a customer has an outstanding gift intent\n'
'  -- against: soft-retire rather than destroy the promise. Retired tiers grant nothing (v394).\n'
'  update public.loyalty_tiers t\n'
'     set paused=true, deleted_at=coalesce(t.deleted_at, now())\n'
'   where t.business_id=v_header.business_id\n'
'     and not exists (select 1 from public.loyalty_tier_versions v\n'
'                      where v.config_version_id=p_version and v.business_id=t.business_id\n'
'                        and v.active and v.tier_id=t.id)\n'
'     and exists (select 1 from public.tier_benefits_v365 tb\n'
'                   join public.customer_gift_intents_v515 gi on gi.benefit_id=tb.id\n'
'                  where tb.tier_id=t.id);\n'
'  -- Anything else the version dropped is removed outright, as it always was.\n'
'  delete from public.loyalty_tiers t\n'
'   where t.business_id=v_header.business_id\n'
'     and not exists (select 1 from public.loyalty_tier_versions v\n'
'                      where v.config_version_id=p_version and v.business_id=t.business_id\n'
'                        and v.active and v.tier_id=t.id)\n'
'     and not exists (select 1 from public.tier_benefits_v365 tb\n'
'                       join public.customer_gift_intents_v515 gi on gi.benefit_id=tb.id\n'
'                      where tb.tier_id=t.id);\n';

  v_count := (length(v_src) - length(replace(v_src, v_old, ''))) / length(v_old);
  if v_count <> 1 then
    raise exception 'nestly_v577: expected the tier republish block exactly once, found %', v_count;
  end if;

  v_src := replace(v_src, v_old, v_new);

  /* The now-unused carry variables go with the block that used them. */
  v_src := replace(v_src,
E'  v_tier_carry_ids uuid[]; v_tier_carry_paused boolean[]; v_tier_carry_deleted timestamptz[];\n',
'');

  if position('v_tier_carry_ids' in v_src) <> 0 then
    raise exception 'nestly_v577: carry variables still referenced after substitution';
  end if;
  if position('on conflict (id) do update set' in v_src) = 0 then
    raise exception 'nestly_v577: upsert not present after substitution';
  end if;

  /* search_path is written UNQUOTED below: these are plain identifiers, so it is the same setting,
     and it keeps the emitted text free of doubled quotes — which the pending-migration search_path
     guard reads literally out of this file and cannot unescape.
     The comment sits ABOVE the format() call, not between its string fragments: adjacent string
     literals are concatenated only when separated by whitespace, and a comment in between ends the
     continuation and raises 42601. Caught by the database on the first apply. */
  v_def := format(
    'create or replace function public.publish_loyalty_config(p_version uuid)'
    ' returns json language plpgsql security definer'
    ' set search_path to pg_catalog, public, app, pg_temp'
    ' as %L', v_src);
  execute v_def;
end
$migration$;


/* ---------------------------------------------------------------------------------------------
   nestly_v577, part 2 — the inbox row must be able to open the promotion it is about.

   OWNER (photo 15): a bracket down the whole Messages list — "i want see promo details".

   A promotion row already knows which offer it is about: customer_in_app_inbox_events.source_ref_id
   is the offer id, and both list RPCs already read it, but only inside a correlated subquery that
   fetches the offer's NAME. It is never returned, so the browser had nothing to open with and the
   row could only navigate to the programme page and leave the customer to find the offer.

   Returning the id it already resolved is the whole change. No new table is read, no new row is
   exposed: source_ref_id is an id the caller is by definition entitled to (the surrounding query
   is already filtered to this customer's own verified links), and the offer's name is ALREADY
   returned beside it. The browser then focuses that promotion through the existing
   customerOfferFocusV167 path.

   Patched by substitution for the same reason as part 1 — these are long functions and only two
   lines each change. Both functions carry both anchors identically, so one loop covers them. */
do $inbox$
declare
  v_name   text;
  v_src    text;
  v_select text := 'select e.id,e.title,e.body,e.route_key,e.created_at,e.deadline_at,e.topic,e.source_kind,';
  v_build  text := '''offer_title'',v_row.offer_title,';
  v_args   text;
begin
  foreach v_name in array array['customer_list_in_app_inbox','customer_list_in_app_inbox_global'] loop
    /* pg_get_function_ARGUMENTS, not identity_arguments: these two carry parameter DEFAULTS, and
       identity_arguments drops them — CREATE OR REPLACE then refuses with 42P13 "cannot remove
       parameter defaults from existing function". Caught by the database on the first rehearsal. */
    select p.prosrc, pg_get_function_arguments(p.oid) into v_src, v_args
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace and n.nspname = 'public'
     where p.proname = v_name;

    if v_src is null then
      raise exception 'nestly_v577: public.% not found', v_name;
    end if;

    /* Already carrying it (a re-run) is not an error; anything else is. */
    if position('''offer_id'',v_row.source_ref_id' in v_src) > 0 then
      continue;
    end if;

    if (length(v_src) - length(replace(v_src, v_select, ''))) / length(v_select) <> 1 then
      raise exception 'nestly_v577: % — expected the row SELECT exactly once', v_name;
    end if;
    if (length(v_src) - length(replace(v_src, v_build, ''))) / length(v_build) <> 1 then
      raise exception 'nestly_v577: % — expected the offer_title build line exactly once', v_name;
    end if;

    v_src := replace(v_src, v_select, v_select || 'e.source_ref_id,');
    v_src := replace(v_src, v_build,  v_build  || '''offer_id'',v_row.source_ref_id,');

    execute format(
      'create or replace function public.%I(%s) returns jsonb language plpgsql security definer'
      ' set search_path to pg_catalog, public, app, pg_temp as %L',
      v_name, v_args, v_src);
  end loop;
end
$inbox$;

/* Grants restated verbatim from the live proacl — CREATE OR REPLACE preserves them, and the
   preflight check requires them stated explicitly against the exact overload signature. */
revoke all on function public.publish_loyalty_config(uuid) from public, anon;
grant execute on function public.publish_loyalty_config(uuid) to authenticated, service_role;
revoke all on function public.customer_list_in_app_inbox(text, jsonb) from public, anon;
grant execute on function public.customer_list_in_app_inbox(text, jsonb) to authenticated, service_role;
revoke all on function public.customer_list_in_app_inbox_global(jsonb) from public, anon;
grant execute on function public.customer_list_in_app_inbox_global(jsonb) to authenticated, service_role;

commit;
