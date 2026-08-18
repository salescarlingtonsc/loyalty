-- Rollback suite for v391. Everything runs inside a transaction that is ROLLED BACK.
--
-- The point of this suite is the thing v384's own tests did not do: EXECUTE the function.
-- A plpgsql body is not checked for column existence until it runs, so a reader can reference
-- a column that has never existed and every static check will still pass.
begin;

do $$
declare
  v_slug text;
  v_result jsonb;
  v_def text;
begin
  -- 1. The two column names the v384 regression used must not appear as column references again.
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='public' and p.proname='customer_portal_capabilities';
  if v_def is null then
    raise exception 'v391: customer_portal_capabilities is missing';
  end if;
  if v_def like '%spine.running_since%' or v_def like '%spine.paused_since%' then
    raise exception 'v391: the reader is reading running_since/paused_since as COLUMNS again';
  end if;
  if v_def not like '%spine.activated_at%' or v_def not like '%spine.deactivated_at%' then
    raise exception 'v391: the reader no longer projects activated_at/deactivated_at';
  end if;

  -- 2. Those two names really are not columns, which is why v384 raised 42703.
  if exists(select 1 from information_schema.columns
             where table_schema='public' and table_name='business_programmes'
               and column_name in ('running_since','paused_since')) then
    raise exception 'v391: business_programmes now HAS these columns — re-check this suite';
  end if;
  if not exists(select 1 from information_schema.columns
                 where table_schema='public' and table_name='business_programmes'
                   and column_name in ('activated_at','deactivated_at')) then
    raise exception 'v391: business_programmes is missing activated_at/deactivated_at';
  end if;

  -- 3. EXECUTE it. Without a customer session it must refuse with its own guard, never 42703.
  --    Any undefined-column fault re-raises loudly instead of being swallowed.
  select b.slug into v_slug from public.businesses b order by b.created_at limit 1;
  if v_slug is not null then
    begin
      v_result := public.customer_portal_capabilities(v_slug);
    exception
      when undefined_column then
        raise exception 'v391: STILL 42703 — the reader names a column that does not exist';
      when insufficient_privilege or invalid_authorization_specification then
        null; -- expected without an authenticated customer: the guard fired, not a column fault
      when others then
        if sqlstate = '42703' then
          raise exception 'v391: STILL 42703 — the reader names a column that does not exist';
        end if;
        null; -- any other refusal is this function's own contract, not v391's concern
    end;
  end if;

  raise notice 'v391 rollback suite: all assertions passed';
end $$;

rollback;
