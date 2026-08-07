-- Rollback-only v200a acceptance: the revenue engine is genuinely scheduled,
-- and the schedule points at the real posting function.
begin;

do $v200a$
declare v_n int; v_command text; v_schedule text; v_active boolean;
begin
  select count(*) into v_n from cron.job
   where jobname = 'platform-subscription-revenue-v200';
  if v_n <> 1 then
    raise exception 'A: expected exactly one revenue cron job, found %', v_n;
  end if;

  select command, schedule, active into v_command, v_schedule, v_active
    from cron.job where jobname = 'platform-subscription-revenue-v200';

  -- It must call the posting RPC, not something that merely looks like it.
  if v_command not like '%platform_run_subscription_revenue_v200%' then
    raise exception 'B: cron job does not call the revenue RPC: %', v_command;
  end if;
  if not v_active then
    raise exception 'C: revenue cron job is scheduled but inactive';
  end if;

  -- 16:20 UTC is 00:20 SGT — just after midnight in Singapore, so a month of
  -- service that begins today is recognised today rather than a day late.
  if v_schedule <> '20 16 * * *' then
    raise exception 'D: expected daily 20 16 * * * (00:20 SGT), got %', v_schedule;
  end if;

  raise notice 'v200a revenue schedule: all assertions passed (% at %)', v_command, v_schedule;
end
$v200a$;

rollback;
