-- V239 rollback verification: points and tiers may run together, but points may never both
-- be spendable and be the measure of the tier. Run inside a transaction that is ROLLED BACK.
begin;

-- (1) 'both' is a legal mode once the ladder is measured in something other than points.
--     ORDER MATTERS and is asserted here because it is what the UI must do: a firm whose
--     ladder is still points_earned cannot be switched into 'both' first.
update public.loyalty_programs set tier_basis='visits'
 where business_id='8492e8d6-8888-4383-ada0-7e1ed69f0caa';
update public.businesses set points_mode='both'
 where id='8492e8d6-8888-4383-ada0-7e1ed69f0caa';

do $$
declare v_refused boolean:=false;
begin
  -- (2) The incoherent state is refused from the loyalty_programs side.
  begin
    update public.loyalty_programs set tier_basis='points_earned'
     where business_id='8492e8d6-8888-4383-ada0-7e1ed69f0caa';
  exception when check_violation then v_refused:=true;
  end;
  if not v_refused then
    raise exception 'v239.basis: points_earned was accepted while points are spendable';
  end if;

  -- (3) ...and a visits ladder under 'both' is accepted, so the guard is not simply refusing.
  v_refused:=false;
  begin
    update public.businesses set points_mode='both'
     where id='8492e8d6-8888-4383-ada0-7e1ed69f0caa';
  exception when check_violation then v_refused:=true;
  end;
  if v_refused then
    raise exception 'v239.mode: both was refused on a visits ladder';
  end if;
end $$;

-- (4) The redemption gate must NOT refuse for the points-mode reason under 'both'. Any other
--     failure (identity, feature flag) is fine here — this asserts only the v229 gate.
do $$
declare v_msg text; v_blocked boolean:=false;
begin
  begin
    perform public.customer_create_redemption_intent_v89(
      '8492e8d6-8888-4383-ada0-7e1ed69f0caa'::uuid,'classic_points',null);
  exception
    when sqlstate '0A000' then
      get stacked diagnostics v_msg = message_text;
      if v_msg like '%count toward membership tiers%' then v_blocked:=true; end if;
    when others then null;
  end;
  if v_blocked then
    raise exception 'v239.gate: redemption still refused for the points-mode reason under both';
  end if;
end $$;

rollback;
