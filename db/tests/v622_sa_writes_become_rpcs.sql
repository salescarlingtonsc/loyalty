-- Rollback-only acceptance for NESTLY v622 — a super admin acts through declared, audited
-- RPCs, never raw table writes.
--
-- Proves, at the server boundary only:
--   · platform_adjust_subscription_v622 moves trial runway ONLY with a stated reason, inside
--     the 180-day ceiling, and leaves an audit row carrying before/after;
--   · platform_set_workspace_pause_v622 is the manual pause/resume lever, and the entitlement
--     authority follows it;
--   · both refuse a non-super-admin with 42501;
--   · the direct doors are shut: the dropped subscriptions_sa_write policy means a super-admin
--     session PATCHing /rest/v1/subscriptions now updates ZERO rows, and the platform can no
--     longer write a tenant's sale_policies.
--
-- Fold-in from v625: the super admin here holds authority only on a Google (oauth) session.
--
-- Self-contained fixtures (gen_random_uuid), count deltas rather than absolute counts, and
-- one transaction that ends in rollback — safe to run against production.
begin;

create or replace function pg_temp.as_v622_session(
  p_uid uuid,
  p_method text default 'password',
  p_role text default 'authenticated'
) returns void language plpgsql as $fn$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','{}',true);
  if p_uid is null then
    return;
  end if;
  if p_role is not null then
    execute format('set local role %I',p_role);
  end if;
  perform set_config('request.jwt.claim.sub',p_uid::text,true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object(
      'sub',p_uid,
      'role',coalesce(p_role,'authenticated'),
      'amr',jsonb_build_array(
        jsonb_build_object('method',p_method,'timestamp',1756500000)
      ),
      'app_metadata',case when p_method='oauth'
        then jsonb_build_object(
          'provider','google','providers',jsonb_build_array('email','google'))
        else jsonb_build_object(
          'provider','email','providers',jsonb_build_array('email')) end
    )::text,
    true
  );
end
$fn$;
grant execute on function pg_temp.as_v622_session(uuid,text,text) to public;

do $v622_main$
declare
  v_super uuid:=gen_random_uuid();
  v_owner uuid:=gen_random_uuid();
  v_business uuid:=gen_random_uuid();
  v_reason text:='v622 acceptance '||substr(gen_random_uuid()::text,1,8);
  v_target timestamptz:=date_trunc('second',now()+interval '30 days');
  v_result jsonb;
  v_rows integer;
  v_stored timestamptz;
  v_paused boolean;
begin
  reset role;

  -- C1 · the replacements are authenticated-only and never anon-callable.
  if has_function_privilege(
       'anon',
       'public.platform_adjust_subscription_v622(uuid,text,timestamptz,text)','EXECUTE')
     or has_function_privilege(
       'anon','public.platform_set_workspace_pause_v622(uuid,boolean,text)','EXECUTE')
     or not has_function_privilege(
       'authenticated',
       'public.platform_adjust_subscription_v622(uuid,text,timestamptz,text)','EXECUTE')
     or not has_function_privilege(
       'authenticated',
       'public.platform_set_workspace_pause_v622(uuid,boolean,text)','EXECUTE') then
    raise exception 'v622 C1: platform RPC ACLs are not fail-closed';
  end if;

  -- C2 · the raw super-admin write policy on subscriptions is gone.
  if exists(
    select 1 from pg_policies
    where schemaname='public' and tablename='subscriptions'
      and policyname='subscriptions_sa_write'
  ) then
    raise exception 'v622 C2: subscriptions_sa_write still exists';
  end if;

  -- C3 · no sale_policies WRITE policy ORs in super-admin authority any more.
  if exists(
    select 1 from pg_policies
    where schemaname='public' and tablename='sale_policies'
      and cmd in('INSERT','UPDATE','DELETE')
      and coalesce(qual,'')||coalesce(with_check,'') like '%is_super_admin%'
  ) then
    raise exception 'v622 C3: a sale_policies write policy still grants the platform';
  end if;

  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,
    email_confirmed_at,created_at,updated_at
  ) select
    '00000000-0000-0000-0000-000000000000',user_id,
    'authenticated','authenticated',email,'',now(),now(),now()
  from (values
    (v_super,'v622-super-'||substr(v_super::text,1,8)||'@example.test'),
    (v_owner,'v622-owner-'||substr(v_owner::text,1,8)||'@example.test')
  ) fixture(user_id,email);
  insert into public.super_admins(user_id,email,note)
  values(
    v_super,'v622-super-'||substr(v_super::text,1,8)||'@example.test',
    'rollback-only v622 fixture'
  );

  insert into public.businesses(id,name,slug,industry,enabled_modules)
  values(
    v_business,'V622 platform write fixture',
    'v622-'||substr(v_business::text,1,8),'test',
    array['dashboard','clients','sales','loyalty','retention','reports']
  );
  insert into public.staff(business_id,user_id,role,full_name,active)
  values(v_business,v_owner,'owner','V622 Owner',true);
  insert into public.branches(business_id,name,is_default,active)
  values(v_business,'Primary',true,true);
  update public.business_workspace_controls_v94
     set approval_status='approved',version=version+1,
         decided_at=clock_timestamp(),
         decision_reason='rollback-only v622 acceptance fixture',
         updated_at=clock_timestamp()
   where business_id=v_business;
  insert into public.subscriptions(
    business_id,status,payment_status,trial_ends_at,
    current_period_start,current_period_end
  ) values(
    v_business,'trialing','not_collected',now()+interval '3 days',
    now(),now()+interval '30 days'
  );

  -- C4 · a Google super-admin session moves the runway through the RPC.
  perform pg_temp.as_v622_session(v_super,'oauth');
  v_result:=public.platform_adjust_subscription_v622(
    v_business,v_reason,v_target,null
  );
  if (v_result->>'trial_ends_at')::timestamptz<>v_target then
    raise exception 'v622 C4: the adjusted runway was not returned: %',v_result;
  end if;
  reset role;
  select trial_ends_at into v_stored from public.subscriptions where business_id=v_business;
  if v_stored<>v_target then
    raise exception 'v622 C5: the adjusted runway was not persisted (% vs %)',v_stored,v_target;
  end if;

  -- C6 · the adjustment is audited with the stated reason and a before/after pair.
  if not exists(
    select 1 from public.audit_log log_row
    where log_row.business_id=v_business
      and log_row.action='PLATFORM_SUBSCRIPTION_ADJUSTED_V622'
      and log_row.detail->>'reason'=v_reason
      and log_row.detail->'before' is not null
      and log_row.detail->'after' is not null
  ) then
    raise exception 'v622 C6: the subscription adjustment left no audit evidence';
  end if;

  -- C7 · a runway change without a stated reason is refused.
  perform pg_temp.as_v622_session(v_super,'oauth');
  begin
    perform public.platform_adjust_subscription_v622(
      v_business,'short',now()+interval '5 days',null
    );
    raise exception 'v622 C7: a reasonless runway change was accepted';
  exception when sqlstate '22023' then null;
  end;

  -- C8 · an adjustment that changes nothing is refused.
  begin
    perform public.platform_adjust_subscription_v622(
      v_business,'v622 nothing to adjust',null,null
    );
    raise exception 'v622 C8: an empty adjustment was accepted';
  exception when sqlstate '22023' then null;
  end;

  -- C9 · runway beyond the 180-day ceiling is refused here.
  begin
    perform public.platform_adjust_subscription_v622(
      v_business,'v622 excessive runway',now()+interval '200 days',null
    );
    raise exception 'v622 C9: runway beyond 180 days was accepted';
  exception when sqlstate '22023' then null;
  end;

  -- C10 · a tenant owner is not a platform operator.
  perform pg_temp.as_v622_session(v_owner,'password');
  begin
    perform public.platform_adjust_subscription_v622(
      v_business,'v622 tenant escalation attempt',now()+interval '90 days',null
    );
    raise exception 'v622 C10: a tenant owner adjusted their own subscription';
  exception when sqlstate '42501' then null;
  end;

  -- C11 · the raw door is shut: a Google super-admin PATCH of subscriptions writes nothing.
  perform pg_temp.as_v622_session(v_super,'oauth');
  update public.subscriptions set note='v622 direct write attempt'
   where business_id=v_business;
  get diagnostics v_rows=row_count;
  if v_rows<>0 then
    raise exception 'v622 C11: a super-admin session still writes subscriptions directly (% rows)',v_rows;
  end if;

  -- C12 · and the platform can no longer rewrite a tenant's sale accounting semantics.
  begin
    insert into public.sale_policies(business_id,kind,counts_as_revenue)
    values(v_business,'retail',false);
    raise exception 'v622 C12: a super-admin session wrote tenant sale_policies';
  exception when sqlstate '42501' then null;
  end;

  -- C13 · the manual pause lever exists and the entitlement authority follows it.
  begin
    v_result:=public.platform_set_workspace_pause_v622(
      v_business,true,'v622 manual pause acceptance'
    );
  exception when others then
    raise exception 'v622 C13: platform_set_workspace_pause_v622 failed to pause [%]: % — the business_subscription_lifecycle_v94_shape check requires overdue_day/provider_invoice_id/due_date on the paused arm',sqlstate,sqlerrm;
  end;
  reset role;
  select workspace_paused into v_paused
    from public.business_subscription_lifecycle_v94 where business_id=v_business;
  if not coalesce(v_paused,false) then
    raise exception 'v622 C14: the manual pause did not persist';
  end if;
  if app.business_operational_v620(v_business) then
    raise exception 'v622 C15: a manually paused workspace stayed operational';
  end if;

  -- C16 · resume reopens it.
  perform pg_temp.as_v622_session(v_super,'oauth');
  begin
    v_result:=public.platform_set_workspace_pause_v622(
      v_business,false,'v622 manual resume acceptance'
    );
  exception when others then
    raise exception 'v622 C16: platform_set_workspace_pause_v622 failed to resume [%]: % — the lifecycle shape check requires overdue_day IS NULL on the current arm',sqlstate,sqlerrm;
  end;
  reset role;
  if not app.business_operational_v620(v_business) then
    raise exception 'v622 C17: resume did not reopen the workspace';
  end if;
  if not exists(
    select 1 from public.audit_log log_row
    where log_row.business_id=v_business
      and log_row.action='PLATFORM_WORKSPACE_PAUSE_V622'
  ) then
    raise exception 'v622 C18: the pause lever left no audit evidence';
  end if;

  perform pg_temp.as_v622_session(null);
  raise notice 'v622 platform write suite: ALL PASS';
end
$v622_main$;

reset role;
rollback;
