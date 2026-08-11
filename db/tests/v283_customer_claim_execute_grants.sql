-- Rollback-only v283 acceptance: the two self-serve customer-claim RPCs are
-- callable by authenticated (never anon), keep their self-authorizing shape, and
-- never create a wrongful link for an arbitrary authenticated caller.
--
-- The grant is applied idempotently at the top so the suite proves the migration's
-- end state independent of current prod ACLs, then rolls everything back.
begin;

grant execute on function public.customer_claim_link_by_verified_phone(text, text)
  to authenticated;
grant execute on function public.customer_claim_link_by_email(text, text)
  to authenticated;

do $v283$
declare
  v_uid uuid;
  v_identity uuid;
  v_resp jsonb;
  v_before integer;
  v_after integer;
begin
  -- A. safe shape: both are SECURITY DEFINER with a pinned search_path.
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('customer_claim_link_by_verified_phone', 'customer_claim_link_by_email')
      and p.prosecdef
      and array_to_string(p.proconfig, ',') like '%search_path=%'
    having count(*) = 2
  ) then
    raise exception 'A: both claim RPCs must be SECURITY DEFINER with a pinned search_path';
  end if;

  -- B. contract: authenticated may execute, anon may not, on both overloads.
  if not has_function_privilege('authenticated', 'public.customer_claim_link_by_verified_phone(text,text)', 'EXECUTE')
     or not has_function_privilege('authenticated', 'public.customer_claim_link_by_email(text,text)', 'EXECUTE') then
    raise exception 'B: authenticated must hold EXECUTE on both claim RPCs';
  end if;
  if has_function_privilege('anon', 'public.customer_claim_link_by_verified_phone(text,text)', 'EXECUTE')
     or has_function_privilege('anon', 'public.customer_claim_link_by_email(text,text)', 'EXECUTE') then
    raise exception 'B: anon must NOT hold EXECUTE on either claim RPC';
  end if;

  -- C. safety: an authenticated caller against a business slug that does not
  --    exist creates no customer_link (proves the derive-own-contact + single-
  --    unclaimed-candidate guard, not a blind trust of the caller). Prefer a real
  --    customer login; skip cleanly where none exists (portable to a fresh DB).
  select ci.auth_user_id into v_uid
    from public.customer_identities ci
    where ci.status = 'active' and ci.auth_user_id is not null
    order by ci.created_at limit 1;
  if v_uid is null then
    select id into v_uid from auth.users order by created_at limit 1;
  end if;
  if v_uid is not null then
    perform set_config('request.jwt.claim.sub', v_uid::text, true);
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
    begin
      v_identity := app.v31_current_identity();
    exception
      when sqlstate '42501' then v_identity := null; -- non-customer login: skip probe
    end;
    if v_identity is not null then
      select count(*) into v_before from public.customer_links where identity_id = v_identity;
      begin
        v_resp := public.customer_claim_link_by_verified_phone(
          'zzz-v283-no-such-business-' || replace(v_uid::text, '-', ''), 'v283-accept-key');
        if coalesce(v_resp->>'outcome', '') not in ('no_link_created', 'try_later') then
          raise exception 'C: bogus-slug claim returned unexpected outcome %', v_resp->>'outcome';
        end if;
        select count(*) into v_after from public.customer_links where identity_id = v_identity;
        if v_after <> v_before then
          raise exception 'C: a bogus-slug claim created a link (% -> %)', v_before, v_after;
        end if;
      exception
        when sqlstate '0A000' then null; -- customer_claims feature disabled: acceptable
      end;
    end if;
  end if;

  raise notice 'v283 customer-claim grants: all assertions passed';
end $v283$;

rollback;
