-- V257 — a cart containing a BUNDLE could never be finalised. The sale was unrecordable.
--
-- Owner report: "Price updated — please confirm the new total" appears on confirming a sale, and
-- clicking Confirm does nothing. Proven against production (read-only) on 2026-08-09: five
-- checkout_evaluations for the same 190.00 cart, minted seconds apart on 2026-08-08 18:26-18:28,
-- every one of them consumed_at IS NULL. The till was looping, not idling.
--
-- Mechanism. `app.ps1c_plan_checkout` expands a bundle into one line per member service, priced
-- pro-rata from the BUNDLE price (`app.ps1c_bundle_lines_v204`), and stamps each expanded line
-- `catalog_kind='service'` — the only kind `sale_items`, commissions and staff performance know
-- how to read. `public.record_cart_sale` §8.4 then re-prices every non-custom server line through
-- `app.ps1b_catalog_price`, which returns the service's OWN list price, and re-hashes. For the
-- production bundle "Rainbow special" (price 8000, two members at 3000 each) the token hash is
-- 35b2d2b3… and the reprojected hash is 05289c7d… — so §8.4 raises
--   stale_evaluation: catalog prices changed since evaluation; re-evaluate
-- on EVERY attempt. Nothing had changed: the finaliser was comparing the bundle's allocation
-- against the parts' list prices. Any bundle whose price differs from the sum of its members'
-- list prices — which is the entire point of a bundle — was therefore unsellable at the till.
--
-- The fix is to re-project a bundle line the way it was priced: from the bundle. Each expanded
-- line now carries its origin (`bundle_id`, `bundle_qty`) in the immutable token, and §8.4 replays
-- `app.ps1c_bundle_lines_v204` for that bundle instead of pricing the member service on its own.
-- The drift guard is NOT weakened — it is pointed at the right authority: if the bundle's price,
-- membership, order or availability changed since the evaluation, the replay produces different
-- shares (or a non-ok status) and the finalise still fails stale, exactly as intended.
--
-- `app.ps1c_cart_hash` reads only (ord, catalog_kind, catalog_id, qty, unit_price_cents,
-- line_total_cents), so adding the two provenance keys leaves every existing hash unchanged.
-- Tokens minted before this migration carry no bundle_id and keep failing stale until they expire
-- (10 minutes); nothing is charged by a stale finalise, so there is no data to repair.
--
-- Splices, not rewrites: both functions are re-derived from their live definitions so an
-- unrelated later change to either is preserved. Every needle is COMMENT-FREE, because the
-- Supabase MCP apply strips full-line comments and a comment-anchored needle would match a
-- psql-replayed rehearsal but not production.
-- Applied to production 2026-08-09. Acceptance run against production inside an aborted
-- transaction, on a fixture whose bundle price (8000) differs from its members' list prices
-- (3000+3000) — the exact shape that could not be finalised:
--   [1] evaluate ok total=19000; [2] 2 lines stamped bundle_id/qty at 8000;
--   [3] FINALISED ok (the regression); [4] money=19000 bundle, not 21000 parts;
--   [5] genuine drift still refused stale.
begin;

do $v257_plan$
declare
  v_def text;
  v_old text;
  v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='app' and p.proname='ps1c_plan_checkout';
  if v_def is null then
    raise exception 'v257: app.ps1c_plan_checkout not found - refusing to guess';
  end if;
  if position('bundle_qty' in v_def) > 0 then
    return;
  end if;

  v_old := '  v_bundle jsonb; v_bline jsonb;';
  v_new := '  v_bundle jsonb; v_bline jsonb; v_bsrc uuid[]; v_bsrcqty int[];';
  if position(v_old in v_def) = 0 then
    raise exception 'v257: ps1c_plan_checkout declaration needle not found';
  end if;
  v_def := replace(v_def, v_old, v_new);

  v_old := '      v_lreason := array_append(v_lreason, v_creason);';
  v_new := '      v_lreason := array_append(v_lreason, v_creason);'||chr(10)
        || '      v_bsrc := array_append(v_bsrc, null::uuid);'||chr(10)
        || '      v_bsrcqty := array_append(v_bsrcqty, null::int);';
  if position(v_old in v_def) = 0 then
    raise exception 'v257: ps1c_plan_checkout custom-line needle not found';
  end if;
  v_def := replace(v_def, v_old, v_new);

  v_old := '        v_lreason := array_append(v_lreason, null::text);'||chr(10)
        || '        v_subtotal := v_subtotal + (v_bline->>''line_cents'')::int;';
  v_new := '        v_lreason := array_append(v_lreason, null::text);'||chr(10)
        || '        v_bsrc := array_append(v_bsrc, v_cid);'||chr(10)
        || '        v_bsrcqty := array_append(v_bsrcqty, (v_line->>''qty'')::int);'||chr(10)
        || '        v_subtotal := v_subtotal + (v_bline->>''line_cents'')::int;';
  if position(v_old in v_def) = 0 then
    raise exception 'v257: ps1c_plan_checkout bundle-expansion needle not found';
  end if;
  v_def := replace(v_def, v_old, v_new);

  v_old := '    v_lreason := array_append(v_lreason, null::text);'||chr(10)
        || '    v_subtotal := v_subtotal + ((v_price->>''price_cents'')::int * (v_line->>''qty'')::int);';
  v_new := '    v_lreason := array_append(v_lreason, null::text);'||chr(10)
        || '    v_bsrc := array_append(v_bsrc, null::uuid);'||chr(10)
        || '    v_bsrcqty := array_append(v_bsrcqty, null::int);'||chr(10)
        || '    v_subtotal := v_subtotal + ((v_price->>''price_cents'')::int * (v_line->>''qty'')::int);';
  if position(v_old in v_def) = 0 then
    raise exception 'v257: ps1c_plan_checkout catalog-line needle not found';
  end if;
  v_def := replace(v_def, v_old, v_new);

  v_old := '    if v_kind[j] = ''custom'' then'||chr(10)
        || '      v_entry := v_entry || jsonb_build_object(''entered_by'', v_entered_by[j], ''reason'', v_lreason[j]);'||chr(10)
        || '    end if;';
  v_new := '    if v_kind[j] = ''custom'' then'||chr(10)
        || '      v_entry := v_entry || jsonb_build_object(''entered_by'', v_entered_by[j], ''reason'', v_lreason[j]);'||chr(10)
        || '    end if;'||chr(10)
        || '    if v_bsrc[j] is not null then'||chr(10)
        || '      v_entry := v_entry || jsonb_build_object(''bundle_id'', v_bsrc[j], ''bundle_qty'', v_bsrcqty[j]);'||chr(10)
        || '    end if;';
  if position(v_old in v_def) = 0 then
    raise exception 'v257: ps1c_plan_checkout server-line builder needle not found';
  end if;
  v_def := replace(v_def, v_old, v_new);

  execute v_def;
end
$v257_plan$;

do $v257_finalise$
declare
  v_def text;
  v_old text;
  v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='record_cart_sale'
    and p.oid::regprocedure::text
        = 'record_cart_sale(uuid,uuid,uuid,uuid,text,text,jsonb,uuid,boolean)';
  if v_def is null then
    raise exception 'v257: the 9-argument public.record_cart_sale not found - refusing to guess';
  end if;
  if position('v257_bundle' in v_def) > 0 then
    return;
  end if;

  v_old := '  v_reproj jsonb := ''[]''::jsonb;';
  v_new := '  v_reproj jsonb := ''[]''::jsonb;'||chr(10)
        || '  v257_bundle jsonb; v257_bline jsonb; v257_bid uuid; v257_bqty int;'||chr(10)
        || '  v257_cur_bid uuid; v257_cur_bqty int; v257_pos int := 0;';
  if position(v_old in v_def) = 0 then
    raise exception 'v257: record_cart_sale declaration needle not found';
  end if;
  v_def := replace(v_def, v_old, v_new);

  -- Re-project a bundle-expanded line from the BUNDLE, which is where its price came from.
  -- Lines of one bundle are contiguous and in the expansion's own order, so they are consumed
  -- with a cursor: a changed member set, order or price falls out as a mismatch and stays stale.
  v_old := '    if v_kind = ''custom'' then'||chr(10)
        || '      v_unit := (v_line->>''unit_price_cents'')::int;'||chr(10)
        || '    else';
  v_new := '    if v_kind = ''custom'' then'||chr(10)
        || '      v_unit := (v_line->>''unit_price_cents'')::int;'||chr(10)
        || '    elsif nullif(v_line->>''bundle_id'', '''') is not null then'||chr(10)
        || '      v257_bid := (v_line->>''bundle_id'')::uuid;'||chr(10)
        || '      v257_bqty := coalesce(nullif(v_line->>''bundle_qty'', '''')::int, 1);'||chr(10)
        || '      if v257_cur_bid is distinct from v257_bid or v257_cur_bqty is distinct from v257_bqty then'||chr(10)
        || '        v257_bundle := app.ps1c_bundle_lines_v204(p_business, v257_bid, v257_bqty);'||chr(10)
        || '        if v257_bundle->>''status'' <> ''ok'' then'||chr(10)
        || '          raise exception ''stale_evaluation: bundle on line % can no longer be priced (%); re-evaluate'', v_ord, v257_bundle->>''status'''||chr(10)
        || '            using errcode = ''P0001'';'||chr(10)
        || '        end if;'||chr(10)
        || '        v257_cur_bid := v257_bid; v257_cur_bqty := v257_bqty; v257_pos := 0;'||chr(10)
        || '      end if;'||chr(10)
        || '      v257_pos := v257_pos + 1;'||chr(10)
        || '      v257_bline := v257_bundle->''lines''->(v257_pos - 1);'||chr(10)
        || '      if v257_bline is null or nullif(v257_bline->>''service_id'', '''')::uuid is distinct from v_cid then'||chr(10)
        || '        raise exception ''stale_evaluation: the bundle on line % changed since evaluation; re-evaluate'', v_ord'||chr(10)
        || '          using errcode = ''P0001'';'||chr(10)
        || '      end if;'||chr(10)
        || '      v_unit := (v257_bline->>''line_cents'')::int;'||chr(10)
        || '    else';
  if position(v_old in v_def) = 0 then
    raise exception 'v257: record_cart_sale reprojection needle not found';
  end if;
  v_def := replace(v_def, v_old, v_new);

  execute v_def;
end
$v257_finalise$;

commit;
