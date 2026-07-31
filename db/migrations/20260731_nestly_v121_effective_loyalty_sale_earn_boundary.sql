-- NESTLY v121 — EFFECTIVE LOYALTY SALE-EARN BOUNDARY
--
-- Forward-only local review candidate. Sale recording remains authoritative
-- and appointment completion still checks out once, but a new points/stamps
-- earn is allowed only when Loyalty is writable at the sale's exact branch.
-- Existing ledger balances and customer read policy are untouched.

begin;

do $v121_patch_sale_earn$
declare
  v_def text;
  v_old text:='if new.earns_points then';
  v_new text:='if new.earns_points'
    || E'\n     and exists('
    || E'\n       select 1'
    || E'\n       from app.effective_platform_module_mode_v94('
    || E'\n         new.business_id,new.branch_id,''loyalty'''
    || E'\n       ) effective'
    || E'\n       where effective.mode=''rw'''
    || E'\n     ) then';
  v_old_count integer;
  v_new_count integer;
begin
  if to_regprocedure(
       'app.effective_platform_module_mode_v94(uuid,uuid,text)'
     ) is null then
    raise exception
      'v121 requires the v94 effective platform module resolver';
  end if;

  select pg_get_functiondef(
    'app.on_sale_recorded()'::regprocedure
  ) into strict v_def;

  v_old_count:=
    (length(v_def)-length(replace(v_def,v_old,'')))/length(v_old);
  v_new_count:=
    (length(v_def)-length(replace(v_def,v_new,'')))/length(v_new);
  if v_old_count<>1 or v_new_count<>0 then
    raise exception
      'unexpected on_sale_recorded predecessor (old=%, new=%)',
      v_old_count,v_new_count;
  end if;
  if position('security definer' in lower(v_def))=0
     or position('set search_path' in lower(v_def))=0
     or position(
       'app.resolve_loyalty_branch_config(' in v_def
     )=0
     or position(
       'insert into public.points_ledger' in v_def
     )=0 then
    raise exception
      'on_sale_recorded predecessor lost reviewed security or earn contracts';
  end if;

  execute replace(v_def,v_old,v_new);
end
$v121_patch_sale_earn$;

revoke all on function app.on_sale_recorded()
  from public,anon,authenticated;

do $v121_postcondition$
declare
  v_def text;
begin
  select pg_get_functiondef(
    'app.on_sale_recorded()'::regprocedure
  ) into strict v_def;
  if position(
       'app.effective_platform_module_mode_v94(' in v_def
     )=0
     or position(
       'new.business_id,new.branch_id,''loyalty''' in v_def
     )=0
     or position(
       'effective.mode=''rw''' in v_def
     )=0
     or position(
       'insert into public.points_ledger' in v_def
     )=0
     or not exists(
       select 1
       from pg_trigger trigger_row
       where trigger_row.tgrelid='public.sales'::regclass
         and trigger_row.tgfoid='app.on_sale_recorded()'::regprocedure
         and not trigger_row.tgisinternal
     ) then
    raise exception
      'v121 effective Loyalty sale-earn boundary is incomplete';
  end if;
end
$v121_postcondition$;

commit;
