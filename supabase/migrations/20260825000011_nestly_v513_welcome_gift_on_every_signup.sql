-- nestly_v513 — a new customer gets the welcome gift however they were signed up.
--
-- OWNER RULING (2026-08-25, photo 2): "record sale must clearly reflect the available rewards
-- (not sure why some rewards like welcome rewards is not shown)". Investigated against prod: the
-- till code is NOT the bug. tillRewardsBlockV373 already renders the welcome banner whenever
-- staff_get_customer_entitlements_v102 returns one, and that reader already returns it. The gift
-- is missing because THE GRANT WAS NEVER CREATED.
--
-- MEASURED ON PROD. app.issue_welcome_offer_v215 has exactly two callers:
--     public.internal_public_join_v89(text,text,text,text,boolean)
--     public.customer_join_business_from_qr_v89_base_v90(text,uuid)
-- (verified: select oid::regprocedure from pg_proc where pg_get_functiondef(oid) ilike
--  '%issue_welcome_offer_v215%'). Both are CUSTOMER SELF-SIGNUP routes. Every staff-side and
-- portal-side route that creates a customer produced no grant at all, so:
--
--     Hougang ABC    welcome offer ON, "Candy Floss", NO minimum spend,  8 customers, 0 ever granted
--     HENG HENG 888  welcome offer ON, "Carlsberg (1 Bottle)",           1 customer,  0 ever granted
--     Cubbly SPA     welcome offer ON, "Free Soyabean", $5 minimum,      8 customers, 2 ever granted
--
-- Eight Hougang ABC customers were each owed a free Candy Floss that no counter was ever offered.
--
-- THE FIX. One `perform app.issue_welcome_offer_v215(...)` on each remaining SIGN-UP path:
--   public.staff_create_client        — the Customers form, till Quick add, onboarding
--   public.quick_add_client           — the till's fast path (created branch only)
--   app.upsert_portal_client          — the public booking portal
--   public.staff_scan_member_qr_v327  — an app member scanning in at a business they had not
--                                       joined; it auto-provisions the client, so it IS a sign-up
--
-- DELIBERATELY EXCLUDED, on the owner's explicit decision (2026-08-25):
--   public.commit_import_job — a CSV backfill of historical customers is NOT a sign-up. Granting
--   there would mint one free gift per imported row, turning a data migration into an unplanned
--   giveaway. Left alone.
--   NO RETROACTIVE BACKFILL — the customers who already missed out stay as they are, so no
--   surprise free items appear against existing customers and no unplanned liability lands on the
--   three businesses. Owner ruling, same date.
--
-- NO NEW LOGIC AND NO NEW GUARD, because app.issue_welcome_offer_v215 is already fully
-- self-gating: it returns null when no offer is configured or the offer is paused; it refuses
-- when the reward item is no longer active; it refuses for any customer who already has a
-- non-reversal sale; and it ends in `on conflict (business_id, client_id) do nothing` against
-- welcome_offer_grants_v215_client_uk, so it is idempotent under retry.
--
-- ONE RULE, LEARNED THE HARD WAY IN THIS VERY MIGRATION: when the anchor IS a statement, the
-- replacement must REPRODUCE that statement. The first cut anchored quick_add_client on its final
-- `return json_build_object('status','created',…)` and replaced it with the grant call alone,
-- dropping the return — every till Quick add then raised 2F005 'control reached end of function
-- without RETURN'. The acceptance suite caught it, and nestly_v513a restored the function; the
-- inject below now carries the return with it. Note also that the verify block at the end is NOT
-- sufficient on its own: a body missing its return still references issue_welcome_offer_v215 and
-- still passes that check. Only executing the function proves it.
--
-- HOW THE FUNCTIONS ARE EDITED, AND WHY. These are large settled SECURITY DEFINER bodies
-- (staff_create_client is ~5.4KB). Retyping one to add ONE line is the riskiest possible way to
-- add one line — the failure mode v277 recorded. So each body is read with pg_get_functiondef,
-- the single line is spliced in at a unique anchor, and the result is executed. Every splice
-- asserts its anchor matched exactly once and RAISES otherwise, so a body that has drifted since
-- this migration was written fails loudly instead of silently skipping the fix.

begin;

do $splice$
declare
  v_def text;
  v_new text;
  v_anchor text;
  v_inject text;
  v_target text;
  v_specs jsonb := jsonb_build_array(
    jsonb_build_object(
      'fn', 'public.quick_add_client(uuid,text,text,boolean)',
      'anchor', '  return json_build_object(''status'',''created'',''client_id'', c.id, ''full_name'', c.full_name);',
      'inject', '  -- nestly_v513: a till Quick add is a sign-up. The ''existing'' branch above has already
  -- returned, so this runs only for a genuinely new customer.
  perform app.issue_welcome_offer_v215(p_business, c.id);
  return json_build_object(''status'',''created'',''client_id'', c.id, ''full_name'', c.full_name);'),
    jsonb_build_object(
      'fn', 'app.upsert_portal_client(uuid,text,text,text)',
      'anchor', '    perform set_config(''app.portal_client_created'', v_client::text, true);
    return v_client;',
      'inject', '    perform set_config(''app.portal_client_created'', v_client::text, true);
    -- nestly_v513: booking through the public portal creates the customer, so it is a sign-up.
    -- Only this branch runs for a NEW client; the pre-existing and lost-race branches return
    -- earlier and must not re-issue.
    perform app.issue_welcome_offer_v215(p_biz, v_client);
    return v_client;'),
    jsonb_build_object(
      'fn', 'public.staff_create_client(uuid,uuid,text,text,text,date,text,boolean,text,text)',
      'anchor', '    coalesce(p_marketing_consent, false)
  ) returning * into v_client;',
      'inject', '    coalesce(p_marketing_consent, false)
  ) returning * into v_client;

  -- nestly_v513: the Customers form, the till Quick add and onboarding all land here. A customer
  -- created by staff is a sign-up exactly as a self-serve join is, and was the largest hole:
  -- app.issue_welcome_offer_v215 had only the two public join routes as callers.
  perform app.issue_welcome_offer_v215(p_business, v_client.id);'),
    jsonb_build_object(
      'fn', 'public.staff_scan_member_qr_v327(uuid,text)',
      'anchor', '    insert into public.clients (business_id, full_name)
    values (p_business, v_display_name)
    returning * into v_client;',
      'inject', '    insert into public.clients (business_id, full_name)
    values (p_business, v_display_name)
    returning * into v_client;

    -- nestly_v513: an app member scanning in at a business they had not joined is auto-provisioned
    -- here — that is a sign-up, and it is the one path where the customer is standing at the
    -- counter when it happens.
    perform app.issue_welcome_offer_v215(p_business, v_client.id);')
  );
  v_spec jsonb;
begin
  for v_spec in select * from jsonb_array_elements(v_specs) loop
    v_target := v_spec->>'fn';
    v_anchor := v_spec->>'anchor';
    v_inject := v_spec->>'inject';
    v_def := pg_get_functiondef(v_target::regprocedure);

    if v_def is null then
      raise exception 'nestly_v513: % could not be read', v_target using errcode='XX001';
    end if;
    -- Fail loudly on drift: the anchor must appear EXACTLY once, or the splice would either miss
    -- silently or land in the wrong branch.
    if (length(v_def) - length(replace(v_def, v_anchor, ''))) / nullif(length(v_anchor),0) <> 1 then
      raise exception 'nestly_v513: anchor did not match exactly once in % — the body has drifted; re-derive the anchor',
        v_target using errcode='XX001';
    end if;
    -- Already spliced? Then this migration is being replayed; leave the body alone.
    if position('issue_welcome_offer_v215' in v_def) > 0 then
      raise notice 'nestly_v513: % already grants the welcome offer, skipping', v_target;
      continue;
    end if;

    v_new := replace(v_def, v_anchor, v_inject);
    if v_new = v_def then
      raise exception 'nestly_v513: splice produced no change for %', v_target using errcode='XX001';
    end if;
    execute v_new;
    raise notice 'nestly_v513: % now issues the welcome offer', v_target;
  end loop;
end
$splice$;

-- Prove it took, in the same transaction: all four must now reference the issuer.
do $verify$
declare v_missing text;
begin
  select string_agg(t.fn, ', ') into v_missing
    from (values
      ('public.quick_add_client(uuid,text,text,boolean)'),
      ('app.upsert_portal_client(uuid,text,text,text)'),
      ('public.staff_create_client(uuid,uuid,text,text,text,date,text,boolean,text,text)'),
      ('public.staff_scan_member_qr_v327(uuid,text)')
    ) as t(fn)
   where position('issue_welcome_offer_v215' in pg_get_functiondef(t.fn::regprocedure)) = 0;
  if v_missing is not null then
    raise exception 'nestly_v513: these sign-up paths still do not grant the welcome offer: %', v_missing
      using errcode='XX001';
  end if;
end
$verify$;

commit;
