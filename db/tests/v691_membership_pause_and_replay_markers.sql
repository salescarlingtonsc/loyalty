-- Rollback-only nestly_v691 acceptance: pausing a membership stops its billing clock, and three
-- idempotent RPCs stop reporting a replay as a fresh write.
--
-- WHAT THE BUGS WERE
--   F088  public.set_membership_status wrote ONE column: status. Pausing froze
--         memberships.current_period_end where it stood, and the daily cron
--         app.run_membership_renewals correctly skipped the row while it said 'paused' — but the
--         moment it said 'active' again the cron saw a current_period_end months in the past and
--         its catch-up while-loop (capped at 12) fired once per elapsed period. Each iteration
--         inserts a kind='membership' sale, which app.sale_policy_defaults marks
--         counts_as_revenue, and — when the plan carries credit — one 'membership_credit' row on
--         the append-only credit ledger. A four-month pause on an $80/mo plan with $60 of credit
--         booked $320 of revenue nobody paid and dropped $240 of spendable credit, overnight,
--         with no owner action. The idempotency keys differ per period, so nothing deduped it.
--   F089  public.enroll_membership_v41 (4-arg) returned v_existing.result verbatim on a cache hit
--         and the underlying 3-arg returned row_to_json(memberships-row) on a fresh call, so
--         neither carried a 'replayed' marker. The client's isReplayResult(data) was false on
--         EVERY call and "Already enrolled — no duplicate created" was unreachable dead code.
--   F134  public.sell_package_v102 and public.use_package_session_v102 baked 'replayed', false
--         into the result at creation time and returned that same cached jsonb verbatim on the
--         replay branch, so data.replayed was structurally incapable of being true. A second scan
--         of an already-consumed package-session QR showed staff the identical receipt as the
--         first.
--
-- In F089 and F134 the LEDGER was always correct — no second charge, no second decrement. Only
-- the answer was wrong, which is why every replay assertion below also counts the rows.
--
-- WHAT THIS SUITE PROVES, against a tenant it builds itself:
--    1. F088 the pause records when it began and moves nothing else — the periods it froze are
--       exactly where they were.
--    2. F088 the resume gives back exactly the time that was held: both period columns move
--       forward by the pause length, paused_at is cleared, and the RPC reports the days returned.
--    3. F088 THE MONEY. After a four-month pause and a resume, the real cron
--       app.run_membership_renewals bills NOTHING: no membership sale, no credit-ledger row.
--    4. F088 sensitivity control — the catch-up loop is intact, not disabled. An identical
--       membership that was never paused, whose period ended four months ago, IS caught up: five
--       sales and five credit rows (the four elapsed months, plus the period that begins today —
--       the loop bills while v_period_start <= now()). Without this, assertion 3 would pass on a
--       cron that does nothing at all.
--    5. F088 negative — a status change that neither enters nor leaves 'paused'
--       (active -> cancel_at_period_end) shifts no period and returns zero days.
--    6. F088 negative — a row paused BEFORE this migration existed carries no paused_at, and is
--       deliberately left with today's behaviour: coalesce(paused_at, now()) makes the shift
--       zero rather than inventing a pause length from a column nobody ever wrote.
--    7. F088 negative — another business's owner cannot pause this firm's membership (42501) and
--       the row is untouched.
--    8. F089 a fresh enrollment says replayed:false; the replay of the same key says
--       replayed:true, and there is still exactly ONE membership and ONE enrolment sale.
--    9. F134 a fresh package sale says replayed:false; the replay says replayed:true, and there
--       is still exactly ONE client_packages row and ONE package sale.
--   10. F134 a fresh package session says replayed:false; the replay says replayed:true, and
--       remaining has been decremented exactly ONCE.
--
-- Run against production inside this transaction; every fixture row is rolled back:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/v691_membership_pause_and_replay_markers.sql
-- Assertions are recorded as rows rather than raised, so one final SELECT reports the whole
-- suite. Any row whose outcome starts with FAIL is a failure.

begin;

create temp table v691_out(seq integer, step text, outcome text) on commit drop;
grant insert, select on v691_out to public;

create or replace function pg_temp.as_v691_system() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','',true);
end
$$;
grant execute on function pg_temp.as_v691_system() to public;

create or replace function pg_temp.as_v691_user(p_uid uuid, p_role text default 'authenticated')
returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','{}',true);
  execute format('set local role %I',p_role);
  perform set_config('request.jwt.claim.sub',coalesce(p_uid::text,''),true);
  perform set_config('request.jwt.claims',
    json_build_object('sub',p_uid,'role',p_role)::text,true);
end
$$;
grant execute on function pg_temp.as_v691_user(uuid,text) to public;

-- A tenant that can sell: approved workspace, unpaused subscription, a paid subscriptions row
-- (business_operational_v620), the memberships / packages / sales modules on, one owner and a
-- default branch the owner is assigned to.
create or replace function pg_temp.v691_tenant(
  p_business uuid, p_owner uuid, p_branch uuid, p_label text
) returns void language plpgsql as $$
declare
  v_owner_staff uuid;
begin
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                         email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000',p_owner,'authenticated','authenticated',
          'v691-owner-'||substr(p_owner::text,1,8)||'@example.test','',now(),now(),now())
  on conflict (id) do nothing;

  perform set_config('app.v79_system_transition','on',true);
  insert into public.businesses(id,name,slug,industry,currency,enabled_modules)
  values (p_business,'V691 '||p_label,'v691-'||substr(p_business::text,1,8),
          'fnb','SGD',
          array['dashboard','clients','sales','services','till','memberships','packages']);
  perform set_config('app.v79_system_transition','',true);

  update public.business_workspace_controls_v94
     set approval_status='approved', version=version+1, decided_by=p_owner,
         decided_at=clock_timestamp(), decision_reason='v691 rollback fixture',
         updated_at=clock_timestamp()
   where business_id = p_business;
  insert into public.business_subscription_lifecycle_v94(business_id,workspace_paused)
  values (p_business,false)
  on conflict (business_id) do update set workspace_paused=false;
  insert into public.subscriptions(business_id,status,payment_status,current_period_end)
  values (p_business,'active','paid',now()+interval '30 days')
  on conflict (business_id) do update
    set status='active', payment_status='paid', current_period_end=now()+interval '30 days';

  insert into public.staff(business_id,user_id,role,full_name,active,access_state)
  values (p_business,p_owner,'owner','V691 Owner '||p_label,true,'approved')
  returning id into v_owner_staff;
  insert into public.branches(id,business_id,name,active,is_default)
  values (p_branch,p_business,'V691 Main '||p_label,true,true);
  insert into public.staff_branches(business_id,staff_id,branch_id)
  values (p_business,v_owner_staff,p_branch);
end
$$;
grant execute on function pg_temp.v691_tenant(uuid,uuid,uuid,text) to public;

do $v691_test$
declare
  bA uuid := gen_random_uuid();
  oA uuid := gen_random_uuid();
  brA uuid := gen_random_uuid();
  bB uuid := gen_random_uuid();          -- a second tenant, for the cross-tenant refusal
  oB uuid := gen_random_uuid();
  brB uuid := gen_random_uuid();
  planA uuid := gen_random_uuid();
  pkgPlan uuid := gen_random_uuid();
  cPaused uuid := gen_random_uuid();     -- paused four months, then resumed
  cRunning uuid := gen_random_uuid();    -- never paused, four periods overdue
  cLegacy uuid := gen_random_uuid();     -- paused before v691 existed (no paused_at)
  cEnroll uuid := gen_random_uuid();     -- the F089 enrolment
  cPack uuid := gen_random_uuid();       -- the F134 package
  mPaused uuid;
  mRunning uuid;
  mLegacy uuid;
  v_pause_started constant timestamptz := now() - interval '4 months';
  v_period_end constant timestamptz := now() + interval '10 days';
  v_res jsonb;
  v_err text;
  v_msg text;
  v_row public.memberships%rowtype;
  v_sales integer;
  v_credits integer;
  v_sales2 integer;
  v_credits2 integer;
  v_key uuid;
  v_key_text text;
  v_res2 jsonb;
  v_n integer;
  v_pkg uuid;
begin
  perform pg_temp.as_v691_system();
  perform pg_temp.v691_tenant(bA,oA,brA,'Alpha');
  perform pg_temp.v691_tenant(bB,oB,brB,'Beta');

  insert into public.membership_plans(id,business_id,name,price_cents,cadence,credit_cents,
                                      discount_pct,active)
  values (planA,bA,'V691 Gold',8000,'monthly',6000,0,true);
  insert into public.package_plans(id,business_id,name,price_cents,sessions,active)
  values (pkgPlan,bA,'V691 Ten Cuts',20000,10,true);

  insert into public.clients(id,business_id,full_name,phone) values
    (cPaused,bA,'V691 Paused','+65 9691 0001'),
    (cRunning,bA,'V691 Running','+65 9691 0002'),
    (cLegacy,bA,'V691 Legacy Pause','+65 9691 0003'),
    (cEnroll,bA,'V691 Enrolment','+65 9691 0004'),
    (cPack,bA,'V691 Package','+65 9691 0005');

  -- Three memberships written directly: the pause LENGTH cannot be created inside one
  -- transaction, where now() is frozen, so the fixture places the clock and the RPC does the
  -- arithmetic. Every one of them has ten days of paid-for period left.
  insert into public.memberships(business_id,client_id,plan_id,status,started_at,
                                 current_period_start,current_period_end,paused_at)
  values (bA,cPaused,planA,'paused',now()-interval '5 months',
          v_period_end - interval '1 month', v_period_end, null)
  returning id into mPaused;
  insert into public.memberships(business_id,client_id,plan_id,status,started_at,
                                 current_period_start,current_period_end,paused_at)
  values (bA,cRunning,planA,'active',now()-interval '5 months',
          v_pause_started - interval '1 month', v_pause_started, null)
  returning id into mRunning;
  insert into public.memberships(business_id,client_id,plan_id,status,started_at,
                                 current_period_start,current_period_end,paused_at)
  values (bA,cLegacy,planA,'paused',now()-interval '5 months',
          v_period_end - interval '1 month', v_period_end, null)
  returning id into mLegacy;

  -- ------------------------------------------------------------------ 1. the pause records when
  -- mPaused was seeded 'paused' with no paused_at, which is also the legacy shape; take it back
  -- to 'active' first so the pause under test is a real transition made by the RPC.
  update public.memberships set status='active' where id=mPaused;
  perform pg_temp.as_v691_user(oA);
  v_err := null;
  begin
    v_res := public.set_membership_status(bA,mPaused,'paused');
  exception when others then
    v_err := sqlstate; v_msg := sqlerrm; v_res := null;
  end;
  perform pg_temp.as_v691_system();
  select * into v_row from public.memberships where id=mPaused;
  if v_err is null and v_row.status='paused' and v_row.paused_at = now()
     and v_row.current_period_end = v_period_end
     and v_row.current_period_start = v_period_end - interval '1 month' then
    insert into v691_out values (1,'F088 the pause records when it began and moves no period','PASS');
  else
    insert into v691_out values (1,'F088 the pause records when it began and moves no period',
      format('FAIL - sqlstate=%s message=%s status=%s paused_at=%s period=[%s,%s]',
             coalesce(v_err,'<none>'),coalesce(v_msg,''),v_row.status,
             coalesce(v_row.paused_at::text,'<null>'),
             v_row.current_period_start,v_row.current_period_end));
  end if;

  -- ------------------------------------------------------------------ 2. the resume gives it back
  update public.memberships set paused_at = v_pause_started where id=mPaused;
  perform pg_temp.as_v691_user(oA);
  v_err := null;
  begin
    v_res := public.set_membership_status(bA,mPaused,'active');
  exception when others then
    v_err := sqlstate; v_msg := sqlerrm; v_res := null;
  end;
  perform pg_temp.as_v691_system();
  select * into v_row from public.memberships where id=mPaused;
  if v_err is null and v_row.status='active' and v_row.paused_at is null
     and v_row.current_period_end = v_period_end + (now() - v_pause_started)
     and v_row.current_period_start
         = (v_period_end - interval '1 month') + (now() - v_pause_started)
     and (v_res->>'paused_days_returned')::numeric
         = round((extract(epoch from (now()-v_pause_started))/86400.0)::numeric,3) then
    insert into v691_out values (2,'F088 the resume returns exactly the time that was held','PASS');
  else
    insert into v691_out values (2,'F088 the resume returns exactly the time that was held',
      format('FAIL - sqlstate=%s message=%s result=%s period=[%s,%s] expected_end=%s',
             coalesce(v_err,'<none>'),coalesce(v_msg,''),coalesce(v_res::text,'<null>'),
             v_row.current_period_start,v_row.current_period_end,
             v_period_end + (now() - v_pause_started)));
  end if;

  -- ------------------------------------------------------------------ 3/4. the money, and the control
  perform pg_temp.as_v691_system();
  perform app.run_membership_renewals();

  select count(*) into v_sales from public.sales
   where business_id=bA and client_id=cPaused and kind='membership';
  select count(*) into v_credits from public.credit_ledger
   where business_id=bA and client_id=cPaused and entry_type='membership_credit';
  select count(*) into v_sales2 from public.sales
   where business_id=bA and client_id=cRunning and kind='membership';
  select count(*) into v_credits2 from public.credit_ledger
   where business_id=bA and client_id=cRunning and entry_type='membership_credit';

  if v_sales = 0 and v_credits = 0 then
    insert into v691_out values (3,'F088 the resumed membership is billed NOTHING by the cron','PASS');
  else
    insert into v691_out values (3,'F088 the resumed membership is billed NOTHING by the cron',
      format('FAIL - %s membership sale(s) and %s credit row(s) appeared for a pause nobody owed',
             v_sales,v_credits));
  end if;

  if v_sales2 = 5 and v_credits2 = 5 then
    insert into v691_out values (4,'F088 sensitivity: a genuinely overdue membership IS still caught up (5 periods)','PASS');
  else
    insert into v691_out values (4,'F088 sensitivity: a genuinely overdue membership IS still caught up (5 periods)',
      format('FAIL - the cron billed %s sale(s) and %s credit row(s); assertion 3 may be passing on a cron that does nothing',
             v_sales2,v_credits2));
  end if;

  -- ------------------------------------------------------------------ 5. an unrelated status change
  perform pg_temp.as_v691_system();
  select * into v_row from public.memberships where id=mPaused;
  perform pg_temp.as_v691_user(oA);
  v_err := null;
  begin
    v_res := public.set_membership_status(bA,mPaused,'cancel_at_period_end');
  exception when others then
    v_err := sqlstate; v_msg := sqlerrm; v_res := null;
  end;
  perform pg_temp.as_v691_system();
  if v_err is null and (v_res->>'paused_days_returned')::numeric = 0
     and exists (select 1 from public.memberships m
                  where m.id=mPaused and m.status='cancel_at_period_end'
                    and m.current_period_start = v_row.current_period_start
                    and m.current_period_end = v_row.current_period_end
                    and m.paused_at is null) then
    insert into v691_out values (5,'F088 negative: a status change that never touches pause shifts no period','PASS');
  else
    insert into v691_out values (5,'F088 negative: a status change that never touches pause shifts no period',
      format('FAIL - sqlstate=%s message=%s result=%s',
             coalesce(v_err,'<none>'),coalesce(v_msg,''),coalesce(v_res::text,'<null>')));
  end if;

  -- ------------------------------------------------------------------ 6. a pause from before v691
  perform pg_temp.as_v691_user(oA);
  v_err := null;
  begin
    v_res := public.set_membership_status(bA,mLegacy,'active');
  exception when others then
    v_err := sqlstate; v_msg := sqlerrm; v_res := null;
  end;
  perform pg_temp.as_v691_system();
  select * into v_row from public.memberships where id=mLegacy;
  if v_err is null and (v_res->>'paused_days_returned')::numeric = 0
     and v_row.current_period_end = v_period_end
     and v_row.current_period_start = v_period_end - interval '1 month' then
    insert into v691_out values (6,'F088 negative: a pause with no paused_at resumes with a zero shift, not a guess','PASS');
  else
    insert into v691_out values (6,'F088 negative: a pause with no paused_at resumes with a zero shift, not a guess',
      format('FAIL - sqlstate=%s message=%s result=%s period=[%s,%s]',
             coalesce(v_err,'<none>'),coalesce(v_msg,''),coalesce(v_res::text,'<null>'),
             v_row.current_period_start,v_row.current_period_end));
  end if;

  -- ------------------------------------------------------------------ 7. another tenant's owner
  perform pg_temp.as_v691_system();
  select * into v_row from public.memberships where id=mLegacy;
  perform pg_temp.as_v691_user(oB);
  v_err := null;
  begin
    v_res := public.set_membership_status(bA,mLegacy,'paused');
  exception when others then
    v_err := sqlstate; v_msg := sqlerrm; v_res := null;
  end;
  perform pg_temp.as_v691_system();
  if v_err = '42501'
     and exists (select 1 from public.memberships m
                  where m.id=mLegacy and m.status=v_row.status and m.paused_at is null) then
    insert into v691_out values (7,'F088 negative: another business''s owner is refused (42501) and the row stands','PASS');
  else
    insert into v691_out values (7,'F088 negative: another business''s owner is refused (42501) and the row stands',
      format('FAIL - sqlstate=%s message=%s',coalesce(v_err,'<none>'),coalesce(v_msg,'')));
  end if;

  -- ------------------------------------------------------------------ 8. F089 the enrolment replay
  perform pg_temp.as_v691_user(oA);
  v_key := gen_random_uuid();
  v_err := null;
  begin
    v_res := public.enroll_membership_v41(bA,cEnroll,planA,v_key)::jsonb;
    v_res2 := public.enroll_membership_v41(bA,cEnroll,planA,v_key)::jsonb;
  exception when others then
    v_err := sqlstate; v_msg := sqlerrm;
  end;
  perform pg_temp.as_v691_system();
  select count(*) into v_n from public.memberships where business_id=bA and client_id=cEnroll;
  select count(*) into v_sales from public.sales
   where business_id=bA and client_id=cEnroll and kind='membership';
  if v_err is null and (v_res->>'replayed') = 'false' and (v_res2->>'replayed') = 'true'
     and v_n = 1 and v_sales = 1 then
    insert into v691_out values (8,'F089 a membership enrolment marks fresh vs replay, and enrols once','PASS');
  else
    insert into v691_out values (8,'F089 a membership enrolment marks fresh vs replay, and enrols once',
      format('FAIL - sqlstate=%s message=%s first=%s second=%s memberships=%s sales=%s',
             coalesce(v_err,'<none>'),coalesce(v_msg,''),
             coalesce(v_res->>'replayed','<absent>'),coalesce(v_res2->>'replayed','<absent>'),
             v_n,v_sales));
  end if;

  -- ------------------------------------------------------------------ 9. F134 the package sale replay
  perform pg_temp.as_v691_user(oA);
  v_key := gen_random_uuid();
  v_err := null;
  begin
    v_res := public.sell_package_v102(bA,cPack,pkgPlan,brA,v_key);
    v_res2 := public.sell_package_v102(bA,cPack,pkgPlan,brA,v_key);
  exception when others then
    v_err := sqlstate; v_msg := sqlerrm;
  end;
  perform pg_temp.as_v691_system();
  select count(*) into v_n from public.client_packages where business_id=bA and client_id=cPack;
  select count(*) into v_sales from public.sales
   where business_id=bA and client_id=cPack and kind='package';
  if v_err is null and (v_res->>'replayed') = 'false' and (v_res2->>'replayed') = 'true'
     and v_n = 1 and v_sales = 1 then
    v_pkg := (v_res->>'client_package_id')::uuid;
    insert into v691_out values (9,'F134 a package sale marks fresh vs replay, and sells once','PASS');
  else
    insert into v691_out values (9,'F134 a package sale marks fresh vs replay, and sells once',
      format('FAIL - sqlstate=%s message=%s first=%s second=%s packages=%s sales=%s',
             coalesce(v_err,'<none>'),coalesce(v_msg,''),
             coalesce(v_res->>'replayed','<absent>'),coalesce(v_res2->>'replayed','<absent>'),
             v_n,v_sales));
  end if;

  -- ------------------------------------------------------------------ 10. F134 the session replay
  perform pg_temp.as_v691_user(oA);
  v_key_text := 'v691-session-'||replace(gen_random_uuid()::text,'-','');
  v_err := null;
  begin
    v_res := public.use_package_session_v102(bA,v_pkg,brA,v_key_text);
    v_res2 := public.use_package_session_v102(bA,v_pkg,brA,v_key_text);
  exception when others then
    v_err := sqlstate; v_msg := sqlerrm;
  end;
  perform pg_temp.as_v691_system();
  select remaining into v_n from public.client_packages where id=v_pkg;
  select count(*) into v_sales from public.package_session_consumptions
   where business_id=bA and client_package_id=v_pkg;
  if v_err is null and (v_res->>'replayed') = 'false' and (v_res2->>'replayed') = 'true'
     and v_n = 9 and v_sales = 1 then
    insert into v691_out values (10,'F134 a package session marks fresh vs replay, and decrements once','PASS');
  else
    insert into v691_out values (10,'F134 a package session marks fresh vs replay, and decrements once',
      format('FAIL - sqlstate=%s message=%s first=%s second=%s remaining=%s consumptions=%s',
             coalesce(v_err,'<none>'),coalesce(v_msg,''),
             coalesce(v_res->>'replayed','<absent>'),coalesce(v_res2->>'replayed','<absent>'),
             v_n,v_sales));
  end if;
end
$v691_test$;

select seq, step, outcome from v691_out order by seq;

/* The report above is printed first so a human sees WHICH assertion failed; this block then
   makes the failure fatal. It matters because scripts/db-tests/run.mjs judges a file purely by
   psql's exit code — a suite that only records FAIL rows is reported green. */
do $v691_gate$
declare
  v_bad integer;
  v_all integer;
begin
  select count(*) filter (where outcome not like 'PASS%'), count(*) into v_bad, v_all from v691_out;
  if v_all <> 10 then
    raise exception 'nestly_v691: % of 10 assertions ran — the suite aborted early', v_all;
  end if;
  if v_bad > 0 then
    raise exception 'nestly_v691: % assertion(s) FAILED — see the report above', v_bad;
  end if;
end
$v691_gate$;

rollback;
