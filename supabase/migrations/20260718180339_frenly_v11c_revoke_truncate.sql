do $$
declare r record;
begin
  for r in select tablename from pg_tables where schemaname = 'public' loop
    execute format('revoke truncate on public.%I from authenticated, anon', r.tablename);
  end loop;
end $$;