-- NESTLY v649 — Phase C, C3: the canonical node is snapshotted on the sale line at write time.
-- D7's core rule: classification at transaction time is a historical fact; later mapping
-- edits reach the future only. Mechanism: ONE BEFORE INSERT trigger on sale_items — the
-- v631/A3 capture pattern, zero writer patches, so every line from every writer (cart
-- kernel, the v634 synthesized paths, and anything future) is stamped identically.
--   service lines : via service_canonical_map (unmapped -> null, visible in coverage,
--                   never guessed)
--   retail lines  : via product_canonical_map, else the pack default (DC-1 accepted:
--                   fnb -> 'packaged_retail', everything else -> 'retail_product')
--   all other kinds (package/membership/gift_card/package_session/reward_fulfilment/
--   custom/studio_discount) stamp NULL in v1: no approved node names their question yet,
--   and the tree rule is no node without a question. Coverage reporting separates the
--   stampable population (service+retail) from the rest.
-- Stamped values sit under sale_items' existing immutability — facts the moment they exist.
-- A resolution failure stamps null rather than blocking a sale (the v633 posture).
-- NO backfill, by ruling: pre-v649 lines are PROJECTED through the current mapping at read
-- time and labelled as such; only post-v649 stamps are snapshots.
begin;

alter table public.sale_items
  add column canonical_node_key text,
  add column taxonomy_version_no integer;

create or replace function app.sale_items_category_stamp_v649()
returns trigger language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_node text;
begin
  begin
    if new.item_type = 'service' and new.ref_id is not null then
      select m.node_key into v_node
        from public.service_canonical_map m
       where m.business_id = new.business_id and m.service_id = new.ref_id;
    elsif new.item_type = 'retail' then
      select m.node_key into v_node
        from public.product_canonical_map m
       where m.business_id = new.business_id
         and m.product_id = coalesce(new.product_id, new.ref_id);
      if v_node is null then
        v_node := case app.business_pack_v648(new.business_id)
                    when 'fnb' then 'packaged_retail' else 'retail_product' end;
      end if;
    end if;
    if v_node is not null then
      new.canonical_node_key := v_node;
      new.taxonomy_version_no := 1;
    end if;
  exception when others then
    raise warning 'v649 category stamp failed for sale_item on sale %: %', new.sale_id, sqlerrm;
  end;
  return new;
end;
$$;
create trigger trg_sale_items_category_stamp_v649
  before insert on public.sale_items
  for each row execute function app.sale_items_category_stamp_v649();

insert into public.analytics_observation_watermarks (metric_key, observed_since, reason)
values ('category_snapshots', now(),
        'sale lines carry canonical-category snapshots from v649; earlier lines are projected through the current mapping and labelled');

commit;
