-- Rolled-back acceptance for v209 — one permanent join QR per business.
begin;
do $$
declare v_biz uuid; v_owner uuid; v_a text; v_b text; v_status jsonb;
begin
  select s.business_id, s.user_id into v_biz, v_owner from public.staff s
   where s.role='owner' and s.user_id is not null and s.access_state='approved'
     and exists (select 1 from public.business_customer_join_qr_v89 q
                  where q.business_id=s.business_id and q.status='active')
   limit 1;
  if v_biz is null then raise notice 'no fixture; skipping'; return; end if;
  perform set_config('request.jwt.claims', json_build_object('sub',v_owner,'role','authenticated')::text, true);

  v_status := public.business_get_customer_join_qr_status_v91(v_biz);
  v_a := v_status->>'join_token';
  assert v_a is not null, 'the status read must return the code so the panel can draw it';
  assert (v_status->>'active_count')::int = 1, 'exactly one active QR per business';

  -- the ensure path must agree, and repeating either must never change the code
  v_b := public.business_ensure_customer_join_qr_v91(v_biz)->>'join_token';
  assert v_a = v_b, 'the ensure path must return the SAME code as the status path';
  assert v_a = (public.business_get_customer_join_qr_status_v91(v_biz)->>'join_token'),
    'reading it again must not change it — that is the whole point of a static QR';
  raise notice 'v209: one permanent code, stable across reads';
end$$;

-- The index is what keeps "only 1" true for every future writer.
do $$
begin
  assert exists (select 1 from pg_indexes
                  where indexname='business_customer_join_qr_one_active_v209'),
    'the single-active index must exist';
  assert not exists (
    select business_id from public.business_customer_join_qr_v89
     where status='active' group by business_id having count(*)>1),
    'no business may hold two active QRs';
end$$;
rollback;
