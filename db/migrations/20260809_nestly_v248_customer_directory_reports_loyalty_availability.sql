-- V248 — the customer directory never reported whether Loyalty was actually visible.
--
-- V145 built `public.staff_list_customers_v129` to return `loyalty_available`, computed from
-- `app.metric_module_scope_available_v145(p_business, null, 'loyalty')`, so the directory could
-- tell "we could not confirm complete Loyalty access" apart from "genuinely zero". V155 rewrote
-- the directory as `public.staff_list_customers_v155` for multi-branch scopes and DROPPED that key
-- from the payload; the client kept reading `data.loyalty_available === true`. `undefined === true`
-- is false, so EVERY business, for EVERY caller, saw the "Loyalty access could not be confirmed"
-- banner and "Unavailable" in the Points and Credit columns — while the payload was carrying real
-- `points` and `balance_cents` numbers all along.
--
-- This restores the V145 key with the V145 expression, unchanged in meaning: the null-branch form
-- of `metric_module_scope_available_v145` is true only when the caller can read the Loyalty module
-- across the WHOLE business (every visible branch), which is exactly the "complete Loyalty access"
-- the banner copy names. It is deliberately NOT hardcoded true: the function's own authority gate
-- is `app.can_module_read(p_business,'clients')`, which says nothing about Loyalty, so a
-- clients-only employee must still be told the balances are unconfirmed rather than shown a zero.
begin;
do $$
declare
  v_def text;
  v_old text;
  v_new text;
  v_after text;
begin
  select pg_get_functiondef(p.oid) into v_def
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='staff_list_customers_v155';

  if v_def is null then
    raise exception 'v248: public.staff_list_customers_v155 not found — refusing to guess';
  end if;

  -- Idempotent re-run: the key is already in the payload, nothing to splice.
  if position('''loyalty_available''' in v_def) > 0 then
    return;
  end if;

  -- Needle and replacement are COMMENT-FREE: the Supabase MCP apply strips full-line comments,
  -- so a comment-anchored needle would match a psql-replayed rehearsal and not production.
  -- Verified single-occurrence against production before writing this migration.
  v_old := '    ''inactive_bucket'',p_inactive_bucket,
    ''total'',(select count(*) from customer_rows),';
  v_new := '    ''inactive_bucket'',p_inactive_bucket,
    ''loyalty_available'',app.metric_module_scope_available_v145(p_business,null,''loyalty''),
    ''total'',(select count(*) from customer_rows),';

  if position(v_old in v_def) = 0 then
    raise exception 'v248: the v155 payload anchor was not found — refusing to guess';
  end if;

  execute replace(v_def, v_old, v_new);

  select pg_get_functiondef(p.oid) into v_after
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='staff_list_customers_v155';
  if position('''loyalty_available''' in v_after) = 0 then
    raise exception 'v248: the rewrite did not land — loyalty_available is still absent';
  end if;
end $$;

comment on function public.staff_list_customers_v155(uuid,text,text,text,uuid[],uuid,integer,integer) is
  'Lists a bounded, branch-scoped customer page with valid last-visit facts and loyalty balances; V248 restores the loyalty_available flag (complete business-wide Loyalty read scope) that V155 dropped, so the client can tell unconfirmed access apart from a genuine zero.';
commit;
