begin;

/* nestly_v579 — an existing promotion message must be able to name and open its promotion.

   OWNER (photo 2, second time of asking): a bracket down the whole Messages list, "i want see
   promo details". v577 made the two inbox list RPCs return offer_id so the browser could open the
   promotion. It changed nothing on screen, because the id it returns is
   customer_in_app_inbox_events.source_ref_id and EVERY row in production has it NULL:

     source_kind            events   with_source_ref
     v122_promotion_new         19                 0
     v122_promotion_expiry       6                 0

   app.enqueue_promotion_alert_v122 does write it (nestly_v571 added the column to the insert and
   supplies v_content.id), so alerts generated from now on carry it. But v571 landed on 2026-08-28
   and the newest existing event is 2026-08-27 — not one row has been written since, so every
   message the owner can actually see predates the fix.

   The same NULL also suppressed the offer's NAME: offer_title is looked up by
   business_localized_copy_v95.entity_id = source_ref_id, so with no ref every row fell back to its
   stored title. That is why the list reads "New promotion available" over and over instead of
   naming the offers.

   WHY THIS IS A READ-TIME RESOLUTION AND NOT A BACKFILL. The obvious fix is to UPDATE the old
   rows. customer_in_app_inbox_events is append-only — app.c46_append_only_guard raises 23000 on
   anything but INSERT — and that guard is the point of an event log, not an obstacle to route
   around. (Attempted, refused, and left refused.) So the id is recovered when the row is READ.

   It is recoverable because it was never really lost: source_fingerprint is a sha256 over a JSON
   object that CONTAINS the promotion id, so the original is found by recomputing that hash for
   each of the business's own promotions and matching. The helper below reproduces the generator's
   expression exactly, including the source_kind-dependent 'ends_at' term that only expiry alerts
   add. Measured against production: 25 events missing a ref, 25 recoverable, 25 UNIQUE matches —
   one candidate per event, nothing to disambiguate — and all 25 then resolve a real localised
   title (e.g. "CNY!!!!: 30% off").

   The helper short-circuits on source_ref_id, so every row written from v571 onwards costs
   nothing and this work disappears as the old rows age out. It is scoped to the promotion source
   kinds and to the event's own business, so it can never attach an event to another tenant's
   promotion. */

create or replace function app.c46_inbox_promotion_ref_v579(
  p_business uuid,
  p_source_kind text,
  p_fingerprint text,
  p_source_ref uuid
) returns uuid
language sql
stable
security definer
set search_path to pg_catalog, public, app, pg_temp
as $fn$
  select coalesce(
    p_source_ref,
    (select p.id
       from public.business_customer_content_v95 p
      where p_source_ref is null
        and p_source_kind in ('v122_promotion_new','v122_promotion_expiry')
        and p.business_id = p_business
        and app.c46_sha256_hex((jsonb_build_object(
              'promotion_id', p.id,
              'source_kind', p_source_kind,
              'published_once_at', p.metadata->>'published_once_at'
            ) || case when p_source_kind = 'v122_promotion_expiry'
                      then jsonb_build_object('ends_at', p.ends_at)
                      else '{}'::jsonb end)::text) = p_fingerprint
      limit 1));
$fn$;

revoke all on function app.c46_inbox_promotion_ref_v579(uuid, text, text, uuid) from public, anon;
grant execute on function app.c46_inbox_promotion_ref_v579(uuid, text, text, uuid) to authenticated, service_role;

/* Both list RPCs read the resolved id in the two places that need it: the row projection (which
   becomes offer_id) and the offer_title lookup. Patched by substitution rather than restated —
   these are long functions and only two lines each change; see the nestly_v577 note for the same
   reasoning. Both anchors were confirmed present exactly twice per function before this ran. */
do $inbox$
declare
  v_name text;
  v_src  text;
  v_args text;
  v_call constant text :=
    'app.c46_inbox_promotion_ref_v579(e.business_id,e.source_kind,e.source_fingerprint,e.source_ref_id)';
  v_select constant text := 'e.topic,e.source_kind,e.source_ref_id,';
  v_title  constant text := 'copy_row.entity_id=e.source_ref_id';
begin
  foreach v_name in array array['customer_list_in_app_inbox','customer_list_in_app_inbox_global'] loop
    select p.prosrc, pg_get_function_arguments(p.oid) into v_src, v_args
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace and n.nspname = 'public'
     where p.proname = v_name;

    if v_src is null then
      raise exception 'nestly_v579: public.% not found', v_name;
    end if;

    if position('c46_inbox_promotion_ref_v579' in v_src) > 0 then
      continue;  -- already resolved (re-run)
    end if;

    if (length(v_src) - length(replace(v_src, v_select, ''))) / length(v_select) <> 1 then
      raise exception 'nestly_v579: % — expected the row projection exactly once', v_name;
    end if;
    if (length(v_src) - length(replace(v_src, v_title, ''))) / length(v_title) <> 1 then
      raise exception 'nestly_v579: % — expected the offer_title lookup exactly once', v_name;
    end if;

    v_src := replace(v_src, v_select, 'e.topic,e.source_kind,' || v_call || ' as source_ref_id,');
    v_src := replace(v_src, v_title,  'copy_row.entity_id=' || v_call);

    execute format(
      'create or replace function public.%I(%s) returns jsonb language plpgsql security definer'
      ' set search_path to pg_catalog, public, app, pg_temp as %L',
      v_name, v_args, v_src);
  end loop;
end
$inbox$;

revoke all on function public.customer_list_in_app_inbox(text, jsonb) from public, anon;
grant execute on function public.customer_list_in_app_inbox(text, jsonb) to authenticated, service_role;
revoke all on function public.customer_list_in_app_inbox_global(jsonb) from public, anon;
grant execute on function public.customer_list_in_app_inbox_global(jsonb) to authenticated, service_role;

commit;
