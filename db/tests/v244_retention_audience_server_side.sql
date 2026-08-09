-- Rolled-back acceptance for v244 — the bring-back audience is computed server-side.
--
-- Proves, against a synthetic fixture on a real approved business:
--   * a client with enough valid visits, all lapsed, is a candidate with the right
--     net count and Singapore calendar-day lapse;
--   * a reversal row is never a visit and discounts its reversed original
--     (validVisitSales parity);
--   * a reversal stored with counts_as_visit=false does NOT discount its original —
--     deliberate quirk parity with the browser algorithm this replaces, which built
--     its reversal set from counts_as_visit=true rows only;
--   * a recent visit resets the lapse and removes the candidate;
--   * clamping (lapsed_days/min_visits) and the response envelope
--     (candidates/total/truncated) hold;
--   * an anonymous caller is refused (42501 via require_module_scope_v145).
begin;

do $v244$
declare
  v_biz uuid; v_owner uuid;
  v_lapsed uuid:=gen_random_uuid();     -- 3 valid visits, all long ago -> candidate
  v_reversed uuid:=gen_random_uuid();   -- visits reversed away -> not a candidate
  v_quirk uuid:=gen_random_uuid();      -- reversal row carries counts_as_visit=false -> stays
  v_recent uuid:=gen_random_uuid();     -- enough visits but one recent -> not a candidate
  v_orig uuid; v_quirk_orig uuid;
  v_res jsonb; v_cand jsonb;
  v_days integer;
begin
  select s.business_id, s.user_id into v_biz, v_owner from public.staff s
   where s.role='owner' and s.user_id is not null and s.active limit 1;
  if v_biz is null then raise notice 'no fixture; skipping'; return; end if;

  insert into public.clients(id,business_id,full_name,phone) values
    (v_lapsed,v_biz,'V244 Lapsed Regular','+6580000244'),
    (v_reversed,v_biz,'V244 Reversed Away','+6580001244'),
    (v_quirk,v_biz,'V244 Quirk Parity','+6580002244'),
    (v_recent,v_biz,'V244 Recent Visitor','+6580003244');

  -- Lapsed regular: 3 valid visits, newest 90 SG days ago.
  insert into public.sales(business_id,client_id,kind,amount_cents,occurred_at,note) values
    (v_biz,v_lapsed,'quick_sale',1000,now()-interval '200 days','v244'),
    (v_biz,v_lapsed,'quick_sale',1000,now()-interval '140 days','v244'),
    (v_biz,v_lapsed,'quick_sale',1000,now()-interval '90 days','v244');

  -- Reversed away: one aged visit, then a visit-counting reversal referencing it.
  insert into public.sales(business_id,client_id,kind,amount_cents,occurred_at,note)
    values (v_biz,v_reversed,'quick_sale',1000,now()-interval '120 days','v244')
    returning id into v_orig;
  -- Quirk parity original: aged visit that will carry a NON-visit reversal.
  insert into public.sales(business_id,client_id,kind,amount_cents,occurred_at,note)
    values (v_biz,v_quirk,'quick_sale',1000,now()-interval '110 days','v244')
    returning id into v_quirk_orig;
  /* Reversal rows may only be created through public.reverse_sale() (guard trigger), and that
     path always stamps the policy's counts_as_visit. The quirk branch needs a reversal stored
     with counts_as_visit=false, so both reversal fixtures are written with user triggers off
     and every stamped column explicit. The suite runs as the chain superuser and the whole
     transaction rolls back. */
  alter table public.sales disable trigger user;
  -- Triggers normally stamp every policy column, so with them off the other NOT NULL
  -- stamps must be written explicitly. Only counts_as_visit/reversal_of matter to the
  -- function under test; revenue/points stamps are false as befits a reversal.
  insert into public.sales(business_id,client_id,kind,amount_cents,occurred_at,
      counts_as_visit,counts_as_revenue,earns_points,policy_resolved_at,
      commission_rate_bps,commission_resolved_at,reversal_of,
      reversal_reason,reversal_actor,reversal_idempotency_key,note) values
    (v_biz,v_reversed,'quick_sale',-1000,now()-interval '119 days',true,false,false,now(),0,now(),v_orig,
      'v244 acceptance fixture reversal',v_owner,'v244-rev-'||v_orig,'v244 reversal'),
    (v_biz,v_quirk,'quick_sale',-1000,now()-interval '109 days',false,false,false,now(),0,now(),v_quirk_orig,
      'v244 acceptance fixture reversal',v_owner,'v244-rev-'||v_quirk_orig,'v244 non-visit reversal');
  alter table public.sales enable trigger user;
  assert (select counts_as_visit from public.sales where reversal_of=v_orig),
    'fixture: the true-reversal row carries counts_as_visit=true';
  assert not (select counts_as_visit from public.sales where reversal_of=v_quirk_orig),
    'fixture: the quirk reversal carries counts_as_visit=false';

  -- Recent visitor: 3 visits, newest yesterday.
  insert into public.sales(business_id,client_id,kind,amount_cents,occurred_at,note) values
    (v_biz,v_recent,'quick_sale',1000,now()-interval '80 days','v244'),
    (v_biz,v_recent,'quick_sale',1000,now()-interval '40 days','v244'),
    (v_biz,v_recent,'quick_sale',1000,now()-interval '1 day','v244');

  perform set_config('request.jwt.claims',
    json_build_object('sub',v_owner,'role','authenticated')::text,true);

  v_res:=public.retention_lapsed_candidates_v244(v_biz,45,3);
  assert jsonb_typeof(v_res->'candidates')='array','envelope carries a candidates array';
  assert (v_res->>'truncated')='false','a tiny audience is never truncated';
  assert (v_res->>'total')::int=jsonb_array_length(v_res->'candidates'),'total matches the array';

  select c into v_cand from jsonb_array_elements(v_res->'candidates') c
   where c->>'id'=v_lapsed::text;
  assert v_cand is not null,'the lapsed regular is a candidate';
  assert (v_cand->>'net_visits')::int=3,'net visits count valid originals only';
  v_days:=((now() at time zone 'Asia/Singapore')::date
          -((now()-interval '90 days') at time zone 'Asia/Singapore')::date);
  assert (v_cand->>'last_visit_days')::int=v_days,
    'lapse is complete Singapore calendar days since the newest valid visit';

  assert not exists (select 1 from jsonb_array_elements(v_res->'candidates') c
    where c->>'id'=v_reversed::text),
    'a reversal row is never a visit and its original is discounted';
  assert not exists (select 1 from jsonb_array_elements(v_res->'candidates') c
    where c->>'id'=v_recent::text),
    'a recent visit removes the client from the lapsed audience';

  -- Quirk parity: min_visits=1 so the single surviving original qualifies on its own.
  v_res:=public.retention_lapsed_candidates_v244(v_biz,45,1);
  assert exists (select 1 from jsonb_array_elements(v_res->'candidates') c
    where c->>'id'=v_quirk::text),
    'a counts_as_visit=false reversal must NOT discount its original (browser parity)';
  assert not exists (select 1 from jsonb_array_elements(v_res->'candidates') c
    where c->>'id'=v_reversed::text),
    'the true-reversal client stays excluded even at min_visits=1';

  -- Clamping: out-of-range arguments fold to the documented bounds instead of erroring.
  v_res:=public.retention_lapsed_candidates_v244(v_biz,0,0);
  assert v_res ? 'candidates','lapsed_days=0 clamps to 1 and still answers';
  v_res:=public.retention_lapsed_candidates_v244(v_biz,9999,3);
  assert (select not exists (select 1 from jsonb_array_elements(v_res->'candidates') c
    where c->>'id'=v_lapsed::text)),
    'lapsed_days clamps to 365, beyond the 90-day fixture lapse';

  -- Fail closed: no session -> the same 42501 the browser path produced.
  perform set_config('request.jwt.claims','',true);
  perform set_config('request.jwt.claim.sub','',true);
  begin
    perform public.retention_lapsed_candidates_v244(v_biz,45,3);
    raise exception 'an anonymous caller was allowed to read the audience';
  exception when sqlstate '42501' then null;
  end;

  raise notice 'v244 acceptance passed';
end$v244$;
rollback;
