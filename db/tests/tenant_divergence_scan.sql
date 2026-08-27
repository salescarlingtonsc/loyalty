-- Read-only tenant-consistency scanner — every business audited for state divergence between the
-- programme spine, the live loyalty row, the versioned config, and the readers that consume them.
-- Run: supabase db query --linked -f db/tests/tenant_divergence_scan.sql
-- Pure SELECT inside begin;…rollback; — nothing is written, and it is safe to run repeatedly
-- against production. The only object created is an ON COMMIT DROP temp table.
--
-- OUTPUT: one result set with a `section` column.
--   section='DETAIL'  → (business_id, business_name, check_id, severity, detail), one row per
--                       divergence. An empty DETAIL section means every tenant is consistent.
--   section='SUMMARY' → total scanned, healthy tenants, and the divergent count per check.
--
-- SEVERITY LEGEND
--   RUNTIME-DANGEROUS  the divergence is reachable by a live reader or writer TODAY — a customer
--                      or a till can see the wrong thing, or a write can land on the wrong state.
--   HISTORICAL-ONLY    the divergence is real but no live path can act on it (guards already
--                      closed the door, or the row is provenance only). Counted, not alarming.
--
-- CHECKS
--   D01  RUNTIME  loyalty_programs.active disagrees with the spine formula (points OR stamps).
--   D01b RUNTIME  the tiers-only shape: tiers spine on, points+stamps off, live row inactive.
--                 Its own row because a fix making tiers count toward the formula is in flight.
--   D02  RUNTIME  loyalty_model/kind disagree with the spine (stamps spine ⇒ model 'stamps';
--                 points-only spine ⇒ model in classic|points_tiers).
--   D03  RUNTIME  stamps spine active with no usable card numbers (target or per-stamp spend).
--   D04  RUNTIME  stamps spine active with no active published gift at cost_points=stamp_target
--                 (the gift-at-last-stamp invariant: a card that can never pay out).
--   D05  RUNTIME  expiry_mode='fixed' with no positive expiry_days — the sweep has no window.
--   D06  RUNTIME  the business's active config pointer and the loyalty row's pointer disagree,
--                 or the active pointer references a version that is not 'published'.
--   D07  RUNTIME  the two-readers-disagree live check: a reward the presentation reader shows
--                 (loyalty_rewards.active AND NOT paused) that the availability core excludes.
--   D08  RUNTIME  referral spine on with no referral_programs row, or enabled ≠ spine.
--   D09  RUNTIME  a client points pot on a programme that is not a spine row of that business
--                 (orphan/cross-tenant), or a pot on a spine row of a kind that never earns.
--   D10  HISTORICAL  the armed-time-machine inventory: open drafts whose typed row differs from
--                 the live row on any of the 13 typed columns. The v564 stale-draft guard makes
--                 these unpublishable, so they are inventory rather than danger — still counted.
--   D11  RUNTIME  the stranded-birth shape: loyalty enabled with no loyalty_programs row at all,
--                 or no active config version pointer.
--   D12  HISTORICAL  version-1 provenance (firm_config_versions.source) differs from the live
--                 row's recommendation_source. Information only — nothing reads both.
--   D13  RUNTIME  a platform module override that would force a module on/off against the raw
--                 enabled_modules array. The 42-reader split only bites when such a row exists.
--   D14  RUNTIME  the v560 invariant: an active welcome offer with a zero-sale client holding no
--                 grant — a customer promised an offer the wallet cannot show.
--   D15  RUNTIME  the silent-expiry-disagreement shape: the live row's stamp validity / reward
--                 expiry is NULL while some historical version for that tenant carries a value,
--                 and stamps are live. Whichever version a cycle pins decides expiry silently.

begin;

create temp table _scan(
  business_id uuid,
  business_name text,
  check_id text,
  severity text,
  detail text
) on commit drop;

-- ---------------------------------------------------------------------------------------------
-- The spine, folded to one row per business. business_programmes holds one row per kind; the
-- readers resolve "the points/stamps programme" as the first active row by (sort, id), so the
-- spine ids below use that same ordering.
-- ---------------------------------------------------------------------------------------------
create temp view _spine as
select b.id as business_id,
       b.name as business_name,
       b.enabled_modules,
       b.active_config_version_id,
       coalesce(bool_or(sp.kind='points'   and sp.active), false) as points_on,
       coalesce(bool_or(sp.kind='stamps'   and sp.active), false) as stamps_on,
       coalesce(bool_or(sp.kind='tiers'    and sp.active), false) as tiers_on,
       coalesce(bool_or(sp.kind='referral' and sp.active), false) as referral_on,
       (select sp2.id from public.business_programmes sp2
         where sp2.business_id=b.id and sp2.kind='stamps' and sp2.active
         order by sp2.sort, sp2.id limit 1) as stamps_spine_id,
       (select sp2.id from public.business_programmes sp2
         where sp2.business_id=b.id and sp2.kind='points' and sp2.active
         order by sp2.sort, sp2.id limit 1) as points_spine_id
  from public.businesses b
  left join public.business_programmes sp on sp.business_id=b.id
 group by b.id, b.name, b.enabled_modules, b.active_config_version_id;

-- D01 — the live row's active flag against the spine formula the writers use today.
insert into _scan
select s.business_id, s.business_name, 'D01', 'RUNTIME-DANGEROUS',
       'loyalty_programs.active='||lp.active||' but the spine formula (points='||s.points_on
       ||', stamps='||s.stamps_on||') says '||(s.points_on or s.stamps_on)
  from _spine s
  join public.loyalty_programs lp on lp.business_id=s.business_id
 where lp.active is distinct from (s.points_on or s.stamps_on);

-- D01b — tiers-only: the formula ignores tiers, so a tiers-only tenant runs with an inactive
-- live row. Recorded separately because the in-flight fix changes exactly this shape.
insert into _scan
select s.business_id, s.business_name, 'D01b', 'RUNTIME-DANGEROUS',
       'tiers spine is active with points+stamps off and loyalty_programs.active=false — the '
       ||'current formula does not count tiers'
  from _spine s
  join public.loyalty_programs lp on lp.business_id=s.business_id
 where s.tiers_on and not s.points_on and not s.stamps_on and lp.active is false;

-- D02 — model/kind against the spine.
insert into _scan
select s.business_id, s.business_name, 'D02', 'RUNTIME-DANGEROUS',
       case when s.stamps_on
         then 'stamps spine is active but loyalty_model='||coalesce(lp.loyalty_model,'<null>')
              ||' (kind='||coalesce(lp.kind,'<null>')||')'
         else 'points spine is active but loyalty_model='||coalesce(lp.loyalty_model,'<null>')
              ||' is not classic/points_tiers (kind='||coalesce(lp.kind,'<null>')||')'
       end
  from _spine s
  join public.loyalty_programs lp on lp.business_id=s.business_id
 where (s.stamps_on and lp.loyalty_model is distinct from 'stamps')
    or (s.points_on and not s.stamps_on
        and coalesce(lp.loyalty_model,'<null>') not in ('classic','points_tiers'));

-- D03 — a live stamps tenant with no usable card numbers.
insert into _scan
select s.business_id, s.business_name, 'D03', 'RUNTIME-DANGEROUS',
       'stamps spine is active with stamp_target='||coalesce(lp.stamp_target::text,'<null>')
       ||' and stamp_per_cents='||coalesce(lp.stamp_per_cents::text,'<null>')
  from _spine s
  join public.loyalty_programs lp on lp.business_id=s.business_id
 where s.stamps_on
   and (coalesce(lp.stamp_target,0) <= 0 or coalesce(lp.stamp_per_cents,0) <= 0);

-- D04 — gift-at-last-stamp. Judged against the published version the business points at.
insert into _scan
select s.business_id, s.business_name, 'D04', 'RUNTIME-DANGEROUS',
       'stamps spine is active with target '||coalesce(lp.stamp_target::text,'<null>')
       ||' but the published version carries no active stamp gift at that cost'
  from _spine s
  join public.loyalty_programs lp on lp.business_id=s.business_id
 where s.stamps_on
   and coalesce(lp.stamp_target,0) > 0
   and not exists (
     select 1 from public.loyalty_reward_versions rv
      where rv.business_id=s.business_id
        and rv.config_version_id=s.active_config_version_id
        and rv.active
        and rv.programme_id=s.stamps_spine_id
        and rv.cost_points=lp.stamp_target);

-- D05 — a fixed expiry window that is not a window.
insert into _scan
select s.business_id, s.business_name, 'D05', 'RUNTIME-DANGEROUS',
       'expiry_mode=fixed with expiry_days='||coalesce(lp.expiry_days::text,'<null>')
  from _spine s
  join public.loyalty_programs lp on lp.business_id=s.business_id
 where lp.expiry_mode='fixed' and coalesce(lp.expiry_days,0) <= 0;

-- D06 — the two config pointers, and the status of the one the readers follow.
insert into _scan
select s.business_id, s.business_name, 'D06', 'RUNTIME-DANGEROUS',
       case when s.active_config_version_id is distinct from lp.current_config_version_id
         then 'businesses.active_config_version_id='
              ||coalesce(s.active_config_version_id::text,'<null>')
              ||' but loyalty_programs.current_config_version_id='
              ||coalesce(lp.current_config_version_id::text,'<null>')
         else 'the active config pointer references a version whose status is '
              ||coalesce((select fcv.status from public.firm_config_versions fcv
                           where fcv.id=s.active_config_version_id),'<missing>')
       end
  from _spine s
  join public.loyalty_programs lp on lp.business_id=s.business_id
 where s.active_config_version_id is distinct from lp.current_config_version_id
    or (s.active_config_version_id is not null
        and coalesce((select fcv.status from public.firm_config_versions fcv
                       where fcv.id=s.active_config_version_id),'<missing>') <> 'published');

-- D17 (nestly_v569) — the READER-vs-AUTHORITY check for staff logins, and the operational
-- follow-up beside it. The canonical rule is app.is_salon_member: workspace open AND staff active
-- AND access_state='approved'.
--
-- D17 is the DANGEROUS half: public.get_my_personas' own workspace_access answer must equal what
-- the authority would grant that same account. It was not, which is how a teammate was shown as
-- active, refused at every read, routed to a dead end and billed for an unusable login. Note this
-- is deliberately reader-vs-AUTHORITY, never reader-vs-reader: two readers agreeing on a wrong
-- answer is exactly the shape nestly_v568 taught us a consistency check cannot see.
do $d17$
declare r record; v_reported boolean; v_bad text := '';
begin
  for r in
    select s.id, s.business_id, b.name as business_name, s.user_id, s.full_name, s.access_state,
           (app.business_workspace_open_v94(s.business_id) and s.active
             and s.access_state='approved') as authority
      from public.staff s
      join public.businesses b on b.id=s.business_id
     where s.user_id is not null and s.active
  loop
    perform set_config('request.jwt.claims',
      json_build_object('sub',r.user_id,'role','authenticated','aud','authenticated')::text,true);
    begin
      select coalesce((select (persona->>'workspace_access')::boolean
                         from jsonb_array_elements(public.get_my_personas()->'staff') persona
                        where (persona->>'business_id')::uuid = r.business_id), false)
        into v_reported;
    exception when others then
      insert into _scan values (r.business_id, r.business_name, 'D17', 'RUNTIME-DANGEROUS',
        'the persona reader could not be evaluated for '||coalesce(r.full_name,'?')||': '||sqlerrm);
      continue;
    end;
    if v_reported is distinct from r.authority then
      insert into _scan values (r.business_id, r.business_name, 'D17', 'RUNTIME-DANGEROUS',
        coalesce(r.full_name,'?')||' ['||coalesce(r.access_state,'?')||']: the persona reader says '
        ||v_reported::text||' while the membership authority says '||r.authority::text);
    end if;
  end loop;
  perform set_config('request.jwt.claims','',true);
end
$d17$;

-- D17b — the OPERATIONAL half, deliberately non-blocking. A teammate who has accepted their
-- invite sits at access_state='pending' until the owner approves them, which is the intended
-- security posture (public.accept_invite always writes 'pending'). It is legitimate and often
-- transient, so it must never redden the gate — but it is a person waiting to be let in, so it
-- is surfaced with its age rather than left silent, which is how the recorded case sat unnoticed.
insert into _scan
select s.business_id, b.name, 'D17b', 'HISTORICAL-ONLY',
       count(*)||' teammate(s) waiting for the owner to approve their login: '
       ||string_agg(coalesce(s.full_name,'?')||' (waiting '
                    ||greatest(0,(current_date - s.created_at::date))||'d)', '; '
                    order by s.full_name)
  from public.staff s
  join public.businesses b on b.id=s.business_id
 where s.user_id is not null and s.active and s.access_state='pending'
 group by s.business_id, b.name;

-- D16 (nestly_v568) — the CORE's own answer, audited against the platform's own rule rather
-- than against another reader. D07 asks "do the two readers agree?"; after v566 made the
-- presentation delegate to app.reward_availability_v432, that question became tautological and
-- could not see a defect INSIDE the shared core — which is exactly how the v568 survivor-arm
-- leak (a parked pot's gift offered as a stamp gift) survived a green D07. This check states the
-- rule directly: a reward may only be OFFERED to a customer if its own programme is running.
do $d16$
declare r record; v_names text;
begin
  for r in
    select distinct on (link.business_id)
           link.business_id, b.name as business_name, link.client_id
      from public.customer_links link
      join public.businesses b on b.id=link.business_id
     where link.state='verified'
     order by link.business_id, link.created_at, link.id
  loop
    begin
      select string_agg(distinct lr.customer_name||' ['||coalesce(sp.kind,'no programme')||']', ', ')
        into v_names
        from app.reward_availability_v432(r.business_id, r.client_id, now()) core
        join public.loyalty_rewards lr on lr.id=core.reward_id
        left join public.business_programmes sp on sp.id=lr.programme_id
       where not exists (select 1 from public.business_programmes sp2
                          where sp2.id=lr.programme_id and sp2.active);
    exception when others then
      insert into _scan values (r.business_id, r.business_name, 'D16', 'RUNTIME-DANGEROUS',
        'the availability core could not be evaluated: '||sqlerrm);
      continue;
    end;
    if v_names is not null then
      insert into _scan values (r.business_id, r.business_name, 'D16', 'RUNTIME-DANGEROUS',
        'reward(s) offered from a switched-off programme: '||v_names);
    end if;
  end loop;
end
$d16$;

-- D07 — the two readers disagree, measured by EXECUTING both readers (nestly_v566 made the
-- presentation delegate to app.reward_availability_v432, so the honest check is no longer a
-- data predicate — rewards legitimately PARKED on a switched-off programme still exist in
-- loyalty_rewards and are shown by neither reader). For every business with a verified
-- customer link, call the live presentation as that customer and diff its reward set against
-- the availability core's own answer. Businesses with no verified customer cannot be probed
-- (presentation refuses without one) and are skipped — the lifecycle certification covers them.
do $d07$
declare
  r record; v_json jsonb; v_shown uuid[]; v_expected uuid[];
  v_extra text; v_missing text;
begin
  for r in
    select distinct on (link.business_id)
           link.business_id, b.name as business_name, link.auth_user_id, link.client_id
      from public.customer_links link
      join public.customer_identities ident
        on ident.id=link.identity_id and ident.auth_user_id=link.auth_user_id
       and ident.status='active'
      join public.businesses b on b.id=link.business_id
      join public.business_brand_presentation_v95 brand on brand.business_id=link.business_id
     where link.state='verified'
       and exists (select 1 from public.branches br
                    where br.business_id=link.business_id and br.active)
     order by link.business_id, link.created_at, link.id
  loop
    perform set_config('request.jwt.claims',
      json_build_object('sub',r.auth_user_id,'role','authenticated')::text, true);
    begin
      v_json := public.customer_get_business_presentation_v95(r.business_id);
    exception when others then
      insert into _scan values (r.business_id, r.business_name, 'D07', 'RUNTIME-DANGEROUS',
        'presentation unreadable for the probe customer: '||sqlerrm);
      continue;
    end;
    select coalesce(array_agg((elem->>'id')::uuid),'{}') into v_shown
      from jsonb_array_elements(v_json->'catalogue'->'rewards') elem;
    select coalesce(array_agg(core.reward_id),'{}') into v_expected
      from app.reward_availability_v432(r.business_id,r.client_id,now()) core
     where core.availability not in ('not_started','ended');
    select string_agg(x::text,', ') into v_extra
      from unnest(v_shown) x where not (x = any(v_expected));
    select string_agg(x::text,', ') into v_missing
      from unnest(v_expected) x where not (x = any(v_shown));
    if v_extra is not null or v_missing is not null then
      insert into _scan values (r.business_id, r.business_name, 'D07', 'RUNTIME-DANGEROUS',
        coalesce('presentation shows what availability refuses: '||v_extra,'')
        ||coalesce(' / availability offers what presentation hides: '||v_missing,''));
    end if;
  end loop;
  perform set_config('request.jwt.claims','',true);
end
$d07$;

-- D08 — the referral spine against its own settings row.
insert into _scan
select s.business_id, s.business_name, 'D08', 'RUNTIME-DANGEROUS',
       case when rp.id is null
         then 'referral spine is active but the business has no referral_programs row'
         else 'referral spine active='||s.referral_on||' but referral_programs.enabled='
              ||rp.enabled||' (kind='||coalesce(rp.reward_kind,'<null>')||', points='
              ||coalesce(rp.reward_points::text,'<null>')||')'
       end
  from _spine s
  left join public.referral_programs rp on rp.business_id=s.business_id
 where (s.referral_on and rp.id is null)
    or (rp.id is not null and rp.enabled is distinct from s.referral_on);

-- D09 — every distinct pot a client ledger actually references, tested against the spine.
insert into _scan
select s.business_id, s.business_name, 'D09', 'RUNTIME-DANGEROUS',
       string_agg(p.note, '; ' order by p.note)
  from _spine s
  join lateral (
    select case when sp.id is null
             then 'ledger pot '||coalesce(pots.programme_id::text,'<null>')
                  ||' is not a spine row of this business ('||pots.n||' entries)'
             else 'ledger pot '||pots.programme_id::text||' is a spine row of kind '''||sp.kind
                  ||''' which neither earns nor spends points ('||pots.n||' entries)'
           end as note
      from (select pl.programme_id, count(*) n
              from public.points_ledger pl
             where pl.business_id=s.business_id
             group by pl.programme_id) pots
      left join public.business_programmes sp
        on sp.id=pots.programme_id and sp.business_id=s.business_id
     where sp.id is null or sp.kind not in ('points','stamps')
  ) p on true
 group by s.business_id, s.business_name;

-- D10 — the armed-time-machine inventory. All 13 typed columns compared, differences listed.
insert into _scan
select s.business_id, s.business_name, 'D10', 'HISTORICAL-ONLY',
       'draft v'||fcv.version_no||' ('||coalesce(fcv.source,'<no source>')||', created '
       ||to_char(fcv.created_at at time zone 'Asia/Singapore','YYYY-MM-DD')
       ||') differs from the live row on: '||array_to_string(d.cols, ', ')
  from _spine s
  join public.firm_config_versions fcv
    on fcv.business_id=s.business_id and fcv.status='draft'
  join public.loyalty_program_versions lpv on lpv.config_version_id=fcv.id
  join public.loyalty_programs lp on lp.business_id=s.business_id
  join lateral (
    select array_remove(array[
      case when lpv.kind is distinct from lp.kind then 'kind' end,
      case when lpv.loyalty_model is distinct from lp.loyalty_model then 'loyalty_model' end,
      case when lpv.active is distinct from lp.active then 'active' end,
      case when lpv.earn_points_per_dollar is distinct from lp.earn_points_per_dollar
        then 'earn_points_per_dollar' end,
      case when lpv.redeem_points is distinct from lp.redeem_points then 'redeem_points' end,
      case when lpv.reward_credit_cents is distinct from lp.reward_credit_cents
        then 'reward_credit_cents' end,
      case when lpv.stamp_target is distinct from lp.stamp_target then 'stamp_target' end,
      case when lpv.stamp_per_cents is distinct from lp.stamp_per_cents then 'stamp_per_cents' end,
      case when lpv.tier_basis is distinct from lp.tier_basis then 'tier_basis' end,
      case when lpv.expiry_mode is distinct from lp.expiry_mode then 'expiry_mode' end,
      case when lpv.expiry_days is distinct from lp.expiry_days then 'expiry_days' end,
      case when lpv.stamp_validity_days is distinct from lp.stamp_validity_days
        then 'stamp_validity_days' end,
      case when lpv.stamp_reward_expiry_days is distinct from lp.stamp_reward_expiry_days
        then 'stamp_reward_expiry_days' end
    ], null) as cols
  ) d on true
 where cardinality(d.cols) > 0;

-- D11 — stranded birth.
insert into _scan
select s.business_id, s.business_name, 'D11', 'RUNTIME-DANGEROUS',
       case when lp.id is null and s.active_config_version_id is null
              then 'the tenant has neither a loyalty_programs row nor an active config version'
                   ||case when 'loyalty' = any(s.enabled_modules)
                          then ' — and the loyalty module IS enabled' else '' end
            when lp.id is null
              then 'the loyalty module is enabled but the tenant has no loyalty_programs row'
            else 'the tenant has no active_config_version_id — every versioned reader resolves '
                 ||'to nothing'
       end
  from _spine s
  left join public.loyalty_programs lp on lp.business_id=s.business_id
 where ('loyalty' = any(s.enabled_modules) and lp.id is null)
    or s.active_config_version_id is null;

-- D12 — version-1 provenance, information only.
insert into _scan
select s.business_id, s.business_name, 'D12', 'HISTORICAL-ONLY',
       'version 1 source='||coalesce(fcv.source,'<null>')||' but recommendation_source='
       ||coalesce(lp.recommendation_source,'<null>')
  from _spine s
  join public.firm_config_versions fcv
    on fcv.business_id=s.business_id and fcv.version_no=1
  join public.loyalty_programs lp on lp.business_id=s.business_id
 where coalesce(fcv.source,'<null>') is distinct from coalesce(lp.recommendation_source,'<null>');

-- D13 — platform overrides that contradict the raw module array.
insert into _scan
select s.business_id, s.business_name, 'D13', 'RUNTIME-DANGEROUS',
       'override module='||o.module_key||' mode='||o.mode||' '
       ||case when o.mode='disabled' then 'forces OFF a module enabled_modules lists as ON'
              else 'forces ON a module enabled_modules does not list' end
       ||coalesce(' (branch '||o.branch_scope::text||')','')
       ||' — reason: '||coalesce(o.reason,'<none>')
  from _spine s
  join public.platform_module_overrides_v94 o on o.business_id=s.business_id
 where (o.mode='disabled' and o.module_key = any(s.enabled_modules))
    or (o.mode in ('r','rw') and not (o.module_key = any(s.enabled_modules)));

-- D14 — the v560 welcome-offer invariant. business_welcome_offers_v215 has no `paused` column
-- in production, so `active` alone is the live flag (see ADAPTATIONS at the foot of this file).
insert into _scan
select s.business_id, s.business_name, 'D14', 'RUNTIME-DANGEROUS',
       count(*)||' zero-sale client(s) of an active welcome offer hold no grant'
  from _spine s
  join public.business_welcome_offers_v215 offer
    on offer.business_id=s.business_id and offer.active
  join public.clients c on c.business_id=offer.business_id
 where not exists (select 1 from public.sales sa
                    where sa.business_id=offer.business_id and sa.client_id=c.id
                      and sa.reversal_of is null)
   and not exists (select 1 from public.welcome_offer_grants_v215 g
                    where g.business_id=offer.business_id and g.client_id=c.id)
 group by s.business_id, s.business_name;

-- D15 — silent expiry disagreement between the live row and the versions a cycle can pin.
insert into _scan
select s.business_id, s.business_name, 'D15', 'RUNTIME-DANGEROUS',
       'stamps are live with '
       ||case when lp.stamp_validity_days is null and lp.stamp_reward_expiry_days is null
                then 'both stamp_validity_days and stamp_reward_expiry_days NULL'
              when lp.stamp_validity_days is null then 'stamp_validity_days NULL'
              else 'stamp_reward_expiry_days NULL' end
       ||' on the live row, while historical versions carry validity='
       ||coalesce((select max(v.stamp_validity_days) from public.loyalty_program_versions v
                    where v.business_id=s.business_id)::text,'<none>')
       ||' / reward_expiry='
       ||coalesce((select max(v.stamp_reward_expiry_days) from public.loyalty_program_versions v
                    where v.business_id=s.business_id)::text,'<none>')
  from _spine s
  join public.loyalty_programs lp on lp.business_id=s.business_id
 where s.stamps_on
   and (lp.stamp_validity_days is null or lp.stamp_reward_expiry_days is null)
   and exists (
     select 1 from public.loyalty_program_versions v
      where v.business_id=s.business_id
        and ((lp.stamp_validity_days is null and v.stamp_validity_days is not null)
          or (lp.stamp_reward_expiry_days is null and v.stamp_reward_expiry_days is not null)));

-- ---------------------------------------------------------------------------------------------
-- OUTPUT
-- ---------------------------------------------------------------------------------------------
select 'DETAIL' as section,
       business_id::text as business_id,
       business_name,
       check_id,
       severity,
       detail
  from _scan

union all

select 'SUMMARY', null, null, 'ZZ01 total businesses scanned', '-',
       (select count(*)::text from public.businesses)
union all
select 'SUMMARY', null, null, 'ZZ02 healthy (no divergence)', '-',
       (select count(*)::text from public.businesses b
         where not exists (select 1 from _scan s where s.business_id=b.id))
union all
select 'SUMMARY', null, null, 'ZZ03 divergent businesses', '-',
       (select count(distinct business_id)::text from _scan)
union all
select 'SUMMARY', null, null, 'ZZ04 total divergence rows', '-',
       (select count(*)::text from _scan)
union all
select 'SUMMARY', null, null, 'ZZ05 '||c.check_id, c.severity,
       (select count(*)::text from _scan s where s.check_id=c.check_id)
       ||' business row(s)'
  from (values
    ('D01','RUNTIME-DANGEROUS'),('D01b','RUNTIME-DANGEROUS'),('D02','RUNTIME-DANGEROUS'),
    ('D03','RUNTIME-DANGEROUS'),('D04','RUNTIME-DANGEROUS'),('D05','RUNTIME-DANGEROUS'),
    ('D06','RUNTIME-DANGEROUS'),('D07','RUNTIME-DANGEROUS'),('D08','RUNTIME-DANGEROUS'),('D16','RUNTIME-DANGEROUS'),('D17','RUNTIME-DANGEROUS'),('D17b','HISTORICAL-ONLY'),
    ('D09','RUNTIME-DANGEROUS'),('D10','HISTORICAL-ONLY'),('D11','RUNTIME-DANGEROUS'),
    ('D12','HISTORICAL-ONLY'),('D13','RUNTIME-DANGEROUS'),('D14','RUNTIME-DANGEROUS'),
    ('D15','RUNTIME-DANGEROUS')
  ) c(check_id, severity)

 order by 1 desc, 4, 3;

rollback;

-- ADAPTATIONS made because production differs from the checklist as written:
--  * business_welcome_offers_v215 has no `paused` column — `active` is the only live flag, so
--    D14 keys on it alone (this matches the v560 acceptance suite's own data assertion).
--  * platform_module_overrides_v94.mode is one of inherit|disabled|r|rw. D13 treats 'disabled'
--    as force-off and 'r'/'rw' as force-on; 'inherit' is by definition never a divergence.
--  * D07 resolves the version arm against businesses.active_config_version_id. The availability
--    core pins a STAMP reward to the cycle's own config version (stamp_cycle_version_v416), which
--    is per-client and therefore not expressible in a per-business scan; a stamp reward whose
--    active typed row lives only in an older pinned version is reported here as
--    'no active row in the published version'. Treat that reason on a stamps tenant as
--    "confirm against the client's pinned cycle" rather than an automatic defect.
--  * D11 is evaluated as (loyalty enabled AND no loyalty_programs row) OR (no active config
--    version pointer) — the second disjunct is not gated on the loyalty module, because a NULL
--    pointer strands every versioned reader regardless of which modules are on.
