-- Rollback-only acceptance for nestly_v550 — the recovered-revenue report is conservative and auditable.
--   supabase db query --linked -f db/tests/v550_recovery_report.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
-- Fixture: production tenant qa-kaya-toast, every row rolled back, summary assertions are DELTAS
-- against a baseline call. Visits are `service` sales; offsets are days before now().
-- Report window: [today-45d, tomorrow) SGT — every fixture intervention's 30-day window is closed
-- or measurable inside it.
--
--   H "Voucher Winner"     visits -120,-90 · voucher grant -40d (REDEEMED against the -30d sale)
--                          returns -30d ($30, inside) and -5d ($99, OUTSIDE the 30d window)
--   I "Message Returner"   visits -100,-70 · outreach -35d · returns -20d ($20, inside)
--   J "Messaged Away"      visits -80,-60  · outreach -30d · never returns
--   K "Not Lapsed"         visits -18,-10  · outreach -5d  · 5-day absence -> EXCLUDED, not a win
--   L "Double Contact"     visits -90,-70  · voucher -38d AND outreach -33d -> ONE intervention
--                          returns -15d ($50, inside the voucher's window)
--   M "Baseline Stayer"    visits -100,-80 · no intervention · never returns
--   N "Baseline Returner"  visits -110,-85 · no intervention · returns -40d (inside 30d of window start)
--   P "Synthetic Ghost"    is_synthetic; voucher + return -> appears in NOTHING
--
--   01  baseline report call as the owner (shape sanity)
--   02  outreach writer: same-day taps collapse to one row; a foreign client raises 22023
--   03  outreach rows are immutable evidence (update -> 42501)
--   04  deltas: treated +4 (2 vouchers + 2 messages), returned +3, gross +10000,
--       excluded_not_lapsed +1, baseline cohort +2 / returned +1, redeemed voucher +1 (+3000)
--   05  internal consistency: monthly sums equal totals; net follows the stated formula from the
--       report's own numbers and never exceeds gross
--   06  authorization: stranger 42501 on the report AND the writer; anon holds EXECUTE on neither
--
begin;

create temp table _r(k text, v text) on commit drop;
create temp table _fx(label text primary key, client_id uuid) on commit drop;
create temp table _base(payload jsonb) on commit drop;

create or replace function pg_temp.as_v550_user(p_uid uuid) returns void language plpgsql as $$
begin
  execute 'reset role';
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
end
$$;
grant execute on function pg_temp.as_v550_user(uuid) to public;

create or replace function pg_temp.v550_owner() returns uuid language sql as $$
  select st.user_id from public.staff st
  where st.business_id = '38b30e6d-de73-4c2b-a2ca-19b08950896c'
    and st.role = 'owner' and st.user_id is not null
  order by st.created_at limit 1
$$;

create or replace function pg_temp.v550_report() returns jsonb language plpgsql as $$
declare p jsonb;
begin
  perform pg_temp.as_v550_user(pg_temp.v550_owner());
  p := public.get_recovery_report_v550(
    '38b30e6d-de73-4c2b-a2ca-19b08950896c',
    ((now() at time zone 'Asia/Singapore')::date - 45),
    ((now() at time zone 'Asia/Singapore')::date + 1));
  execute 'reset role';
  return p;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 01  baseline call
-- ---------------------------------------------------------------------------------------------
do $$
declare p jsonb;
begin
  p := pg_temp.v550_report();
  insert into _base values (p);
  insert into _r values ('01_baseline',
    case when (p ?& array['window','interventions','returned','recovered','baseline','net','monthly'])
      then 'PASS ' || (p->'interventions')::text || ' ' || (p->'baseline')::text
      else 'FAIL shape: ' || coalesce(p::text,'null') end);
end $$;

-- ---------------------------------------------------------------------------------------------
-- fixtures
-- ---------------------------------------------------------------------------------------------
do $$
declare
  b uuid := '38b30e6d-de73-4c2b-a2ca-19b08950896c';
  v_id uuid; v_campaign uuid; v_sale_h30 uuid; v_off integer;
begin
  execute 'reset role';
  insert into public.bringback_campaigns_v361(business_id, name, reward_label, away_days)
    values (b, 'V550 Suite Campaign', 'Free kopi', 30) returning id into v_campaign;

  -- H
  insert into public.clients(business_id, full_name, phone, is_synthetic)
    values (b, 'V550 Voucher Winner', '90005501', false) returning id into v_id;
  insert into _fx values ('H', v_id);
  foreach v_off in array array[120,90] loop
    insert into public.sales(business_id, client_id, kind, amount_cents, counts_as_visit, earns_points, occurred_at)
      values (b, v_id, 'service', 2000, true, false, now() - make_interval(days => v_off));
  end loop;
  insert into public.sales(business_id, client_id, kind, amount_cents, counts_as_visit, earns_points, occurred_at)
    values (b, v_id, 'service', 3000, true, false, now() - make_interval(days => 30))
    returning id into v_sale_h30;
  insert into public.sales(business_id, client_id, kind, amount_cents, counts_as_visit, earns_points, occurred_at)
    values (b, v_id, 'service', 9900, true, false, now() - make_interval(days => 5));
  insert into public.bringback_grants_v361(business_id, campaign_id, client_id, reward_label, away_days,
      cycle_key, status, granted_at, redeemed_at, redeemed_sale_id)
    values (b, v_campaign, v_id, 'Free kopi', 30,
      (now() - make_interval(days => 40))::date, 'redeemed',
      now() - make_interval(days => 40), now() - make_interval(days => 30), v_sale_h30);

  -- I
  insert into public.clients(business_id, full_name, phone, is_synthetic)
    values (b, 'V550 Message Returner', '90005502', false) returning id into v_id;
  insert into _fx values ('I', v_id);
  foreach v_off in array array[100,70] loop
    insert into public.sales(business_id, client_id, kind, amount_cents, counts_as_visit, earns_points, occurred_at)
      values (b, v_id, 'service', 2000, true, false, now() - make_interval(days => v_off));
  end loop;
  insert into public.attention_outreach_v550(business_id, client_id, occurred_at, occurred_on)
    values (b, v_id, now() - make_interval(days => 35), ((now() - make_interval(days => 35)) at time zone 'Asia/Singapore')::date);
  insert into public.sales(business_id, client_id, kind, amount_cents, counts_as_visit, earns_points, occurred_at)
    values (b, v_id, 'service', 2000, true, false, now() - make_interval(days => 20));

  -- J
  insert into public.clients(business_id, full_name, phone, is_synthetic)
    values (b, 'V550 Messaged Away', '90005503', false) returning id into v_id;
  insert into _fx values ('J', v_id);
  foreach v_off in array array[80,60] loop
    insert into public.sales(business_id, client_id, kind, amount_cents, counts_as_visit, earns_points, occurred_at)
      values (b, v_id, 'service', 2000, true, false, now() - make_interval(days => v_off));
  end loop;
  insert into public.attention_outreach_v550(business_id, client_id, occurred_at, occurred_on)
    values (b, v_id, now() - make_interval(days => 30), ((now() - make_interval(days => 30)) at time zone 'Asia/Singapore')::date);

  -- K
  insert into public.clients(business_id, full_name, phone, is_synthetic)
    values (b, 'V550 Not Lapsed', '90005504', false) returning id into v_id;
  insert into _fx values ('K', v_id);
  foreach v_off in array array[18,10] loop
    insert into public.sales(business_id, client_id, kind, amount_cents, counts_as_visit, earns_points, occurred_at)
      values (b, v_id, 'service', 2000, true, false, now() - make_interval(days => v_off));
  end loop;
  insert into public.attention_outreach_v550(business_id, client_id, occurred_at, occurred_on)
    values (b, v_id, now() - make_interval(days => 5), ((now() - make_interval(days => 5)) at time zone 'Asia/Singapore')::date);

  -- L
  insert into public.clients(business_id, full_name, phone, is_synthetic)
    values (b, 'V550 Double Contact', '90005505', false) returning id into v_id;
  insert into _fx values ('L', v_id);
  foreach v_off in array array[90,70] loop
    insert into public.sales(business_id, client_id, kind, amount_cents, counts_as_visit, earns_points, occurred_at)
      values (b, v_id, 'service', 2000, true, false, now() - make_interval(days => v_off));
  end loop;
  insert into public.bringback_grants_v361(business_id, campaign_id, client_id, reward_label, away_days, cycle_key, granted_at)
    values (b, v_campaign, v_id, 'Free kopi', 30, (now() - make_interval(days => 38))::date, now() - make_interval(days => 38));
  insert into public.attention_outreach_v550(business_id, client_id, occurred_at, occurred_on)
    values (b, v_id, now() - make_interval(days => 33), ((now() - make_interval(days => 33)) at time zone 'Asia/Singapore')::date);
  insert into public.sales(business_id, client_id, kind, amount_cents, counts_as_visit, earns_points, occurred_at)
    values (b, v_id, 'service', 5000, true, false, now() - make_interval(days => 15));

  -- M
  insert into public.clients(business_id, full_name, phone, is_synthetic)
    values (b, 'V550 Baseline Stayer', '90005506', false) returning id into v_id;
  insert into _fx values ('M', v_id);
  foreach v_off in array array[100,80] loop
    insert into public.sales(business_id, client_id, kind, amount_cents, counts_as_visit, earns_points, occurred_at)
      values (b, v_id, 'service', 2000, true, false, now() - make_interval(days => v_off));
  end loop;

  -- N
  insert into public.clients(business_id, full_name, phone, is_synthetic)
    values (b, 'V550 Baseline Returner', '90005507', false) returning id into v_id;
  insert into _fx values ('N', v_id);
  foreach v_off in array array[110,85,40] loop
    insert into public.sales(business_id, client_id, kind, amount_cents, counts_as_visit, earns_points, occurred_at)
      values (b, v_id, 'service', 2000, true, false, now() - make_interval(days => v_off));
  end loop;

  -- P (synthetic)
  insert into public.clients(business_id, full_name, phone, is_synthetic)
    values (b, 'V550 Synthetic Ghost', '90005508', true) returning id into v_id;
  insert into _fx values ('P', v_id);
  foreach v_off in array array[100,80] loop
    insert into public.sales(business_id, client_id, kind, amount_cents, counts_as_visit, earns_points, occurred_at)
      values (b, v_id, 'service', 2000, true, false, now() - make_interval(days => v_off));
  end loop;
  insert into public.bringback_grants_v361(business_id, campaign_id, client_id, reward_label, away_days, cycle_key, granted_at)
    values (b, v_campaign, v_id, 'Free kopi', 30, (now() - make_interval(days => 40))::date, now() - make_interval(days => 40));
  insert into public.sales(business_id, client_id, kind, amount_cents, counts_as_visit, earns_points, occurred_at)
    values (b, v_id, 'service', 7000, true, false, now() - make_interval(days => 25));
end $$;

-- ---------------------------------------------------------------------------------------------
-- 02  the outreach writer: dedupe + membership guard, called as the real owner
-- ---------------------------------------------------------------------------------------------
do $$
declare
  b uuid := '38b30e6d-de73-4c2b-a2ca-19b08950896c';
  v_client uuid; v_foreign uuid; v_rows integer; v_state text := 'no error';
  r1 jsonb; r2 jsonb;
begin
  execute 'reset role';
  select client_id into v_client from _fx where label = 'M';
  select c.id into v_foreign from public.clients c
    where c.business_id <> b limit 1;
  perform pg_temp.as_v550_user(pg_temp.v550_owner());
  r1 := public.record_attention_outreach_v550(b, v_client);
  r2 := public.record_attention_outreach_v550(b, v_client);
  begin
    perform public.record_attention_outreach_v550(b, v_foreign);
  exception when others then v_state := SQLSTATE;
  end;
  execute 'reset role';
  select count(*) into v_rows from public.attention_outreach_v550
    where business_id = b and client_id = v_client;
  -- The two taps above also make M an intervened client TODAY; the report window below still
  -- counts M in the baseline? NO — M is now intervened, which would break check 04's baseline
  -- delta. Remove the evidence rows for M via the suite's superuser context: allowed here ONLY
  -- because this is a rolled-back fixture correction, not an application path.
  alter table public.attention_outreach_v550 disable trigger attention_outreach_v550_immutable;
  delete from public.attention_outreach_v550 where business_id = b and client_id = v_client;
  alter table public.attention_outreach_v550 enable trigger attention_outreach_v550_immutable;
  insert into _r values ('02_writer_dedupe_and_guard',
    case when r1->>'status' = 'ok' and r2->>'status' = 'ok' and v_rows = 1 and v_state = '22023'
      then 'PASS two taps -> one row, foreign client 22023'
      else 'FAIL rows=' || v_rows || ' state=' || v_state
        || ' r1=' || coalesce(r1::text,'null') || ' r2=' || coalesce(r2::text,'null') end);
end $$;

-- ---------------------------------------------------------------------------------------------
-- 03  outreach rows are immutable evidence
-- ---------------------------------------------------------------------------------------------
do $$
declare
  b uuid := '38b30e6d-de73-4c2b-a2ca-19b08950896c';
  v_state text := 'no error';
begin
  execute 'reset role';
  begin
    update public.attention_outreach_v550 set channel = 'whatsapp_manual'
      where business_id = b;
  exception when others then v_state := SQLSTATE;
  end;
  insert into _r values ('03_immutable',
    case when v_state = '42501' then 'PASS update refused 42501'
      else 'FAIL state=' || v_state end);
end $$;

-- ---------------------------------------------------------------------------------------------
-- 04  the report deltas
-- ---------------------------------------------------------------------------------------------
do $$
declare
  p jsonb; base jsonb;
  d_treated int; d_vouchers int; d_messages int; d_returned int; d_excluded int;
  d_gross bigint; d_bcohort int; d_breturned int; d_redeemed int; d_redeemed_cents bigint;
begin
  p := pg_temp.v550_report();
  select payload into base from _base;
  d_treated  := (p#>>'{interventions,treated}')::int  - (base#>>'{interventions,treated}')::int;
  d_vouchers := (p#>>'{interventions,vouchers}')::int - (base#>>'{interventions,vouchers}')::int;
  d_messages := (p#>>'{interventions,messages}')::int - (base#>>'{interventions,messages}')::int;
  d_excluded := (p#>>'{interventions,excluded_not_lapsed}')::int - (base#>>'{interventions,excluded_not_lapsed}')::int;
  d_returned := (p#>>'{returned,count}')::int - (base#>>'{returned,count}')::int;
  d_gross    := (p#>>'{recovered,gross_cents}')::bigint - (base#>>'{recovered,gross_cents}')::bigint;
  d_bcohort  := (p#>>'{baseline,cohort}')::int - (base#>>'{baseline,cohort}')::int;
  d_breturned:= (p#>>'{baseline,returned}')::int - (base#>>'{baseline,returned}')::int;
  d_redeemed := (p#>>'{recovered,redeemed_vouchers}')::int - (base#>>'{recovered,redeemed_vouchers}')::int;
  d_redeemed_cents := (p#>>'{recovered,redeemed_voucher_cents}')::bigint - (base#>>'{recovered,redeemed_voucher_cents}')::bigint;
  insert into _r values ('04_deltas',
    case when d_treated = 4 and d_vouchers = 2 and d_messages = 2 and d_returned = 3
           and d_gross = 10000 and d_excluded = 1
           and d_bcohort = 2 and d_breturned = 1
           and d_redeemed = 1 and d_redeemed_cents = 3000
      then 'PASS treated+4 (2v/2m) returned+3 gross+10000 excluded+1 baseline+2/+1 redeemed+1/+3000'
      else 'FAIL treated+' || d_treated || ' v+' || d_vouchers || ' m+' || d_messages
        || ' returned+' || d_returned || ' gross+' || d_gross || ' excluded+' || d_excluded
        || ' bcohort+' || d_bcohort || ' breturned+' || d_breturned
        || ' redeemed+' || d_redeemed || '/' || d_redeemed_cents end);
end $$;

-- ---------------------------------------------------------------------------------------------
-- 05  internal consistency: monthly sums = totals, net follows the stated formula
-- ---------------------------------------------------------------------------------------------
do $$
declare
  p jsonb;
  m_interventions int; m_returned int; m_gross bigint;
  t_treated int; t_returned int; t_gross bigint;
  b_cohort int; b_returned int; net bigint; expected bigint;
begin
  p := pg_temp.v550_report();
  select coalesce(sum((x->>'interventions')::int),0),
         coalesce(sum((x->>'returned')::int),0),
         coalesce(sum((x->>'gross_cents')::bigint),0)
    into m_interventions, m_returned, m_gross
    from jsonb_array_elements(p->'monthly') x;
  t_treated := (p#>>'{interventions,treated}')::int;
  t_returned := (p#>>'{returned,count}')::int;
  t_gross := (p#>>'{recovered,gross_cents}')::bigint;
  b_cohort := (p#>>'{baseline,cohort}')::int;
  b_returned := (p#>>'{baseline,returned}')::int;
  net := (p#>>'{net,cents}')::bigint;
  expected := case
    when t_treated = 0 or t_returned = 0 then 0
    when b_cohort = 0 then t_gross
    else greatest(0, round(t_gross
      * (1 - (b_returned::numeric / b_cohort) / (t_returned::numeric / t_treated))))::bigint end;
  insert into _r values ('05_consistency',
    case when m_interventions = t_treated and m_returned = t_returned and m_gross = t_gross
           and net = expected and net <= t_gross
      then 'PASS monthly sums match totals; net=' || net || ' of gross=' || t_gross
      else 'FAIL monthly(' || m_interventions || ',' || m_returned || ',' || m_gross
        || ') vs totals(' || t_treated || ',' || t_returned || ',' || t_gross
        || ') net=' || net || ' expected=' || expected end);
end $$;

-- ---------------------------------------------------------------------------------------------
-- 06  authorization
-- ---------------------------------------------------------------------------------------------
do $$
declare
  b uuid := '38b30e6d-de73-4c2b-a2ca-19b08950896c';
  v_report text := 'no error'; v_writer text := 'no error';
  v_anon_report boolean; v_anon_writer boolean; v_client uuid;
begin
  select client_id into v_client from _fx where label = 'M';
  begin
    perform pg_temp.as_v550_user(gen_random_uuid());
    perform public.get_recovery_report_v550(b,
      ((now() at time zone 'Asia/Singapore')::date - 45),
      ((now() at time zone 'Asia/Singapore')::date + 1));
  exception when others then v_report := SQLSTATE;
  end;
  begin
    perform pg_temp.as_v550_user(gen_random_uuid());
    perform public.record_attention_outreach_v550(b, v_client);
  exception when others then v_writer := SQLSTATE;
  end;
  execute 'reset role';
  v_anon_report := has_function_privilege('anon', 'public.get_recovery_report_v550(uuid,date,date)', 'execute');
  v_anon_writer := has_function_privilege('anon', 'public.record_attention_outreach_v550(uuid,uuid)', 'execute');
  insert into _r values ('06_authorization',
    case when v_report = '42501' and v_writer = '42501' and not v_anon_report and not v_anon_writer
      then 'PASS strangers 42501 on both, anon unprivileged on both'
      else 'FAIL report=' || v_report || ' writer=' || v_writer
        || ' anon_report=' || v_anon_report || ' anon_writer=' || v_anon_writer end);
end $$;

select k, v from _r order by k;

rollback;
