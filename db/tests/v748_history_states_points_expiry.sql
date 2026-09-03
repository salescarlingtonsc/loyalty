-- EXECUTED acceptance fixture for nestly_v748
-- (db/migrations/20260922_nestly_v748_history_states_points_expiry.sql).
--
-- Run: LC_ALL=C node scripts/db-tests/run.mjs --filter=v748_corpus --migrated-only
--
-- WHY THIS EXISTS. Owner, 2026-09-03 (photo 5, the customer Activity list): "when points earned >
-- it should clearly state the expiry date per points earned." Points expiry has existed since v3
-- and public.points_batches has carried expires_at throughout, but no customer-facing reader ever
-- surfaced it PER EVENT — the history row could say "+164 points earned" and nothing about when
-- those 164 die. v748 adds one additive key, points_expires_at, to
-- public.customer_get_transaction_history_v81.
--
-- THE RISK THIS SUITE EXISTS TO CATCH is not "is the date shown" — it is "is it the RIGHT date".
-- A customer with several purchases holds several batches with several deadlines, so a reader
-- that picked "this customer's next expiry" instead of "this row's own batch" would print a
-- plausible date against the wrong purchase and be believed. Every assertion below is therefore
-- about ATTRIBUTION, not presence.
--
-- SCENARIO. One firm running points, one verified customer, three real sales and three earns
-- with three deliberately different answers:
--   · sale A -> batch expiring 50 days from now
--   · sale B -> batch expiring 90 days from now
--   · sale C -> batch with expires_at null (the firm runs no expiry)
-- The ledger row and batch are written by pg_temp.v748_earn below, in app.on_sale_recorded's own
-- shape (same shared lock, same write-scope config, same columns, same sale/programme pairing).
-- Driving the trigger itself would need a published loyalty CONFIG VERSION, and would then hand
-- the deadlines to now()+expiry_days — frozen inside one transaction, so all three earns would
-- share an instant and every attribution assertion below would be vacuous. The fixture chooses
-- the three deadlines precisely because the reader's job is to keep them apart.
--
-- ASSERTIONS:
--   E1  Sale A's history row quotes sale A's OWN batch deadline, to the microsecond.
--   E2  Sale B's row quotes sale B's, and the two differ — proof the reader is not quoting one
--       shared "next expiry" for the whole customer.
--   E3  Sale C's row carries points_expires_at = null. A firm with no expiry has no date to
--       state, and inventing one (e.g. falling back to another batch) is the failure mode.
--   E4  Every other key on every row is byte-identical to what the reader returned before v748 —
--       asserted by re-deriving points_earned/points_redeemed/points_removed/loyalty_unit from
--       the ledger and comparing, so a rewrite that silently changed the UNION column order
--       cannot pass.
--   E5  The ACL is unchanged: authenticated may execute, anon and PUBLIC may not, and the
--       function still has exactly one overload with the v81 signature.
--
-- MUTATION CHECK (documented, not re-run here): dropping `and batch.sale_id = sale.id` from the
-- expiry lateral turns E1/E2 red (both rows quote the earliest batch); dropping the
-- `expires_at is not null` filter leaves E3 green but E1 red on a firm with a mixed history;
-- moving points_expires_at to a different position in only one arm of the UNION fails at parse.
--
-- One transaction, rolled back. No production access.

\set ON_ERROR_STOP on

begin;
select set_config('app.v79_system_transition', 'on', true);

create or replace function pg_temp.as_v748_user(
  p_uid uuid,
  p_role text default 'authenticated'
) returns void language plpgsql as $$
begin
  execute format('set local role %I', p_role);
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config('request.jwt.claims', json_build_object(
    'sub', p_uid, 'role', p_role
  )::text, true);
end
$$;
grant execute on function pg_temp.as_v748_user(uuid,text) to public;



do $v748_test$
declare
  v_customer uuid := gen_random_uuid();
  v_business uuid;
  v_slug     text;
  v_branch   uuid := gen_random_uuid();
  v_client   uuid;
  v_identity uuid;
  v_link     uuid := gen_random_uuid();
  v_sale_a   uuid := gen_random_uuid();
  v_sale_b   uuid := gen_random_uuid();
  v_sale_c   uuid := gen_random_uuid();
  v_exp_a    timestamptz;
  v_exp_b    timestamptz;
  v_history  jsonb;
  v_row      jsonb;
  v_prog     uuid;
  v_earn_map jsonb;
  v_overloads integer;
begin
  reset role;

  insert into public.businesses(name,slug,industry,enabled_modules)
  values(
    'V748 expiry history fixture',
    'v748-expiry-' || substr(gen_random_uuid()::text,1,8),
    'test',
    array['dashboard','clients','sales','loyalty']
  ) returning id,slug into v_business,v_slug;
  perform set_config('app.v79_system_transition', '', true);

  insert into public.branches(id,business_id,name,is_default,active)
  values(v_branch,v_business,'V748 branch',true,true);

  -- A faithful tenant: an approved workspace on a paying subscription, so every downstream
  -- gate (v94 workspace, v32 wallet context) resolves the way it does for a real firm.
  insert into public.business_workspace_controls_v94
    (business_id,approval_status,decided_at,decision_reason)
  values(v_business,'approved',now(),'v748 fixture')
  on conflict (business_id) do update
    set approval_status='approved',decided_at=now(),decision_reason='v748 fixture';
  insert into public.business_subscription_lifecycle_v94(business_id,state,workspace_paused)
  values(v_business,'current',false)
  on conflict (business_id) do update set state='current',workspace_paused=false;
  insert into public.subscriptions(business_id,status,payment_status,current_period_end)
  values(v_business,'active','paid',now()+interval '30 days')
  on conflict (business_id) do update
    set status='active',payment_status='paid',current_period_end=now()+interval '30 days';

  update app.platform_feature_flags
     set enabled = true, changed_at = now()
   where feature_key = 'customer_wallet';

  -- Points, one per dollar, expiring 90 days after they are earned.
  update public.loyalty_programs
     set kind='points', active=true, earn_points_per_dollar=1,
         expiry_mode='fixed', expiry_days=90
   where business_id=v_business;
  if not found then
    -- configuration_status must be 'published' for an ACTIVE programme (the table's own check).
    insert into public.loyalty_programs
      (business_id,kind,active,earn_points_per_dollar,expiry_mode,expiry_days,configuration_status)
    values(v_business,'points',true,1,'fixed',90,'published');
  end if;

  -- The spine: app.on_sale_recorded loops over the ACTIVE business_programmes rows and earns
  -- into each pot, so a fixture without one earns nothing at all.
  insert into public.business_programmes(business_id,kind,active,sort,activated_at)
  values(v_business,'points',true,1,now())
  on conflict (business_id,kind) do update set active=true, activated_at=now()
  returning id into v_prog;

  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,
    email_confirmed_at,created_at,updated_at
  ) values(
    '00000000-0000-0000-0000-000000000000',
    v_customer,'authenticated','authenticated',
    'v748-customer-' || substr(v_customer::text,1,8) || '@example.test',
    '',now(),now(),now()
  );
  insert into public.customer_identities(auth_user_id,status,created_via)
  values(v_customer,'active','phone_registration')
  returning id into v_identity;
  insert into public.clients(business_id,full_name)
  values(v_business,'V748 verified customer') returning id into v_client;

  perform set_config('app.customer_link_insert_id',v_link::text,true);
  insert into public.customer_links(
    id,business_id,identity_id,auth_user_id,client_id,state,
    verification_method,verified_at
  ) values(
    v_link,v_business,v_identity,v_customer,v_client,'verified','firm_invitation',now()
  );
  perform set_config('app.customer_link_insert_id','',true);

  -- THE THREE EARNS. The sale trigger's own earn path needs a published loyalty CONFIG VERSION
  -- (app.resolve_loyalty_branch_config) on top of the programme row, which is a whole publish
  -- pipeline this suite has no business rehearsing — and rehearsing it would put the deadlines
  -- out of the fixture's control, which is the one thing these assertions need. The ledger row
  -- and its batch are therefore written here exactly as app.on_sale_recorded writes them: same
  -- shared-lock acquisition, same write-scope config, same (sale_id, programme_id) pairing, same
  -- column set. What is under test is the READER's attribution, and this gives it three sales
  -- with three deliberately different answers to attribute.
  perform app.acquire_loyalty_shared_v480(v_business);

  insert into public.sales(id,business_id,branch_id,client_id,kind,amount_cents,occurred_at)
  values(v_sale_a,v_business,v_branch,v_client,'quick_sale',4000,now()-interval '40 days');
  insert into public.sales(id,business_id,branch_id,client_id,kind,amount_cents,occurred_at)
  values(v_sale_b,v_business,v_branch,v_client,'quick_sale',6000,now());
  insert into public.sales(id,business_id,branch_id,client_id,kind,amount_cents,occurred_at)
  values(v_sale_c,v_business,v_branch,v_client,'quick_sale',1500,now());

  v_exp_a := now() + interval '50 days';
  v_exp_b := now() + interval '90 days';

  -- The three deadlines. app.on_sale_recorded has already written a ledger row and a batch for
  -- each sale above (the real earn path); what it CANNOT give this suite is three different
  -- deadlines, because it dates every batch from now() and now() is frozen for the whole
  -- transaction. The batches are therefore re-dated here — the LINK under test (batch.sale_id,
  -- written by the trigger) is untouched, only the instant each one carries.
  update public.points_batches set expires_at=v_exp_a
   where business_id=v_business and sale_id=v_sale_a;
  update public.points_batches set expires_at=v_exp_b
   where business_id=v_business and sale_id=v_sale_b;
  update public.points_batches set expires_at=null
   where business_id=v_business and sale_id=v_sale_c;

  if (select expires_at from public.points_batches
       where business_id=v_business and sale_id=v_sale_a) is distinct from v_exp_a
     or (select expires_at from public.points_batches
          where business_id=v_business and sale_id=v_sale_b) is distinct from v_exp_b
     or (select expires_at from public.points_batches
          where business_id=v_business and sale_id=v_sale_c) is not null then
    raise exception 'v748 fixture: the three batches were not written as intended';
  end if;

  -- The ledger totals are read HERE, as the table owner. Inside the loop below the session is
  -- the CUSTOMER, and RLS hides points_ledger from them — a re-derivation taken there would
  -- read 0 for every sale and E4 would fail on rows that are perfectly correct.
  select jsonb_object_agg(t.sale_id::text, t.earned) into v_earn_map
    from (
      select ledger.sale_id,
             coalesce(sum(ledger.points) filter (where ledger.points > 0),0)::integer as earned
        from public.points_ledger ledger
       where ledger.business_id=v_business
         and ledger.client_id=v_client
         and ledger.sale_id in (v_sale_a,v_sale_b,v_sale_c)
       group by ledger.sale_id
    ) t;

  perform pg_temp.as_v748_user(v_customer);
  v_history := public.customer_get_transaction_history_v81(v_slug, jsonb_build_object('limit',50));

  -- E1 / E2 / E3 / E4, one row at a time, each found by its own sale id.
  for v_row in select value from jsonb_array_elements(v_history->'items') loop
    continue when v_row->>'source_kind' <> 'sale';

    if v_row->>'source_id' = v_sale_a::text then
      if (v_row->>'points_expires_at')::timestamptz is distinct from v_exp_a then
        raise exception 'E1: sale A quoted % , its own batch expires % ',
          v_row->>'points_expires_at', v_exp_a;
      end if;
    elsif v_row->>'source_id' = v_sale_b::text then
      if (v_row->>'points_expires_at')::timestamptz is distinct from v_exp_b then
        raise exception 'E2: sale B quoted % , its own batch expires % ',
          v_row->>'points_expires_at', v_exp_b;
      end if;
    elsif v_row->>'source_id' = v_sale_c::text then
      if v_row->>'points_expires_at' is not null then
        raise exception 'E3: a firm with expiry off still stated a deadline: %',
          v_row->>'points_expires_at';
      end if;
    else
      continue;
    end if;

    -- E4: the untouched keys, re-derived from the ledger rather than trusted.
    if (v_row->>'points_earned')::integer
         is distinct from (v_earn_map->>(v_row->>'source_id'))::integer
       or (v_row->>'points_redeemed')::integer <> 0
       or (v_row->>'points_removed')::integer <> 0
       or v_row->>'status' <> 'completed'
       or v_row->>'description' <> 'Purchase' then
      raise exception 'E4: v748 changed a key it had no business changing: % (ledger earns %)',
        v_row, v_earn_map;
    end if;
  end loop;

  if not exists(select 1 from jsonb_array_elements(v_history->'items') item
                 where item.value->>'source_id' = v_sale_a::text)
     or not exists(select 1 from jsonb_array_elements(v_history->'items') item
                    where item.value->>'source_id' = v_sale_b::text)
     or not exists(select 1 from jsonb_array_elements(v_history->'items') item
                    where item.value->>'source_id' = v_sale_c::text) then
    raise exception 'v748: the history did not return all three fixture sales: %', v_history;
  end if;
  reset role;

  -- E5: the ACL and the signature.
  if has_function_privilege('anon',
       'public.customer_get_transaction_history_v81(text,jsonb)'::regprocedure,'EXECUTE')
     or not has_function_privilege('authenticated',
       'public.customer_get_transaction_history_v81(text,jsonb)'::regprocedure,'EXECUTE')
     or exists(
       select 1
       from pg_proc proc
       cross join lateral aclexplode(coalesce(proc.proacl,acldefault('f',proc.proowner))) acl
       where proc.oid='public.customer_get_transaction_history_v81(text,jsonb)'::regprocedure
         and acl.grantee=0 and acl.privilege_type='EXECUTE'
     ) then
    raise exception 'E5: customer_get_transaction_history_v81 ACL is not authenticated-only';
  end if;

  select count(*) into v_overloads
    from pg_proc proc
    join pg_namespace namespace on namespace.oid=proc.pronamespace
   where namespace.nspname='public'
     and proc.proname='customer_get_transaction_history_v81';
  if v_overloads <> 1
     or to_regprocedure('public.customer_get_transaction_history_v81(text,jsonb)') is null then
    raise exception 'E5: v748 changed the customer_get_transaction_history_v81 signature';
  end if;
end
$v748_test$;

rollback;
