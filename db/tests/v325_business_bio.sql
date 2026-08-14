-- v325 acceptance — businesses.bio is a nullable, additive column with no backfill.
-- Rolled back at the end. Set v325.business (any tenant) and v325.owner.

begin;

do $suite$
declare
  v_biz uuid := current_setting('v325.business', true)::uuid;
  v_owner uuid; v_bio text;
  v_pass int := 0; v_fail int := 0; v_log text := '';
begin
  if v_biz is null then raise exception 'set v325.business and v325.owner'; end if;
  select s.user_id into v_owner from public.staff s
  where s.business_id = v_biz and s.role = 'owner' and s.active limit 1;

  -- Additive and nullable: an untouched row has no bio.
  select bio into v_bio from public.businesses where id = v_biz;
  if v_bio is null
    then v_pass:=v_pass+1; v_log:=v_log||E'\nPASS 1  bio is null until an owner sets it';
    else v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 1  bio was not null: '||v_bio; end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  perform set_config('role','authenticated', true);

  -- The owner can set it on their own row, exactly like booking_policy/review_url.
  update public.businesses set bio = 'A short description shown to customers.' where id = v_biz;
  select bio into v_bio from public.businesses where id = v_biz;
  if v_bio = 'A short description shown to customers.'
    then v_pass:=v_pass+1; v_log:=v_log||E'\nPASS 2  the owner can set their own bio';
    else v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 2  bio did not save: '||coalesce(v_bio,'<null>'); end if;

  -- The public portal read (get_business_public, via internal_public_booking_page) surfaces the
  -- same bio the owner just set — the one read site this migration wires up.
  reset role;
  reset request.jwt.claims;
  declare v_public_bio text;
  begin
    select public.get_business_public((select slug from public.businesses where id = v_biz))::jsonb->>'bio'
      into v_public_bio;
    if v_public_bio = 'A short description shown to customers.'
      then v_pass:=v_pass+1; v_log:=v_log||E'\nPASS 2b  the public portal read surfaces bio';
      else v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 2b  public read did not surface bio: '||coalesce(v_public_bio,'<null>'); end if;
  end;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  perform set_config('role','authenticated', true);

  -- Clearing it back to null must round-trip cleanly (no NOT NULL, no default reasserting).
  update public.businesses set bio = null where id = v_biz;
  select bio into v_bio from public.businesses where id = v_biz;
  if v_bio is null
    then v_pass:=v_pass+1; v_log:=v_log||E'\nPASS 3  bio clears back to null';
    else v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 3  bio did not clear: '||v_bio; end if;

  reset role;
  reset request.jwt.claims;

  raise notice '%', v_log;
  if v_fail > 0 then
    raise exception 'v325 business_bio: % failed, % passed', v_fail, v_pass;
  else
    raise notice 'v325 business_bio: all % checks passed', v_pass;
  end if;
end;
$suite$;

rollback;
