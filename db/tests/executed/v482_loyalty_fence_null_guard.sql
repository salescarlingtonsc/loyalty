-- Rollback-only proof: no advisory lock is denied; this backend's shared lock
-- permits the same row-triggered mutation.
\set ON_ERROR_STOP on
begin;

create temp table v482_fence_probe(business_id uuid not null, value integer not null);
create trigger trg_v482_fence_probe
before insert or update or delete on v482_fence_probe
for each row execute function app.require_loyalty_shared_v480();

do $proof$
declare
  v_business uuid:=gen_random_uuid();
  v_blocked boolean:=false;
begin
  begin
    insert into v482_fence_probe values(v_business,1);
  exception when sqlstate '55000' then
    if position('loyalty value write requires a transaction fence' in sqlerrm)=0 then raise; end if;
    v_blocked:=true;
  end;
  if not v_blocked or exists(select 1 from v482_fence_probe) then
    raise exception 'v482 no-lock mutation was not fail-closed';
  end if;
  perform app.acquire_loyalty_shared_v480(v_business);
  insert into v482_fence_probe values(v_business,1);
  update v482_fence_probe set value=2 where business_id=v_business;
  if not exists(select 1 from v482_fence_probe where business_id=v_business and value=2) then
    raise exception 'v482 shared-lock mutation was not accepted';
  end if;
end
$proof$;

select 'PASS v482 NULL lock mode denied and shared lock accepted' as result;
rollback;
