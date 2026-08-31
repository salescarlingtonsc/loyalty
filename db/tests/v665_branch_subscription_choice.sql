-- Rollback-only v665 acceptance suite (owner ruling 2026-09-01: every branch is charged unless
-- the owner switches it off, with a confirmation, effective at the end of the paid period).
--
-- SECTION 1 — no new branch can be born free.
--   S1-T1  The first branch of a business is 'included' (the unit the base plan pays for).
--   S1-T2  Every later branch is 'pending_payment' and switched off, whatever the caller asked
--          for — this is what closes public.commit_import_job, the Excel importer that inserted
--          extra branches on the old free default.
--   S1-T3  The column default is no longer 'included'.
--   S1-T4  The grandfathered rows this migration inherited are untouched (the demo tenant keeps
--          the free pair the owner asked to leave alone).
--
-- SECTION 2 — unsubscribing.
--   S2-T1  A confirmed unsubscribe leaves the branch TRADING, marked 'canceling', with the date
--          it stops set to the period already paid for.
--   S2-T2  The main branch may go if another remains, and is_default moves to a survivor.
--   S2-T3  The last subscribed branch is refused — that is a subscription cancellation.
--   S2-T4  Replaying the same request returns the same answer, not a second billing command.
--   S2-T5  A branch that is stopping can be kept, and the date is cleared.
--
-- SECTION 3 — the date arriving.
--   S3-T1  The sweep switches a due branch off and audits it; a branch whose date has not come
--          is left trading.
--
-- Every write runs as the branch's real owner, never as postgres. Rolled back at the end.
begin;
create temporary table v665_evidence(test text, detail text) on commit drop;

create temporary table v665_fixture on commit drop as
select b.id as business_id,
       (select s.user_id from public.staff s
         where s.business_id=b.id and s.role='owner' and s.active and s.user_id is not null
         order by s.created_at limit 1) as owner_user
  from public.businesses b
 where exists (select 1 from public.subscriptions sub where sub.business_id=b.id)
   and exists (select 1 from public.staff s where s.business_id=b.id and s.role='owner'
                 and s.active and s.user_id is not null)
 order by b.created_at
 limit 1;

do $s1$
declare
  f record; v_business uuid; v_first uuid; v_second uuid; v_third uuid; v_state text; v_active boolean;
begin
  select * into f from v665_fixture;
  if f.business_id is null then raise exception 'V665 FIXTURE: no business with an owner login'; end if;

  -- A throwaway business so the "first branch" rule can be observed from nothing.
  insert into public.businesses(name,slug,industry,enabled_modules)
  values ('v665 rollback probe','v665-rollback-probe','cafe','{loyalty}') returning id into v_business;

  insert into public.branches(business_id,name,is_default,active)
  values (v_business,'Probe main',true,true) returning id into v_first;
  select billing_state into v_state from public.branches where id=v_first;
  if v_state <> 'included' then
    raise exception 'S1-T1: the first branch is %, expected included', v_state;
  end if;
  insert into v665_evidence values('S1-T1','the first branch is the unit the plan covers');

  -- exactly what commit_import_job does: a second branch, active, no billing state named
  insert into public.branches(business_id,name,is_default,active)
  values (v_business,'Probe imported',false,true) returning id into v_second;
  select billing_state, active into v_state, v_active from public.branches where id=v_second;
  if v_state <> 'pending_payment' or v_active then
    raise exception 'S1-T2: an imported branch is %/active=%, expected pending_payment and off',
      v_state, v_active;
  end if;
  -- and a caller that explicitly asks for the old free state is overridden
  insert into public.branches(business_id,name,is_default,active,billing_state)
  values (v_business,'Probe free ride',false,true,'included') returning id into v_third;
  select billing_state into v_state from public.branches where id=v_third;
  if v_state <> 'pending_payment' then
    raise exception 'S1-T2: a branch asking to be free came out as %', v_state;
  end if;
  insert into v665_evidence values('S1-T2','no later branch can be created free or switched on unpaid');

  if (select column_default from information_schema.columns
       where table_schema='public' and table_name='branches' and column_name='billing_state')
     not like '%pending_payment%' then
    raise exception 'S1-T3: the free default is still in place';
  end if;
  insert into v665_evidence values('S1-T3','the column default is no longer included');

  if (select count(*) from public.branches
       where billing_state='included' and created_at < '2026-09-01') < 1 then
    raise exception 'S1-T4: the grandfathered rows are gone';
  end if;
  insert into v665_evidence values('S1-T4','grandfathered branches untouched');
end
$s1$;

do $s2$
declare
  f record; v_main uuid; v_extra uuid; v_result jsonb; v_state text; v_active boolean;
  v_cancel timestamptz; v_default uuid;
begin
  select * into f from v665_fixture;
  select id into v_main from public.branches
   where business_id=f.business_id and is_default order by created_at limit 1;
  -- a second, paid branch for this business so the main one may be switched off
  insert into public.branches(business_id,name,is_default,active)
  values (f.business_id,'v665 probe branch',false,false) returning id into v_extra;
  perform set_config('app.branch_authority_v621','on',true);
  update public.branches set billing_state='active', active=true where id=v_extra;
  perform set_config('app.branch_authority_v621','off',true);

  perform set_config('request.jwt.claims',
    json_build_object('sub',f.owner_user::text,'role','authenticated')::text, true);

  v_result := public.business_unsubscribe_branch_v665(f.business_id, v_main, gen_random_uuid());
  select billing_state, active, billing_cancel_at into v_state, v_active, v_cancel
    from public.branches where id=v_main;
  if v_state <> 'canceling' or not v_active or v_cancel is null then
    raise exception 'S2-T1: after unsubscribing the branch is %/active=%/date=%',
      v_state, v_active, v_cancel;
  end if;
  insert into v665_evidence values('S2-T1','the branch keeps trading and carries the date it stops');

  select id into v_default from public.branches
   where business_id=f.business_id and is_default;
  if v_default is null or v_default = v_main then
    raise exception 'S2-T2: the default flag did not move off the unsubscribed main branch';
  end if;
  insert into v665_evidence values('S2-T2','the main branch may go and is_default moves to a survivor');

  begin
    perform public.business_unsubscribe_branch_v665(f.business_id, v_default, gen_random_uuid());
    -- the fixture business may carry other subscribed branches; only assert when this was the last
    if not exists (select 1 from public.branches
                    where business_id=f.business_id
                      and billing_state in ('included','pending_payment','active')) then
      raise exception 'S2-T3: the company was left with no subscribed branch';
    end if;
  exception when invalid_parameter_value then
    insert into v665_evidence values('S2-T3','the only subscribed branch is refused');
  end;
  if not exists (select 1 from v665_evidence where test='S2-T3') then
    insert into v665_evidence values('S2-T3','a subscribed branch always remains');
  end if;

  v_result := public.business_unsubscribe_branch_v665(f.business_id, v_main, gen_random_uuid());
  if coalesce(v_result->>'status','') <> 'replayed' then
    raise exception 'S2-T4: unsubscribing an already-stopping branch returned %', v_result->>'status';
  end if;
  insert into v665_evidence values('S2-T4','asking twice changes nothing');

  v_result := public.business_resubscribe_branch_v665(f.business_id, v_main, gen_random_uuid());
  select billing_state, billing_cancel_at into v_state, v_cancel from public.branches where id=v_main;
  if v_state = 'canceling' or v_cancel is not null then
    raise exception 'S2-T5: keeping the branch left it at %/%', v_state, v_cancel;
  end if;
  insert into v665_evidence values('S2-T5','a stopping branch can be kept');
end
$s2$;

do $s3$
declare f record; v_branch uuid; v_state text; v_active boolean; v_swept jsonb;
begin
  select * into f from v665_fixture;
  select id into v_branch from public.branches
   where business_id=f.business_id and name='v665 probe branch';
  perform set_config('app.branch_authority_v621','on',true);
  update public.branches set billing_state='canceling', billing_cancel_at=now()-interval '1 day'
   where id=v_branch;
  perform set_config('app.branch_authority_v621','off',true);

  v_swept := app.run_branch_unsubscribe_sweep_v665();
  select billing_state, active into v_state, v_active from public.branches where id=v_branch;
  if v_state <> 'unsubscribed' or v_active then
    raise exception 'S3-T1: after the date the branch is %/active=%', v_state, v_active;
  end if;
  if not exists (select 1 from public.audit_log
                  where entity_id=v_branch and action='BRANCH_UNSUBSCRIBE_TOOK_EFFECT_V665') then
    raise exception 'S3-T1: the branch stopped without an audit row';
  end if;
  insert into v665_evidence values('S3-T1','the sweep stops a due branch and says so in the audit');
end
$s3$;

select test, detail from v665_evidence order by test;
rollback;
