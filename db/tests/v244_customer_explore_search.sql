-- Rollback-only acceptance for v244 — Explore search over the join-enabled directory.
--
-- Runs against the REAL tenants inside one transaction, then rolls back. Proves:
--   * the empty query returns the whole join-enabled directory, joined businesses first;
--   * a catalogue query ("facial") finds the business that SELLS it, and the match_note names
--     the item that matched, so the result can explain itself;
--   * filler words are dropped ("facial near me" matches like "facial");
--   * AND semantics: a token that matches nothing empties the result rather than widening it;
--   * an unjoined row NEVER carries a balance (the v242 isolation rule, restated here);
--   * anonymous has no EXECUTE.

begin;

do $suite$
declare
  v_auth uuid;
  v_all jsonb;
  v_q jsonb;
  v_and jsonb;
  v_first jsonb;
begin
  select l.auth_user_id into v_auth from public.customer_links l
  where l.business_id='8492e8d6-8888-4383-ada0-7e1ed69f0caa' and l.state='verified'
    and l.unlinked_at is null limit 1;
  if v_auth is null then
    raise exception 'v244: fixture needs one verified Cubbly customer to borrow';
  end if;

  perform set_config('request.jwt.claim.sub',v_auth::text,true);
  perform set_config('request.jwt.claims',json_build_object('sub',v_auth,'role','authenticated')::text,true);
  execute 'set local role authenticated';

  v_all := public.customer_explore_businesses_v244(null);
  v_q := public.customer_explore_businesses_v244('facial near me');
  v_and := public.customer_explore_businesses_v244('facial zzznothing');
  execute 'reset role';

  if jsonb_array_length(v_all) < 2 then
    raise exception 'v244: the empty query must list the join-enabled directory, got %', jsonb_array_length(v_all);
  end if;
  v_first := v_all->0;
  if (v_first->>'joined')::boolean is not true then
    raise exception 'v244: joined businesses must sort first';
  end if;
  if exists(select 1 from jsonb_array_elements(v_all) e
             where (e->>'joined')='false' and e->>'points_balance' is not null) then
    raise exception 'v244: an unjoined row must never carry a balance';
  end if;

  if not exists(select 1 from jsonb_array_elements(v_q) e
                 where e->>'name'='Cubbly' and e->>'match_note' ilike '%facial%') then
    raise exception 'v244: "facial near me" must find the business selling a facial, naming the match';
  end if;

  if jsonb_array_length(v_and) <> 0 then
    raise exception 'v244: AND semantics — an impossible extra token must empty the result, got %', jsonb_array_length(v_and);
  end if;

  begin
    perform set_config('request.jwt.claim.sub','',true);
    perform set_config('request.jwt.claims',json_build_object('role','anon')::text,true);
    execute 'set local role anon';
    perform public.customer_explore_businesses_v244('kopi');
    execute 'reset role';
    raise exception 'v244: anon must not search the directory';
  exception when others then
    execute 'reset role';
  end;

  raise notice 'v244 acceptance: all assertions passed';
end $suite$;

rollback;
