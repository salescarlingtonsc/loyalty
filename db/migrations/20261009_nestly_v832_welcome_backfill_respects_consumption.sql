-- nestly_v832 — pressing Save on the Welcome offer editor may not re-gift a number that used it.
--
-- FOUND BY the adversarial audit of v831 (2026-09-09), and worth recording HOW: six independent
-- auditors attacked v831, three skeptics voted on every finding, and this one was voted down 3-0
-- as "already handled". The completeness critic re-raised it, read the live body, and was right.
-- A unanimous refutation is not proof.
--
-- THE HOLE. v831 re-keyed every JOIN-TIME issuer onto the consumption mark, and
-- app.issue_welcome_offer_v215 is correctly gated. But nestly_v560 added a SECOND writer that is
-- not a join at all: public.business_set_welcome_offer_v215 mass-grants the welcome gift, on an
-- ACTIVE save, to every client of the business with no non-reversed sale — a direct
-- `insert into public.welcome_offer_grants_v215 ... select ... from public.clients` that never
-- asks the gate. Its `on conflict (business_id, client_id) do nothing` protects only clients who
-- ALREADY hold a grant; a customer who deleted and re-registered is a BRAND NEW client row with
-- no grant, so the insert hands them a second welcome gift.
--
-- The path is ordinary, not exotic: the owner opens Rewards, changes the reward item or the
-- minimum spend or the expiry, and presses Save. That save re-runs the v560 backfill. Every
-- deleted-and-rejoined number that v831 correctly refused at sign-up is silently re-gifted. The
-- audit_log shows WELCOME_OFFER_GRANTED_TO_EXISTING_V560 has already fired three times in
-- production, so this is a route businesses actually use.
--
-- Measured before fixing: zero grants currently exist for a number that already consumed one, so
-- the hole had not yet fired onto a consumed number and there is nothing to claw back. This
-- migration closes it before it does.
--
-- TWO LAYERS, deliberately.
--   1. The backfill stops creating the grant. Best outcome: no phantom gift is ever shown to the
--      customer, so nothing has to be taken away from them later.
--   2. The counter refuses to redeem one anyway. app.benefit_consumed_v831 is checked inside
--      public.staff_redeem_welcome_offer_v215 as well, so if any FUTURE writer mass-grants again
--      the owner's rule still holds at the till. A mark can only be present at redemption time if
--      some OTHER grant was already consumed by this number — this grant's own mark is written by
--      the trigger AFTER this check, and a reversal deletes it — so this cannot refuse a first,
--      honest redemption.
--
-- Everything else the audit raised was either killed on the evidence or is governance, not
-- behaviour: fourteen of fifteen findings were refuted 3-0 or 2-1, and the estate scan confirmed
-- no production function still reads app.phone_recently_deleted_v751, all three public.referrals
-- writers consult app.referral_referred_is_new_v683, and both referral payout kinds (points and
-- voucher) are covered by a consumption trigger.

begin;

do $splice$
declare
  v_def text;
  v_new text;
  v_spec jsonb;
  v_target text;
  v_anchor text;
  v_inject text;
  v_probe text;
  v_hits integer;
  v_specs jsonb := jsonb_build_array(

    -- (1) The v560 mass-grant learns the rule.
    jsonb_build_object(
      'fn', $t$public.business_set_welcome_offer_v215(uuid,boolean,integer,text,uuid,integer,text)$t$,
      'probe', $t$benefit_consumed_v831$t$,
      'anchor', $t$        from public.clients c
       where c.business_id = p_business
         and not exists (
           select 1 from public.sales s
            where s.business_id = p_business and s.client_id = c.id
              and s.reversal_of is null
         )
      on conflict (business_id, client_id) do nothing$t$,
      'inject', $t$        from public.clients c
       where c.business_id = p_business
         and not exists (
           select 1 from public.sales s
            where s.business_id = p_business and s.client_id = c.id
              and s.reversal_of is null
         )
         -- nestly_v832: the same question app.issue_welcome_offer_v215 asks at sign-up. Without
         -- it, an ACTIVE save re-gifts every number that already used its welcome gift here and
         -- then deleted and re-registered — a new client row has no grant, so ON CONFLICT does
         -- not stop it.
         and not app.benefit_consumed_v831(p_business, c.id, 'welcome', 'once')
      on conflict (business_id, client_id) do nothing$t$),

    -- (2) The counter refuses one anyway, whoever created it.
    jsonb_build_object(
      'fn', $t$public.staff_redeem_welcome_offer_v215(uuid,uuid,uuid,uuid,text)$t$,
      'probe', $t$benefit_consumed_v831$t$,
      'anchor', $t$  if v_grant.expires_at is not null and v_grant.expires_at <= now() then
    update public.welcome_offer_grants_v215 set status='expired' where id = v_grant.id;
    raise exception 'welcome_offer_expired' using errcode='22023';
  end if;$t$,
      'inject', $t$  if v_grant.expires_at is not null and v_grant.expires_at <= now() then
    update public.welcome_offer_grants_v215 set status='expired' where id = v_grant.id;
    raise exception 'welcome_offer_expired' using errcode='22023';
  end if;

  -- nestly_v832: fail closed at the till. A mark can only be here if some OTHER grant for this
  -- number was already consumed at this business — this grant's own mark is written by the
  -- trigger after this point, and reversing a redemption deletes it — so an honest first
  -- redemption is never refused.
  if app.benefit_consumed_v831(p_business, p_client, 'welcome', 'once') then
    raise exception 'welcome_offer_already_used_by_this_number' using errcode='22023';
  end if;$t$)
  );
begin
  for v_spec in select * from jsonb_array_elements(v_specs) loop
    v_target := v_spec->>'fn';
    v_anchor := v_spec->>'anchor';
    v_inject := v_spec->>'inject';
    v_probe  := coalesce(v_spec->>'probe', '');
    v_def := pg_get_functiondef(v_target::regprocedure);
    if v_def is null then
      raise exception 'nestly_v832: % could not be read', v_target using errcode='XX001';
    end if;
    if v_probe <> '' and position(v_probe in v_def) > 0 then
      raise notice 'nestly_v832: % already carries this edit, skipping', v_target;
      continue;
    end if;
    v_hits := (length(v_def) - length(replace(v_def, v_anchor, ''))) / nullif(length(v_anchor), 0);
    if v_hits is distinct from 1 then
      raise exception 'nestly_v832: anchor matched % time(s) in % — the body has drifted; re-derive the anchor',
        coalesce(v_hits, 0), v_target using errcode='XX001';
    end if;
    v_new := replace(v_def, v_anchor, v_inject);
    if v_new = v_def then
      raise exception 'nestly_v832: splice produced no change for %', v_target using errcode='XX001';
    end if;
    execute v_new;
    raise notice 'nestly_v832: % now respects the consumption mark', v_target;
  end loop;
end
$splice$;

-- Grants restated verbatim from the live proacl.
revoke all on function public.business_set_welcome_offer_v215(uuid, boolean, integer, text, uuid, integer, text)
  from public, anon;
grant execute on function public.business_set_welcome_offer_v215(uuid, boolean, integer, text, uuid, integer, text)
  to authenticated, service_role;
revoke all on function public.staff_redeem_welcome_offer_v215(uuid, uuid, uuid, uuid, text) from public, anon;
grant execute on function public.staff_redeem_welcome_offer_v215(uuid, uuid, uuid, uuid, text)
  to authenticated, service_role;

do $verify$
declare v_bad text;
begin
  select string_agg(t.fn, ', ') into v_bad
    from (values
      ('public.business_set_welcome_offer_v215(uuid,boolean,integer,text,uuid,integer,text)'),
      ('public.staff_redeem_welcome_offer_v215(uuid,uuid,uuid,uuid,text)')
    ) as t(fn)
   where position('benefit_consumed_v831' in pg_get_functiondef(t.fn::regprocedure)) = 0;
  if v_bad is not null then
    raise exception 'nestly_v832: these still ignore the consumption mark: %', v_bad using errcode='XX001';
  end if;
end
$verify$;

commit;
