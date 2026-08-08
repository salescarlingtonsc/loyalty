-- Rolled-back acceptance for v246 — get_my_personas reads the resolver directly.
--
-- Proves on a real staff fixture:
--   * payload shape holds: staff[] / customer[] / default_route, and every staff
--     entry carries the documented keys including the modules fallback list;
--   * the modules list equals the sorted key set of the v233/v246 resolver map —
--     the same value app.staff_modules computes — so the browser's fail-closed
--     fallback (app.js workspaceStaffPersona.modules) is unchanged;
--   * default_route points at the first workspace by (name, slug);
--   * with the customer feature flags off, customer[] is empty and the wallet
--     route is never chosen;
--   * an anonymous caller is refused with 28000 before any data is read.
begin;

do $v246$
declare
  v_owner uuid; v_biz uuid; v_slug text;
  v_res jsonb; v_entry jsonb;
  v_modules jsonb; v_expected jsonb;
  v_state text;
begin
  select s.user_id, s.business_id into v_owner, v_biz from public.staff s
   where s.role='owner' and s.user_id is not null and s.active limit 1;
  if v_owner is null then raise notice 'no fixture; skipping'; return; end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub',v_owner,'role','authenticated')::text,true);

  v_res:=public.get_my_personas();
  assert v_res ?& array['staff','customer','default_route'],'envelope keys hold';
  assert jsonb_typeof(v_res->'staff')='array' and jsonb_typeof(v_res->'customer')='array',
    'staff and customer are arrays';
  assert jsonb_array_length(v_res->'staff')>0,'the owner fixture has a workspace';

  select e into v_entry from jsonb_array_elements(v_res->'staff') e
   where (e->>'business_id')::uuid=v_biz;
  assert v_entry is not null,'the fixture workspace is listed';
  assert v_entry ?& array['business_id','business_slug','business_name','role','modules',
    'workspace_access','approval_status','subscription_state','workspace_paused',
    'representative_name','representative_hotline'],
    'every documented staff-entry key survives the rewrite';

  -- The one field the rewrite recomputes: modules must equal the resolver's
  -- sorted key set (what app.staff_modules returns), or the browser's
  -- fail-closed fallback silently changes meaning.
  v_modules:=v_entry->'modules';
  select coalesce(jsonb_agg(to_jsonb(key.k) order by key.k),'[]'::jsonb) into v_expected
    from jsonb_object_keys(app.staff_module_perms_at_v115(v_biz,null)) as key(k);
  assert v_modules=v_expected,
    'modules is exactly the sorted resolver key set: '||v_modules::text||' vs '||v_expected::text;

  -- default_route = first workspace by (name, slug).
  v_slug:=v_res->'staff'->0->>'business_slug';
  assert v_res->>'default_route'='#/workspace/'||v_slug||'/dashboard',
    'default_route follows the first workspace by (name, slug)';

  -- Customer arm honours the flags: with customer_wallet off, the AND-of-three
  -- gate fails, customer[] stays empty and the wallet route is unreachable.
  update app.platform_feature_flags set enabled=false where feature_key='customer_wallet';
  v_res:=public.get_my_personas();
  assert jsonb_array_length(v_res->'customer')=0,
    'customer personas are gated on all three customer feature flags';
  assert v_res->>'default_route' like '#/workspace/%',
    'a staff actor keeps the workspace route regardless of customer flags';
  update app.platform_feature_flags set enabled=true where feature_key='customer_wallet';

  -- Fail closed before any read.
  perform set_config('request.jwt.claims','',true);
  perform set_config('request.jwt.claim.sub','',true);
  begin
    perform public.get_my_personas();
    raise exception 'an anonymous caller was allowed personas';
  exception when sqlstate '28000' then null;
  end;

  raise notice 'v246 acceptance passed';
end$v246$;
rollback;
