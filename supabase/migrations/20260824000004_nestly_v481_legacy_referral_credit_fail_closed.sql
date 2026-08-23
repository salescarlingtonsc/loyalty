-- nestly_v481_legacy_referral_credit_fail_closed.sql
-- A pre-v322 referral can say a cash-credit reward was paid even when its
-- immutable credit-ledger child is missing. v20 would otherwise create the
-- negative clawback from the mutable referral row alone. Require the one
-- exact historical child before compensation; inconsistent history stays
-- fail-closed until an explicit, audited reconciliation is performed.

begin;

do $v481_patch$
declare
  v_def text;
  v_new text;
  v_needle text := $needle$  if exists (
    select 1 from app.referral_value_provenance_v480 p
    left join public.points_ledger l on l.id=p.ledger_id$needle$;
  v_guard text := $guard$  if v_referral.id is not null
     and coalesce(v_referral.reward_cents,0)>0
     and coalesce(v_referral.reward_points,0)=0
     and not exists (
       select 1
         from public.credit_ledger c
        where c.business_id=p_business
          and c.client_id=v_referral.referrer_client_id
          and c.sale_id=p_sale
          and c.entry_type='referral_reward'
        group by c.business_id,c.client_id,c.sale_id,c.entry_type
       having count(*)=1
          and min(c.amount_cents)=v_referral.reward_cents
          and max(c.amount_cents)=v_referral.reward_cents
     ) then
    raise exception 'historical referral credit provenance requires reconciliation before reversal'
      using errcode='55000';
  end if;
$guard$;
begin
  select pg_catalog.pg_get_functiondef(
    'app.reverse_sale_with_loyalty_v480(uuid,uuid,text,text,text,text,boolean)'::regprocedure
  ) into strict v_def;
  if position('historical referral credit provenance requires reconciliation before reversal' in v_def)>0 then
    raise exception 'v481 referral-credit guard is already installed';
  end if;
  if (length(v_def)-length(replace(v_def,v_needle,'')))/length(v_needle)<>1 then
    raise exception 'v481 could not prove the referral-provenance insertion anchor';
  end if;
  v_new:=replace(v_def,v_needle,v_guard||v_needle);
  execute v_new;
end
$v481_patch$;

do $$
begin
  if position(
    'historical referral credit provenance requires reconciliation before reversal'
    in pg_catalog.pg_get_functiondef(
      'app.reverse_sale_with_loyalty_v480(uuid,uuid,text,text,text,text,boolean)'::regprocedure
    )
  )=0 then
    raise exception 'v481 postcondition: referral-credit guard is absent';
  end if;
end
$$;

commit;
