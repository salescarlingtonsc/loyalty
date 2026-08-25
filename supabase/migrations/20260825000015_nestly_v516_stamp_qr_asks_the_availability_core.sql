-- nestly_v516 — a stamp gift the card says is READY can actually be shown as a QR.
--
-- OWNER (2026-08-25, photo 5, arrows to two "Show QR at counter" buttons): "why i press and
-- nothing come out". Reproduced against prod for the real customer in that screenshot.
--
-- Devi M at QA Kaya Toast holds 31 stamps: 30 across TWO COMPLETED cards, 1 on the card she is
-- filling now. app.reward_availability_v432 — the authority the wallet card, the till and the
-- counter all read — correctly reports ABC / Jffjj / Free Facial as available_at_counter
-- (quantity 1, 2 and 2), because since v478/v496 a gift EARNED on a card survives that card
-- closing and stacks.
--
-- customer_create_redemption_intent_v89 did not ask that authority. It re-derived readiness:
--
--     select sp.filled into v_stamp_filled from app.stamp_progress_v323(p_business, v_client) sp;
--     if coalesce(v_stamp_filled,0) < v_cost_points then
--       raise exception 'not enough stamps yet' using errcode='23514';
--
-- `filled` is the CURRENT card only — 1 of 15 — so every gift earned on a completed card was
-- refused. The browser surfaces that refusal as a toast, which is why the button looked dead.
--
-- THE FIX: the gate becomes the same question the card asked. One authority, so the promise and
-- the refusal cannot disagree again — v145's own rule applied to the writer that was exempt from
-- it. The points path is untouched (this branch only runs for kind='stamps'), and the
-- stamp_milestone_claims check that follows is untouched because v432 already nets claims out of
-- its quantity.
--
-- Applied to prod via the splice below; the anchor is REPRODUCED in the replacement, the rule
-- nestly_v513 learned the hard way.

begin;

do $splice$
declare
  v_def text; v_new text;
  v_anchor constant text :=
'    if coalesce(v_stamp_filled,0)<v_cost_points then
      raise exception ''not enough stamps yet'' using errcode=''23514'';
    end if;';
  v_inject constant text :=
'    -- nestly_v516: ask the ONE authority the card, the till and the counter already read.
    -- v_stamp_filled is the CURRENT card only, so comparing it to the cost refused every gift
    -- earned on a card the customer has already completed — the exact "I press and nothing comes
    -- out" the owner reported. It is still selected above because the milestone-claim check below
    -- uses the cycle it comes with.
    if not exists (
      select 1 from app.reward_availability_v432(p_business, v_client, now()) ra
       where ra.reward_id = p_reward
         and ra.availability = ''available_at_counter''
    ) then
      raise exception ''not enough stamps yet'' using errcode=''23514'';
    end if;';
begin
  v_def := pg_get_functiondef('public.customer_create_redemption_intent_v89(uuid,uuid,uuid,text)'::regprocedure);
  if position('nestly_v516' in v_def) > 0 then
    raise notice 'nestly_v516: already applied, skipping';
  else
    if (length(v_def) - length(replace(v_def, v_anchor, ''))) / nullif(length(v_anchor),0) <> 1 then
      raise exception 'nestly_v516: anchor did not match exactly once — body drifted' using errcode='XX001';
    end if;
    v_new := replace(v_def, v_anchor, v_inject);
    if v_new = v_def then
      raise exception 'nestly_v516: splice produced no change' using errcode='XX001';
    end if;
    execute v_new;
  end if;
end
$splice$;

do $verify$
begin
  if position('nestly_v516'
       in pg_get_functiondef('public.customer_create_redemption_intent_v89(uuid,uuid,uuid,text)'::regprocedure)) = 0 then
    raise exception 'nestly_v516: the stamp gate was not replaced' using errcode='XX001';
  end if;
end
$verify$;

commit;
