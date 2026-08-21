-- nestly_v421 — the friend gets the reward too.
--
-- OWNER, 2026-08-21, answering the question v420 raised and left open ("only the REFERRER is paid…
-- making a referral two-sided is a cost decision for the firm, not a defect, and it is raised
-- separately"): "yes make the friend get the reward too".
--
-- So a qualified referral now pays BOTH sides. What each side gets:
--
--   * The REFERRER is paid exactly as before — reward_points, or the reward_label gift v420 built.
--     Nothing about that path changes.
--   * The FRIEND is paid the same KIND, and by default the same amount or the same gift. A firm
--     that wants to give the friend something different sets friend_reward_points /
--     friend_reward_label; a firm that wants the old one-sided behaviour back sets
--     friend_enabled = false.
--
-- READ THIS BEFORE APPLYING — it changes what existing firms pay. friend_enabled defaults to TRUE
-- and existing rows take that default, so every firm with referrals on starts paying the friend as
-- well from the moment this lands. That is the owner's instruction and it is deliberate, not a
-- side effect: a referral that pays only the person doing the referring is the thing they asked to
-- change. Four referral_programs rows exist in production, all enabled, all on 'points' — so the
-- concrete effect is that those four firms pay their reward_points figure twice per qualified
-- referral instead of once. The control to turn the friend's side off ships with it.
--
-- Not two-sided anywhere else: the welcome offer (v215) is a separate thing a new customer already
-- receives, and a friend who is owed both simply has both.

begin;

-- ============================================================================================
-- 1. WHAT THE FRIEND GETS
-- ============================================================================================
alter table public.referral_programs
  add column if not exists friend_enabled boolean not null default true,
  add column if not exists friend_reward_points integer,
  add column if not exists friend_reward_label text;

do $$
begin
  if not exists(select 1 from pg_constraint where conname='referral_programs_friend_points_nonneg') then
    alter table public.referral_programs
      add constraint referral_programs_friend_points_nonneg
      check (friend_reward_points is null or friend_reward_points >= 0);
  end if;
  if not exists(select 1 from pg_constraint where conname='referral_programs_friend_label_len') then
    alter table public.referral_programs
      add constraint referral_programs_friend_label_len
      check (friend_reward_label is null or length(btrim(friend_reward_label)) between 2 and 80);
  end if;
end $$;

comment on column public.referral_programs.friend_enabled is
  'v421: whether the friend who was introduced is paid as well as the referrer. Default true '
  '(owner ruling 2026-08-21). False restores the one-sided payout referrals had until v421.';
comment on column public.referral_programs.friend_reward_points is
  'v421: points for the friend when reward_kind = ''points''. NULL means the same as the '
  'referrer''s reward_points; 0 means the friend is paid nothing even while friend_enabled is on.';
comment on column public.referral_programs.friend_reward_label is
  'v421: the gift for the friend when reward_kind = ''voucher''. NULL means the same gift the '
  'referrer receives.';

-- ============================================================================================
-- 2. THE GRANT MAKES ROOM FOR TWO
-- ============================================================================================
-- v420 keyed the grant to the referral alone — one payout per referral, ever — which is exactly
-- the right guard for a one-sided referral and exactly the wrong one for two. The guard becomes
-- one payout per referral PER SIDE, so a replayed trigger still cannot pay either side twice.
alter table public.referral_grants_v420
  add column if not exists beneficiary text not null default 'referrer';

do $$
begin
  if not exists(select 1 from pg_constraint where conname='referral_grants_v420_beneficiary_check') then
    alter table public.referral_grants_v420
      add constraint referral_grants_v420_beneficiary_check
      check (beneficiary = any(array['referrer','friend']));
  end if;
  if exists(select 1 from pg_constraint where conname='referral_grants_v420_once') then
    alter table public.referral_grants_v420 drop constraint referral_grants_v420_once;
  end if;
  if not exists(select 1 from pg_constraint where conname='referral_grants_v421_once_per_side') then
    alter table public.referral_grants_v420
      add constraint referral_grants_v421_once_per_side unique (referral_id, beneficiary);
  end if;
end $$;

comment on column public.referral_grants_v420.beneficiary is
  'v421: which side of the referral this gift belongs to - ''referrer'' (the customer who '
  'introduced) or ''friend'' (the customer who was introduced). Existing rows are all referrer.';

-- ============================================================================================
-- 3. THE PAYOUT PATH PAYS BOTH
-- ============================================================================================
-- Extracted from production and patched programmatically, then diffed. The referrer's two payout
-- blocks are untouched, character for character; each gains a friend block AFTER it, inside the
-- same `if found` that proves this referral was still pending when we claimed it — so the friend
-- is paid if and only if the referrer was, and a replay pays neither twice.
CREATE OR REPLACE FUNCTION app.on_sale_recorded()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare lp record; rp record; refrow record; refprog record; v_tier public.loyalty_tiers%rowtype;
  v_refcfg record; v_ref_prog uuid; v_ref_points integer;
  v_friend_on boolean; v_friend_points integer; v_friend_earn_id uuid;
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
        -- nestly_v421: what the friend is owed, resolved once. NULL friend_reward_points means
        -- "the same as the referrer", which is the default a firm never has to think about; an
        -- explicit 0 means the friend gets nothing even with their side switched on.
        v_friend_on:=coalesce(refprog.friend_enabled,true);
        v_friend_points:=coalesce(refprog.friend_reward_points,v_ref_points,0);
        -- nestly_v420: 'voucher' finally pays something. The CHECK constraint has allowed this
        -- value for as long as the column has existed and nothing ever acted on it, so a firm set
        -- to 'voucher' qualified the referral and paid the referrer nothing at all.
        if refprog.reward_kind='voucher' then
          update public.referrals set status='rewarded',qualified_at=now(),qualified_sale_id=new.id
           where id=refrow.id and status='pending';
          if found then
            -- ON CONFLICT DO NOTHING against referral_grants_v421_once_per_side: the trigger must
            -- be replay-safe, and one referral owes each side exactly one gift however many times
            -- a sale is re-processed.
            insert into public.referral_grants_v420(business_id,client_id,referral_id,beneficiary,reward_label)
            values(new.business_id,refrow.referrer_client_id,refrow.id,'referrer',
                   coalesce(nullif(btrim(refprog.reward_label),''),'Referral gift'))
            on conflict (referral_id,beneficiary) do nothing;
            -- nestly_v421: and the friend, on the same terms. new.client_id IS the friend - this
            -- whole branch was reached by finding a pending referral whose referred_client_id is
            -- the customer standing at the counter.
            if v_friend_on then
              insert into public.referral_grants_v420(business_id,client_id,referral_id,beneficiary,reward_label)
              values(new.business_id,new.client_id,refrow.id,'friend',
                     coalesce(nullif(btrim(refprog.friend_reward_label),''),
                              nullif(btrim(refprog.reward_label),''),'Referral gift'))
              on conflict (referral_id,beneficiary) do nothing;
            end if;
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
            -- nestly_v421: the friend's side. Its own ledger id and its own batch, on the same
            -- programme and the same expiry the referrer's payout resolved, with a reference that
            -- says which side of the referral it settles. sale_id stays NULL: this is a referral
            -- payout, not an earn on the sale, and the earn/batch parity check above counts only
            -- rows carrying this sale's id.
            if v_friend_on and v_friend_points>0 then
              v_friend_earn_id:=gen_random_uuid();
              perform set_config('app.points_ledger_insert_id',v_friend_earn_id::text,true); perform set_config('app.points_ledger_write_scope','referral_reward_points',true);
              insert into public.points_ledger(id,business_id,client_id,entry_type,points,sale_id,reference,actor,programme_id)
              values(v_friend_earn_id,new.business_id,new.client_id,'earn',v_friend_points,null,'referral qualified: introduced by a friend',auth.uid(),v_ref_prog);
              perform set_config('app.points_ledger_insert_id','',true); perform set_config('app.points_ledger_write_scope','',true);
              insert into public.points_batches(business_id,client_id,earned,remaining,sale_id,earned_at,expires_at,programme_id)
              values(new.business_id,new.client_id,v_friend_points,v_friend_points,null,now(),v_expires,v_ref_prog);
            end if;
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
-- 4. SETTING IT
-- ============================================================================================
-- A NEW name again, not more parameters on save_referral_program_v420: adding a parameter creates
-- a SECOND function keyed on the new argument list rather than replacing the first, which is how
-- v378/v379 produced the twin overloads that took every promotion save down until nestly_v410.
create or replace function public.save_referral_program_v421(
  p_business uuid, p_enabled boolean, p_reward_kind text,
  p_reward_points integer, p_reward_label text, p_min_spend_cents integer,
  p_friend_enabled boolean, p_friend_reward_points integer, p_friend_reward_label text
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
  v_friend_on boolean := coalesce(p_friend_enabled,true);
  v_friend_label text := nullif(btrim(coalesce(p_friend_reward_label,'')),'');
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
  -- The friend's side is only validated when it is switched ON, and NULL always means "the same as
  -- the referrer" rather than "nothing" - so a firm that never touches these fields gets the
  -- two-sided referral the owner asked for without filling anything in.
  if v_friend_on and p_friend_reward_points is not null and p_friend_reward_points < 0 then
    raise exception 'the friend''s points cannot be negative' using errcode='22023';
  end if;

  insert into public.referral_programs (business_id, enabled, reward_kind, reward_points, reward_label, min_spend_cents,
                                        friend_enabled, friend_reward_points, friend_reward_label)
  values (p_business, p_enabled, v_kind, coalesce(p_reward_points,0), v_label, p_min_spend_cents,
          v_friend_on, p_friend_reward_points, v_friend_label)
  on conflict (business_id) do update set
    enabled = excluded.enabled,
    reward_kind = excluded.reward_kind,
    reward_points = case when excluded.reward_kind='points' then excluded.reward_points
                         else public.referral_programs.reward_points end,
    reward_label = case when excluded.reward_kind='voucher' then excluded.reward_label
                        else public.referral_programs.reward_label end,
    min_spend_cents = excluded.min_spend_cents,
    friend_enabled = excluded.friend_enabled,
    friend_reward_points = case when excluded.reward_kind='points' then excluded.friend_reward_points
                                else public.referral_programs.friend_reward_points end,
    friend_reward_label = case when excluded.reward_kind='voucher' then excluded.friend_reward_label
                               else public.referral_programs.friend_reward_label end
  returning * into v_program;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'referral_program.saved', 'referral_programs', v_program.id,
    jsonb_build_object('enabled',v_program.enabled,'reward_kind',v_program.reward_kind,
                       'reward_points',v_program.reward_points,'reward_label',v_program.reward_label,
                       'min_spend_cents',v_program.min_spend_cents,
                       'friend_enabled',v_program.friend_enabled,
                       'friend_reward_points',v_program.friend_reward_points,
                       'friend_reward_label',v_program.friend_reward_label));

  return jsonb_build_object('status','completed','program_id',v_program.id,
    'enabled',v_program.enabled,'reward_kind',v_program.reward_kind,
    'reward_points',v_program.reward_points,'reward_label',v_program.reward_label,
    'min_spend_cents',v_program.min_spend_cents,
    'friend_enabled',v_program.friend_enabled,
    'friend_reward_points',v_program.friend_reward_points,
    'friend_reward_label',v_program.friend_reward_label);
end $$;

revoke all on function public.save_referral_program_v421(uuid,boolean,text,integer,text,integer,boolean,integer,text) from public, anon;
grant execute on function public.save_referral_program_v421(uuid,boolean,text,integer,text,integer,boolean,integer,text) to authenticated;

-- ============================================================================================
-- 5. THE CUSTOMER READS WHAT THEY WILL ACTUALLY GET
-- ============================================================================================
-- The card told every customer a POINTS figure. v420 made a gift selectable, so a firm paying a
-- gift had its customers reading "0 points" - the payout is real, the sentence describing it was
-- not. reward_label rides along now, and so does the friend's side, because "and your friend gets
-- one too" is the whole reason a customer forwards the code.
CREATE OR REPLACE FUNCTION public.customer_get_referral_card_v300(p_business_slug text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_actor uuid := auth.uid();
  v_context record;
  v_program record;
  v_code text;
  v_referred integer := 0;
  v_enabled boolean := false;
begin
  if v_actor is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;
  if not app.platform_feature_enabled('customer_wallet') then
    raise exception 'customer wallet is not enabled' using errcode = '0A000';
  end if;
  select identity_id, business_id, client_id, business_currency, enabled_modules
    into v_context
    from app.v32_customer_wallet_context(p_business_slug)
   limit 1;
  if not found then
    raise exception 'verified customer link required' using errcode = '42501';
  end if;
  select rp.enabled, rp.reward_cents, rp.reward_points, rp.reward_kind, rp.reward_label,
         rp.min_spend_cents, rp.friend_enabled, rp.friend_reward_points, rp.friend_reward_label
    into v_program
    from public.referral_programs rp
   where rp.business_id = v_context.business_id
   limit 1;
  v_enabled := coalesce(v_program.enabled, false)
    and 'referrals' = any(coalesce(v_context.enabled_modules, '{}'::text[]));
  if not v_enabled then
    return jsonb_build_object('enabled', false);
  end if;
  select c.referral_code into v_code
    from public.clients c
   where c.id = v_context.client_id;
  select count(*)::integer into v_referred
    from public.referrals r
   where r.business_id = v_context.business_id
     and r.referrer_client_id = v_context.client_id
     and r.status in ('qualified','rewarded');
  return jsonb_build_object(
    'enabled', true,
    'code', v_code,
    'reward_cents', coalesce(v_program.reward_cents, 0),
    'reward_points', coalesce(v_program.reward_points, 0),
    'reward_kind', coalesce(v_program.reward_kind, 'points'),
    'reward_label', v_program.reward_label,
    'min_spend_cents', coalesce(v_program.min_spend_cents, 0),
    -- The friend's side is resolved HERE rather than in the browser, so the sentence a customer
    -- reads cannot disagree with what app.on_sale_recorded will actually pay.
    'friend_enabled', coalesce(v_program.friend_enabled, true),
    'friend_reward_points', case when coalesce(v_program.friend_enabled,true)
                                 then coalesce(v_program.friend_reward_points, v_program.reward_points, 0) else 0 end,
    'friend_reward_label', case when coalesce(v_program.friend_enabled,true)
                                then coalesce(v_program.friend_reward_label, v_program.reward_label) end,
    'currency', coalesce(v_context.business_currency, 'SGD'),
    'referred_count', v_referred
  );
end
$function$;

revoke all on function public.customer_get_referral_card_v300(text) from public, anon;
grant execute on function public.customer_get_referral_card_v300(text) to authenticated, service_role;

commit;
