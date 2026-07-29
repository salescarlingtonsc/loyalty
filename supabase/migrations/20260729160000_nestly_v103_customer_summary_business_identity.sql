-- NESTLY v103 - CUSTOMER SUMMARY BUSINESS IDENTITY CONTRACT
--
-- The customer programme detail UI resolves a verified relationship by slug
-- through customer_get_business_summary(text), then passes the returned business
-- UUID to business-scoped customer RPCs. The v32 summary omitted that UUID from
-- both its normal and defensive-fallback business projections. JSON serialization
-- consequently omitted the required p_business RPC argument even though the
-- customer's verified wallet data had loaded successfully.
--
-- This migration changes only the explicit JSON allowlist. The UUID is the same
-- v_context.business_id already derived from auth.uid() -> active identity ->
-- verified customer_links; callers cannot choose or widen that scope.

begin;

do $v103_projection$
declare
  v_def text;
  v_old text := '''business'', jsonb_build_object('
    || E'\n      ''slug'', v_context.business_slug';
  v_new text := '''business'', jsonb_build_object('
    || E'\n      ''id'', v_context.business_id,'
    || E'\n      ''slug'', v_context.business_slug';
  v_old_n integer;
  v_new_n integer;
begin
  select pg_get_functiondef(
    'public.customer_get_business_summary(text)'::regprocedure
  ) into strict v_def;

  v_old_n := (length(v_def) - length(replace(v_def, v_old, '')))
    / length(v_old);
  v_new_n := (length(v_def) - length(replace(v_def, v_new, '')))
    / length(v_new);

  if v_old_n <> 2 or v_new_n <> 0 then
    raise exception
      'unexpected customer_get_business_summary predecessor projection (old=%, new=%)',
      v_old_n, v_new_n;
  end if;
  if position('security definer' in lower(v_def)) = 0
     or position('set search_path' in lower(v_def)) = 0
     or position('app.v32_customer_wallet_context(p_business_slug)' in v_def) = 0 then
    raise exception
      'customer_get_business_summary predecessor lost its verified context or definer pinning';
  end if;

  execute replace(v_def, v_old, v_new);
end
$v103_projection$;

-- CREATE OR REPLACE preserves ACLs, but the browser boundary is deliberately
-- restated: authenticated callers only; tenant identity remains self-derived.
revoke all on function public.customer_get_business_summary(text)
  from public, anon, authenticated;
grant execute on function public.customer_get_business_summary(text)
  to authenticated;

do $v103_postcondition$
declare
  v_def text;
  v_expected text := '''business'', jsonb_build_object('
    || E'\n      ''id'', v_context.business_id,'
    || E'\n      ''slug'', v_context.business_slug';
  v_expected_n integer;
begin
  select pg_get_functiondef(
    'public.customer_get_business_summary(text)'::regprocedure
  ) into strict v_def;
  v_expected_n := (length(v_def) - length(replace(v_def, v_expected, '')))
    / length(v_expected);

  if v_expected_n <> 2 then
    raise exception
      'customer_get_business_summary did not receive both verified business ID projections';
  end if;
  if has_function_privilege(
       'anon',
       'public.customer_get_business_summary(text)'::regprocedure,
       'EXECUTE'
     )
     or not has_function_privilege(
       'authenticated',
       'public.customer_get_business_summary(text)'::regprocedure,
       'EXECUTE'
     )
     or exists (
       select 1
       from pg_proc proc
       cross join lateral aclexplode(
         coalesce(proc.proacl, acldefault('f', proc.proowner))
       ) acl
       where proc.oid =
         'public.customer_get_business_summary(text)'::regprocedure
         and acl.grantee = 0
         and acl.privilege_type = 'EXECUTE'
     ) then
    raise exception
      'customer_get_business_summary browser ACL is not authenticated-only';
  end if;
end
$v103_postcondition$;

commit;
