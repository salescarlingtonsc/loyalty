-- Rolled-back acceptance for v206 — fast manual corrections.
begin;
do $$
declare v jsonb; v_biz uuid; v_br uuid; v_svc uuid; v_owner uuid;
begin
  select s.business_id, s.user_id into v_biz, v_owner from public.staff s
   where s.role='owner' and s.user_id is not null limit 1;
  select id into v_br from public.branches where business_id=v_biz and is_default limit 1;
  select id into v_svc from public.services where business_id=v_biz and active and price_cents>1000 limit 1;
  if v_biz is null or v_br is null or v_svc is null then raise notice 'no fixture; skipping'; return; end if;
  perform set_config('request.jwt.claims', json_build_object('sub',v_owner,'role','authenticated')::text, true);

  -- a note is optional now
  v := public.evaluate_checkout(v_biz,v_br,null,
    '[{"catalog_kind":"custom","description":"Ad hoc item","amount_cents":500}]'::jsonb, gen_random_uuid());
  assert (v->>'total_cents')::int = 500, 'a manual line with no note must be accepted';

  -- a negative correction reduces the sale, and therefore the points earned
  v := public.evaluate_checkout(v_biz,v_br,null,
    ('[{"catalog_kind":"service","catalog_id":"'||v_svc||'","qty":1},
       {"catalog_kind":"custom","description":"Overcharged","amount_cents":-500}]')::jsonb, gen_random_uuid());
  assert (v->>'total_cents')::int
         = (select price_cents from public.services where id=v_svc) - 500,
    'a negative line must reduce the total by exactly its amount';

  -- but it can never zero out or invert a sale
  begin
    v := public.evaluate_checkout(v_biz,v_br,null,
      ('[{"catalog_kind":"service","catalog_id":"'||v_svc||'","qty":1},
         {"catalog_kind":"custom","description":"Too big","amount_cents":-99999999}]')::jsonb, gen_random_uuid());
    raise exception 'a negative line was allowed to zero out a sale';
  exception when sqlstate '22023' then null;
  end;

  -- zero says nothing and is refused
  begin
    v := public.evaluate_checkout(v_biz,v_br,null,
      '[{"catalog_kind":"custom","description":"Nothing","amount_cents":0}]'::jsonb, gen_random_uuid());
    raise exception 'a zero-value manual line was accepted';
  exception when sqlstate '22023' then null;
  end;

  raise notice 'v206 acceptance passed';
end$$;
rollback;
