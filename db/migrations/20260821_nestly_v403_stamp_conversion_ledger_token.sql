-- ============================================================================
-- nestly_v403 — the stamp-card switch could never write its own ledger rows
--
-- Owner, photo 3 (2026-08-21): "set up stamp does not work". The Stamp Card
-- setup page showed
--   "points_ledger may only be appended by approved loyalty routes
--    Nothing was changed."
--
-- Cause. app.loyalty_ledger_write_guard (v312) admits an insert into points_ledger
-- only when BOTH of these hold:
--   * app.points_ledger_write_scope is one of seven approved routes, and
--   * app.points_ledger_insert_id equals the inserted row's own id.
-- public.business_switch_to_stamps_v384 set the scope ('programme_pot_transfer',
-- which IS approved) but never set the token, and generated both row ids inline
-- with gen_random_uuid() inside the VALUES list, so there was no id to publish.
-- v_token was therefore NULL, `v_token is distinct from new.id::text` was true,
-- and the guard raised 42501 on the first conversion row.
--
-- Blast radius. The conversion loop only runs for customers whose spendable
-- points are worth at least one stamp, so a business with no points converted
-- cleanly and a business with points could not switch at all. That is why this
-- survived v384's own tests and reached the owner: the failure needs real
-- balances. Cubbly has them.
--
-- Fix. Generate each id into a variable and publish it immediately before its
-- own insert, then clear both settings — the exact shape every working route
-- already uses (see the points_expiry sweep in v312). Nothing else about the
-- function changes: same name, same signature, same arguments, same accounting,
-- same batches, same idempotency. The guard itself is NOT touched, and no new
-- route is added to its allowlist.
-- ============================================================================

begin;

create or replace function public.business_switch_to_stamps_v384(
  p_business uuid,
  p_convert_existing_points boolean,
  p_points_per_stamp integer,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_points_programme uuid;
  v_stamps_programme uuid;
  v_rate integer := coalesce(p_points_per_stamp, 0);
  v_existing jsonb;
  v_switch jsonb;
  v_row record;
  v_batch record;
  v_left integer;
  v_take integer;
  v_customers integer := 0;
  v_points integer := 0;
  v_stamps integer := 0;
  v_leftover integer := 0;
  v_response jsonb;
  v_spend_ledger_id uuid;
  v_issue_ledger_id uuid;
begin
  if p_idempotency_key is null then
    raise exception 'idempotency key is required' using errcode = '22023';
  end if;
  if not app.c45_owner_loyalty_write(p_business) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if coalesce(p_convert_existing_points, false) and v_rate <= 0 then
    raise exception 'points per stamp must be greater than zero' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('v384:stamp-switch:'||p_business::text, 0));

  select response into v_existing
    from public.programme_stamp_conversions_v384
   where business_id = p_business and idempotency_key = p_idempotency_key;
  if found then
    return v_existing;
  end if;

  select id into v_points_programme
    from public.business_programmes
   where business_id = p_business and kind = 'points'
   order by sort, id
   limit 1;
  select id into v_stamps_programme
    from public.business_programmes
   where business_id = p_business and kind = 'stamps'
   order by sort, id
   limit 1;
  if v_points_programme is null or v_stamps_programme is null then
    raise exception 'points and stamp programmes are required' using errcode = '23514';
  end if;

  v_switch := public.set_programmes_v314(
    p_business,
    jsonb_build_object('stamps', true, 'points', false, 'tiers', false),
    p_idempotency_key
  );

  if coalesce(p_convert_existing_points, false) then
    if exists (
      select 1 from public.programme_stamp_conversions_v384 done
       where done.business_id = p_business
         and done.points_programme_id = v_points_programme
         and done.stamps_programme_id = v_stamps_programme
    ) then
      raise exception 'points have already been converted to this stamp card'
        using errcode = '23505';
    end if;

    for v_row in
      with balances as (
        select coalesce(l.client_id, b.client_id) as client_id,
               greatest(least(coalesce(l.points_balance, 0), coalesce(b.batch_balance, 0)), 0)::integer as spendable_points
          from (
            select client_id, sum(points)::integer as points_balance
              from public.points_ledger
             where business_id = p_business and programme_id = v_points_programme
             group by client_id
          ) l
          full join (
            select client_id, sum(remaining)::integer as batch_balance
              from public.points_batches
             where business_id = p_business
               and programme_id = v_points_programme
               and remaining > 0
             group by client_id
          ) b using (client_id)
      )
      select client_id,
             ((spendable_points / v_rate) * v_rate)::integer as points_to_convert,
             (spendable_points / v_rate)::integer as stamps_to_issue,
             (spendable_points - ((spendable_points / v_rate) * v_rate))::integer as leftover_points
        from balances
       where (spendable_points / v_rate)::integer > 0
       order by client_id
    loop
      v_left := v_row.points_to_convert;
      for v_batch in
        select id, remaining
          from public.points_batches
         where business_id = p_business
           and client_id = v_row.client_id
           and programme_id = v_points_programme
           and remaining > 0
         order by expires_at nulls last, earned_at, id
         for update
      loop
        exit when v_left = 0;
        v_take := least(v_batch.remaining, v_left);
        update public.points_batches
           set remaining = remaining - v_take
         where id = v_batch.id;
        v_left := v_left - v_take;
      end loop;
      if v_left <> 0 then
        raise exception 'could not prove points batch conversion for customer %', v_row.client_id
          using errcode = '23514';
      end if;

      -- V403 (owner, photo 3: "set up stamp does not work").
      -- The points_ledger guard (v312) admits an insert only when BOTH
      -- app.points_ledger_write_scope names an approved route AND
      -- app.points_ledger_insert_id equals the row's own id. v384 set the scope and never the
      -- token, and generated the ids inline so there was nothing to publish -- so both inserts
      -- below raised 42501 'points_ledger may only be appended by approved loyalty routes'.
      -- Any business holding points could therefore never switch to the stamp card.
      -- Each id is now generated into a variable and published before its own insert, the same
      -- shape every working route uses (see the points_expiry sweep in v312).
      v_spend_ledger_id := gen_random_uuid();
      perform set_config('app.points_ledger_insert_id', v_spend_ledger_id::text, true);
      perform set_config('app.points_ledger_write_scope', 'programme_pot_transfer', true);
      insert into public.points_ledger(
        id,business_id,client_id,entry_type,points,sale_id,reference,actor,programme_id
      ) values (
        v_spend_ledger_id, p_business, v_row.client_id, 'adjust', -v_row.points_to_convert,
        null, 'stamp conversion: points spent', null, v_points_programme
      );
      v_issue_ledger_id := gen_random_uuid();
      perform set_config('app.points_ledger_insert_id', v_issue_ledger_id::text, true);
      insert into public.points_ledger(
        id,business_id,client_id,entry_type,points,sale_id,reference,actor,programme_id
      ) values (
        v_issue_ledger_id, p_business, v_row.client_id, 'adjust', v_row.stamps_to_issue,
        null, 'stamp conversion: stamps issued', null, v_stamps_programme
      );
      perform set_config('app.points_ledger_insert_id', '', true);
      perform set_config('app.points_ledger_write_scope', '', true);

      insert into public.points_batches(
        business_id,client_id,earned,remaining,sale_id,earned_at,expires_at,programme_id
      ) values (
        p_business, v_row.client_id, v_row.stamps_to_issue, v_row.stamps_to_issue,
        null, statement_timestamp(), null, v_stamps_programme
      );

      v_customers := v_customers + 1;
      v_points := v_points + v_row.points_to_convert;
      v_stamps := v_stamps + v_row.stamps_to_issue;
      v_leftover := v_leftover + v_row.leftover_points;
    end loop;
  end if;

  v_response := jsonb_build_object(
    'ok', true,
    'converted', coalesce(p_convert_existing_points, false),
    'points_per_stamp', case when coalesce(p_convert_existing_points, false) then v_rate else null end,
    'customers', v_customers,
    'points_converted', v_points,
    'stamps_issued', v_stamps,
    'leftover_points', v_leftover,
    'programmes', v_switch->'programmes'
  );

  if coalesce(p_convert_existing_points, false) then
    insert into public.programme_stamp_conversions_v384(
      business_id,idempotency_key,points_programme_id,stamps_programme_id,
      points_per_stamp,converted_customers,converted_points,issued_stamps,leftover_points,response
    ) values (
      p_business,p_idempotency_key,v_points_programme,v_stamps_programme,
      v_rate,v_customers,v_points,v_stamps,v_leftover,v_response
    );
  end if;

  return v_response;
exception when others then
  perform set_config('app.points_ledger_insert_id', '', true);
  perform set_config('app.points_ledger_write_scope', '', true);
  raise;
end;
$$;

revoke all privileges on function public.business_switch_to_stamps_v384(uuid,boolean,integer,uuid)
  from public, anon;
grant execute on function public.business_switch_to_stamps_v384(uuid,boolean,integer,uuid)
  to authenticated;

comment on function public.business_switch_to_stamps_v384(uuid,boolean,integer,uuid) is
  'v403: publishes app.points_ledger_insert_id for each conversion row. v384 set only the '
  'write scope, so the v312 ledger guard rejected every insert with 42501 and no business '
  'holding points could switch to the stamp card.';

commit;
