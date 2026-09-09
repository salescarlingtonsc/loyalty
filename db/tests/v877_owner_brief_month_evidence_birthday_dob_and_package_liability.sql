-- nestly_v877 rollback suite — the month fact carries evidence, the birthday fact reads the
-- profile birth date, the liability answer counts prepaid sessions.
--
-- Run inside a transaction against production and ROLLED BACK. The three facts are called for
-- Cubbly SPA (seven prepaid packages) and their figures recomputed independently.

\set ON_ERROR_STOP on

begin;

do $suite$
declare
  cb constant uuid := '8492e8d6-8888-4383-ada0-7e1ed69f0caa';
  owner_uid uuid; month_fact jsonb; bday jsonb; liab jsonb; expected bigint; n integer := 0;
begin
  -- I1..I3: month
  month_fact := app.owner_brief_fact_month_v828(cb);
  n := n + 1;
  if (month_fact->>'status') <> 'ok' or month_fact->>'evidence' not in ('ok','insufficient') then
    raise exception 'I% failed: month fact has no evidence verdict: %', n, month_fact::text;
  end if;
  n := n + 1;
  if (month_fact->>'evidence') = 'insufficient' and (month_fact->>'on_pace_cents') is not null then
    raise exception 'I% failed: a pace is projected on insufficient evidence', n;
  end if;
  n := n + 1;
  if (month_fact->>'evidence') = 'ok' and ((month_fact->>'days_elapsed')::int < 7 or (month_fact->>'trading_days_mtd')::int < 3) then
    raise exception 'I% failed: evidence ok below the floor', n;
  end if;

  -- I4: birthdays
  bday := app.owner_brief_fact_birthdays_v828(cb);
  n := n + 1;
  if (bday->>'status') <> 'ok' or position('customer_profiles' in (bday->>'source')) = 0 then
    raise exception 'I% failed: birthday fact status/source: %', n, bday::text;
  end if;

  -- I5..I6: liability
  -- get_reports_summary inside the liability fact is owner-gated: impersonate Cubbly's real owner,
  -- exactly as the nightly refresh runs it (v867 suite precedent).
  select s.user_id into owner_uid from public.staff s where s.business_id = cb and s.role = 'owner' and s.user_id is not null limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', owner_uid, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', owner_uid::text, true);
  liab := app.owner_brief_fact_liability_v828(cb);
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  select coalesce(sum(round(cp.price_cents_snapshot::numeric * cp.remaining / nullif(cp.sessions_snapshot,0))), 0)::bigint into expected
    from public.client_packages cp
    join public.clients c on c.id = cp.client_id and c.business_id = cp.business_id
   where cp.business_id = cb and cp.status = 'active' and cp.remaining > 0
     and (cp.expires_at is null or cp.expires_at > now()) and not c.is_synthetic;
  n := n + 1;
  if (liab->>'status') <> 'ok' or (liab->>'prepaid_sessions_liability_cents')::bigint <> expected then
    raise exception 'I% failed: prepaid liability % <> recomputed %', n, liab->>'prepaid_sessions_liability_cents', expected;
  end if;
  n := n + 1;
  if (liab->>'known_cents_total')::bigint <> coalesce((liab->>'credit_liability_cents')::bigint,0)
       + coalesce((liab->>'stored_value_liability_cents')::bigint,0) + expected then
    raise exception 'I% failed: known_cents_total does not add up', n;
  end if;
  n := n + 1;
  if (liab ? 'gift_card_liability_cents') then raise exception 'I% failed: a retired module still contributes', n; end if;

  raise notice 'nestly_v877 suite: % assertions passed (prepaid liability %c)', n, expected;
end
$suite$;

rollback;
