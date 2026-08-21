-- nestly_v420 — a referral may pay a free gift, not only points.
--
-- OWNER, 2026-08-21 (photo 4): "referral why only points option? can also be free gift. and will
-- both the user receive the benefits? - have you tested? - fail to fix it"
--
-- Fair. The previous pass TESTED this and reported the answer without building anything, which is
-- not the same as fixing it. What the test found, and what this migration acts on:
--
--   * referral_programs.reward_kind already allowed 'points' OR 'voucher' — the CHECK constraint
--     has permitted 'voucher' for as long as the column has existed.
--   * app.on_sale_recorded had NO branch for it:
--         v_ref_prog := case when refprog.reward_kind='points' then app.referral_payout_programme_v322(...) end;
--         if v_ref_prog is not null and v_ref_points>0 then <pay> end if;
--     so a firm set to 'voucher' resolved v_ref_prog to NULL and was paid NOTHING AT ALL. The
--     option existed in the schema and paid out nowhere.
--   * save_referral_program_v322 has no reward_kind parameter, so the workspace could never set
--     it. That is the only reason no firm has silently lost a referral payout to this.
--
-- ANSWERED, because the owner asked and the answer is a fact about the code, not an opinion: only
-- the REFERRER is paid. app.on_sale_recorded inserts one points row, for
-- refrow.referrer_client_id. Nothing anywhere pays the friend. That is unchanged here — making a
-- referral two-sided is a cost decision for the firm, not a defect, and it is raised separately.
--
-- The gift is built as a VOUCHER LANE, the shape this codebase already uses three times over
-- (welcome_offer_grants_v215, bringback_grants_v361): a named thing the customer may claim once at
-- the counter, surfaced through staff_get_customer_entitlements_v102 and handed over against a $0
-- sale so the visit is real and the revenue is not.
--
-- A NEW saver rather than more parameters on save_referral_program_v322: adding a parameter
-- creates a SECOND function keyed on the new argument list rather than replacing the first, which
-- is exactly how v378/v379 produced the twin overloads that took every promotion save down until
-- nestly_v410 dropped them.

begin;

-- ============================================================================================
-- 1. WHAT THE GIFT IS CALLED
-- ============================================================================================
alter table public.referral_programs
  add column if not exists reward_label text;
do $$
begin
  if not exists(select 1 from pg_constraint where conname='referral_programs_reward_label_len') then
    alter table public.referral_programs
      add constraint referral_programs_reward_label_len
      check (reward_label is null or length(btrim(reward_label)) between 2 and 80);
  end if;
end $$;

comment on column public.referral_programs.reward_label is
  'v420: what the referrer receives when reward_kind = ''voucher'' - the name staff read at the '
  'counter and the customer sees. Ignored when reward_kind = ''points''.';

-- ============================================================================================
-- 2. THE GRANT
-- ============================================================================================
create table if not exists public.referral_grants_v420(
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  client_id uuid not null references public.clients(id) on delete cascade,
  referral_id uuid not null references public.referrals(id) on delete cascade,
  reward_label text not null,
  status text not null default 'granted',
  granted_at timestamptz not null default now(),
  expires_at timestamptz,
  redeemed_at timestamptz,
  redeemed_sale_id uuid,
  redeemed_by uuid,
  constraint referral_grants_v420_status_check
    check (status = any(array['granted','redeemed','expired'])),
  -- One payout per referral, ever. The referrals row is already the unique record of "this person
  -- introduced that person"; keying the grant to it means a replayed sale trigger cannot pay twice.
  constraint referral_grants_v420_once unique (referral_id)
);
create index if not exists referral_grants_v420_client_open_idx
  on public.referral_grants_v420(business_id, client_id, status);
alter table public.referral_grants_v420 enable row level security;

drop policy if exists referral_grants_v420_staff_read on public.referral_grants_v420;
create policy referral_grants_v420_staff_read on public.referral_grants_v420
  for select using (app.is_salon_owner(business_id) or app.can_module_read(business_id,'referrals'));

revoke all on table public.referral_grants_v420 from public, anon, authenticated;
grant select on table public.referral_grants_v420 to authenticated;

comment on table public.referral_grants_v420 is
  'v420: a free-gift referral payout owed to the REFERRER, claimed once at the counter. Written '
  'only by app.on_sale_recorded when the friend''s first qualifying visit lands; redeemed by '
  'public.staff_redeem_referral_v420 against a $0 sale.';


-- ============================================================================================
-- 3. THE PAYOUT PATH
-- ============================================================================================
-- Extracted from production and patched programmatically, then diffed: ONE line replaced, the
-- rest added. Nothing about the points path, the retention loop, the earn guard or the sale
-- policy resolution is touched, and a firm on 'points' behaves exactly as it did.
CREATE OR REPLACE FUNCTION app.on_sale_recorded()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare lp record; rp record; refrow record; refprog record; v_tier public.loyalty_tiers%rowtype;
  v_refcfg record; v_ref_prog uuid; v_ref_points integer;
  v_pts integer; v_idx integer; v_count integer; v_earn_id uuid; v_credit_id uuid;
  w_start timestamptz; w_end timestamptz;
  v_prog record; v_rows integer; v_expires timestamptz; v_earn_rows integer; v_batch_rows integer;
begin
  if new.reversal_of is not null or new.client_id is null or not(new.earns_points or new.counts_as_visit) then return new; end if;
  if new.earns_points
     and exists(
       select 1
       from app.effective_platform_module_mode_v94(
         new.business_id,new.branch_id,'loyalty'
       ) effective
       where effective.mode='rw'
     ) then
    select * into lp from app.resolve_loyalty_branch_config(new.business_id,new.branch_id,new.config_version_id);
    if found then
      for v_prog in
        select spine.id, spine.kind
          from public.business_programmes spine
         where spine.business_id=new.business_id
           and spine.active
           and spine.kind in ('points','stamps')
         order by spine.sort
      loop
        v_earn_id:=gen_random_uuid(); v_rows:=0; v_pts:=0; v_expires:=null;
        if v_prog.kind='stamps' then
          v_pts:=case when coalesce(lp.stamp_per_cents,0)>0 then floor(new.amount_cents::numeric/lp.stamp_per_cents) else 0 end;
        elsif v_prog.kind='points' then
          v_pts:=case when coalesce(lp.earn_points_per_dollar,0)>0 then floor((new.amount_cents/100.0)*lp.earn_points_per_dollar) else 0 end;
          select * into v_tier from app.loyalty_tier_for(new.business_id,new.client_id);
          if v_tier.id is not null and v_tier.points_multiplier>1 then v_pts:=floor(v_pts*v_tier.points_multiplier); end if;
          v_expires:=case when lp.expiry_mode='fixed' then now()+make_interval(days=>lp.expiry_days) end;
        else
          v_pts:=0;
        end if;
        if v_pts>0 then
          perform set_config('app.points_ledger_insert_id',v_earn_id::text,true); perform set_config('app.points_ledger_write_scope','sale_trigger',true);
          insert into public.points_ledger(id,business_id,client_id,entry_type,points,sale_id,reference,actor,programme_id)
          values(v_earn_id,new.business_id,new.client_id,'earn',v_pts,new.id,'auto-earn on sale',auth.uid(),v_prog.id)
          on conflict (sale_id,programme_id) where entry_type='earn' and sale_id is not null do nothing;
          get diagnostics v_rows=row_count;
          perform set_config('app.points_ledger_insert_id','',true); perform set_config('app.points_ledger_write_scope','',true);
          if v_rows=1 then
            insert into public.points_batches(business_id,client_id,earned,remaining,sale_id,earned_at,expires_at,programme_id)
            values(new.business_id,new.client_id,v_pts,v_pts,new.id,now(),v_expires,v_prog.id);
          end if;
        end if;
      end loop;
      select count(*) into v_earn_rows from public.points_ledger l where l.sale_id=new.id and l.entry_type='earn';
      select count(*) into v_batch_rows from public.points_batches b where b.sale_id=new.id;
      if v_earn_rows<>v_batch_rows then
        raise exception 'earn loop left ledger/batch parity broken for sale %',new.id using errcode='XX001';
      end if;
    end if;
  end if;
  if new.counts_as_visit then
    -- v332: only loop over a retention program version whose LIVE retention_programs row is not
    -- deleted. retention_program_versions.active alone is not enough once the row belongs to an
    -- already-published config version, because that row is frozen (trg_guard_retention_program_
    -- version blocks any UPDATE the moment its config_version_id is not a draft) -- so a delete can
    -- only ever be observed here through the live table, not the snapshot.
    for rp in select rpv.* from public.retention_program_versions rpv
      join public.retention_programs prog
        on prog.id=rpv.program_id and prog.business_id=rpv.business_id
       where rpv.business_id=new.business_id and rpv.config_version_id=new.config_version_id
         and rpv.active and prog.deleted_at is null
    loop
      v_idx:=floor(extract(epoch from(new.occurred_at-rp.starts_on::timestamptz))/(rp.period_days*86400));
      if v_idx>=0 then
        w_start:=rp.starts_on::timestamptz+make_interval(days=>v_idx*rp.period_days); w_end:=w_start+make_interval(days=>rp.period_days);
        select count(*) into v_count from public.sales s where s.business_id=new.business_id and s.client_id=new.client_id and s.counts_as_visit and s.reversal_of is null and not exists(select 1 from public.sales r where r.business_id=s.business_id and r.reversal_of=s.id) and s.occurred_at>=w_start and s.occurred_at<w_end;
        if v_count>=rp.goal_visits then
          begin
            insert into public.reward_grants(business_id,program_id,client_id,period_index,reward_type,reward_value,reward_item,config_version_id,retention_program_version_id)
            values(new.business_id,rp.program_id,new.client_id,v_idx,rp.fulfillment_kind,coalesce(rp.discount_percent,rp.credit_cents,0),rp.manual_item,new.config_version_id,rp.id);
            if rp.fulfillment_kind='credit' and rp.credit_cents>0 then
              v_credit_id:=gen_random_uuid(); perform set_config('app.credit_ledger_insert_id',v_credit_id::text,true); perform set_config('app.credit_ledger_write_scope','sale_trigger',true);
              insert into public.credit_ledger(id,business_id,client_id,entry_type,amount_cents,reference,sale_id,actor) values(v_credit_id,new.business_id,new.client_id,'loyalty_earn',rp.credit_cents,'retention reward: '||rp.name,new.id,auth.uid());
              perform set_config('app.credit_ledger_insert_id','',true); perform set_config('app.credit_ledger_write_scope','',true);
            end if;
          exception when unique_violation then null; end;
        end if;
      end if;
    end loop;
    select r.* into refrow from public.referrals r where r.business_id=new.business_id and r.referred_client_id=new.client_id and r.status='pending' limit 1;
    if found then
      select * into refprog from public.referral_programs where business_id=new.business_id and enabled limit 1;
      if found and new.amount_cents>=coalesce(refprog.min_spend_cents,0) then
        v_ref_prog:=case when refprog.reward_kind='points' then app.referral_payout_programme_v322(new.business_id) end;
        v_ref_points:=coalesce(refprog.reward_points,0);
        -- nestly_v420: 'voucher' finally pays something. The CHECK constraint has allowed this
        -- value for as long as the column has existed and nothing ever acted on it, so a firm set
        -- to 'voucher' qualified the referral and paid the referrer nothing at all.
        if refprog.reward_kind='voucher' then
          update public.referrals set status='rewarded',qualified_at=now(),qualified_sale_id=new.id
           where id=refrow.id and status='pending';
          if found then
            -- ON CONFLICT DO NOTHING against referral_grants_v420_once: the trigger must be
            -- replay-safe, and one referral owes exactly one gift however many times a sale is
            -- re-processed.
            insert into public.referral_grants_v420(business_id,client_id,referral_id,reward_label)
            values(new.business_id,refrow.referrer_client_id,refrow.id,
                   coalesce(nullif(btrim(refprog.reward_label),''),'Referral gift'))
            on conflict (referral_id) do nothing;
          end if;
        elsif v_ref_prog is not null and v_ref_points>0 then
          update public.referrals set status='rewarded',qualified_at=now(),qualified_sale_id=new.id,reward_points=v_ref_points where id=refrow.id and status='pending';
          if found then
            v_expires:=null;
            select * into v_refcfg from app.resolve_loyalty_branch_config(new.business_id,new.branch_id,new.config_version_id);
            if found and v_refcfg.expiry_mode='fixed' then v_expires:=now()+make_interval(days=>v_refcfg.expiry_days); end if;
            v_earn_id:=gen_random_uuid();
            perform set_config('app.points_ledger_insert_id',v_earn_id::text,true); perform set_config('app.points_ledger_write_scope','referral_reward_points',true);
            insert into public.points_ledger(id,business_id,client_id,entry_type,points,sale_id,reference,actor,programme_id)
            values(v_earn_id,new.business_id,refrow.referrer_client_id,'earn',v_ref_points,null,'referral qualified: first visit completed',auth.uid(),v_ref_prog);
            perform set_config('app.points_ledger_insert_id','',true); perform set_config('app.points_ledger_write_scope','',true);
            insert into public.points_batches(business_id,client_id,earned,remaining,sale_id,earned_at,expires_at,programme_id)
            values(new.business_id,refrow.referrer_client_id,v_ref_points,v_ref_points,null,now(),v_expires,v_ref_prog);
            perform app.emit_referral_qualified_v322(new.business_id,refrow.id,refrow.referrer_client_id,new.client_id,v_ref_points,v_earn_id,now(),new.config_version_id);
          end if;
        end if;
      end if;
    end if;
  end if;
  return new;
end
$function$;

revoke all on function app.on_sale_recorded() from public, anon, authenticated;

-- ============================================================================================
-- 4. THE COUNTER SEES IT
-- ============================================================================================
CREATE OR REPLACE FUNCTION public.staff_get_customer_entitlements_v102(p_business uuid, p_client uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_bringback jsonb;
  v_referral jsonb;
  v_welcome jsonb;
  v_packages jsonb;
  v_vouchers jsonb;
begin
  if not (
    app.is_super_admin()
    or app.can_module_read(p_business,'till')
    or app.can_module_read(p_business,'sales')
    or app.can_module_read(p_business,'packages')
  ) then
    raise exception 'customer_entitlements_access_required' using errcode='42501';
  end if;
  if not exists(
    select 1 from public.clients client
    where client.id=p_client and client.business_id=p_business
  ) then
    raise exception 'customer_not_found' using errcode='22023';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'client_package_id',customer_package.id,
    'remaining',customer_package.remaining,
    'status',customer_package.status,
    'plan_id',customer_package.plan_id,
    'plan_version',customer_package.plan_version_snapshot,
    'plan_name',customer_package.plan_name_snapshot,
    'sessions',customer_package.sessions_snapshot,
    'price_cents',customer_package.price_cents_snapshot,
    'service_id',customer_package.service_id_snapshot,
    'service_name',customer_package.service_name_snapshot,
    'variant_label',customer_package.service_variant_snapshot,
    'list_unit_cents',customer_package.list_unit_cents_snapshot,
    'list_value_cents',customer_package.list_value_cents_snapshot,
    'duration_min',customer_package.service_duration_min_snapshot
  ) order by customer_package.purchased_at,customer_package.id),'[]'::jsonb)
  into v_packages
  from public.client_packages customer_package
  where customer_package.business_id=p_business
    and customer_package.client_id=p_client
    and customer_package.status='active'
    and customer_package.remaining>0;

  select coalesce(jsonb_agg(jsonb_build_object(
    'intent_id',intent.id,
    'redemption_kind',intent.redemption_kind,
    'reward_name',coalesce(reward.name,'Points reward'),
    'points_spent',intent.quoted_points_spent,
    'credit_cents',intent.quoted_credit_cents,
    'expires_at',intent.expires_at
  ) order by intent.expires_at,intent.id),'[]'::jsonb)
  into v_vouchers
  from public.customer_redemption_intents_v89 intent
  left join public.loyalty_rewards reward on reward.id=intent.reward_id
    and reward.business_id=intent.business_id
  where intent.business_id=p_business
    and intent.client_id=p_client
    and intent.status='pending'
    and intent.expires_at>now();

  -- v215: the welcome offer belongs next to packages and vouchers because this
  -- is the one payload the till reads for a looked-up customer. An expired
  -- grant is withheld here rather than offered and then refused at redeem time.
  select jsonb_build_object(
    'grant_id',grant_row.id,
    'reward_label',grant_row.reward_label,
    'reward_catalog_kind',grant_row.reward_catalog_kind,
    'reward_catalog_id',grant_row.reward_catalog_id,
    'min_spend_cents',grant_row.min_spend_cents,
    'expires_at',grant_row.expires_at)
  into v_welcome
  from public.welcome_offer_grants_v215 grant_row
  where grant_row.business_id=p_business
    and grant_row.client_id=p_client
    and grant_row.status='granted'
    and (grant_row.expires_at is null or grant_row.expires_at>now());

  select jsonb_build_object('grant_id',bb.id,'reward_label',bb.reward_label,'away_days',bb.away_days,'expires_at',bb.expires_at) into v_bringback from public.bringback_grants_v361 bb where bb.business_id=p_business and bb.client_id=p_client and bb.status='granted' and (bb.expires_at is null or bb.expires_at>now()) order by bb.granted_at limit 1; select jsonb_build_object('grant_id',rg.id,'reward_label',rg.reward_label,'expires_at',rg.expires_at)
    into v_referral
    from public.referral_grants_v420 rg
   where rg.business_id=p_business and rg.client_id=p_client and rg.status='granted'
     and (rg.expires_at is null or rg.expires_at>now())
   order by rg.granted_at limit 1;
  -- nestly_v420: the referral gift joins the one payload the till reads for a looked-up customer,
  -- beside the welcome offer and the bring-back voucher it is shaped after. An expired grant is
  -- withheld here rather than offered and then refused at redeem time (v215's rule).
  return jsonb_build_object('packages',v_packages,'vouchers',v_vouchers,'welcome_offer',v_welcome,'bringback_offer',v_bringback,'referral_offer',v_referral);
end
$function$;

revoke all on function public.staff_get_customer_entitlements_v102(uuid,uuid) from public, anon;
grant execute on function public.staff_get_customer_entitlements_v102(uuid,uuid) to authenticated, service_role;

-- ============================================================================================
-- 5. HANDING IT OVER
-- ============================================================================================
-- staff_redeem_bringback_v361's shape, because it is the same act: a named free thing, claimed
-- once, recorded as a real visit worth nothing.
create or replace function public.staff_redeem_referral_v420(
  p_business uuid, p_client uuid, p_branch uuid, p_grant uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_grant public.referral_grants_v420%rowtype;
  v_sale_id uuid := gen_random_uuid();
begin
  if v_actor is null then raise exception 'authenticated staff required' using errcode='42501'; end if;
  if not (app.is_salon_owner(p_business) or app.can_module_write(p_business,'till')
          or app.can_module_write(p_business,'referrals')) then
    raise exception 'referral redemption authorization required' using errcode='42501';
  end if;

  select * into v_grant from public.referral_grants_v420
   where id=p_grant and business_id=p_business and client_id=p_client for update;
  if not found then raise exception 'referral_grant_not_found' using errcode='22023'; end if;
  if v_grant.status='redeemed' then raise exception 'referral_already_redeemed' using errcode='22023'; end if;
  if v_grant.status<>'granted' then raise exception 'referral_not_redeemable' using errcode='22023'; end if;
  if v_grant.expires_at is not null and v_grant.expires_at<=now() then
    update public.referral_grants_v420 set status='expired' where id=v_grant.id;
    raise exception 'referral_expired' using errcode='22023';
  end if;

  perform 1 from public.branches branch
   where branch.id=p_branch and branch.business_id=p_business and branch.active
     and app.can_see_branch(p_business, branch.id);
  if not found then raise exception 'referral_branch_not_permitted' using errcode='42501'; end if;

  -- A $0 sale: a real visit worth nothing, never phantom revenue.
  insert into public.sales(id,business_id,client_id,kind,amount_cents,note,branch_id)
  values (v_sale_id,p_business,p_client,'retail',0,'referral gift redeemed: '||v_grant.reward_label,p_branch);

  update public.referral_grants_v420
     set status='redeemed', redeemed_at=now(), redeemed_sale_id=v_sale_id, redeemed_by=v_actor
   where id=v_grant.id;

  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(p_business,v_actor,'REFERRAL_GIFT_REDEEMED_V420','referral_grants_v420',v_grant.id,
    jsonb_build_object('client_id',p_client,'branch_id',p_branch,'sale_id',v_sale_id,
                       'reward_label',v_grant.reward_label));

  return jsonb_build_object('status','completed','grant_id',v_grant.id,'sale_id',v_sale_id,
    'reward_label',v_grant.reward_label);
end $$;

revoke all on function public.staff_redeem_referral_v420(uuid,uuid,uuid,uuid) from public, anon;
grant execute on function public.staff_redeem_referral_v420(uuid,uuid,uuid,uuid) to authenticated;

-- ============================================================================================
-- 6. CHOOSING IT
-- ============================================================================================
-- A NEW name, not more parameters on save_referral_program_v322 — see the header.
create or replace function public.save_referral_program_v420(
  p_business uuid, p_enabled boolean, p_reward_kind text,
  p_reward_points integer, p_reward_label text, p_min_spend_cents integer
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_staff uuid;
  v_kind text := lower(btrim(coalesce(p_reward_kind,'points')));
  v_label text := nullif(btrim(coalesce(p_reward_label,'')),'');
  v_program public.referral_programs%rowtype;
begin
  if v_actor is null or not app.can_module_write(p_business, 'referrals') then
    raise exception 'active referrals-module write authorization is required' using errcode='42501';
  end if;
  select s.id into v_staff from public.staff s
   where s.business_id = p_business and s.user_id = v_actor and s.active
   order by case when s.role = 'owner' then 0 else 1 end, s.created_at limit 1 for update;
  if not found then raise exception 'active staff authorization is required' using errcode='42501'; end if;
  if v_kind not in ('points','voucher') then
    raise exception 'a referral pays either points or a free gift' using errcode='22023';
  end if;
  if p_enabled is null or p_min_spend_cents is null or p_min_spend_cents < 0 then
    raise exception 'invalid referral program' using errcode='22023';
  end if;
  -- Each kind validates only what IT needs. A firm switching to a gift should not have to invent
  -- a points figure it will never pay, and one switching back should not lose the points it had.
  if v_kind='points' and (p_reward_points is null or p_reward_points < 1) then
    raise exception 'a points referral must award at least one point' using errcode='22023';
  end if;
  if v_kind='voucher' and v_label is null then
    raise exception 'name the gift the referrer receives' using errcode='22023';
  end if;

  insert into public.referral_programs (business_id, enabled, reward_kind, reward_points, reward_label, min_spend_cents)
  values (p_business, p_enabled, v_kind, coalesce(p_reward_points,0), v_label, p_min_spend_cents)
  on conflict (business_id) do update set
    enabled = excluded.enabled,
    reward_kind = excluded.reward_kind,
    reward_points = case when excluded.reward_kind='points' then excluded.reward_points
                         else public.referral_programs.reward_points end,
    reward_label = case when excluded.reward_kind='voucher' then excluded.reward_label
                        else public.referral_programs.reward_label end,
    min_spend_cents = excluded.min_spend_cents
  returning * into v_program;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'referral_program.saved', 'referral_programs', v_program.id,
    jsonb_build_object('enabled',v_program.enabled,'reward_kind',v_program.reward_kind,
                       'reward_points',v_program.reward_points,'reward_label',v_program.reward_label,
                       'min_spend_cents',v_program.min_spend_cents));

  return jsonb_build_object('status','completed','program_id',v_program.id,
    'enabled',v_program.enabled,'reward_kind',v_program.reward_kind,
    'reward_points',v_program.reward_points,'reward_label',v_program.reward_label,
    'min_spend_cents',v_program.min_spend_cents);
end $$;

revoke all on function public.save_referral_program_v420(uuid,boolean,text,integer,text,integer) from public, anon;
grant execute on function public.save_referral_program_v420(uuid,boolean,text,integer,text,integer) to authenticated;

commit;
