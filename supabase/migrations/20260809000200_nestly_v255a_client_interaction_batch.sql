-- NESTLY v255a - BATCHED CLIENT INTERACTION INGEST
--
-- The client records one RPC per interaction today. Instrumenting route views,
-- promotion views and search shapes multiplies that by roughly an order of
-- magnitude, which is a request-per-tap tax on a phone browser on a Singapore
-- 4G connection.
--
-- record_product_interactions_batch_v255 takes up to 50 events and loops the
-- EXISTING public.record_product_interaction_v100 per event, so every privacy,
-- allowlist, authorization, time-window and idempotency rule stays in exactly
-- one place. Replay safety is the v100
-- (actor_user_id, idempotency_key) unique index, unchanged.
--
-- The batch is deliberately fail-soft PER EVENT: one malformed or unauthorized
-- event must not discard the other 49, and telemetry must never surface an
-- error to a customer mid-tap. Per-event outcomes are returned so tests can
-- assert them, and a whole-batch shape violation still raises.

begin;

create or replace function public.record_product_interactions_batch_v255(
  p_events jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_actor uuid:=auth.uid();
  v_event jsonb;
  v_results jsonb:='[]'::jsonb;
  v_accepted integer:=0;
  v_replayed integer:=0;
  v_rejected integer:=0;
  v_outcome jsonb;
  v_count integer;
begin
  if v_actor is null then
    raise exception 'authenticated interaction session is required'
      using errcode='28000';
  end if;
  if p_events is null or jsonb_typeof(p_events)<>'array' then
    raise exception 'a batch must be a JSON array of interaction events'
      using errcode='22023';
  end if;
  select count(*)::integer into v_count
  from pg_catalog.jsonb_array_elements(p_events);
  if v_count=0 then
    raise exception 'a batch must contain at least one interaction event'
      using errcode='22023';
  end if;
  if v_count>50 then
    raise exception 'a batch may contain at most 50 interaction events'
      using errcode='22023';
  end if;
  if octet_length(p_events::text)>65536 then
    raise exception 'batch payload exceeds the accepted size'
      using errcode='22023';
  end if;

  for v_event in
    select value from pg_catalog.jsonb_array_elements(p_events) as element(value)
  loop
    begin
      if jsonb_typeof(v_event)<>'object' then
        raise exception 'each batch entry must be an object'
          using errcode='22023';
      end if;
      v_outcome:=public.record_product_interaction_v100(
        v_event->>'event_name',
        nullif(v_event->>'business_id','')::uuid,
        nullif(v_event->>'branch_id','')::uuid,
        nullif(v_event->>'session_id','')::uuid,
        v_event->>'idempotency_key',
        coalesce(
          nullif(v_event->>'occurred_at','')::timestamptz,clock_timestamp()
        ),
        coalesce(v_event->'context','{}'::jsonb)
      );
      if coalesce((v_outcome->>'replayed')::boolean,false) then
        v_replayed:=v_replayed+1;
      else
        v_accepted:=v_accepted+1;
      end if;
      v_results:=v_results||pg_catalog.jsonb_build_object(
        'idempotency_key',v_event->>'idempotency_key',
        'status',case when coalesce((v_outcome->>'replayed')::boolean,false)
          then 'replayed' else 'accepted' end
      );
    exception when others then
      v_rejected:=v_rejected+1;
      v_results:=v_results||pg_catalog.jsonb_build_object(
        'idempotency_key',v_event->>'idempotency_key',
        'status','rejected',
        'errcode',pg_catalog.upper(sqlstate)
      );
    end;
  end loop;

  return pg_catalog.jsonb_build_object(
    'submitted',v_count,'accepted',v_accepted,'replayed',v_replayed,
    'rejected',v_rejected,'results',v_results,
    'recording_status','accepted_interaction_only',
    'business_outcome_asserted',false
  );
end
$$;
revoke all privileges on function
  public.record_product_interactions_batch_v255(jsonb)
  from public,anon,authenticated,service_role;
grant execute on function
  public.record_product_interactions_batch_v255(jsonb) to authenticated;

comment on function public.record_product_interactions_batch_v255(jsonb) is
  'Batched wrapper over record_product_interaction_v100. Every privacy, authorization and idempotency rule stays in the single-event function; one bad event never discards the batch.';

commit;
