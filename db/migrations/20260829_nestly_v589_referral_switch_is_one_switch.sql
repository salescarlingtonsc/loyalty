-- nestly_v589 — the referral programme has ONE switch, whichever door the owner uses.
--
-- Owner, 2026-08-29 (pre-go-live): "unify the referral switches."
--
-- THE SPLIT. Referral on/off lives in two columns that both claim authority:
--   * public.referral_programs.enabled — what app.on_sale_recorded actually pays on;
--   * public.business_programmes(kind='referral').active — the spine, what every Rewards &
--     Offer surface presents as running.
-- v425 closed HALF of it: set_programmes_v314 (the Rewards Programme switch) moves `enabled` in
-- the same transaction as the spine. But the standalone Referrals page saves through
-- save_referral_program_v421, which wrote referral_programs ONLY — so its Status dropdown moved
-- the paying column and never told the spine. Measured live: Jess Salon has enabled=true (paying
-- 200 points per qualified friend, points pot ON) while its spine says referral is off — the
-- engine pays, silently, under a UI that says Off. That is tenant-gate finding D08.
--
-- THE FIX, mirroring v425 exactly in the other direction: save_referral_program_v421 now syncs
-- the spine row inside its own transaction whenever p_enabled differs from spine.active — same
-- update shape as set_programmes_v314 (active + activated_at/deactivated_at), same audit trail.
-- Turning ON with no spine row raises the same XX001 set_programmes_v314 raises (v565 seeds the
-- row for every business, so a missing one is corrupt state, not a legitimate tenant). No client
-- sequencing can split the two columns again, from either door.
--
-- ONE-TIME REPAIR: the single divergent tenant is aligned spine := enabled. Direction: `enabled`
-- is the owner's last expressed choice (the Referrals page's own Status control wrote it) AND the
-- column the engine has been paying on — so the spine comes up to match reality rather than the
-- payer being switched off underneath a programme the owner believes is running. Their points pot
-- is on, so nothing unkeepable goes live.
--
-- Everything else in save_referral_program_v421 — the owner gate, the loyalty exclusive lock, the
-- per-kind validation, the v425 payable-pot check, the upsert's kind-preserving arms — is
-- byte-preserved.

begin;

create or replace function public.save_referral_program_v421(
  p_business uuid, p_enabled boolean, p_reward_kind text, p_reward_points integer,
  p_reward_label text, p_min_spend_cents integer, p_friend_enabled boolean,
  p_friend_reward_points integer, p_friend_reward_label text)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_actor uuid := auth.uid();
  v_staff uuid;
  v_kind text := lower(btrim(coalesce(p_reward_kind,'points')));
  v_label text := nullif(btrim(coalesce(p_reward_label,'')),'');
  v_friend_on boolean := coalesce(p_friend_enabled,true);
  v_friend_label text := nullif(btrim(coalesce(p_friend_reward_label,'')),'');
  v_program public.referral_programs%rowtype;
  v_spine_before boolean;
  v_spine_found boolean := false;
begin
  perform app.acquire_loyalty_exclusive_v480(p_business);
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

  -- nestly_v589: the mirror of v425. `enabled` and the spine are ONE decision; this is the second
  -- door onto it, so it moves both in one transaction — same update shape and audit discipline as
  -- set_programmes_v314. The row is guaranteed to exist above, so v425's "on with nothing to pay"
  -- state cannot be created from here either.
  select spine.active into v_spine_before
    from public.business_programmes spine
   where spine.business_id = p_business and spine.kind = 'referral'
     for update;
  v_spine_found := found;
  if not v_spine_found and p_enabled then
    raise exception 'business % has no referral programme row', p_business using errcode = 'XX001';
  end if;
  if v_spine_found and v_spine_before is distinct from p_enabled then
    update public.business_programmes spine
       set active = p_enabled,
           activated_at = case when p_enabled and not spine.active then now()
                               else spine.activated_at end,
           deactivated_at = case when spine.active and not p_enabled then now()
                                 else spine.deactivated_at end
     where spine.business_id = p_business and spine.kind = 'referral';
    insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
    select p_business, v_actor, 'referral_spine.synced_to_program', 'business_programmes', spine.id,
           jsonb_build_object('from', v_spine_before, 'to', p_enabled, 'source', 'save_referral_program_v421')
      from public.business_programmes spine
     where spine.business_id = p_business and spine.kind = 'referral';
  end if;

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
revoke all on function public.save_referral_program_v421(uuid,boolean,text,integer,text,integer,boolean,integer,text) from public, anon;
grant execute on function public.save_referral_program_v421(uuid,boolean,text,integer,text,integer,boolean,integer,text) to authenticated, service_role;

-- One-time repair (tenant-gate D08): align the spine with the paying column for the divergent
-- tenant(s). Scoped to rows where enabled=true and the spine disagrees — the reverse direction
-- (spine on, enabled off) does not exist live and, if it ever did, `enabled` already pays nothing,
-- so there would be nothing dangerous to repair.
with repaired as (
  update public.business_programmes spine
     set active = true,
         activated_at = coalesce(spine.activated_at, now())
    from public.referral_programs rp
   where rp.business_id = spine.business_id
     and spine.kind = 'referral'
     and rp.enabled = true
     and spine.active = false
  returning spine.business_id, spine.id
)
insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
select repaired.business_id, null, 'referral_spine.repaired_v589', 'business_programmes', repaired.id,
       jsonb_build_object('to', true, 'reason', 'tenant-gate D08: enabled=true while spine off')
  from repaired;

commit;
