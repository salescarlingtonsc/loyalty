-- V242 rollback verification: the directory shows the whole ecosystem, balances only where
-- the caller holds a verified link, and nothing at all to anon. ROLLED BACK.
begin;
select set_config('request.jwt.claims',
  json_build_object('sub','253de8ef-b08c-40fa-b435-5723a6123a9d','role','authenticated')::text, true);
set local role authenticated;
do $$
declare v jsonb;
begin
  v := public.customer_list_business_directory_v242();
  if jsonb_typeof(v) <> 'array' or jsonb_array_length(v) < 2 then
    raise exception 'v242.list: expected the ecosystem, got %', v;
  end if;
  if not exists (select 1 from jsonb_array_elements(v) e
                  where (e->>'joined')::boolean and (e->>'points_balance') is not null) then
    raise exception 'v242.joined: a verified link must carry its own points balance';
  end if;
  if exists (select 1 from jsonb_array_elements(v) e
              where not (e->>'joined')::boolean and (e->>'points_balance') is not null) then
    raise exception 'v242.leak: an unjoined business must never carry a balance';
  end if;
  -- Joined rows sort first, so "your" businesses lead the list.
  if (v->0->>'joined')::boolean is distinct from true then
    raise exception 'v242.order: joined businesses must lead';
  end if;
end $$;
reset role;
-- anon holds no EXECUTE at all.
do $$
begin
  set local role anon;
  begin
    perform public.customer_list_business_directory_v242();
    raise exception 'v242.anon: anon could call the directory';
  exception when insufficient_privilege then null;
  end;
  reset role;
end $$;
rollback;
