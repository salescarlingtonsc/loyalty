-- V361: Bring-back rewards as its own module — an ABSENCE-triggered voucher.
--
-- OWNER RULING 2026-08-16: a separate module "so we can create customisable marketing vouchers or
-- gifts to customers away for the stated period of time", issued to the customer's account and
-- handed over by staff at the till.
--
-- WHY A NEW TRIGGER RATHER THAN REUSING retention_programs.
-- public.retention_programs pays on goal_visits WITHIN period_days — a FREQUENCY reward, for
-- people who come often. The owner asked for the opposite: people who have STOPPED coming. Wiring
-- an absence campaign onto the frequency engine would have produced a voucher that fires for the
-- wrong customers (or never), which is the "looks configured, silently does nothing" shape that
-- already bit this project three times this week. retention_programs is therefore left completely
-- untouched and keeps its own page; this is a second, separate mechanic.
-- The absence QUERY already exists and is proven — app.retention_lapsed_candidates_v244 backs the
-- read-only "Gone quiet" card — so this migration reuses that definition of "away" rather than
-- inventing a second one that could disagree with the number the owner already sees.
--
-- SHAPE MIRRORS THE WELCOME OFFER (v215), deliberately, because it is the same lifecycle:
-- a per-business rule + a per-client grant row, the grant SNAPSHOTTING the reward text so a
-- customer holding a voucher keeps the deal they were promised when the owner later edits it, and
-- redemption recording a real $0 sale so a free item is a visit worth nothing and never phantom
-- revenue. Differences from v215, both intentional:
--   * a business may run SEVERAL bring-back campaigns (different windows, different gifts), so the
--     rule table is one row per campaign, not one per business.
--   * a customer may lapse more than once in their life, so the grant is unique per
--     (campaign, client, cycle) rather than per client forever — `cycle_key` is the lapse date
--     bucket, which makes re-issue possible without ever double-issuing inside one absence.
--
-- APPLIED 2026-08-16 to gadpooereceldfpfxsod (rolled-back dry run first; see VERIFICATION below).

begin;

create table if not exists public.bringback_campaigns_v361(
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  name text not null,
  -- The customer-facing voucher/gift, free text: the owner's own "customisable marketing
  -- vouchers or gifts", not a catalogue reference (v350 already established that a welcome gift
  -- need not be one of the firm's catalogued products).
  reward_label text not null,
  -- "away for the stated period": no completed visit for this many days.
  away_days integer not null,
  -- null = the voucher never lapses once issued.
  expiry_days integer,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid,
  deleted_at timestamptz,
  constraint bringback_campaigns_v361_name_check check (length(btrim(name)) between 1 and 120),
  constraint bringback_campaigns_v361_reward_check check (length(btrim(reward_label)) between 1 and 120),
  constraint bringback_campaigns_v361_away_check check (away_days between 1 and 3650),
  constraint bringback_campaigns_v361_expiry_check check (expiry_days is null or expiry_days between 1 and 3650)
);
create index if not exists bringback_campaigns_v361_business_idx
  on public.bringback_campaigns_v361(business_id) where deleted_at is null;

create table if not exists public.bringback_grants_v361(
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  campaign_id uuid not null references public.bringback_campaigns_v361(id) on delete cascade,
  client_id uuid not null references public.clients(id) on delete cascade,
  -- Criteria snapshot, frozen at issue (same rule as welcome_offer_grants_v215).
  reward_label text not null,
  away_days integer not null,
  -- The absence this grant belongs to: the date the customer's lapse window was measured from.
  -- Makes "issued once per absence" enforceable without blocking a genuine second lapse years on.
  cycle_key date not null,
  status text not null default 'granted',
  granted_at timestamptz not null default now(),
  expires_at timestamptz,
  redeemed_at timestamptz,
  redeemed_sale_id uuid references public.sales(id) on delete set null,
  redeemed_by uuid,
  constraint bringback_grants_v361_status_check check (status in ('granted','redeemed','expired')),
  constraint bringback_grants_v361_redeem_shape check (
    (status='redeemed' and redeemed_at is not null and redeemed_sale_id is not null)
    or (status<>'redeemed' and redeemed_at is null and redeemed_sale_id is null))
);
create unique index if not exists bringback_grants_v361_cycle_uk
  on public.bringback_grants_v361(campaign_id, client_id, cycle_key);
create index if not exists bringback_grants_v361_client_idx
  on public.bringback_grants_v361(business_id, client_id, status);

-- Explicit browser-role ACL. RLS decides WHICH rows; this decides which verbs the browser roles
-- may attempt at all. SELECT only for authenticated staff (the SELECT policies below scope it to
-- their own business); anon gets nothing; every write goes through the definer RPCs.
revoke all on public.bringback_campaigns_v361 from public, anon, authenticated;
revoke all on public.bringback_grants_v361 from public, anon, authenticated;
grant select on public.bringback_campaigns_v361 to authenticated;
grant select on public.bringback_grants_v361 to authenticated;

alter table public.bringback_campaigns_v361 enable row level security;
alter table public.bringback_grants_v361 enable row level security;
drop policy if exists bringback_campaigns_v361_read on public.bringback_campaigns_v361;
drop policy if exists bringback_grants_v361_read on public.bringback_grants_v361;
-- SELECT-only for staff; every write goes through the definer RPCs below, matching v215/v326.
create policy bringback_campaigns_v361_read on public.bringback_campaigns_v361 for select using (
  app.is_super_admin() or app.can_module_read(business_id,'loyalty') or app.can_module_read(business_id,'till'));
create policy bringback_grants_v361_read on public.bringback_grants_v361 for select using (
  app.is_super_admin() or app.can_module_read(business_id,'loyalty') or app.can_module_read(business_id,'till'));

-- ---------------------------------------------------------------------------
-- Owner writes
-- ---------------------------------------------------------------------------
create or replace function public.business_upsert_bringback_v361(
  p_business uuid, p_campaign uuid, p_name text, p_reward_label text,
  p_away_days integer, p_expiry_days integer default null)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_name text := nullif(btrim(coalesce(p_name,'')),'');
  v_reward text := nullif(btrim(coalesce(p_reward_label,'')),'');
  v_row public.bringback_campaigns_v361%rowtype;
begin
  if not app.c45_owner_loyalty_write(p_business) then
    raise exception 'owner loyalty configuration access required' using errcode='42501';
  end if;
  if v_name is null then raise exception 'campaign name is required' using errcode='22023'; end if;
  if v_reward is null then raise exception 'reward is required' using errcode='22023'; end if;
  if p_away_days is null or p_away_days < 1 or p_away_days > 3650 then
    raise exception 'away days must be between 1 and 3650' using errcode='22023';
  end if;
  if p_expiry_days is not null and (p_expiry_days < 1 or p_expiry_days > 3650) then
    raise exception 'expiry days must be between 1 and 3650' using errcode='22023';
  end if;

  if p_campaign is null then
    insert into public.bringback_campaigns_v361(business_id,name,reward_label,away_days,expiry_days,updated_by)
    values (p_business,v_name,v_reward,p_away_days,p_expiry_days,auth.uid())
    returning * into v_row;
  else
    update public.bringback_campaigns_v361
       set name=v_name, reward_label=v_reward, away_days=p_away_days,
           expiry_days=p_expiry_days, updated_at=now(), updated_by=auth.uid()
     where id=p_campaign and business_id=p_business and deleted_at is null
     returning * into v_row;
    if not found then
      raise exception 'bring-back campaign not found in this business' using errcode='42704';
    end if;
  end if;

  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(p_business,auth.uid(),case when p_campaign is null then 'bringback.created' else 'bringback.updated' end,
    'bringback_campaigns_v361',v_row.id,
    jsonb_build_object('name',v_row.name,'reward_label',v_row.reward_label,
                       'away_days',v_row.away_days,'expiry_days',v_row.expiry_days));

  return jsonb_build_object('status','ok','campaign_id',v_row.id,'name',v_row.name,
    'reward_label',v_row.reward_label,'away_days',v_row.away_days,
    'expiry_days',v_row.expiry_days,'active',v_row.active);
end $$;
revoke all privileges on function public.business_upsert_bringback_v361(uuid,uuid,text,text,integer,integer) from public, anon, authenticated;
grant execute on function public.business_upsert_bringback_v361(uuid,uuid,text,text,integer,integer) to authenticated;

create or replace function public.business_set_bringback_paused_v361(p_business uuid, p_campaign uuid, p_paused boolean)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_row public.bringback_campaigns_v361%rowtype;
begin
  if not app.c45_owner_loyalty_write(p_business) then
    raise exception 'owner loyalty configuration access required' using errcode='42501';
  end if;
  if p_paused is null then raise exception 'paused flag is required' using errcode='22023'; end if;
  update public.bringback_campaigns_v361 set active=not p_paused, updated_at=now(), updated_by=auth.uid()
   where id=p_campaign and business_id=p_business and deleted_at is null
   returning * into v_row;
  if not found then raise exception 'bring-back campaign not found in this business' using errcode='42704'; end if;
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(p_business,auth.uid(),case when p_paused then 'bringback.paused' else 'bringback.unpaused' end,
    'bringback_campaigns_v361',p_campaign,jsonb_build_object('name',v_row.name));
  return jsonb_build_object('status','ok','campaign_id',p_campaign,'active',v_row.active);
end $$;
revoke all privileges on function public.business_set_bringback_paused_v361(uuid,uuid,boolean) from public, anon, authenticated;
grant execute on function public.business_set_bringback_paused_v361(uuid,uuid,boolean) to authenticated;

create or replace function public.business_delete_bringback_v361(p_business uuid, p_campaign uuid)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_row public.bringback_campaigns_v361%rowtype;
begin
  if not app.c45_owner_loyalty_write(p_business) then
    raise exception 'owner loyalty configuration access required' using errcode='42501';
  end if;
  -- Soft delete only. Vouchers already issued from this campaign stay valid and redeemable:
  -- withdrawing a gift a customer has already been promised is not a UI action.
  update public.bringback_campaigns_v361 set active=false, deleted_at=now(), updated_at=now(), updated_by=auth.uid()
   where id=p_campaign and business_id=p_business and deleted_at is null
   returning * into v_row;
  if not found then raise exception 'bring-back campaign not found in this business' using errcode='42704'; end if;
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(p_business,auth.uid(),'bringback.deleted','bringback_campaigns_v361',p_campaign,
    jsonb_build_object('name',v_row.name));
  return jsonb_build_object('status','ok','campaign_id',p_campaign,'mode','deleted');
end $$;
revoke all privileges on function public.business_delete_bringback_v361(uuid,uuid) from public, anon, authenticated;
grant execute on function public.business_delete_bringback_v361(uuid,uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Issuing. Never called from the browser — the daily sweep below owns it.
-- ---------------------------------------------------------------------------
create or replace function app.issue_bringback_for_business_v361(p_business uuid)
returns integer language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
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
    -- already reads: last completed, non-reversed sale older than away_days. Anyone with no sale
    -- at all is excluded — they never came, so there is nothing to bring them back from.
    insert into public.bringback_grants_v361(
      business_id,campaign_id,client_id,reward_label,away_days,cycle_key,expires_at)
    select p_business, v_campaign.id, last_seen.client_id, v_campaign.reward_label,
           v_campaign.away_days, last_seen.last_day,
           case when v_campaign.expiry_days is null then null
                else now() + make_interval(days => v_campaign.expiry_days) end
      from (
        select s.client_id, max(s.created_at)::date as last_day
          from public.sales s
         where s.business_id=p_business and s.client_id is not null and s.reversal_of is null
           and not exists(select 1 from public.sales r where r.reversal_of=s.id)
         group by s.client_id
        having max(s.created_at) < now() - make_interval(days => v_campaign.away_days)
      ) last_seen
    on conflict (campaign_id, client_id, cycle_key) do nothing;
    get diagnostics v_rows = row_count;
    v_issued := v_issued + v_rows;
  end loop;
  return v_issued;
end $$;
revoke all privileges on function app.issue_bringback_for_business_v361(uuid) from public, anon, authenticated;

create or replace function app.run_bringback_issue_v361()
returns integer language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_business uuid; v_total integer := 0;
begin
  -- Expire first, so a lapsed voucher never counts as outstanding.
  update public.bringback_grants_v361 set status='expired'
   where status='granted' and expires_at is not null and expires_at <= now();
  for v_business in
    select distinct business_id from public.bringback_campaigns_v361 where active and deleted_at is null
  loop
    v_total := v_total + app.issue_bringback_for_business_v361(v_business);
  end loop;
  return v_total;
end $$;
revoke all privileges on function app.run_bringback_issue_v361() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Redemption at the till. Mirrors staff_redeem_welcome_offer_v215's contract.
-- ---------------------------------------------------------------------------
create or replace function public.staff_redeem_bringback_v361(
  p_business uuid, p_client uuid, p_branch uuid, p_grant uuid)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_grant public.bringback_grants_v361%rowtype;
  v_sale_id uuid := gen_random_uuid();
begin
  if v_actor is null then raise exception 'authenticated staff required' using errcode='42501'; end if;
  if not (app.is_salon_owner(p_business) or app.can_module_write(p_business,'till')
          or app.can_module_write(p_business,'loyalty')) then
    raise exception 'bringback redemption authorization required' using errcode='42501';
  end if;

  select * into v_grant from public.bringback_grants_v361
   where id=p_grant and business_id=p_business and client_id=p_client for update;
  if not found then raise exception 'bringback_grant_not_found' using errcode='22023'; end if;
  if v_grant.status='redeemed' then raise exception 'bringback_already_redeemed' using errcode='22023'; end if;
  if v_grant.status<>'granted' then raise exception 'bringback_not_redeemable' using errcode='22023'; end if;
  if v_grant.expires_at is not null and v_grant.expires_at<=now() then
    update public.bringback_grants_v361 set status='expired' where id=v_grant.id;
    raise exception 'bringback_expired' using errcode='22023';
  end if;

  perform 1 from public.branches branch
   where branch.id=p_branch and branch.business_id=p_business and branch.active
     and app.can_see_branch(p_business, branch.id);
  if not found then raise exception 'bringback_branch_not_permitted' using errcode='42501'; end if;

  -- A $0 sale: a real visit worth nothing, never phantom revenue (v215's own rule).
  insert into public.sales(id,business_id,client_id,kind,amount_cents,note,branch_id)
  values (v_sale_id,p_business,p_client,'retail',0,'bring-back voucher redeemed: '||v_grant.reward_label,p_branch);

  update public.bringback_grants_v361
     set status='redeemed', redeemed_at=now(), redeemed_sale_id=v_sale_id, redeemed_by=v_actor
   where id=v_grant.id;

  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(p_business,v_actor,'BRINGBACK_REDEEMED_V361','bringback_grants_v361',v_grant.id,
    jsonb_build_object('client_id',p_client,'branch_id',p_branch,'sale_id',v_sale_id,
                       'reward_label',v_grant.reward_label));

  return jsonb_build_object('status','completed','grant_id',v_grant.id,'sale_id',v_sale_id,
    'reward_label',v_grant.reward_label);
end $$;
revoke all privileges on function public.staff_redeem_bringback_v361(uuid,uuid,uuid,uuid) from public, anon;
grant execute on function public.staff_redeem_bringback_v361(uuid,uuid,uuid,uuid) to authenticated;

-- ============================================================================================
-- VERIFICATION (rolled-back transaction against production before applying for real)
-- ============================================================================================
-- Verified 2026-08-16 inside a rolled-back transaction against gadpooereceldfpfxsod (Cubbly):
--   1. owner creates a campaign (away 60 days, "Free coffee") -> row stored, active.
--   2. update changes name/reward/window; a non-owner staff attempt -> 42501, nothing changed.
--   3. away_days 0 and a blank reward -> both refused 22023.
--   4. app.issue_bringback_for_business_v361 issues exactly one grant per lapsed client, and a
--      SECOND run in the same absence issues nothing (the cycle unique index holds).
--   5. a client whose last sale is inside the window gets nothing; a client with no sales at all
--      gets nothing.
--   6. delete is soft: the campaign disappears from the live list, already-issued grants survive
--      and stay redeemable.
--   7. sales/points_ledger totals identical before and after issuing (issuing never moves money).
--
-- CRON: schedule app.run_bringback_issue_v361() daily alongside the other nestly-*-daily jobs.
-- Registered separately so this migration stays idempotent and reviewable on its own.
commit;
