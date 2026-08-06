-- Rollback-only v178 acceptance: Vault-backed verification of the v176
-- dispatch secret. Run after the canonical chain through v178.
-- Prod-compatible: uses a transaction-local Vault secret name is NOT possible
-- (the verifier is pinned to `v176_dispatch_secret`), so the suite exercises
-- the negative paths unconditionally and the positive path only when the
-- Vault secret exists in this database.
begin;

do $v178$
declare
  v_expected text;
  v_result boolean;
begin
  if to_regprocedure('public.internal_verify_v176_dispatch_secret(text)') is null then
    raise exception 'internal_verify_v176_dispatch_secret is missing';
  end if;
  if has_function_privilege('anon',
       'public.internal_verify_v176_dispatch_secret(text)','EXECUTE') then
    raise exception 'the dispatch verifier is callable by anon';
  end if;
  if has_function_privilege('authenticated',
       'public.internal_verify_v176_dispatch_secret(text)','EXECUTE') then
    raise exception 'the dispatch verifier is callable by authenticated';
  end if;

  -- Negative paths never raise and never return true.
  if public.internal_verify_v176_dispatch_secret(null) then
    raise exception 'null secret verified';
  end if;
  if public.internal_verify_v176_dispatch_secret('short') then
    raise exception 'a short secret verified';
  end if;
  if public.internal_verify_v176_dispatch_secret(repeat('x', 64)) then
    raise exception 'a wrong 64-char secret verified';
  end if;

  -- Positive path, only where the Vault secret exists (prod does; a pristine
  -- disposable chain database may not).
  begin
    execute 'select decrypted_secret from vault.decrypted_secrets where name = $1 order by created_at desc limit 1'
      into v_expected using 'v176_dispatch_secret';
  exception when others then
    v_expected := null;
  end;
  if v_expected is not null and length(v_expected) >= 32 then
    v_result := public.internal_verify_v176_dispatch_secret(v_expected);
    if v_result is not true then
      raise exception 'the correct Vault secret did not verify';
    end if;
    if public.internal_verify_v176_dispatch_secret(v_expected || 'x') then
      raise exception 'an extended secret verified';
    end if;
  else
    raise notice 'v178: vault secret absent in this database; positive path skipped';
  end if;

  raise notice 'v178 dispatch-secret verification: all assertions passed';
end
$v178$;

rollback;
