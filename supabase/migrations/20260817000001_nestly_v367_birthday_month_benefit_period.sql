-- NESTLY v367 — a tier benefit may be limited to the customer's BIRTHDAY MONTH.
--
-- OWNER RULING 2026-08-17 (photo 2, on the v365 limit control): "add during birthday month
-- (because there are birthday rewards given) and set how many times (example 1 time)".
--
-- v365 shipped five periods — day/week/month/year/ever — all of which are the same window for
-- every customer. A birthday benefit is the first one that is a DIFFERENT window per customer,
-- and the owner's own tiers already carry lines like "Birthday free 1 main" that were being
-- counted per calendar month, i.e. claimable twelve times a year. This closes that.
--
-- SHAPE. 'birthday_month' is a sixth period, not a second mechanism:
--   * the period KEY stays the calendar month bucket (YYYY-MM in SGT), so "1 per birthday month"
--     counts exactly like "1 per month" — one claim inside the month it applies to;
--   * eligibility gains one test at issue time: the client's birth_date month must BE the current
--     SGT month. Outside it the benefit is simply not claimable, which is what the words promise.
-- Doing it this way means no new table, no second counter, and the existing idempotency, advisory
-- lock and audit path are unchanged.
--
-- A CLIENT WITH NO BIRTH DATE cannot claim it. That is deliberate and it is refused loudly
-- ('tier_benefit_birthday_unknown'), not silently allowed: guessing would hand a yearly gift to
-- every customer whose profile happens to be incomplete, every month.
--
-- APPLIED 2026-08-17 to gadpooereceldfpfxsod, after a rolled-back rehearsal of this file plus
-- db/tests/v365_tier_benefit_limits.sql together.

begin;

alter table public.tier_benefits_v365
  drop constraint if exists tier_benefits_v365_limit_period_check;
alter table public.tier_benefits_v365
  add constraint tier_benefits_v365_limit_period_check
  check (limit_period in ('day','week','month','year','ever','birthday_month'));

-- The bucket is the calendar month; only ELIGIBILITY differs. Kept in one place so the counter
-- and the wording cannot disagree about what "a birthday month" is.
create or replace function app.v365_period_key(p_period text, p_at timestamptz)
returns text language sql immutable
set search_path to 'pg_catalog','pg_temp'
as $$
  select case coalesce(p_period,'month')
    when 'ever' then 'ever'
    when 'day' then to_char(timezone('Asia/Singapore',p_at),'YYYY-MM-DD')
    when 'week' then to_char(timezone('Asia/Singapore',p_at),'IYYY-"W"IW')
    when 'year' then to_char(timezone('Asia/Singapore',p_at),'YYYY')
    else to_char(timezone('Asia/Singapore',p_at),'YYYY-MM')
  end
$$;
revoke all on function app.v365_period_key(text,timestamptz) from public, anon, authenticated;

create or replace function app.v365_benefit_sentence(p_label text, p_limit integer, p_period text)
returns text language sql immutable
set search_path to 'pg_catalog','pg_temp'
as $$
  select btrim(p_label) || case
    when p_limit is null and coalesce(p_period,'month')='birthday_month' then ' — during their birthday month'
    when p_limit is null then ''
    when coalesce(p_period,'month')='birthday_month' then ' — '||p_limit||' during their birthday month'
    when coalesce(p_period,'month')='ever' then ' — '||p_limit||' in total'
    else ' — '||p_limit||' per '||coalesce(p_period,'month')
  end
$$;
revoke all on function app.v365_benefit_sentence(text,integer,text) from public, anon, authenticated;

-- Is this client inside their own birthday month, in Singapore time?
create or replace function app.v367_in_birthday_month(p_client uuid, p_at timestamptz)
returns boolean language sql stable
set search_path to 'pg_catalog','public','pg_temp'
as $$
  select c.birth_date is not null
     and extract(month from c.birth_date) = extract(month from timezone('Asia/Singapore',p_at))
    from public.clients c where c.id = p_client
$$;
revoke all on function app.v367_in_birthday_month(uuid,timestamptz) from public, anon, authenticated;

-- The owner-side writer validates the period list in its own body as well as in the table
-- constraint (deliberately: it answers with a sentence an owner can read, not a check violation).
-- Both had to move, and the rehearsal is what proved it — the constraint alone accepted the new
-- period while the RPC still refused it.
create or replace function public.business_set_tier_benefits_v365(
  p_business uuid, p_tier uuid, p_benefits jsonb)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_item jsonb;
  v_index integer := 0;
  v_keep uuid[] := array[]::uuid[];
  v_id uuid;
  v_label text;
  v_limit integer;
  v_period text;
begin
  if not app.c45_owner_loyalty_write(p_business) then
    raise exception 'owner loyalty configuration access required' using errcode='42501';
  end if;
  perform 1 from public.loyalty_tiers where id=p_tier and business_id=p_business;
  if not found then
    raise exception 'tier not found in this business' using errcode='42704';
  end if;
  if p_benefits is not null and jsonb_typeof(p_benefits) <> 'array' then
    raise exception 'benefits must be an array' using errcode='22023';
  end if;

  for v_item in select * from jsonb_array_elements(coalesce(p_benefits,'[]'::jsonb)) loop
    v_label := nullif(btrim(coalesce(v_item->>'label','')),'');
    if v_label is null then
      raise exception 'every benefit needs a description' using errcode='22023';
    end if;
    v_limit := nullif(v_item->>'limit_count','')::integer;
    v_period := coalesce(nullif(btrim(coalesce(v_item->>'limit_period','')),''),'month');
    if v_period not in ('day','week','month','year','ever','birthday_month') then
      raise exception 'benefit period is not one of day/week/month/year/ever/birthday_month' using errcode='22023';
    end if;
    if v_limit is not null and (v_limit < 1 or v_limit > 10000) then
      raise exception 'a benefit limit must be between 1 and 10000' using errcode='22023';
    end if;
    v_id := nullif(v_item->>'id','')::uuid;
    if v_id is not null then
      update public.tier_benefits_v365
         set label=v_label, limit_count=v_limit, limit_period=v_period, sort=v_index,
             active=true, deleted_at=null, updated_at=now(), updated_by=auth.uid()
       where id=v_id and business_id=p_business and tier_id=p_tier;
      if not found then
        raise exception 'benefit not found on this tier' using errcode='42704';
      end if;
    else
      insert into public.tier_benefits_v365(business_id,tier_id,label,limit_count,limit_period,sort,updated_by)
      values(p_business,p_tier,v_label,v_limit,v_period,v_index,auth.uid())
      returning id into v_id;
    end if;
    v_keep := v_keep || v_id;
    v_index := v_index + 1;
  end loop;

  update public.tier_benefits_v365
     set deleted_at=now(), active=false, updated_at=now(), updated_by=auth.uid()
   where business_id=p_business and tier_id=p_tier and deleted_at is null
     and not (id = any(v_keep));

  perform app.v365_apply_perk_note(p_business,p_tier);

  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(p_business,auth.uid(),'tier_benefits.set','loyalty_tiers',p_tier,
    jsonb_build_object('count',v_index));

  return jsonb_build_object('status','ok','tier_id',p_tier,'count',v_index,
    'perk_note',(select perk_note from public.loyalty_tiers where id=p_tier and business_id=p_business));
end $$;
revoke all privileges on function public.business_set_tier_benefits_v365(uuid,uuid,jsonb) from public, anon, authenticated;
grant execute on function public.business_set_tier_benefits_v365(uuid,uuid,jsonb) to authenticated;

-- The till read gains the two facts the counter needs to explain itself: whether this benefit is
-- claimable right now, and why not when it is not.
create or replace function public.staff_tier_benefits_for_client_v365(p_business uuid, p_client uuid)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_tier public.loyalty_tiers%rowtype;
  v_rows jsonb;
  v_birthday boolean;
begin
  if auth.uid() is null then raise exception 'authenticated staff required' using errcode='42501'; end if;
  if not (app.is_salon_owner(p_business) or app.can_module_read(p_business,'till')
          or app.can_module_read(p_business,'loyalty')) then
    raise exception 'till or loyalty access required' using errcode='42501';
  end if;
  perform 1 from public.clients where id=p_client and business_id=p_business;
  if not found then raise exception 'client not found in this business' using errcode='42704'; end if;

  v_tier := app.v365_client_tier(p_business,p_client);
  if v_tier.id is null then
    return jsonb_build_object('status','ok','tier',null,'benefits','[]'::jsonb);
  end if;
  v_birthday := coalesce(app.v367_in_birthday_month(p_client, now()), false);

  select coalesce(jsonb_agg(jsonb_build_object(
      'benefit_id',b.id,'tier_id',b.tier_id,'tier_label',t.name,'label',b.label,
      'limit_count',b.limit_count,'limit_period',b.limit_period,
      'sentence',app.v365_benefit_sentence(b.label,b.limit_count,b.limit_period),
      'used',used.count_in_period,
      'remaining',case when b.limit_count is null then null
                       else greatest(0,b.limit_count-used.count_in_period) end,
      -- V367: a birthday benefit is only claimable inside the customer's own birthday month.
      'claimable_now',(b.limit_period<>'birthday_month' or v_birthday),
      'blocked_reason',case when b.limit_period='birthday_month' and not v_birthday
                            then 'not_birthday_month' else null end
    ) order by t.threshold desc, b.sort, b.id),'[]'::jsonb) into v_rows
    from public.tier_benefits_v365 b
    join public.loyalty_tiers t on t.id=b.tier_id and t.business_id=b.business_id
    cross join lateral (
      select count(*)::integer as count_in_period from public.tier_benefit_issues_v365 i
       where i.benefit_id=b.id and i.client_id=p_client
         and i.period_key=app.v365_period_key(b.limit_period,now())
    ) used
   where b.business_id=p_business and b.deleted_at is null and b.active
     and t.threshold<=v_tier.threshold
     and (t.effective_from is null or t.effective_from<=statement_timestamp())
     and (t.expires_at is null or t.expires_at>statement_timestamp());

  return jsonb_build_object('status','ok',
    'tier',jsonb_build_object('id',v_tier.id,'label',v_tier.name,'threshold',v_tier.threshold),
    'in_birthday_month',v_birthday,
    'benefits',v_rows);
end $$;
revoke all privileges on function public.staff_tier_benefits_for_client_v365(uuid,uuid) from public, anon;
grant execute on function public.staff_tier_benefits_for_client_v365(uuid,uuid) to authenticated;

create or replace function public.staff_issue_tier_benefit_v365(
  p_business uuid, p_client uuid, p_benefit uuid,
  p_branch uuid default null, p_idempotency_key uuid default null)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_key uuid := coalesce(p_idempotency_key, gen_random_uuid());
  v_benefit public.tier_benefits_v365%rowtype;
  v_tier public.loyalty_tiers%rowtype;
  v_benefit_tier public.loyalty_tiers%rowtype;
  v_period_key text;
  v_used integer;
  v_existing public.tier_benefit_issues_v365%rowtype;
  v_id uuid;
  v_birth date;
begin
  if v_actor is null then raise exception 'authenticated staff required' using errcode='42501'; end if;
  if not (app.is_salon_owner(p_business) or app.can_module_write(p_business,'till')
          or app.can_module_write(p_business,'loyalty')) then
    raise exception 'till or loyalty write authorization required' using errcode='42501';
  end if;

  select * into v_benefit from public.tier_benefits_v365
   where id=p_benefit and business_id=p_business and deleted_at is null and active;
  if not found then raise exception 'tier_benefit_not_found' using errcode='42704'; end if;
  select * into v_benefit_tier from public.loyalty_tiers where id=v_benefit.tier_id and business_id=p_business;
  if not found then raise exception 'tier_benefit_not_found' using errcode='42704'; end if;

  -- Replay BEFORE the limit check: a double-tap must return the first issue, never be counted as
  -- a second one and never be reported as "limit reached".
  select * into v_existing from public.tier_benefit_issues_v365
   where benefit_id=p_benefit and client_id=p_client and idem_key=v_key;
  if found then
    return jsonb_build_object('status','duplicate_ignored','issue_id',v_existing.id,
      'label',v_existing.label,'period_key',v_existing.period_key);
  end if;

  -- One customer, one benefit, one period at a time: two counters racing would both read "0 used".
  perform pg_advisory_xact_lock(hashtextextended('v365:issue:'||p_benefit::text||':'||p_client::text,0));

  v_tier := app.v365_client_tier(p_business,p_client);
  if v_tier.id is null or v_tier.threshold < v_benefit_tier.threshold then
    raise exception 'tier_benefit_not_earned' using errcode='42501';
  end if;

  -- V367: the birthday-month test. Refused loudly when the profile carries no birth date rather
  -- than allowed — see the migration header.
  if v_benefit.limit_period='birthday_month' then
    select birth_date into v_birth from public.clients where id=p_client and business_id=p_business;
    if v_birth is null then
      raise exception 'tier_benefit_birthday_unknown' using errcode='22023';
    end if;
    if not app.v367_in_birthday_month(p_client, now()) then
      raise exception 'tier_benefit_not_birthday_month' using errcode='22023';
    end if;
  end if;

  v_period_key := app.v365_period_key(v_benefit.limit_period, now());
  if v_benefit.limit_count is not null then
    select count(*) into v_used from public.tier_benefit_issues_v365
     where benefit_id=p_benefit and client_id=p_client and period_key=v_period_key;
    if v_used >= v_benefit.limit_count then
      raise exception 'tier_benefit_limit_reached' using errcode='22023';
    end if;
  end if;

  if p_branch is not null then
    perform 1 from public.branches branch
     where branch.id=p_branch and branch.business_id=p_business and branch.active
       and app.can_see_branch(p_business, branch.id);
    if not found then raise exception 'tier_benefit_branch_not_permitted' using errcode='42501'; end if;
  end if;

  insert into public.tier_benefit_issues_v365(
    business_id,benefit_id,client_id,tier_id,label,limit_count,limit_period,period_key,
    branch_id,issued_by,idem_key)
  values(p_business,p_benefit,p_client,v_benefit.tier_id,v_benefit.label,v_benefit.limit_count,
    v_benefit.limit_period,v_period_key,p_branch,v_actor,v_key)
  returning id into v_id;

  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(p_business,v_actor,'TIER_BENEFIT_ISSUED_V365','tier_benefit_issues_v365',v_id,
    jsonb_build_object('client_id',p_client,'benefit_id',p_benefit,'label',v_benefit.label,
                       'period_key',v_period_key,'branch_id',p_branch));

  return jsonb_build_object('status','issued','issue_id',v_id,'label',v_benefit.label,
    'period_key',v_period_key,
    'remaining',case when v_benefit.limit_count is null then null
      else greatest(0,v_benefit.limit_count-(
        select count(*) from public.tier_benefit_issues_v365
         where benefit_id=p_benefit and client_id=p_client and period_key=v_period_key)) end);
end $$;
revoke all privileges on function public.staff_issue_tier_benefit_v365(uuid,uuid,uuid,uuid,uuid) from public, anon;
grant execute on function public.staff_issue_tier_benefit_v365(uuid,uuid,uuid,uuid,uuid) to authenticated;

-- Existing benefit rows are untouched: nothing is auto-converted to 'birthday_month', because
-- which of an owner's lines is a birthday perk is their judgement, not a string match on "birthday".

commit;
