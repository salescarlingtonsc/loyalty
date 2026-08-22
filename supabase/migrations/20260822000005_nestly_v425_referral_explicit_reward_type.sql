-- nestly_v425 — a referral reward has a TYPE, and an untypable reward is never paid.
--
-- OWNER, 2026-08-22: a referral reward is one of three explicit things — points, stamps, or a
-- free gift. It is paid into the pot the owner NAMED. It is never paid into "whichever accruing
-- programme happens to be switched on", and points are never silently handed over as stamps.
--
-- WHAT WAS ACTUALLY HAPPENING. app.referral_payout_programme_v322 is kind-BLIND: given a business
-- it returns the single active spine row whose kind is points OR stamps, and returns NULL when
-- there are none or two. app.on_sale_recorded then paid reward_points into whatever came back.
-- Production today, all four referral_programs rows enabled and all four set to 'points':
--
--   Cubbly SPA (8492e8d6…)  points spine OFF, stamps spine ON  -> v322 returns the STAMPS pot, so
--                            a referral configured to pay 50 POINTS pays 50 STAMPS. This is the
--                            exact silent conversion the owner banned in V355.
--   AhXiang (33773caa…)     both spines OFF -> v322 returns NULL, the `elsif` falls through, and
--                            the referral stays 'pending' for ever with nothing anywhere saying so.
--   ZZ-SYNTHETIC (bcd24ddd…) both spines OFF -> same silent strand.
--   QA Test Cafe (dcaaf5d6…) points spine ON -> correct, by luck.
--
-- So of four live configurations, one paid the wrong unit, two paid nothing and said nothing, and
-- one worked. This migration replaces the guess with the owner's declared type.
--
-- FIVE THINGS:
--   1. reward_kind gains 'stamps'. The AMOUNT for either accruing kind stays in reward_points --
--      one number, and reward_kind says which pot it lands in. points_ledger already carries one
--      `points` column for both pots, tagged by programme_id; this mirrors that exactly.
--   2. app.referral_payout_programme_v425(business, kind) resolves the pot OF THAT KIND, or NULL.
--      v322 is left installed and untouched (its only caller in the whole catalog was
--      app.on_sale_recorded -- verified by scanning every prosrc in the database); nothing is
--      dropped, so nothing can break by name resolution at run time.
--   3. app.on_sale_recorded pays by declared type, and FAILS CLOSED when it cannot: the referral
--      stays 'pending', nothing is written to any ledger, and referrals.blocked_reason says why.
--      A $0 sale can no longer qualify a referral at all (owner decision D).
--   4. The savers accept 'stamps', REFUSE a type whose programme is off, and are owner-only.
--   5. set_programmes_v314 syncs referral_programs.enabled with the referral spine row in the same
--      transaction (SA-4), and reports whether the switch just made the referral reward unpayable.
--
-- AND ONE REMOVAL: the legacy retention visit-goal loop leaves app.on_sale_recorded. See §4.

begin;

-- ==============================================================================================
-- 1. THE REWARD HAS A TYPE, AND A BLOCKED REFERRAL SAYS SO
-- ==============================================================================================
alter table public.referral_programs
  drop constraint if exists referral_programs_reward_kind_check;
alter table public.referral_programs
  add constraint referral_programs_reward_kind_check
  check (reward_kind = any(array['points','stamps','voucher']));

comment on column public.referral_programs.reward_kind is
  'v425: what a qualified referral pays — ''points'' into the points pot, ''stamps'' into the '
  'stamp pot, or ''voucher'' as a named free gift. The AMOUNT for points and stamps alike lives '
  'in reward_points (and friend_reward_points); this column alone decides which pot it lands in. '
  'A kind whose programme is switched off is never reinterpreted — the payout fails closed.';

-- referrals.blocked_reason: the state that used to be invisible. A referral that qualified but
-- could not be paid stays 'pending' and carries the reason here, so the Referrals page can show
-- the firm something it can act on instead of a row that silently never moves.
alter table public.referrals
  add column if not exists blocked_reason text;

comment on column public.referrals.blocked_reason is
  'v425: why a qualifying visit did not pay this referral. NULL = nothing is wrong. Set by '
  'app.on_sale_recorded when the configured reward_kind cannot be paid (its programme is off, or '
  'no amount is set) and cleared the moment a later qualifying sale does pay it.';

-- The Referrals page reads `select *`, so a column the browser roles cannot read would not hide
-- the column -- it would 42501 the WHOLE PAGE. public.referrals was checked first and carries a
-- TABLE-level SELECT grant (relacl authenticated=rxtm, anon=rxtm) with zero column-level ACLs, so
-- the new column is already covered. These two grants are therefore redundant on production and
-- are here anyway: they cost nothing, they say the intent out loud, and they mean this migration
-- is still correct on any database whose referrals ACL is column-level. RLS is unchanged --
-- referrals_v41_read still scopes every row by app.can_module_read(business_id,'referrals').
grant select (blocked_reason) on public.referrals to authenticated, anon;

-- ==============================================================================================
-- 2. THE POT OF THAT KIND, OR NOTHING
-- ==============================================================================================
create or replace function app.referral_payout_programme_v425(p_business uuid, p_kind text)
 returns uuid
 language sql
 stable security definer
 set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
  -- business_programmes is unique on (business_id, kind), so this is at most one row. It answers
  -- "is the pot the owner NAMED running?" and nothing else -- it will not substitute a different
  -- pot however many other programmes are active, which is the whole difference from v322.
  select spine.id
    from public.business_programmes spine
   where spine.business_id = p_business
     and spine.active
     and spine.kind = lower(btrim(coalesce(p_kind, '')))
     and spine.kind in ('points','stamps')
$function$;

revoke all on function app.referral_payout_programme_v425(uuid, text) from public, anon, authenticated;

comment on function app.referral_payout_programme_v425(uuid, text) is
  'v425: the ACTIVE spine programme of exactly the requested kind, or NULL. Supersedes the '
  'kind-blind app.referral_payout_programme_v322, which is left installed and unused.';

comment on function app.referral_payout_programme_v322(uuid) is
  'SUPERSEDED by app.referral_payout_programme_v425(uuid,text) in v425. Kind-blind: it returns '
  'the single active accruing programme whatever kind it is, which is how a points referral came '
  'to pay stamps. Deliberately NOT dropped -- PL/pgSQL resolves names at run time and a dropped '
  'function breaks its callers silently. It has no callers left.';

-- ==============================================================================================
-- 3. THE SALE TRIGGER
-- ==============================================================================================
-- Extracted from production with pg_get_functiondef and patched in place. Everything outside the
-- two regions named below is byte-identical to the deployed body: the early-return guard, the
-- whole points/stamps earn loop, the ledger/batch parity check, and the voucher payout path.
--
-- REGION A (removed): the legacy retention visit-goal loop, per the owner's separate ruling that
-- bringback_campaigns_v361 is the canonical bring-back engine. See the note at §4.
-- REGION B (rewritten): the referral payout, from `select r.* into refrow` to the end of the
-- `if found` that wraps it.
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

-- ==============================================================================================
-- 4. THE SAVERS: ACCEPT STAMPS, REFUSE THE UNPAYABLE, OWNER ONLY
-- ==============================================================================================
-- Three changes to each saver, and nothing else:
--   (a) 'stamps' joins the accepted kinds, and the amount rule that guarded 'points' now guards
--       both -- as does the ON CONFLICT clause that decides whether to keep the incoming amount,
--       without which switching a firm to stamps would silently discard the figure just typed.
--   (b) A points or stamps reward is REFUSED unless the matching spine is running (decision B).
--       This is the configuration-time half of the fail-closed rule: the trigger refuses to pay
--       the wrong unit, and this refuses to record a promise the firm cannot keep.
--   (c) Owner only. app.can_module_write('referrals') admits managers; the Referral screen is
--       owner-only in the UI, and the stricter of the two is the one to keep. This is a
--       deliberate narrowing -- a manager who could previously save the referral programme now
--       receives 42501.
CREATE OR REPLACE FUNCTION public.save_referral_program_v421(p_business uuid, p_enabled boolean, p_reward_kind text, p_reward_points integer, p_reward_label text, p_min_spend_cents integer, p_friend_enabled boolean, p_friend_reward_points integer, p_friend_reward_label text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_actor uuid := auth.uid();
  v_staff uuid;
  v_kind text := lower(btrim(coalesce(p_reward_kind,'points')));
  v_label text := nullif(btrim(coalesce(p_reward_label,'')),'');
  v_friend_on boolean := coalesce(p_friend_enabled,true);
  v_friend_label text := nullif(btrim(coalesce(p_friend_reward_label,'')),'');
  v_program public.referral_programs%rowtype;
begin
  if v_actor is null or not app.is_salon_owner(p_business) then
    raise exception 'only the business owner may change the referral programme' using errcode='42501';
  end if;
  select s.id into v_staff from public.staff s
   where s.business_id = p_business and s.user_id = v_actor and s.active
   order by case when s.role = 'owner' then 0 else 1 end, s.created_at limit 1 for update;
  if not found then raise exception 'active staff authorization is required' using errcode='42501'; end if;
  if v_kind not in ('points','stamps','voucher') then
    raise exception 'a referral pays points, stamps or a free gift' using errcode='22023';
  end if;
  if p_enabled is null or p_min_spend_cents is null or p_min_spend_cents < 0 then
    raise exception 'invalid referral program' using errcode='22023';
  end if;
  -- Each kind validates only what IT needs. A firm switching to a gift should not have to invent
  -- a points figure it will never pay, and one switching back should not lose the points it had.
  if v_kind in ('points','stamps') and (p_reward_points is null or p_reward_points < 1) then
    raise exception '%', case when v_kind='points'
      then 'a points referral must award at least one point'
      else 'a stamp referral must award at least one stamp' end using errcode='22023';
  end if;
  if v_kind='voucher' and v_label is null then
    raise exception 'name the gift the referrer receives' using errcode='22023';
  end if;
  -- v425 (decision B): the named pot must actually be running. Without this a firm can save
  -- "pays 50 points" while the Point system is off, and the promise is unkeepable the moment it
  -- is made -- which is how three of the four live configurations got into that state.
  if v_kind in ('points','stamps') and app.referral_payout_programme_v425(p_business, v_kind) is null then
    raise exception '%', case when v_kind='points'
      then 'referral reward type "points" needs the Point system switched on'
      else 'referral reward type "stamps" needs the Stamp card switched on' end using errcode='22023';
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
    reward_points = case when excluded.reward_kind in ('points','stamps') then excluded.reward_points
                         else public.referral_programs.reward_points end,
    reward_label = case when excluded.reward_kind='voucher' then excluded.reward_label
                        else public.referral_programs.reward_label end,
    min_spend_cents = excluded.min_spend_cents,
    friend_enabled = excluded.friend_enabled,
    friend_reward_points = case when excluded.reward_kind in ('points','stamps') then excluded.friend_reward_points
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
end $function$;

-- v420 gets the identical treatment rather than being left as a way around it. It is still
-- installed for the CDN window and nothing in the current bundle calls it, but a saver that
-- accepted an unpayable kind, from a manager, would be a hole in the rule this migration exists
-- to establish.
CREATE OR REPLACE FUNCTION public.save_referral_program_v420(p_business uuid, p_enabled boolean, p_reward_kind text, p_reward_points integer, p_reward_label text, p_min_spend_cents integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_actor uuid := auth.uid();
  v_staff uuid;
  v_kind text := lower(btrim(coalesce(p_reward_kind,'points')));
  v_label text := nullif(btrim(coalesce(p_reward_label,'')),'');
  v_program public.referral_programs%rowtype;
begin
  if v_actor is null or not app.is_salon_owner(p_business) then
    raise exception 'only the business owner may change the referral programme' using errcode='42501';
  end if;
  select s.id into v_staff from public.staff s
   where s.business_id = p_business and s.user_id = v_actor and s.active
   order by case when s.role = 'owner' then 0 else 1 end, s.created_at limit 1 for update;
  if not found then raise exception 'active staff authorization is required' using errcode='42501'; end if;
  if v_kind not in ('points','stamps','voucher') then
    raise exception 'a referral pays points, stamps or a free gift' using errcode='22023';
  end if;
  if p_enabled is null or p_min_spend_cents is null or p_min_spend_cents < 0 then
    raise exception 'invalid referral program' using errcode='22023';
  end if;
  -- Each kind validates only what IT needs. A firm switching to a gift should not have to invent
  -- a points figure it will never pay, and one switching back should not lose the points it had.
  if v_kind in ('points','stamps') and (p_reward_points is null or p_reward_points < 1) then
    raise exception '%', case when v_kind='points'
      then 'a points referral must award at least one point'
      else 'a stamp referral must award at least one stamp' end using errcode='22023';
  end if;
  if v_kind='voucher' and v_label is null then
    raise exception 'name the gift the referrer receives' using errcode='22023';
  end if;
  if v_kind in ('points','stamps') and app.referral_payout_programme_v425(p_business, v_kind) is null then
    raise exception '%', case when v_kind='points'
      then 'referral reward type "points" needs the Point system switched on'
      else 'referral reward type "stamps" needs the Stamp card switched on' end using errcode='22023';
  end if;

  insert into public.referral_programs (business_id, enabled, reward_kind, reward_points, reward_label, min_spend_cents)
  values (p_business, p_enabled, v_kind, coalesce(p_reward_points,0), v_label, p_min_spend_cents)
  on conflict (business_id) do update set
    enabled = excluded.enabled,
    reward_kind = excluded.reward_kind,
    reward_points = case when excluded.reward_kind in ('points','stamps') then excluded.reward_points
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
end $function$;

-- ==============================================================================================
-- 5. ONE SWITCH, ONE TRUTH (SA-4)
-- ==============================================================================================
-- Extracted from production and patched in two places, both marked v425 below. Everything else,
-- including the stamps-exclusivity rule and the V354/V355 pot commentary, is unchanged.
--   (a) Flipping the 'referral' switch now also moves public.referral_programs.enabled, in this
--       transaction. Until now the spine row and that column were two writes from two screens,
--       and app.on_sale_recorded reads the COLUMN -- so a switch that moved only the spine left
--       the engine reading the opposite of what the owner had just set.
--   (b) The result carries referral_reward_kind_now_unpayable, computed after the spine has
--       moved, so switching Points off can tell the owner immediately that the referral reward
--       they configured can no longer be paid. Turning the programme off is NOT blocked -- the
--       owner's switch wins, and the referrals that arrive meanwhile fail closed and say so.
CREATE OR REPLACE FUNCTION public.set_programmes_v314(p_business uuid, p_switches jsonb, p_idempotency_key uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_actor uuid := auth.uid();
  v_hash text;
  v_rows integer;
  v_existing public.programme_switch_operations_v314%rowtype;
  v_kind text;
  v_want boolean;
  v_before boolean;
  v_changes jsonb := '[]'::jsonb;
  v_result jsonb;
  v_points boolean;
  v_stamps boolean;
  v_points_before boolean;
  v_stamps_before boolean;
  v_from uuid;
  v_to uuid;
  v_migration uuid;
  v_after_points boolean;
  v_after_tiers boolean;
  v_after_stamps boolean;
  v_model text;
  v_program_kind text;
  v_referral_want boolean;
  v_ref_unpayable boolean;
begin
  if p_business is null or p_idempotency_key is null then
    raise exception 'business and idempotency key are required' using errcode = '22023';
  end if;
  if p_switches is null or jsonb_typeof(p_switches) <> 'object' then
    raise exception 'switches must be a JSON object' using errcode = '22023';
  end if;
  if jsonb_typeof(p_switches) = 'object' and exists (
    select 1 from jsonb_object_keys(p_switches) key
     where key not in ('points','tiers','stamps','referral')
  ) then
    raise exception 'switches may only name points, tiers, stamps or referral'
      using errcode = '22023';
  end if;
  if exists (
    select 1 from jsonb_each(p_switches) entry
     where jsonb_typeof(entry.value) <> 'boolean'
  ) then
    raise exception 'every switch must be true or false' using errcode = '22023';
  end if;
  if p_switches = '{}'::jsonb then
    raise exception 'at least one switch is required' using errcode = '22023';
  end if;

  if not app.c45_owner_loyalty_write(p_business) then
    raise exception 'owner loyalty configuration access required' using errcode = '42501';
  end if;

  v_hash := md5(p_business::text || ':' || (
    select coalesce(string_agg(key || '=' || (p_switches ->> key), ',' order by key), '')
      from jsonb_object_keys(p_switches) key
  ));

  insert into public.programme_switch_operations_v314
    (business_id, idempotency_key, actor, request_hash)
  values (p_business, p_idempotency_key, v_actor, v_hash)
  on conflict (business_id, idempotency_key) do nothing;
  get diagnostics v_rows = row_count;
  if v_rows = 0 then
    select * into strict v_existing from public.programme_switch_operations_v314
     where business_id = p_business and idempotency_key = p_idempotency_key
       for update;
    if v_existing.request_hash is distinct from v_hash then
      raise exception 'idempotency key conflicts with another programme switch'
        using errcode = '23505';
    end if;
    if v_existing.result is not null then
      return v_existing.result;
    end if;
    raise exception 'programme switch already in progress' using errcode = '55P03';
  end if;

  perform 1 from public.businesses target where target.id = p_business for update;
  if not found then
    raise exception 'business does not exist' using errcode = '42501';
  end if;

  select coalesce(bool_or(spine.active) filter (where spine.kind = 'points'), false),
         coalesce(bool_or(spine.active) filter (where spine.kind = 'stamps'), false)
    into v_points_before, v_stamps_before
    from public.business_programmes spine
   where spine.business_id = p_business;

  insert into public.business_programmes (business_id, kind, active, sort, activated_at)
  select p_business, model.kind, model.running,
         (case model.kind
            when 'points' then 1 when 'tiers' then 2 when 'stamps' then 3 when 'referral' then 4
          end)::smallint,
         case when model.running then now() end
    from app.business_programmes_v307(p_business) model
  on conflict (business_id, kind) do nothing;

  select coalesce((p_switches ->> 'points')::boolean,
                  bool_or(spine.active) filter (where spine.kind = 'points'), false),
         coalesce((p_switches ->> 'tiers')::boolean,
                  bool_or(spine.active) filter (where spine.kind = 'tiers'), false),
         coalesce((p_switches ->> 'stamps')::boolean,
                  bool_or(spine.active) filter (where spine.kind = 'stamps'), false)
    into v_after_points, v_after_tiers, v_after_stamps
    from public.business_programmes spine
   where spine.business_id = p_business;

  if v_after_stamps and (v_after_points or v_after_tiers) then
    raise exception 'The stamp card runs on its own. Turn Points & gifts and Tier membership off '
      'before turning the stamp card on, or turn the stamp card off to run points and tiers.'
      using errcode = '22023';
  end if;

  for v_kind, v_want in
    select entry.key, (entry.value)::boolean
      from jsonb_each_text(p_switches) entry
     order by case entry.key
                when 'points' then 1 when 'tiers' then 2 when 'stamps' then 3 else 4 end
  loop
    select spine.active into v_before
      from public.business_programmes spine
     where spine.business_id = p_business and spine.kind = v_kind
       for update;
    if not found then
      raise exception 'business % has no % programme row', p_business, v_kind
        using errcode = 'XX001';
    end if;
    if v_before is distinct from v_want then
      update public.business_programmes spine
         set active = v_want,
             activated_at = case when v_want and not spine.active then now()
                                 else spine.activated_at end,
             deactivated_at = case when spine.active and not v_want then now()
                                   else spine.deactivated_at end
       where spine.business_id = p_business and spine.kind = v_kind;
      v_changes := v_changes || jsonb_build_object('kind', v_kind, 'from', v_before, 'to', v_want);
      insert into public.audit_log (business_id, actor, action, entity, entity_id, detail)
      select p_business, v_actor, 'PROGRAMME_SWITCH_V314', 'business_programmes', spine.id,
             jsonb_build_object('kind', v_kind, 'from', v_before, 'to', v_want,
                                'source', 'set_programmes_v314')
        from public.business_programmes spine
       where spine.business_id = p_business and spine.kind = v_kind;
    end if;
  end loop;

  -- v425 (a): the referral spine and referral_programs.enabled are ONE decision, so they move
  -- together or the engine and the switch disagree. Only an existing row is synced: this is not
  -- the place to invent a referral configuration a firm has never filled in -- with no row,
  -- app.on_sale_recorded finds no enabled programme and pays nothing, which is what an
  -- unconfigured referral should do.
  v_referral_want := (p_switches ->> 'referral')::boolean;
  if v_referral_want is not null then
    update public.referral_programs rp
       set enabled = v_referral_want
     where rp.business_id = p_business
       and rp.enabled is distinct from v_referral_want;
    if found then
      insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
      select p_business, v_actor, 'referral_enabled.synced_to_spine', 'referral_programs', rp.id,
             jsonb_build_object('enabled', v_referral_want, 'source', 'set_programmes_v314')
        from public.referral_programs rp where rp.business_id = p_business;
    end if;
  end if;

  select coalesce(bool_or(spine.active) filter (where spine.kind = 'points'), false),
         coalesce(bool_or(spine.active) filter (where spine.kind = 'stamps'), false)
    into v_points, v_stamps
    from public.business_programmes spine
   where spine.business_id = p_business;

  -- V355: THE POT MIGRATION IS GONE FROM THIS PATH, DELIBERATELY.
  -- Owner ruling 2026-08-16: "i just want to ensure that the points doesn't flow to become
  -- stamps, if points is off - it will be switch off and show no. of stamps. not conveniently
  -- convert all the points into stamps." V312 used to move every client's balance from the
  -- outgoing programme's pot into the incoming one on a points<->stamps switch, so a firm that
  -- toggled the stamp card on saw 75,877 POINTS reappear as 75,877 STAMPS -- a unit the customer
  -- never earned. Cubbly's own trail shows it firing four times in ninety seconds of toggling.
  -- points_ledger.programme_id already keeps the two pots apart; leaving them apart IS the fix.
  -- A programme that is switched off now simply parks its pot untouched, and the customer sees
  -- only the live programme's own balance, which is what "turned off" should mean. The machinery
  -- (programme_pot_migrations, app.migrate_programme_pot_v312, run_programme_pot_migrations_v312)
  -- is intentionally left in place and callable for a deliberate, super-admin-initiated move --
  -- it is only no longer fired automatically by an owner flipping a switch.
  -- V354: the spine has just moved, so the declared model follows it, in this same transaction.
  -- Without this the two disagree the moment an owner switches back (the live defect above).
  v_model := case when v_stamps then 'stamps' else 'classic' end;
  v_program_kind := case when v_stamps then 'stamps' else 'points' end;
  update public.loyalty_programs
     set loyalty_model = v_model, kind = v_program_kind
   where business_id = p_business
     and (loyalty_model is distinct from v_model or kind is distinct from v_program_kind);
  if found then
    insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
    values (p_business, v_actor, 'loyalty_model.synced_to_spine', 'loyalty_programs', p_business,
      jsonb_build_object('loyalty_model', v_model, 'kind', v_program_kind,
                         'source', 'set_programmes_v314'));
  end if;

  -- v425 (b): computed AFTER the spine has moved, so it describes the world the owner has just
  -- created. TRUE means "the referral programme is on, its reward is points or stamps, and that
  -- pot is not running" -- exactly the state app.on_sale_recorded will now refuse to pay.
  select coalesce(rp.enabled, false)
     and lower(btrim(coalesce(rp.reward_kind,'points'))) in ('points','stamps')
     and app.referral_payout_programme_v425(p_business, rp.reward_kind) is null
    into v_ref_unpayable
    from public.referral_programs rp
   where rp.business_id = p_business;
  v_ref_unpayable := coalesce(v_ref_unpayable, false);

  v_result := jsonb_build_object(
    'business_id', p_business,
    'changed', v_changes,
    'pot_migration_id', v_migration,
    'referral_reward_kind_now_unpayable', v_ref_unpayable,
    'programmes', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', spine.id,
               'kind', spine.kind,
               'active', spine.active,
               'running_since', spine.activated_at,
               'paused_since', spine.deactivated_at) order by spine.sort)
        from public.business_programmes spine
       where spine.business_id = p_business), '[]'::jsonb));

  update public.programme_switch_operations_v314
     set result = v_result
   where business_id = p_business and idempotency_key = p_idempotency_key;

  return v_result;
end
$function$;

-- ==============================================================================================
-- 6. THE CONFIGURATIONS THAT ARE ALREADY WRONG
-- ==============================================================================================
-- Idempotent, and it changes NO configuration -- reward_kind is the owner's declaration and this
-- migration does not get to reinterpret it. All it does is make the existing silence visible:
-- every still-pending referral belonging to a firm whose enabled reward type cannot be paid is
-- marked with the reason the trigger would give it. Expected effect on production the day this
-- was written: 3 firms qualify (AhXiang, Cubbly SPA, ZZ-SYNTHETIC) and ZERO rows are updated,
-- because none of them has a pending referral. It is written for the general case and for the
-- rehearsal, not because there is a backlog to clear.
update public.referrals r
   set blocked_reason = 'reward_kind_'||k.kind||'_requires_active_'||k.kind||'_programme'
  from (
    select rp.business_id, lower(btrim(coalesce(rp.reward_kind,'points'))) as kind
      from public.referral_programs rp
     where rp.enabled
       and lower(btrim(coalesce(rp.reward_kind,'points'))) in ('points','stamps')
       and app.referral_payout_programme_v425(rp.business_id, rp.reward_kind) is null
  ) k
 where r.business_id = k.business_id
   and r.status = 'pending'
   and r.blocked_reason is distinct from
       'reward_kind_'||k.kind||'_requires_active_'||k.kind||'_programme';

-- ============================================================================================
-- 8. ACL RESTATEMENT ON EVERY RE-ISSUED OVERLOAD
-- ============================================================================================
-- create-or-replace preserves ACLs on production, but a fresh replay of this chain would leave
-- PostgreSQL's default PUBLIC execute on these exact overloads. The preflight guard demands the
-- revoke be restated per overload; the grants are restated with it so a replayed database ends
-- up byte-for-byte where production is (each grant matches the function's own prior migration:
-- v421:354, v420:463, v314:585/590-591, v421:262 for the trigger body).
revoke all on function app.on_sale_recorded() from public, anon, authenticated;
revoke all on function public.save_referral_program_v421(uuid,boolean,text,integer,text,integer,boolean,integer,text) from public, anon;
grant execute on function public.save_referral_program_v421(uuid,boolean,text,integer,text,integer,boolean,integer,text) to authenticated;
revoke all on function public.save_referral_program_v420(uuid,boolean,text,integer,text,integer) from public, anon;
grant execute on function public.save_referral_program_v420(uuid,boolean,text,integer,text,integer) to authenticated;
revoke all privileges on function public.set_programmes_v314(uuid,jsonb,uuid) from public, anon;
grant execute on function public.set_programmes_v314(uuid,jsonb,uuid) to authenticated;
grant execute on function public.set_programmes_v314(uuid,jsonb,uuid) to service_role;

commit;
