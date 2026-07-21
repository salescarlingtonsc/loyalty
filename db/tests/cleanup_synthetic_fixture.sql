\set ON_ERROR_STOP on

begin;
set local lock_timeout = '10s';
set local statement_timeout = '60s';

create temporary table pg_temp.frenly_cleanup_scope (
  confirmation text not null,
  business_id uuid,
  business_name text not null,
  business_slug text not null,
  auth_user_1 uuid,
  auth_email_1 text,
  auth_user_2 uuid,
  auth_email_2 text
) on commit drop;

insert into pg_temp.frenly_cleanup_scope values (
  :'cleanup_confirm',
  nullif(:'cleanup_business', '')::uuid,
  :'cleanup_business_name',
  :'cleanup_business_slug',
  nullif(:'cleanup_auth_user_1', '')::uuid,
  nullif(:'cleanup_auth_email_1', ''),
  nullif(:'cleanup_auth_user_2', '')::uuid,
  nullif(:'cleanup_auth_email_2', '')
);

create temporary table pg_temp.frenly_cleanup_pending (
  table_oid oid primary key
) on commit drop;

do $cleanup$
declare
  v_scope pg_temp.frenly_cleanup_scope%rowtype;
  v_business uuid;
  v_matches integer;
  v_progress integer;
  v_remaining text;
  v_table record;
  v_trigger_tables oid[];
  v_trigger_drift text;
  v_oid oid;
  v_user uuid;
  v_email text;
begin
  select * into strict v_scope from pg_temp.frenly_cleanup_scope;
  if v_scope.confirmation <> 'YES-SCOPED-SYNTHETIC-CLEANUP' then
    raise exception 'synthetic cleanup confirmation is missing';
  end if;
  if v_scope.business_name = '' or v_scope.business_slug = '' then
    raise exception 'synthetic cleanup requires exact business name and slug';
  end if;

  v_business := v_scope.business_id;
  if v_business is null then
    select count(*)
      into v_matches
      from public.businesses
     where name = v_scope.business_name and slug = v_scope.business_slug;
    if v_matches > 1 then
      raise exception 'synthetic cleanup identity is not unique';
    end if;
    if v_matches = 1 then
      select id into v_business from public.businesses
       where name = v_scope.business_name and slug = v_scope.business_slug;
    end if;
  end if;

  if v_business is not null then
    select count(*) into v_matches
      from public.businesses
     where id = v_business
       and name = v_scope.business_name
       and slug = v_scope.business_slug;
    if v_matches = 0 then
      if exists (select 1 from public.businesses where id = v_business)
         or exists (
           select 1 from public.businesses
            where name = v_scope.business_name or slug = v_scope.business_slug
         ) then
        raise exception 'business UUID/name/slug cleanup guard did not match exactly';
      end if;
      v_business := null;
    end if;
  end if;

  for v_user, v_email in
    select u, e from (values
      (v_scope.auth_user_1, v_scope.auth_email_1),
      (v_scope.auth_user_2, v_scope.auth_email_2)
    ) users(u, e) where u is not null
  loop
    if v_email is null then
      raise exception 'auth cleanup requires the exact synthetic email for user %', v_user;
    end if;
    select count(*) into v_matches from auth.users where id = v_user and email = v_email;
    if v_matches not in (0, 1) then
      raise exception 'auth UUID/email cleanup guard is ambiguous for user %', v_user;
    end if;
    if exists (
      select 1 from public.staff
       where user_id = v_user and (v_business is null or business_id <> v_business)
    ) then
      raise exception 'refusing to delete auth user % linked to another business', v_user;
    end if;
  end loop;

  if v_business is not null then
    select array_agg(c.oid order by n.nspname, c.relname)
      into v_trigger_tables
     from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind in ('r', 'p')
       and (
         c.relname = 'businesses'
         or exists (
           select 1 from pg_attribute a
            where a.attrelid = c.oid and a.attname = 'business_id'
              and a.attnum > 0 and not a.attisdropped
         )
       );

    select string_agg(format('%s.%s=%s', c.relname, t.tgname, t.tgenabled), ', '
                      order by c.relname, t.tgname)
      into v_trigger_drift
      from pg_trigger t join pg_class c on c.oid = t.tgrelid
     where t.tgrelid = any(v_trigger_tables)
       and not t.tgisinternal and t.tgenabled <> 'O';
    if v_trigger_drift is not null then
      raise exception 'refusing cleanup: selected user triggers are not origin-enabled: %',
        v_trigger_drift;
    end if;

    foreach v_oid in array coalesce(v_trigger_tables, '{}'::oid[]) loop
      execute format('alter table %s disable trigger user', v_oid::regclass);
    end loop;

    update public.businesses set active_config_version_id = null where id = v_business;

    insert into pg_temp.frenly_cleanup_pending(table_oid)
    select c.oid
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public'
       and c.relkind in ('r', 'p')
       and c.relname <> 'businesses'
       and exists (
         select 1 from pg_attribute a
          where a.attrelid = c.oid and a.attname = 'business_id'
            and a.attnum > 0 and not a.attisdropped
       );

    loop
      v_progress := 0;
      for v_table in
        select p.table_oid
          from pg_temp.frenly_cleanup_pending p
          join pg_class c on c.oid = p.table_oid
         order by c.relname
      loop
        begin
          execute format('delete from %s where business_id = $1', v_table.table_oid::regclass)
            using v_business;
          delete from pg_temp.frenly_cleanup_pending where table_oid = v_table.table_oid;
          v_progress := v_progress + 1;
        exception when foreign_key_violation then
          null;
        end;
      end loop;
      exit when not exists (select 1 from pg_temp.frenly_cleanup_pending);
      if v_progress = 0 then
        select string_agg(table_oid::regclass::text, ', ' order by table_oid::regclass::text)
          into v_remaining from pg_temp.frenly_cleanup_pending;
        raise exception 'synthetic cleanup made no FK progress; remaining tables: %', v_remaining;
      end if;
    end loop;

    delete from public.businesses where id = v_business;
    if not found then raise exception 'synthetic business disappeared during cleanup'; end if;

    foreach v_oid in array coalesce(v_trigger_tables, '{}'::oid[]) loop
      execute format('alter table %s enable trigger user', v_oid::regclass);
    end loop;
    select string_agg(format('%s.%s=%s', c.relname, t.tgname, t.tgenabled), ', '
                      order by c.relname, t.tgname)
      into v_trigger_drift
      from pg_trigger t join pg_class c on c.oid = t.tgrelid
     where t.tgrelid = any(v_trigger_tables)
       and not t.tgisinternal and t.tgenabled <> 'O';
    if v_trigger_drift is not null then
      raise exception 'cleanup did not restore origin-enabled user triggers: %', v_trigger_drift;
    end if;
  end if;

  delete from auth.users
   where id in (v_scope.auth_user_1, v_scope.auth_user_2)
     and ((id = v_scope.auth_user_1 and email = v_scope.auth_email_1)
       or (id = v_scope.auth_user_2 and email = v_scope.auth_email_2));

  if v_business is not null and exists (select 1 from public.businesses where id = v_business) then
    raise exception 'post-cleanup business row remains';
  end if;
  if v_business is not null then
    for v_table in
      select c.oid as table_oid
        from pg_class c
        join pg_namespace n on n.oid = c.relnamespace
       where n.nspname = 'public' and c.relkind in ('r', 'p')
         and exists (
           select 1 from pg_attribute a
            where a.attrelid = c.oid and a.attname = 'business_id'
              and a.attnum > 0 and not a.attisdropped
         )
    loop
      execute format('select count(*) from %s where business_id = $1', v_table.table_oid::regclass)
        into v_matches using v_business;
      if v_matches <> 0 then
        raise exception 'post-cleanup rows remain in %', v_table.table_oid::regclass;
      end if;
    end loop;
  end if;
  if exists (
    select 1 from auth.users
     where id in (v_scope.auth_user_1, v_scope.auth_user_2)
  ) then
    raise exception 'post-cleanup synthetic auth user row remains';
  end if;
end
$cleanup$;

commit;
select 'synthetic-fixture-cleanup: PASS';
