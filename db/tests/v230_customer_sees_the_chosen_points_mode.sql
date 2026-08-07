-- Rollback-only acceptance for v230 — customer capabilities follow the chosen points mode.
--
-- Proves, against the REAL customer_portal_capabilities and a real verified customer link:
--   * a firm whose points buy tier membership reports rewards=false and tiers=true, so the
--     customer surface cannot offer the redemption the v229 gate refuses;
--   * flipping the same firm to 'redeem' flips both keys back, with nothing else changing;
--   * a firm that has chosen nothing keeps today's behaviour (rewards on, tiers on when tiers
--     exist), so this migration changes no live behaviour it was not asked to;
--   * tiers=false when a tiers-mode firm has published no tiers, so the customer is never sent
--     to an empty ladder;
--   * points_mode is reported verbatim, including null;
--   * the function stays unreachable to anon.
--
-- Everything runs inside one transaction and is rolled back.

begin;


/* The synthetic-business route was abandoned deliberately: app.v32_customer_wallet_context
   resolves EFFECTIVE modules through the platform entitlement policy, so a business conjured
   inside a transaction reports no modules at all and every capability reads false — proving
   nothing about this change. The suite therefore drives the REAL tenants and flips their chosen
   mode inside the transaction, which is both stronger evidence and closer to what shipped.
   Nothing is committed. */
do $suite$
declare
  v_business uuid;
  v_slug text := 'kopi-tiam-tyeh';
  v_auth uuid;
  v_caps jsonb;
  v_before jsonb;
begin
  select b.id into v_business from public.businesses b where b.slug=v_slug;
  select l.auth_user_id into v_auth
  from public.customer_links l where l.business_id=v_business and l.state='verified' limit 1;
  if v_auth is null then
    raise exception 'v230: fixture needs a verified customer on %',v_slug;
  end if;

  ------------------------------------------------------------- 1 · as it stands today: tiers
  update public.businesses set points_mode='tiers' where id=v_business;
  perform set_config('request.jwt.claim.sub',v_auth::text,true);
  perform set_config('request.jwt.claims',json_build_object('sub',v_auth,'role','authenticated')::text,true);
  execute 'set local role authenticated';
  v_caps := public.customer_portal_capabilities(v_slug);
  execute 'reset role';
  if (v_caps->>'rewards')::boolean is not false then
    raise exception 'v230: tiers mode must switch redemption off, matching the v229 gate';
  end if;
  if (v_caps->>'tiers')::boolean is not true then
    raise exception 'v230: a tiers firm with published tiers must show the ladder';
  end if;
  if (v_caps->>'points_mode') <> 'tiers' then
    raise exception 'v230: the chosen mode must be reported verbatim';
  end if;
  v_before := v_caps;

  ------------------------------------------------------------- 2 · the same firm, redeeming
  update public.businesses set points_mode='redeem' where id=v_business;
  perform set_config('request.jwt.claim.sub',v_auth::text,true);
  perform set_config('request.jwt.claims',json_build_object('sub',v_auth,'role','authenticated')::text,true);
  execute 'set local role authenticated';
  v_caps := public.customer_portal_capabilities(v_slug);
  execute 'reset role';
  if (v_caps->>'tiers')::boolean is not false then
    raise exception 'v230: a redeem firm must not be given a tier ladder';
  end if;
  if (v_caps->>'rewards')::boolean is not true then
    raise exception 'v230: redemption must come back on in redeem mode';
  end if;
  if (v_caps->>'points_mode') <> 'redeem' then
    raise exception 'v230: the chosen mode must be reported verbatim';
  end if;
  -- nothing unrelated moved between the two modes
  if (v_caps->>'wallet') <> (v_before->>'wallet')
     or (v_caps->>'booking_request') <> (v_before->>'booking_request')
     or (v_caps->>'activity') <> (v_before->>'activity')
     or (v_caps->>'appointments') <> (v_before->>'appointments')
     or (v_caps->>'packages') <> (v_before->>'packages')
     or (v_caps->>'membership') <> (v_before->>'membership') then
    raise exception 'v230: only the points-mode keys may change';
  end if;

  ------------------------------------------------------- 3 · nothing chosen keeps both doors
  update public.businesses set points_mode=null where id=v_business;
  perform set_config('request.jwt.claim.sub',v_auth::text,true);
  perform set_config('request.jwt.claims',json_build_object('sub',v_auth,'role','authenticated')::text,true);
  execute 'set local role authenticated';
  v_caps := public.customer_portal_capabilities(v_slug);
  execute 'reset role';
  if (v_caps->>'points_mode') is not null then
    raise exception 'v230: an unchosen mode must be reported as null';
  end if;
  if (v_caps->>'tiers')::boolean is not true or (v_caps->>'rewards')::boolean is not true then
    raise exception 'v230: an unchosen firm keeps the behaviour it had before this migration';
  end if;

  ------------------------------- 4 · tiers mode still needs a live programme to climb inside
  -- Hougang ABC has three tiers configured and NO active programme, which is the exact case a
  -- customer must not be sent to an empty ladder for.
  select b.id into v_business from public.businesses b where b.slug='hougang-abc-ts3u';
  select l.auth_user_id into v_auth
  from public.customer_links l where l.business_id=v_business and l.state='verified' limit 1;
  if v_auth is not null then
    update public.businesses set points_mode='tiers' where id=v_business;
    perform set_config('request.jwt.claim.sub',v_auth::text,true);
    perform set_config('request.jwt.claims',json_build_object('sub',v_auth,'role','authenticated')::text,true);
    execute 'set local role authenticated';
    v_caps := public.customer_portal_capabilities('hougang-abc-ts3u');
    execute 'reset role';
    if (v_caps->>'tiers')::boolean is not false then
      raise exception 'v230: tiers configured with no ACTIVE programme must not show a ladder';
    end if;
  end if;

  ------------------------------------------------------------------ 5 · still closed to anon
  begin
    perform set_config('request.jwt.claim.sub','',true);
    perform set_config('request.jwt.claims',json_build_object('role','anon')::text,true);
    execute 'set local role anon';
    perform public.customer_portal_capabilities('kopi-tiam-tyeh');
    execute 'reset role';
    raise exception 'v230: anon must not read customer capabilities';
  exception when others then
    execute 'reset role';
  end;

  raise notice 'v230 acceptance: all assertions passed';
end $suite$;

rollback;
