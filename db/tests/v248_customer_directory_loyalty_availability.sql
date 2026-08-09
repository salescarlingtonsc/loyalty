-- Rollback-only acceptance for v248 — the customer directory reports Loyalty availability.
--
-- Runs against the REAL directory inside one transaction, then rolls back. Proves, as the owner
-- of the Cubbly fixture business:
--   * the payload carries `loyalty_available` at all (V155 dropped the key entirely, which is why
--     the client's `data.loyalty_available === true` was false for every business, always);
--   * for a caller with complete business-wide Loyalty read scope it is TRUE, not merely present;
--   * the customer rows carry a numeric `points` — so "Unavailable" was never a data problem;
--   * the flag agrees with its authority, app.metric_module_scope_available_v145(..., 'loyalty'),
--     rather than being hardcoded;
--   * the pre-existing keys (status/as_of/scope/total/customers) are untouched;
--   * anon still has no EXECUTE.

begin;

do $suite$
declare
  v_owner uuid := 'f73a9423-33fd-424c-9fb9-2d5ba058a2d7';
  v_business uuid := '8492e8d6-8888-4383-ada0-7e1ed69f0caa';
  v_payload jsonb;
  v_authority boolean;
  v_numeric_points int;
  v_key text;
begin
  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';

  v_payload := public.staff_list_customers_v155(v_business);

  ------------------------------------------------------------------- 1 · the key exists
  if not (v_payload ? 'loyalty_available') then
    raise exception 'v248: the directory payload has no loyalty_available key — keys present: %',
      (select string_agg(k, ',' order by k) from jsonb_object_keys(v_payload) k);
  end if;

  ------------------------------------------------------------------- 2 · and it is true here
  if v_payload->>'loyalty_available' <> 'true' then
    raise exception 'v248: the fixture owner has complete Loyalty scope, so loyalty_available must be true, got %',
      v_payload->'loyalty_available';
  end if;

  ------------------------------------------------------------------- 3 · agrees with its authority
  v_authority := app.metric_module_scope_available_v145(v_business, null, 'loyalty');
  if (v_payload->>'loyalty_available')::boolean is distinct from v_authority then
    raise exception 'v248: loyalty_available (%) disagrees with metric_module_scope_available_v145 (%)',
      v_payload->'loyalty_available', v_authority;
  end if;

  ------------------------------------------------------------------- 4 · the numbers were there
  select count(*) into v_numeric_points
  from jsonb_array_elements(coalesce(v_payload->'customers', '[]'::jsonb)) customer
  where jsonb_typeof(customer->'points') = 'number';
  if v_numeric_points < 1 then
    raise exception 'v248: no customer row carries a numeric points value — payload: %',
      left(v_payload::text, 400);
  end if;

  ------------------------------------------------------------------- 5 · nothing else was lost
  foreach v_key in array array['status','as_of','scope','total','customers','inactive_bucket'] loop
    if not (v_payload ? v_key) then
      raise exception 'v248: the splice dropped the pre-existing key %', v_key;
    end if;
  end loop;

  ------------------------------------------------------------------- 6 · anon stays out
  execute 'reset role';
  if has_function_privilege('anon',
    'public.staff_list_customers_v155(uuid,text,text,text,uuid[],uuid,integer,integer)', 'execute') then
    raise exception 'v248: anon must not execute the staff customer directory';
  end if;

  raise notice 'v248: customer directory reports loyalty_available=true with numeric points — PASS';
end
$suite$;

rollback;
