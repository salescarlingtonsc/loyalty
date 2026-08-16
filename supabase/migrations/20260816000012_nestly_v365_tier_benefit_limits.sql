-- NESTLY v365 — tier benefits become countable entitlements: a stated LIMIT per period, and a
--               merchant scan that issues one and refuses the one after the limit.
--
-- OWNER RULING 2026-08-16 (photo 4, on the multi-benefit tier editor shipped as v363):
--   "every rewards '30% off / 1 for 1 deals' - all these needs to set a limit (like 30times per
--    month or 1 time per month - must be stated clearly) and there must be a qrcode for merchant
--    to scan and issue the rewards."
-- Asked whether the limit should merely be STATED or actually ENFORCED, the owner chose
-- "fully enforced": the scan checks the customer's usage in the current period and refuses when
-- it is used up.
--
-- WHY A TABLE AND NOT MORE TEXT. v363 stored a tier's benefits as newline-separated lines in
-- loyalty_tiers.perk_note, which every customer read path already splits into chips. A LIMIT is
-- not copy — something has to count against it — so the benefit becomes a row. perk_note is NOT
-- abandoned and NOT duplicated: this migration makes it a DERIVED column. app.v365_apply_perk_note
-- rewrites it from the rows on every write, so the sentence a customer reads
-- ("30% off every visit — 1 per month") is generated from the very numbers the enforcement uses.
-- One writer, so the promise and the rule cannot drift — the failure this repo has hit three
-- times (V352 spine vs column, V353 model vs spine, V364 image written but never read).
--
-- ELIGIBILITY IS INHERITED DOWN THE LADDER. A benefit attached to Gold is claimable by anyone at
-- Gold OR ABOVE (threshold comparison, not tier equality). A ladder is cumulative in every
-- customer's mental model — a Diamond member being refused a Gold perk would read as a bug — and
-- the alternative (equality) would silently strip perks from the customers who spend most.
-- Stated here because it is a product decision, not an implementation detail.
--
-- ISSUING MOVES NO MONEY AND WRITES NO SALE. Unlike the bring-back voucher (v361), which is a free
-- item and therefore a $0 visit, a tier benefit is a discount or an extra applied to a purchase
-- the customer is making anyway; that purchase is its own sale. Inserting one here would invent a
-- second visit for one transaction — the same double-count v9/v10 exist to prevent.
--
-- NOT YET APPLIED to gadpooereceldfpfxsod. The session that wrote it had no database access; the
-- verification block at the foot lists exactly what to run in a rolled-back transaction first.

begin;

create table if not exists public.tier_benefits_v365(
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  -- No composite (id,business_id) FK: public.loyalty_tiers has no such unique constraint. The
  -- definer RPCs below are the only writers and each one proves the tier belongs to the business
  -- before it writes, which is the same guarantee a composite key would have given.
  tier_id uuid not null references public.loyalty_tiers(id) on delete cascade,
  label text not null,
  -- null = unlimited. The owner's examples ("30 times per month", "1 time per month") are the
  -- count/period pair; 'ever' is the once-in-a-lifetime case a birthday-style perk needs.
  limit_count integer,
  limit_period text not null default 'month',
  sort integer not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid,
  deleted_at timestamptz,
  constraint tier_benefits_v365_label_check check (length(btrim(label)) between 1 and 120),
  constraint tier_benefits_v365_limit_count_check check (limit_count is null or limit_count between 1 and 10000),
  constraint tier_benefits_v365_limit_period_check check (limit_period in ('day','week','month','year','ever')),
  constraint tier_benefits_v365_sort_check check (sort between 0 and 10000)
);
create index if not exists tier_benefits_v365_tier_idx
  on public.tier_benefits_v365(business_id, tier_id, sort) where deleted_at is null;

create table if not exists public.tier_benefit_issues_v365(
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  benefit_id uuid not null references public.tier_benefits_v365(id) on delete cascade,
  client_id uuid not null references public.clients(id) on delete cascade,
  tier_id uuid not null,
  -- Snapshot of the benefit as promised at the moment it was given, so an owner later editing
  -- "10% off" to "5% off" never rewrites what a customer was already handed (v215/v361's rule).
  label text not null,
  limit_count integer,
  limit_period text not null,
  -- The bucket the limit counts within: '2026-08' for a monthly limit, 'ever' for a lifetime one.
  -- Stored rather than derived at read time so a later timezone or period change cannot silently
  -- re-open a limit that was already spent.
  period_key text not null,
  branch_id uuid references public.branches(id) on delete set null,
  issued_at timestamptz not null default now(),
  issued_by uuid,
  idem_key uuid not null
);
-- Double-tap protection: the same scan repeated returns the first issue instead of a second one.
create unique index if not exists tier_benefit_issues_v365_idem_uk
  on public.tier_benefit_issues_v365(benefit_id, client_id, idem_key);
create index if not exists tier_benefit_issues_v365_period_idx
  on public.tier_benefit_issues_v365(business_id, benefit_id, client_id, period_key);

revoke all on public.tier_benefits_v365 from public, anon, authenticated;
revoke all on public.tier_benefit_issues_v365 from public, anon, authenticated;
grant select on public.tier_benefits_v365 to authenticated;
grant select on public.tier_benefit_issues_v365 to authenticated;

alter table public.tier_benefits_v365 enable row level security;
alter table public.tier_benefit_issues_v365 enable row level security;
drop policy if exists tier_benefits_v365_read on public.tier_benefits_v365;
drop policy if exists tier_benefit_issues_v365_read on public.tier_benefit_issues_v365;
-- SELECT-only for staff of the owning business; every write goes through the definer RPCs.
create policy tier_benefits_v365_read on public.tier_benefits_v365 for select using (
  app.is_super_admin() or app.can_module_read(business_id,'loyalty') or app.can_module_read(business_id,'till'));
create policy tier_benefit_issues_v365_read on public.tier_benefit_issues_v365 for select using (
  app.is_super_admin() or app.can_module_read(business_id,'loyalty') or app.can_module_read(business_id,'till'));

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
-- Singapore time, deliberately: this is a Singapore-first product and a "1 per month" limit has to
-- roll over when the shop's month rolls over, not when UTC's does.
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

-- The customer-facing sentence for one benefit row. This is the ONLY place the limit is put into
-- words, so the chip a customer reads and the rule the till enforces are the same fact.
create or replace function app.v365_benefit_sentence(p_label text, p_limit integer, p_period text)
returns text language sql immutable
set search_path to 'pg_catalog','pg_temp'
as $$
  select btrim(p_label) || case
    when p_limit is null then ''
    when coalesce(p_period,'month')='ever' then ' — '||p_limit||' in total'
    else ' — '||p_limit||' per '||coalesce(p_period,'month')
  end
$$;
revoke all on function app.v365_benefit_sentence(text,integer,text) from public, anon, authenticated;

-- perk_note is derived, never typed, from here on. Called by every writer below.
create or replace function app.v365_apply_perk_note(p_business uuid, p_tier uuid)
returns void language plpgsql
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  update public.loyalty_tiers t
     set perk_note = nullif((
       select string_agg(app.v365_benefit_sentence(b.label,b.limit_count,b.limit_period), E'\n' order by b.sort, b.created_at, b.id)
         from public.tier_benefits_v365 b
        where b.business_id=p_business and b.tier_id=p_tier and b.deleted_at is null and b.active),'')
   where t.id=p_tier and t.business_id=p_business;
end $$;
revoke all on function app.v365_apply_perk_note(uuid,uuid) from public, anon, authenticated;

-- A client's current rung, by the business's own tier_basis. Same metric definitions as
-- public.customer_get_effective_tier_v143 (v186) — deliberately the same three branches, so the
-- tier the till acts on is the tier the customer is shown in their app.
create or replace function app.v365_client_tier(p_business uuid, p_client uuid)
returns public.loyalty_tiers language plpgsql stable
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_basis text;
  v_metric numeric := 0;
  v_tier public.loyalty_tiers%rowtype;
begin
  select coalesce(tier_basis,'visits') into v_basis
    from public.loyalty_programs where business_id=p_business and active limit 1;
  if v_basis='spend' then
    select coalesce(sum(amount_cents),0)/100.0 into v_metric from public.sales
     where business_id=p_business and client_id=p_client and counts_as_revenue;
  elsif v_basis='points_earned' then
    select coalesce(sum(points),0) into v_metric from public.points_ledger
     where business_id=p_business and client_id=p_client and entry_type='earn';
  else
    select count(*) into v_metric from public.sales
     where business_id=p_business and client_id=p_client and counts_as_visit;
  end if;
  select * into v_tier from public.loyalty_tiers
   where business_id=p_business and threshold<=v_metric
     and (effective_from is null or effective_from<=statement_timestamp())
     and (expires_at is null or expires_at>statement_timestamp())
   order by threshold desc, sort desc, id limit 1;
  return v_tier;
end $$;
revoke all on function app.v365_client_tier(uuid,uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Owner write: replace one tier's benefit list
-- ---------------------------------------------------------------------------
-- Replace-all, because that is what the editor is: the owner sees the whole list and presses Save.
-- Rows absent from the payload are SOFT-deleted, never hard-deleted — tier_benefit_issues_v365
-- rows reference them, and a hard delete would cascade away the record that a customer was given
-- something. History outlives the copy.
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
    if v_period not in ('day','week','month','year','ever') then
      raise exception 'benefit period is not one of day/week/month/year/ever' using errcode='22023';
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

-- ---------------------------------------------------------------------------
-- Till: what may this customer claim right now, and give one
-- ---------------------------------------------------------------------------
create or replace function public.staff_tier_benefits_for_client_v365(p_business uuid, p_client uuid)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_tier public.loyalty_tiers%rowtype;
  v_rows jsonb;
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

  -- Inherited down the ladder: everything at or below the customer's own rung. See the header.
  select coalesce(jsonb_agg(jsonb_build_object(
      'benefit_id',b.id,'tier_id',b.tier_id,'tier_label',t.name,'label',b.label,
      'limit_count',b.limit_count,'limit_period',b.limit_period,
      'sentence',app.v365_benefit_sentence(b.label,b.limit_count,b.limit_period),
      'used',used.count_in_period,
      'remaining',case when b.limit_count is null then null
                       else greatest(0,b.limit_count-used.count_in_period) end
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

-- ---------------------------------------------------------------------------
-- Backfill: the v363 perk_note lines become rows, so nothing an owner already typed is lost.
-- Unlimited (limit_count null), because that is what those lines meant when they were written —
-- inventing a limit for them would enforce a rule the owner never set.
-- ---------------------------------------------------------------------------
insert into public.tier_benefits_v365(business_id,tier_id,label,limit_count,limit_period,sort)
select t.business_id, t.id, btrim(line.benefit), null, 'month', (line.ordinal-1)::integer
  from public.loyalty_tiers t
  cross join lateral regexp_split_to_table(coalesce(t.perk_note,''),E'\r?\n')
    with ordinality as line(benefit,ordinal)
 where btrim(line.benefit) <> ''
   and not exists (select 1 from public.tier_benefits_v365 b
                    where b.tier_id=t.id and b.deleted_at is null);

-- ============================================================================================
-- VERIFICATION — run these inside a rolled-back transaction against gadpooereceldfpfxsod first
-- ============================================================================================
--  1. owner sets three benefits on Gold (one unlimited, one "1 per month", one "30 per month")
--     -> three rows, and loyalty_tiers.perk_note reads
--        "10% off every visit\nBirthday free 1 main — 1 per month\n1 for 1 deals — 30 per month".
--  2. a non-owner staff calling business_set_tier_benefits_v365 -> 42501, nothing written.
--  3. limit_count 0 and limit_period 'fortnight' -> both refused 22023.
--  4. saving the list again without one row -> that row is soft-deleted (deleted_at set, the row
--     still there) and perk_note loses exactly that line.
--  5. a Gold client: staff_tier_benefits_for_client_v365 lists the Gold rows AND every lower rung's
--     rows; an Essential client sees only Essential's.
--  6. staff_issue_tier_benefit_v365 on the "1 per month" benefit -> status issued, remaining 0;
--     the SAME call with the same idempotency key -> duplicate_ignored, still one row;
--     a DIFFERENT key in the same month -> tier_benefit_limit_reached (22023), still one row.
--  7. an Essential client against a Gold benefit -> tier_benefit_not_earned (42501).
--  8. sales, points_ledger and credit_ledger totals identical before and after issuing.
--  9. the backfill leaves every existing perk_note byte-identical (rows in, same text out).
commit;
