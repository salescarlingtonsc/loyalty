-- Nestly v94: forward-only repair for v88 firm snapshots.
--
-- Production already applied v88, so its historical bytes must remain immutable.
-- A non-terminal prospect with no next action and fewer than seven unattended
-- days makes v88's three-valued attention predicate NULL. The v88 snapshot row
-- is NOT NULL, so the first super-admin directory read aborts. Repair the
-- snapshot boundary: persist and project NULL as false without rewriting v88.

begin;

do $v94_predecessor$
declare
  v_def text;
  v_compact_def text;
begin
  if to_regprocedure(
    'app.ensure_platform_firm_snapshot_v88(uuid,timestamp with time zone,boolean)'
  ) is null then
    raise exception 'v94 requires the reviewed v88 snapshot predecessor';
  end if;

  select pg_get_functiondef(
    'app.ensure_platform_firm_snapshot_v88(uuid,timestamp with time zone,boolean)'::regprocedure
  ) into strict v_def;
  v_compact_def:=regexp_replace(lower(v_def),'[[:space:]]+','','g');

  if (length(v_compact_def)-length(replace(
      v_compact_def,
      'firm.attention_due,firm.attention_severity',
      ''
    )))/length('firm.attention_due,firm.attention_severity')<>1
     or (length(v_compact_def)-length(replace(v_compact_def,'to_jsonb(firm)','')))
       /length('to_jsonb(firm)')<>1
     or position('coalesce(firm.attention_due,false)' in v_compact_def)>0 then
    raise exception 'v94 predecessor is not the reviewed v88 snapshot writer';
  end if;
end
$v94_predecessor$;

create or replace function app.ensure_platform_firm_snapshot_v88(
  p_actor uuid,
  p_snapshot_at timestamptz,
  p_allow_create boolean
)
returns timestamptz
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_expires_at timestamptz;
  v_created boolean:=false;
begin
  if p_actor is null or p_snapshot_at is null then
    raise exception 'actor and snapshot token are required' using errcode='22023';
  end if;

  select snapshot.expires_at into v_expires_at
  from app.platform_firm_snapshots_v88 snapshot
  where snapshot.actor_id=p_actor and snapshot.snapshot_at=p_snapshot_at;
  if found then
    if v_expires_at<=clock_timestamp() then
      raise exception 'firm snapshot token has expired' using errcode='22023';
    end if;
    return v_expires_at;
  end if;
  if not p_allow_create then
    raise exception 'firm snapshot token was not found' using errcode='22023';
  end if;

  delete from app.platform_firm_snapshots_v88 snapshot
  where snapshot.actor_id=p_actor and snapshot.expires_at<=clock_timestamp();

  insert into app.platform_firm_snapshots_v88(actor_id,snapshot_at)
  values(p_actor,p_snapshot_at)
  on conflict(actor_id,snapshot_at) do nothing
  returning expires_at into v_expires_at;
  v_created:=found;

  if v_created then
    insert into app.platform_firm_snapshot_rows_v88(
      actor_id,snapshot_at,row_id,updated_at,days_unattended,
      attention_due,attention_severity,lane_key,sector_key,industry,
      onboarding_status,subscription_status,search_text,payload
    )
    select
      p_actor,p_snapshot_at,firm.row_id,firm.updated_at,firm.days_unattended,
      coalesce(firm.attention_due,false),firm.attention_severity,firm.lane_key,
      firm.sector_key,firm.industry,firm.onboarding_status,
      firm.subscription_status,
      lower(concat_ws(' ',firm.name,firm.legal_name,firm.registration_number,
        firm.sector_key,firm.industry,firm.boss_name,firm.boss_email,firm.boss_phone)),
      to_jsonb(firm)||jsonb_build_object(
        'attention_due',coalesce(firm.attention_due,false)
      )
    from app.platform_firm_rows_v88(p_snapshot_at) firm;
  else
    select snapshot.expires_at into v_expires_at
    from app.platform_firm_snapshots_v88 snapshot
    where snapshot.actor_id=p_actor and snapshot.snapshot_at=p_snapshot_at;
  end if;

  if v_expires_at is null or v_expires_at<=clock_timestamp() then
    raise exception 'firm snapshot token is unavailable' using errcode='22023';
  end if;
  return v_expires_at;
end
$$;

revoke all on function app.ensure_platform_firm_snapshot_v88(
  uuid,timestamptz,boolean
) from public,anon,authenticated;

comment on function app.ensure_platform_firm_snapshot_v88(
  uuid,timestamptz,boolean
) is 'v94 forward repair: v88 firm snapshots fail-close nullable attention predicates to false in both indexed columns and frozen JSON payloads.';

do $v94_final$
declare
  v_def text;
  v_compact_def text;
begin
  select pg_get_functiondef(
    'app.ensure_platform_firm_snapshot_v88(uuid,timestamp with time zone,boolean)'::regprocedure
  ) into strict v_def;
  v_compact_def:=regexp_replace(lower(v_def),'[[:space:]]+','','g');
  if (length(v_compact_def)-length(replace(
      v_compact_def,
      'coalesce(firm.attention_due,false)',
      ''
    )))/length('coalesce(firm.attention_due,false)')<>2
     or has_function_privilege(
       'authenticated',
       'app.ensure_platform_firm_snapshot_v88(uuid,timestamp with time zone,boolean)',
       'execute'
     )
     or has_function_privilege(
       'anon',
       'app.ensure_platform_firm_snapshot_v88(uuid,timestamp with time zone,boolean)',
       'execute'
     ) then
    raise exception 'v94 final snapshot guard or grants are not exact';
  end if;
end
$v94_final$;

commit;
