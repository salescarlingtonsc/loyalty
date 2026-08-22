-- nestly_v436 — the till earns stamps on the rules the customer's CARD carries, not the rules
-- the owner published five minutes ago (owner rule 6, locked 2026-08-22), and a card past its
-- validity closes before the sale can stamp it (rules 4/5, engine in nestly_v435).
--
-- THE DEFECT (proven live in the 2026-08-22 go-live simulation, T5): Steven's open card started
-- under version A (S$5 per stamp). The owner published version B (S$6). A S$15 sale then earned
-- floor(1500/600) = 2 stamps onto the SAME open card — the card said "S$5 per stamp", the till
-- paid at S$6. The earn loop resolved rates through the sale-time ACTIVE version
-- (resolve_loyalty_branch_config(business, branch, sale.config_version_id)), while every other
-- stamp reader (the customer card, redemption, availability) resolves the OPEN CYCLE's pinned
-- version via app.stamp_cycle_version_v416. This restatement makes the earn path read the same
-- pin. POINTS earning deliberately keeps the sale-time active config: points are batch-anchored
-- (owner rule 8/9 — a rule change affects new batches only), there is no cycle to pin to.
--
-- TIMING NOTE, why the pin is computed BEFORE the earn row is inserted: stamp_cycle_version_v416
-- derives "first stamp of the open card" from the ledger. At the moment the rate is resolved,
-- this sale's stamps are not in the ledger yet — so a card with existing stamps resolves the
-- version those stamps started under (the pin holds), and a fresh card resolves the ACTIVE
-- version, which is exactly the version its first stamp is about to start it on (rule 5's
-- "next qualifying earn starts a new cycle on the latest published version" falls out for free).
--
-- Everything outside the stamps arm of the earn loop is byte-identical to the deployed
-- nestly_v425 body (which is itself the audited restatement of the earn loop + referral payout).

begin;

CREATE OR REPLACE FUNCTION app.on_sale_recorded()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare lp record; refrow record; refprog record; v_tier public.loyalty_tiers%rowtype;
  v_refcfg record; v_ref_prog uuid; v_ref_points integer; v_ref_kind text; v_blocked text;
  v_friend_on boolean; v_friend_points integer; v_friend_earn_id uuid;
  v_pts integer; v_earn_id uuid;
  v_prog record; v_rows integer; v_expires timestamptz; v_earn_rows integer; v_batch_rows integer;
  v_stamp_cfg record; -- nestly_v436
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
          -- nestly_v436: a due card closes BEFORE this sale can stamp it, so this earn starts a
          -- fresh cycle on the latest published version instead of topping up a dead card.
          perform app.stamp_expire_open_cycle_v435(new.business_id,new.client_id,v_prog.id);
          -- nestly_v436: the earn rate of the OPEN CARD's pinned version — the same version the
          -- customer's card, the counter and availability all read — with the branch overlay
          -- applied at that version. Falls back to the sale-time config only if the pinned
          -- version cannot be resolved (it always can for a live business; belt and braces).
          select * into v_stamp_cfg from app.resolve_loyalty_branch_config(
            new.business_id,new.branch_id,
            app.stamp_cycle_version_v416(new.business_id,new.client_id,v_prog.id));
          if not found then v_stamp_cfg:=lp; end if;
          v_pts:=case when coalesce(v_stamp_cfg.stamp_per_cents,0)>0 then floor(new.amount_cents::numeric/v_stamp_cfg.stamp_per_cents) else 0 end;
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
    -- REGION A, v425: the legacy retention visit-goal loop stood here and is gone. It read
    -- retention_program_versions, counted qualifying visits inside a rolling window, and wrote
    -- reward_grants (+ a credit_ledger row for a 'credit' fulfilment). Owner ruling: absence-
    -- triggered bringback_campaigns_v361 -- a cron sweep, not this trigger -- is the canonical
    -- bring-back engine, and two engines generating the same kind of reward from one sale is how
    -- a customer ends up owed the same thing twice. The TABLES AND EVERY ROW STAY: retention_
    -- programs, retention_program_versions and reward_grants are untouched, still readable, and
    -- still written by the v361 campaign path (reward_grants.campaign_id). Only the generation
    -- path inside this trigger is withdrawn. Production blast radius when this was written: ONE
    -- reward_grant row has ever been produced by this loop, on 2026-07-17, in QA Test Cafe;
    -- zero in the last 30 days; zero credit_ledger rows have ever carried a 'retention reward:'
    -- reference. Exactly one loopable version survives (QA Test Cafe, "QA Test 2-visit reward").
    -- No live tenant loses anything it is currently receiving.

    -- REGION B, v425: the referral payout, by declared type.
    select r.* into refrow from public.referrals r where r.business_id=new.business_id and r.referred_client_id=new.client_id and r.status='pending' limit 1;
    if found then
      select * into refprog from public.referral_programs where business_id=new.business_id and enabled limit 1;
      -- A referral is earned by the friend actually SPENDING something. `amount_cents >=
      -- min_spend_cents` alone let a $0 sale through whenever the floor was 0, and $0 sales are
      -- routine here: a used package session, a completed appointment with nothing to pay, a quick
      -- reversal. Eleven of production's twelve 'service' sales are $0. Owner decision D: a
      -- redemption-generated sale never qualifies a referral. The floor still applies on top.
      if found and coalesce(new.amount_cents,0) > 0
         and new.amount_cents >= coalesce(refprog.min_spend_cents,0) then
        v_ref_kind:=lower(btrim(coalesce(refprog.reward_kind,'points')));
        v_ref_points:=coalesce(refprog.reward_points,0);
        -- nestly_v421: what the friend is owed, resolved once. NULL friend_reward_points means
        -- "the same as the referrer", which is the default a firm never has to think about; an
        -- explicit 0 means the friend gets nothing even with their side switched on.
        v_friend_on:=coalesce(refprog.friend_enabled,true);
        v_friend_points:=coalesce(refprog.friend_reward_points,v_ref_points,0);
        -- v425: the pot OF THE DECLARED KIND. NULL here means "the owner asked for a unit this
        -- firm is not running", and the answer to that is to pay nothing, not to pay something
        -- else. v322 answered the different, wrong question and is no longer consulted.
        v_ref_prog:=case when v_ref_kind in ('points','stamps')
                         then app.referral_payout_programme_v425(new.business_id,v_ref_kind) end;
        -- nestly_v420: 'voucher' finally pays something. The CHECK constraint has allowed this
        -- value for as long as the column has existed and nothing ever acted on it, so a firm set
        -- to 'voucher' qualified the referral and paid the referrer nothing at all.
        if v_ref_kind='voucher' then
          update public.referrals set status='rewarded',qualified_at=now(),qualified_sale_id=new.id,blocked_reason=null
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
        elsif v_ref_kind in ('points','stamps') then
          if v_ref_prog is null or v_ref_points<=0 then
            -- FAIL CLOSED (owner decision C). Status stays 'pending'; no ledger row, no batch, no
            -- grant; the referral remains claimable the day the firm switches the programme back
            -- on. The only thing written is the reason, and only when it CHANGES -- referrals
            -- carries an AFTER UPDATE audit trigger and a marker rewritten on every sale would
            -- fill audit_log with nothing.
            v_blocked:=case when v_ref_prog is null
                            then 'reward_kind_'||v_ref_kind||'_requires_active_'||v_ref_kind||'_programme'
                            else 'reward_amount_not_set' end;
            update public.referrals set blocked_reason=v_blocked
             where id=refrow.id and status='pending' and blocked_reason is distinct from v_blocked;
          else
            update public.referrals set status='rewarded',qualified_at=now(),qualified_sale_id=new.id,reward_points=v_ref_points,blocked_reason=null where id=refrow.id and status='pending';
            if found then
              v_expires:=null;
              -- Expiry is a POINTS policy. The earn loop above sets an expiry on a points batch
              -- and never on a stamp batch, so a referral paid in stamps must not invent one --
              -- otherwise stamps handed over for a referral would quietly rot while stamps earned
              -- at the till never do.
              if v_ref_kind='points' then
                select * into v_refcfg from app.resolve_loyalty_branch_config(new.business_id,new.branch_id,new.config_version_id);
                if found and v_refcfg.expiry_mode='fixed' then v_expires:=now()+make_interval(days=>v_refcfg.expiry_days); end if;
              end if;
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
        else
          -- Unreachable while the CHECK constraint holds, and recorded rather than ignored if it
          -- ever does not. Still fails closed.
          v_blocked:='reward_kind_unrecognised';
          update public.referrals set blocked_reason=v_blocked
           where id=refrow.id and status='pending' and blocked_reason is distinct from v_blocked;
        end if;
      end if;
    end if;
  end if;
  return new;
end
$function$;

revoke all on function app.on_sale_recorded() from public, anon, authenticated;

commit;
