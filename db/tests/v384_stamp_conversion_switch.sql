begin;

do $$
declare
  v_def text;
begin
  if to_regprocedure('app.customer_live_loyalty_v384(uuid,uuid,text[],timestamp with time zone)') is null then
    raise exception 'v384 helper is missing';
  end if;
  if to_regprocedure('public.business_preview_stamp_conversion_v384(uuid,integer)') is null
     or to_regprocedure('public.business_switch_to_stamps_v384(uuid,boolean,integer,uuid)') is null then
    raise exception 'v384 stamp conversion RPCs are missing';
  end if;
  if has_function_privilege('anon','public.business_switch_to_stamps_v384(uuid,boolean,integer,uuid)','execute')
     or not has_function_privilege('authenticated','public.business_switch_to_stamps_v384(uuid,boolean,integer,uuid)','execute') then
    raise exception 'v384 stamp switch ACL is wrong';
  end if;

  select pg_get_functiondef('public.customer_get_wallet()'::regprocedure) into strict v_def;
  if position('app.customer_live_loyalty_v384' in v_def) = 0
     or position('programme_pot' in v_def) = 0 then
    raise exception 'customer_get_wallet is not using the live programme projection';
  end if;

  select pg_get_functiondef('public.customer_get_business_summary(text)'::regprocedure) into strict v_def;
  if position('app.customer_live_loyalty_v384' in v_def) = 0 then
    raise exception 'customer_get_business_summary is not using the live programme projection';
  end if;

  select pg_get_functiondef('public.customer_get_reward_catalog(text)'::regprocedure) into strict v_def;
  if position('v384_live_customer_programmes_catalog' in v_def) = 0
     or position('pl.programme_id = v_live_points_programme' in v_def) = 0
     or position('spine.active' in v_def) = 0 then
    raise exception 'customer_get_reward_catalog does not filter live programme rewards';
  end if;

  select pg_get_functiondef('public.customer_get_business_actions_v89(uuid)'::regprocedure) into strict v_def;
  if position('v384_live_customer_programmes_actions' in v_def) = 0
     or position('programme_id=v_live_points_programme' in replace(v_def,' ','')) = 0 then
    raise exception 'customer_get_business_actions_v89 does not filter the live points pot';
  end if;

  select pg_get_functiondef('app.c45_base_actionable_wallet_card(uuid,uuid,text,text,text,text,text[],timestamp with time zone)'::regprocedure)
    into strict v_def;
  if position('v384_live_customer_programmes_actionable' in v_def) = 0
     or position('app.live_balance_programme_v381(p_business_id)' in v_def) = 0 then
    raise exception 'actionable wallet card is not scoped to the live programme';
  end if;
end $$;

rollback;
