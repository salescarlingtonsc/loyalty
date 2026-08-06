-- Rollback-only acceptance for V183 promotion delete/retire.
begin;
do $$
declare v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='business_delete_promotion_v183';
  if v_def is null then raise exception 'business_delete_promotion_v183 missing'; end if;
  -- promotions are content_type='offer'; filtering on 'promotion' matches nothing
  if v_def !~ 'content_type = ''offer''' then
    raise exception 'delete filters the wrong content_type';
  end if;
  -- both write guards must be satisfied or every delete fails in production
  if v_def !~ 'app.v104_promotion_write' or v_def !~ 'app.v104_promotion_copy_write' then
    raise exception 'delete does not satisfy both promotion write guards';
  end if;
  -- a published offer must never be hard-deleted
  if v_def !~ 'v_mode := ''retired''' then
    raise exception 'published offers must be retired, not erased';
  end if;
end $$;
rollback;
