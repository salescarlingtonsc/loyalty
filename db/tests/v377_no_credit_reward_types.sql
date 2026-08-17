-- Rollback-only acceptance for v377 — no reward type pays store credit.
--   supabase db query --linked -f db/tests/v377_no_credit_reward_types.sql
-- Any row whose result starts with FAIL is a failure. Nothing is committed.
--
-- firm_reward_taxonomy holds the labels a bring-back reward may be built from, and each label
-- carries an IMMUTABLE fulfilment behaviour. Eleven businesses each had an active 'credit' label,
-- so a retention reward could still have been configured to mint store credit long after v375
-- retired the classic model. Retiring the label is the sanctioned, reversible instrument the
-- surface already offers ("Labels may be renamed, sorted, or retired") — nothing is deleted and
-- no behaviour is rewritten, which the table's own contract forbids.

begin;

create temp table _r(k text, v text) on commit drop;

insert into _r select '01 credit labels exist before the sweep',
  case when (select count(*) from public.firm_reward_taxonomy where fulfillment_kind='credit' and active)>0
  then 'PASS ('||(select count(*) from public.firm_reward_taxonomy where fulfillment_kind='credit' and active)||' active credit labels)'
  else 'INFO already retired' end;

insert into _r select '02 nothing live is built on one',
  case when (select count(*) from public.retention_programs where reward_type='credit' and active)=0
  then 'PASS (no active retention programme pays credit)'
  else 'FAIL a live programme would lose its reward type' end;

update public.firm_reward_taxonomy set active=false where fulfillment_kind='credit' and active;

insert into _r select '03 no credit label is selectable after it',
  case when (select count(*) from public.firm_reward_taxonomy where fulfillment_kind='credit' and active)=0
  then 'PASS' else 'FAIL a credit label is still active' end;

insert into _r select '04 the other two behaviours are untouched',
  case when (select count(*) from public.firm_reward_taxonomy where fulfillment_kind in ('free_item','discount_pct') and active)
            =(select count(*) from public.firm_reward_taxonomy where fulfillment_kind in ('free_item','discount_pct'))
  then 'PASS' else 'FAIL an unrelated label was retired' end;

insert into _r select '05 the rows are retired, never deleted',
  case when (select count(*) from public.firm_reward_taxonomy where fulfillment_kind='credit')>0
  then 'PASS (still on file, and reversible with active=true)' else 'FAIL rows were deleted' end;

select k as check, v as result from _r order by k;

rollback;
