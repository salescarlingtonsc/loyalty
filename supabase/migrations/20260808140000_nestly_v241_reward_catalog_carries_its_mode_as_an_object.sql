-- V241 — the reward catalog's points_mode was unreadable where it mattered.
--
-- V230 appended points_mode to the catalog payload with `v_result || jsonb_build_object(...)`.
-- v_result is a jsonb ARRAY, and array || object APPENDS the object as a last element — so the
-- payload became [reward, ..., {"points_mode": ...}]. The wallet reads data.points_mode, which
-- an array does not have: the mode never arrived, and the stray element could leak into the
-- reward list as a phantom entry. Found while verifying the owner's $10-sale scenario for the
-- combined points+tiers mode.
--
-- The payload becomes a proper object: {rewards: [...], points_mode: ...}. The client accepts
-- both shapes during the deploy window (walletCatalogV241 / walletPointsModeV241).
begin;
do $$
declare
  v_def text;
  v_old text;
  v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='customer_get_reward_catalog';

  v_old := '  -- v230: the one owner choice for what points are FOR, so the wallet tells one story.
  v_result := v_result || jsonb_build_object(''points_mode'',
    (select points_mode from public.businesses where id = v_context.business_id));

  return v_result;';
  v_new := '  -- v230/v241: the one owner choice for what points are FOR, so the wallet tells one
  -- story. As an OBJECT: appending to the rewards array made the mode unreadable (v241).
  return jsonb_build_object(
    ''rewards'', coalesce(v_result, ''[]''::jsonb),
    ''points_mode'', (select points_mode from public.businesses where id = v_context.business_id));';

  if position(v_old in v_def) = 0 then
    -- Already rewritten (idempotent re-run): assert the object shape is present instead.
    if position('jsonb_build_object(
    ''rewards''' in v_def) = 0 then
      raise exception 'v241: neither the v230 tail nor the v241 shape found — refusing to guess';
    end if;
    return;
  end if;
  execute replace(v_def, v_old, v_new);
end $$;
commit;
