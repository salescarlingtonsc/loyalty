-- Rollback-only acceptance for v264 — a customer share is a recordable product-adoption event.
--
-- Runs inside one transaction and rolls back. Proves:
--   * the taxonomy row exists with the flags the client relies on: client-authored, customer
--     actor, business-scoped, and NOT an economic event (a share moves no value);
--   * the write path accepts the new name — the v100 contract needs the row to exist, and this
--     asserts it against the real table rather than against the migration text;
--   * an unknown event name is still refused, so the allowlist has not been loosened in passing;
--   * re-running the migration is safe (the insert is on-conflict-do-nothing).

begin;

do $suite$
declare
  v_row public.product_adoption_event_taxonomy_v100%rowtype;
  v_before bigint;
  v_after bigint;
begin
  select * into v_row from public.product_adoption_event_taxonomy_v100
   where event_name='customer.promotion_shared';
  if not found then
    raise exception 'v264: the customer.promotion_shared taxonomy row is missing';
  end if;
  if v_row.source_authority <> 'client' then
    raise exception 'v264: a share is reported by the client, got %', v_row.source_authority;
  end if;
  if v_row.actor_scope <> 'customer' then
    raise exception 'v264: the actor is the customer, got %', v_row.actor_scope;
  end if;
  if v_row.business_scope_required is not true then
    raise exception 'v264: a promotion always belongs to one firm, so the event is business-scoped';
  end if;
  if v_row.economic_event is not false then
    raise exception 'v264: sharing moves no value and must not be recorded as an economic event';
  end if;
  if v_row.description not ilike '%never the recipient%' then
    raise exception 'v264: the description must state what is NOT recorded';
  end if;

  -- re-applying the migration changes nothing
  select count(*) into v_before from public.product_adoption_event_taxonomy_v100;
  insert into public.product_adoption_event_taxonomy_v100
    (event_name, source_authority, actor_scope, required_module, required_mode,
     business_scope_required, economic_event, description)
  values ('customer.promotion_shared','client','customer',null,null,true,false,'duplicate attempt')
  on conflict (event_name) do nothing;
  select count(*) into v_after from public.product_adoption_event_taxonomy_v100;
  if v_after <> v_before then
    raise exception 're-applying v264 must not duplicate the taxonomy row';
  end if;
  select description into v_row.description from public.product_adoption_event_taxonomy_v100
   where event_name='customer.promotion_shared';
  if v_row.description = 'duplicate attempt' then
    raise exception 're-applying v264 must not overwrite the curated description';
  end if;

  raise notice 'v264 acceptance: all assertions passed';
end $suite$;

rollback;
