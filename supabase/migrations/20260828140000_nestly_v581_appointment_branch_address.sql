begin;

/* nestly_v581 — a customer's booking row can say WHERE it was.

   OWNER (photo 6): the History rows redrawn as one format — logo, business, "<service> at 4:30 PM",
   the booking's address, the date, and Book — with "(book address)" written into the sketch.

   public.customer_get_appointments_page already joins public.branches (for branch_name) but never
   returns the address, so the browser had nothing to print. Every other part of that row was
   already available; this is the one missing field.

   Branch addresses are real data — "Cubbly · Orchard" is "313 Orchard Road, Singapore 238895" —
   and this is the branch the customer actually attended, which is why it is the branch's address
   and not the business's: a multi-branch firm would otherwise show its head office against an
   appointment kept somewhere else.

   Two substitutions, both inside a function that is otherwise untouched: one column on the
   `ordered` CTE (the `eligible` CTE is `select *`, so it carries through on its own), and one key
   on the item object. Blank addresses normalise to NULL so the row omits the line rather than
   printing an empty one.

   No new table is read and no new row is exposed: the branch is already joined and already named
   in this payload, and app.v32_customer_wallet_context above still gates the whole function on a
   verified customer link to that business. */
do $appt$
declare
  v_src  text;
  v_args text;
  v_pick constant text := 's.name as service_name, br.name as branch_name';
  v_emit constant text := '''service_name'', service_name, ''branch_name'', branch_name';
begin
  select p.prosrc, pg_get_function_arguments(p.oid) into v_src, v_args
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace and n.nspname = 'public'
   where p.proname = 'customer_get_appointments_page';

  if v_src is null then
    raise exception 'nestly_v581: public.customer_get_appointments_page not found';
  end if;

  if position('branch_address' in v_src) > 0 then
    return;  -- already carries it (re-run)
  end if;

  if (length(v_src) - length(replace(v_src, v_pick, ''))) / length(v_pick) <> 1 then
    raise exception 'nestly_v581: expected the branch join projection exactly once';
  end if;
  if (length(v_src) - length(replace(v_src, v_emit, ''))) / length(v_emit) <> 1 then
    raise exception 'nestly_v581: expected the item projection exactly once';
  end if;

  v_src := replace(v_src, v_pick,
    v_pick || ', nullif(btrim(br.address), '''') as branch_address');
  v_src := replace(v_src, v_emit,
    v_emit || ', ''branch_address'', branch_address');

  execute format(
    'create or replace function public.customer_get_appointments_page(%s) returns jsonb'
    ' language plpgsql stable security definer'
    ' set search_path to pg_catalog, public, app, pg_temp as %L',
    v_args, v_src);
end
$appt$;

revoke all on function public.customer_get_appointments_page(text, jsonb) from public, anon;
grant execute on function public.customer_get_appointments_page(text, jsonb) to authenticated, service_role;

commit;
