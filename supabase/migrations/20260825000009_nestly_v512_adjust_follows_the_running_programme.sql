-- nestly_v512 — an owner's balance correction lands in the programme the customer is actually on.
--
-- FOUND WHILE VALIDATING A RECOMMENDATION (owner: "proceed as recommended. ensure that it is the
-- best way", 2026-08-25). The recommendation was that no new feature is needed to credit the
-- sales that earned nothing before v507 — each owner already has "Correct points balance" on the
-- customer, which calls adjust_points_v480 -> public.adjust_points. Checking that claim against
-- the actual tenants disproved it.
--
-- THE DEFECT. adjust_points resolves its target pot like this:
--
--     select spine.id into v_points_programme
--       from public.business_programmes spine
--      where spine.business_id = p_business and spine.kind = 'points';
--
-- No `and spine.active`. Every business carries all four spine rows from birth (v314 seeds them),
-- so this ALWAYS resolves to the points pot — including on a business running the stamp card,
-- where the points pot is dormant and no customer surface reads it. Since V312/v381 each
-- programme keeps its own pot and the customer is shown only the LIVE programme's balance, so on
-- a stamps business the correction is written, the RPC returns a cheerful new balance, and the
-- customer sees absolutely nothing. A silent wrong-pot credit that reports success is worse than
-- a refusal.
--
-- MEASURED, not reasoned: AhXiang runs stamps (spine stamps.active = true, points.active = false)
-- and its points spine ROW still exists — the exact shape that makes this fire. It is also the
-- tenant holding the S$3,200 sale of 2026-08-23 that earned nothing, i.e. the single most likely
-- business for an owner to reach for this control.
--
-- AND THE OTHER HALF: a stamp-card business had NO adjustment path at all. Nothing else in the
-- schema writes a stamps-programme points_ledger row outside the sale trigger and the one-time
-- v384 conversion, so a stamp count could never be corrected by hand — a customer shorted a stamp
-- had no remedy. Fixing the resolution fixes both faults with one change.
--
-- THE FIX. The target is the RUNNING programme: whichever of points/stamps carries an active
-- spine row. They are mutually exclusive — public.set_programmes_v314 refuses to have the stamp
-- card on beside points or tiers — so "the active one" is never ambiguous. With neither running,
-- the function now REFUSES instead of quietly filling a dormant pot: an owner who has switched
-- everything off has no balance to correct, and saying so is the honest answer.
--
-- Everything downstream is untouched: the same owner-only gate, the same open-workspace check,
-- the same overdraw guard, the same FEFO batch drain and reconciliation for negatives, the same
-- audited ledger write under the sanctioned 'adjust_points' scope. Only the pot they all point at
-- is now the right one. public.adjust_points_v480 is the ONLY caller (verified against
-- pg_get_functiondef across public and app), and it is unchanged — its idempotency envelope,
-- replay semantics and response shape are all preserved.

begin;

create or replace function public.adjust_points(p_business uuid, p_client uuid, p_points integer, p_reason text)
returns integer
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_actor uuid := auth.uid();
  v_staff uuid;
  v_balance integer;
  v_batch_balance integer;
  v_remaining integer;
  v_take integer;
  v_points_id uuid := gen_random_uuid();
  v_expiry timestamptz;
  v_batch record;
  lp public.loyalty_programs%rowtype;
  v_points_programme uuid;
  v_programme_kind text;   -- nestly_v512
begin
  perform app.acquire_loyalty_shared_v480(p_business);
  if coalesce(p_points, 0) = 0 then
    raise exception 'points adjustment must be non-zero';
  end if;
  if p_reason is null or length(btrim(p_reason)) < 3 then
    raise exception 'points adjustment reason must be at least 3 characters';
  end if;

  select s.id into v_staff
    from public.staff s
   where s.business_id = p_business
     and s.user_id = v_actor
     and s.active
     and s.role = 'owner'
   order by s.created_at
   limit 1
   for update;
  if not found then
    raise exception 'only an active owner may adjust points'
      using errcode = '42501';
  end if;

  perform app.require_workspace_open_v173(p_business);

  perform 1 from public.clients c
   where c.id = p_client and c.business_id = p_business
   for update;
  if not found then
    raise exception 'client does not belong to this business';
  end if;

  -- nestly_v512: the RUNNING programme, not the points row that every business owns whether or
  -- not it is switched on. points and stamps are mutually exclusive (set_programmes_v314 refuses
  -- the stamp card beside points/tiers), so the active one is unambiguous; ordering is a
  -- tie-break that can only matter if that invariant is ever broken.
  select spine.id, spine.kind into v_points_programme, v_programme_kind
    from public.business_programmes spine
   where spine.business_id = p_business
     and spine.kind in ('points','stamps')
     and spine.active
   order by case spine.kind when 'stamps' then 0 else 1 end
   limit 1;
  if v_points_programme is null then
    raise exception 'this business has no running points or stamp programme to adjust'
      using errcode = 'check_violation';
  end if;

  select coalesce(sum(pl.points), 0)::integer into v_balance
    from public.points_ledger pl
   where pl.business_id = p_business and pl.client_id = p_client
     and pl.programme_id = v_points_programme;
  if p_points < 0 and v_balance + p_points < 0 then
    raise exception 'points adjustment would overdraw balance % by %', v_balance, -p_points;
  end if;

  if p_points < 0 then
    select coalesce(sum(pb.remaining), 0)::integer into v_batch_balance
      from public.points_batches pb
     where pb.business_id = p_business
       and pb.client_id = p_client
       and pb.programme_id = v_points_programme
       and pb.remaining > 0;
    if v_batch_balance < -p_points then
      raise exception 'points batches % cannot prove negative adjustment %',
        v_batch_balance, -p_points
        using errcode = 'check_violation';
    end if;

    v_remaining := -p_points;
    for v_batch in
      select pb.id, pb.remaining
        from public.points_batches pb
       where pb.business_id = p_business
         and pb.client_id = p_client
         and pb.programme_id = v_points_programme
         and pb.remaining > 0
       order by pb.expires_at nulls last, pb.earned_at, pb.id
       for update
    loop
      exit when v_remaining = 0;
      v_take := least(v_batch.remaining, v_remaining);
      update public.points_batches
         set remaining = remaining - v_take
       where id = v_batch.id;
      v_remaining := v_remaining - v_take;
    end loop;
  if v_remaining <> 0 then raise exception 'points adjustment batch drain was incomplete' using errcode = 'XX001'; end if;
  if (select coalesce(sum(pb.remaining),0)::integer from public.points_batches pb where pb.business_id=p_business and pb.client_id=p_client and pb.programme_id=v_points_programme) <> v_batch_balance+p_points then raise exception 'points adjustment batch delta does not reconcile' using errcode='XX001'; end if;
  else
    -- nestly_v512: the fixed-expiry rule belongs to POINTS. A stamp is not a points batch with a
    -- shelf life — a stamp card's lifetime is its cycle (stamp_validity_days, enforced by the
    -- v435 cycle expiry), so an added stamp inherits the card it lands on rather than a made-up
    -- batch expiry. The lookup follows the resolved programme so this stays deliberate instead of
    -- happening by accident through a kind mismatch.
    if v_programme_kind = 'points' then
      select * into lp
        from public.loyalty_programs
       where business_id = p_business
         and active
         and kind = 'points'
       limit 1;
      v_expiry := case
        when found and lp.expiry_mode = 'fixed' and coalesce(lp.expiry_days, 0) > 0
          then now() + make_interval(days => lp.expiry_days)
        else null
      end;
    else
      v_expiry := null;
    end if;
    insert into public.points_batches (
      business_id, client_id, earned, remaining, earned_at, expires_at, programme_id
    ) values (
      p_business, p_client, p_points, p_points, now(), v_expiry, v_points_programme
    );
  end if;

  perform set_config('app.points_ledger_insert_id', v_points_id::text, true);
  perform set_config('app.points_ledger_write_scope', 'adjust_points', true);
  insert into public.points_ledger (
    id, business_id, client_id, entry_type, points, reference, actor, programme_id
  ) values (
    v_points_id, p_business, p_client, 'adjust', p_points, btrim(p_reason), v_actor,
    v_points_programme
  );
  perform set_config('app.points_ledger_insert_id', '', true);
  perform set_config('app.points_ledger_write_scope', '', true);

  return v_balance + p_points;
end $function$;

comment on function public.adjust_points(uuid,uuid,integer,text) is
  'nestly_v512: an owner balance correction lands in the RUNNING programme''s pot (points or stamps), never the dormant points pot a stamps business still owns; refuses when no programme is running.';

revoke all on function public.adjust_points(uuid,uuid,integer,text) from public, anon;
grant execute on function public.adjust_points(uuid,uuid,integer,text) to authenticated;
grant execute on function public.adjust_points(uuid,uuid,integer,text) to service_role;

commit;
