-- nestly_v514 — "On" means live on BOTH sides. One authority, and redemption is on by default.
--
-- OWNER DIRECTIVE (2026-08-25): "why there is a blind spot of discrepancy in customer and
-- business? ... i cannot afford to have data and visuals inconsistencies ... some see correct
-- wordings some cannot."
--
-- THE MEASUREMENT. The customer reader and the business reader were run over every verified
-- (business, customer) pair on prod and diffed. Balances agreed everywhere. The UNIT diverged on
-- six of ten businesses: the customer got NULL where the business said points/stamps.
--
-- THE ROOT CAUSE — TWO AUTHORITIES FOR ONE QUESTION.
--   business surface  (staff_get_customer_actionable_loyalty_v145) gates on the v314 SPINE
--   customer surface  (app.c45_base_actionable_wallet_card, + 17 more) gates on
--                     `coalesce(lp.active,false) AND engine.running`
-- where engine.running is literally `spine.points_running or spine.stamps_running`. So the two
-- sides already agree on the spine half; the ONLY divergent term in the whole product is
-- `loyalty_programs.active`.
--
-- And nothing keeps that column true. public.set_programmes_v314 — the owner's actual On/Off
-- switch since the v314 inversion — writes loyalty_model and kind (v354) but NEVER active.
-- `active` is written only by publish_loyalty_config, from loyalty_program_versions.active, which
-- the setup wizard sets via saveDraft({active:!keepPaused}). A business that switched a programme
-- on without finishing the wizard therefore had spine=true and lp.active=false:
--
--     AhXiang, Bistro 999, HENG HENG 888, Hougang ABC, KKY demo
--       business workspace: "On"      customer app: no unit, no catalogue
--
-- FIX 1 — the spine writes `active` in the same transaction, exactly as v354 taught it to write
-- loyalty_model and kind. `(v_points or v_stamps)` is byte-for-byte the expression the customer
-- reader computes as engine.running, so after this the customer's condition reduces to
-- `module enabled AND spine` — which IS the business's condition. They cannot drift again.
--
-- Deliberately NOT included in `active`: the tiers spine. engine.running does not include it
-- either, so adding it here would create the very divergence this migration exists to remove.
--
-- FIX 2 — REDEMPTION IS ON BY DEFAULT. customer_create_redemption_intent_v89 gates on
--     coalesce((select redemption_enabled from business_customer_capabilities_v89 ...), FALSE)
-- so a MISSING ROW means redemption is OFF. Only 3 of 14 businesses have that row, which is why
-- "Show QR at counter" worked on Cubbly SPA and raised 42501 'customer redemption is disabled for
-- this business' everywhere else — the owner's photo-1 dead QR. Its only two controls are a
-- legacy Loyalty-page toggle and a Settings screen; neither is on the Rewards Programme page the
-- owner works in, so the state was unreachable as well as invisible.
--
-- An AFTER INSERT trigger on public.businesses seeds the row ENABLED for every future business —
-- the v507 lesson: fix the one trigger, not the four callers. Booking and appointment changes
-- keep their false default; this migration is about redemption only, and switching on a booking
-- surface a firm has not configured would be a different, unasked-for change.
--
-- THE ONE-OFF DATA REPAIR THAT ACCOMPANIES THIS FILE is applied separately, per business, and is
-- recorded in audit_log with source 'nestly_v514_backfill':
--   (a) loyalty_programs.active re-aligned with the spine for the five diverged businesses;
--   (b) a capability row seeded ENABLED for every business that had none. An EXPLICIT false is
--       never overwritten — Bistro 999 has redemption_enabled=false on the record and keeps it,
--       because that may be a real decision rather than an accident.

begin;

-- ---------------------------------------------------------------------------------------------
-- FIX 1 — the switch writes both stores. Spliced, not retyped: set_programmes_v314 is a ~9KB
-- SECURITY DEFINER body and retyping it to add a few lines is how v277's incident happened. The
-- anchor is REPRODUCED inside the replacement — the rule nestly_v513 learned the hard way, where
-- an anchor that was itself a statement got replaced instead of extended.
do $splice$
declare
  v_def text; v_new text;
  v_anchor constant text := '  v_model := case when v_stamps then ''stamps'' else ''classic'' end;';
  v_inject constant text :=
'  -- nestly_v514: the customer surfaces gate on loyalty_programs.active while this switch moves
  -- the spine, so the two must move together or the business reads On while the customer reads
  -- nothing. (v_points or v_stamps) is the same expression app.c45_base_actionable_wallet_card
  -- computes as engine.running, so the two conditions are now one fact.
  update public.loyalty_programs
     set active = (v_points or v_stamps)
   where business_id = p_business
     and active is distinct from (v_points or v_stamps);
  if found then
    insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
    values (p_business, v_actor, ''loyalty_active.synced_to_spine'', ''loyalty_programs'', p_business,
      jsonb_build_object(''active'', (v_points or v_stamps), ''source'', ''set_programmes_v314''));
  end if;
  v_model := case when v_stamps then ''stamps'' else ''classic'' end;';
begin
  v_def := pg_get_functiondef('public.set_programmes_v314(uuid,jsonb,uuid)'::regprocedure);
  if position('loyalty_active.synced_to_spine' in v_def) > 0 then
    raise notice 'nestly_v514: set_programmes_v314 already syncs active, skipping';
  else
    if (length(v_def) - length(replace(v_def, v_anchor, ''))) / nullif(length(v_anchor),0) <> 1 then
      raise exception 'nestly_v514: anchor did not match exactly once in set_programmes_v314 — body drifted'
        using errcode='XX001';
    end if;
    v_new := replace(v_def, v_anchor, v_inject);
    if v_new = v_def then
      raise exception 'nestly_v514: splice produced no change' using errcode='XX001';
    end if;
    execute v_new;
  end if;
end
$splice$;

-- ---------------------------------------------------------------------------------------------
-- FIX 2 — every business created from now on can accept a redemption QR.
create or replace function app.seed_customer_capabilities_v514()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
begin
  -- nestly_v514: redemption defaults ON. A customer holding a reward they earned should be able
  -- to show its QR without an owner first finding a switch on a screen they never visit. Booking
  -- and appointment changes keep their false default: those surfaces need configuration first.
  insert into public.business_customer_capabilities_v89(business_id, redemption_enabled)
  values (new.id, true)
  on conflict (business_id) do nothing;
  return new;
end
$function$;

comment on function app.seed_customer_capabilities_v514() is
  'nestly_v514: every new business can accept a customer redemption QR from birth; a missing capability row used to mean redemption was silently off.';

drop trigger if exists trg_seed_customer_capabilities_v514 on public.businesses;
create trigger trg_seed_customer_capabilities_v514
  after insert on public.businesses
  for each row execute function app.seed_customer_capabilities_v514();

-- ---------------------------------------------------------------------------------------------
-- Prove the CODE change took. (The data repair has its own verification, run alongside it.)
do $verify$
begin
  if position('loyalty_active.synced_to_spine'
        in pg_get_functiondef('public.set_programmes_v314(uuid,jsonb,uuid)'::regprocedure)) = 0 then
    raise exception 'nestly_v514: set_programmes_v314 does not sync loyalty_programs.active'
      using errcode='XX001';
  end if;
  if not exists (select 1 from pg_trigger
                  where tgrelid='public.businesses'::regclass
                    and tgname='trg_seed_customer_capabilities_v514') then
    raise exception 'nestly_v514: the capability seed trigger is not installed' using errcode='XX001';
  end if;
end
$verify$;

commit;
