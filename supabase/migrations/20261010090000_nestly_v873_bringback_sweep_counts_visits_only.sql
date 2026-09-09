-- nestly_v873 — the Bring-back sweep measures "away" from the last VISIT, not the last sale row.
--
-- WHAT WAS LIVE, AND WHY IT IS WRONG. app.issue_bringback_for_business_v361 (the nightly sweep
-- that issues absence-triggered vouchers) said in its own comment that "away for the stated
-- period" uses THE SAME definition as the Gone-quiet report — and did not. The report
-- (public.retention_lapsed_candidates_v244) counts `counts_as_visit = true`, judges reversals
-- and synthetic clients through app.analytics_sale_class_v1, and measures from `occurred_at`
-- in Singapore days. The sweep counted every non-reversed sale row of any kind and measured
-- from `created_at`. So an automatic membership renewal, a gift-card issue or a package
-- purchase — none of which is a visit under the firm's sale policy — reset the customer's
-- "last seen" and silently suppressed the voucher the Gone-quiet report said they were due.
-- A back-dated sale (occurred_at in the past, created_at today) did the same.
--
-- THE FIX. The sweep now reads exactly the report's predicate: valid original sales that count
-- as a visit, synthetic clients excluded by the shared classifier, "last seen" = the Singapore
-- day of the latest qualifying occurred_at. Everything else — one grant per campaign per
-- last-seen cycle, expiry, the reward label — is unchanged.

begin;

create or replace function app.issue_bringback_for_business_v361(p_business uuid)
returns integer
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_campaign public.bringback_campaigns_v361%rowtype;
  v_issued integer := 0;
  v_rows integer;
begin
  for v_campaign in
    select * from public.bringback_campaigns_v361
     where business_id=p_business and active and deleted_at is null
  loop
    -- "Away for the stated period" uses the SAME definition as the Gone-quiet report the owner
    -- already reads (public.retention_lapsed_candidates_v244): the last VALID sale that counts
    -- as a visit, older than away_days. Anyone with no visit at all is excluded — they never
    -- came, so there is nothing to bring them back from.
    -- nestly_v873: counts_as_visit, occurred_at and the shared sale classifier — the sweep used
    -- to count every sale row (membership renewals, gift cards, packages) from created_at, and
    -- so suppressed vouchers the report said were due.
    insert into public.bringback_grants_v361(
      business_id,campaign_id,client_id,reward_label,away_days,cycle_key,expires_at)
    select p_business, v_campaign.id, last_seen.client_id, v_campaign.reward_label,
           v_campaign.away_days, last_seen.last_day,
           case when v_campaign.expiry_days is null then null
                else now() + make_interval(days => v_campaign.expiry_days) end
      from (
        -- nestly_v685: the cycle_key and the customer-visible "last seen" day are Singapore
        -- days. The UTC day filed a customer last seen between midnight and 08:00 SGT under
        -- the previous day, which is both a wrong date on screen and a second dedupe cycle.
        select s.client_id, app.sg_day(max(s.occurred_at)) as last_day
          from public.sales s
          cross join lateral app.analytics_sale_class_v1(s) sc
         where s.business_id=p_business and s.client_id is not null
           and sc.include_visit
           and not sc.is_synthetic_client
         group by s.client_id
        having max(s.occurred_at) < now() - make_interval(days => v_campaign.away_days)
      ) last_seen
    on conflict (campaign_id, client_id, cycle_key) do nothing;
    get diagnostics v_rows = row_count;
    v_issued := v_issued + v_rows;
  end loop;
  return v_issued;
end $function$;

-- ACL restated verbatim from prod (nestly_v873): the nightly runner only.
revoke all on function app.issue_bringback_for_business_v361(uuid) from public;
grant execute on function app.issue_bringback_for_business_v361(uuid) to service_role;

do $verify$
declare v_def text := pg_get_functiondef('app.issue_bringback_for_business_v361(uuid)'::regprocedure);
begin
  if position('sc.include_visit' in v_def) = 0 or position('max(s.created_at)' in v_def) > 0 then
    raise exception 'nestly_v873: bring-back sweep still counts non-visit sales' using errcode = 'XX001';
  end if;
end
$verify$;

commit;
