begin;

do $$
declare
  target_oid oid := 'public.get_birthday_program_draft(uuid)'::regprocedure::oid;
  volatility "char";
begin
  select p.provolatile into volatility
  from pg_proc p
  where p.oid = target_oid;

  if volatility <> 'v' then
    raise exception 'v46a expected get_birthday_program_draft(uuid) to be VOLATILE';
  end if;

  if has_function_privilege('anon', target_oid, 'EXECUTE') then
    raise exception 'v46a anonymous execution must remain revoked';
  end if;

  if not has_function_privilege('authenticated', target_oid, 'EXECUTE') then
    raise exception 'v46a authenticated execution grant is missing';
  end if;

  if exists (
    select 1
    from pg_proc p
    cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) acl
    where p.oid = target_oid
      and acl.grantee = 0
      and acl.privilege_type = 'EXECUTE'
  ) then
    raise exception 'v46a PUBLIC execution must remain revoked';
  end if;
end
$$;

rollback;
