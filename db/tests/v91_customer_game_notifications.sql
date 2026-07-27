begin;

do $$
begin
  if to_regprocedure('public.business_get_customer_join_qr_status_v91(uuid)') is null then
    raise exception 'v91 customer join QR status reader is missing';
  end if;

  if to_regprocedure('app.c46_customer_safe_inbox_candidates(jsonb)') is null then
    raise exception 'v91 customer notification candidate function is missing';
  end if;

  if to_regprocedure('public.business_ensure_customer_join_qr_v91(uuid,timestamptz)') is null then
    raise exception 'v91 atomic customer join QR ensure function is missing';
  end if;

  if has_function_privilege('anon',
      'public.business_ensure_customer_join_qr_v91(uuid,timestamptz)',
      'execute') then
    raise exception 'anonymous QR ensure execution must remain revoked';
  end if;

  if not has_function_privilege('authenticated',
      'public.business_ensure_customer_join_qr_v91(uuid,timestamptz)',
      'execute') then
    raise exception 'authenticated owners require QR ensure execution';
  end if;
end
$$;

rollback;
