-- nestly_v861 — a typed-in "Other item" line pays no commission.
--
-- OWNER RULING (2026-09-09, asked through the app's question prompt after the nestly_v850 walk
-- left it open as AO-3): "When staff ring up an Other item on the till … what commission should
-- that line pay?" → "No commission." A custom line is a name and a price the counter typed; the
-- owner never set a rate on it, so paying the member's product % on it (v818/v827's "anything
-- else" fallback) was a guess nobody asked for. On one tenant it paid 100% of $123,477.70 of
-- typed-in lines.
--
-- WHAT CHANGES.
--   §1  app.on_sale_item_commission_snapshot_v825 gains one branch, by anchored replacement on
--       the live body (anchor asserted to occur exactly once): item_type = 'custom' → 0.
--   §2  The nestly_v850 re-price window (app.sale_items_discount_reprice_v832) is widened to
--       custom lines — still ONLY the four commission columns, still nothing else — and the 60
--       existing custom lines are re-priced to 0 (10 of them paid; one tenant).
--   §3  The v850 walk now expects 0 on its custom line (db/tests/v850_commission_accuracy_end_to_end.sql).
--
-- NOT changed: membership lines (still the member's product %; not live — AO-1) and every
-- other rule nestly_v850 pinned.

begin;

do $patch$
declare
  v_src text;
  v_hits int;
  c_anchor constant text := E'  if new.item_type = ''gift_card'' then\n';
  c_branch constant text := $b$  -- nestly_v861 (owner ruling 2026-09-09): a typed-in "Other item" pays no commission.
  if new.item_type = 'custom' then
    new.commission_rate_bps := 0;
    new.commission_flat_cents := null;
    new.commission_cents := 0;
    new.commission_resolved_at := now();
    return new;
  end if;
$b$;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'on_sale_item_commission_snapshot_v825';
  if v_src is null then raise exception 'v861: app.on_sale_item_commission_snapshot_v825 is missing'; end if;
  if position('new.item_type = ''custom''' in v_src) > 0 then
    raise notice 'v861: the trigger already zeroes custom lines';
  else
    v_hits := (length(v_src) - length(replace(v_src, c_anchor, ''))) / length(c_anchor);
    if v_hits <> 1 then raise exception 'v861: gift_card anchor occurs % times, expected 1', v_hits; end if;
    execute replace(v_src, c_anchor, c_branch || c_anchor);
  end if;
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'on_sale_item_commission_snapshot_v825';
  if position('new.item_type = ''custom''' in v_src) = 0 then raise exception 'v861: the trigger did not take the custom branch'; end if;

  -- §2 widen the re-price window to custom lines
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'sale_items_immutable_guard';
  if position('old.item_type not in (''studio_discount'', ''custom'')' in v_src) = 0 then
    v_hits := (length(v_src) - length(replace(v_src, 'if old.item_type <> ''studio_discount'' then', ''))) / length('if old.item_type <> ''studio_discount'' then');
    if v_hits <> 1 then raise exception 'v861: reprice-window anchor occurs % times, expected 1', v_hits; end if;
    execute replace(v_src, 'if old.item_type <> ''studio_discount'' then', 'if old.item_type not in (''studio_discount'', ''custom'') then');
  end if;
end
$patch$;

select set_config('app.sale_items_discount_reprice_v832', 'nestly_v861', true);

update public.sale_items
   set commission_rate_bps = 0, commission_flat_cents = null, commission_cents = 0, commission_resolved_at = now()
 where item_type = 'custom'
   and (coalesce(commission_rate_bps, 0) <> 0 or commission_flat_cents is not null or coalesce(commission_cents, 0) <> 0);

select set_config('app.sale_items_discount_reprice_v832', '', true);

do $check$
begin
  if exists (select 1 from public.sale_items where item_type = 'custom' and coalesce(commission_cents, 0) <> 0) then
    raise exception 'v861: a custom line still pays commission';
  end if;
end
$check$;

commit;
