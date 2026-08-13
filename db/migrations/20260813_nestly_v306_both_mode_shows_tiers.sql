-- NESTLY v306 — a firm running points AND tiers must show BOTH to its customers.
--
-- The bug. v231 taught public.customer_portal_capabilities the v229 vocabulary, which at the
-- time held exactly two chosen modes, and decided the tier ladder with
--   and coalesce(v_points_mode,'tiers') = 'tiers'
-- v239 then made points_mode='both' legal (points redeem for rewards while the ladder is
-- climbed by visits or spend — the Chagee shape), and that equality is FALSE for 'both'. So a
-- firm that deliberately runs both programmes has its ladder suppressed on every customer
-- surface: capabilities answer tiers=false, and the wallet never mounts the two-tab
-- tier+points layout it already knows how to draw. Nothing on the client needs to change.
--
-- The neighbouring predicates are already correct for 'both' and are deliberately untouched:
-- 'rewards' asks coalesce(v_points_mode,'redeem') <> 'tiers', and the v229 redemption gate in
-- customer_create_redemption_intent_v89 refuses only ='tiers'. A 'both' firm therefore already
-- redeems normally; only the ladder was missing.
--
-- Owner ruling 2026-08-13 — the programmes are INDEPENDENT. Points, tiers, referrals and
-- offers may run in any combination, and every programme a firm has switched on has to be
-- visible to that firm's customers. A capability that hides a running programme is the
-- platform contradicting the owner's own setup.
--
-- Why a text patch instead of a re-stated create-or-replace (the v229 and v121 precedent).
-- The APPLIED definition is the authority here, not this repository's last copy of it: v231
-- shipped this function and later migrations may have spliced into it since, so re-stating
-- v231's body verbatim would silently revert whatever they added. The applied definition is
-- read with pg_get_functiondef, exactly one predicate is replaced, and pre/post assertions
-- prove the anchor existed exactly once, that the mode vocabulary had not already been
-- widened, and that the new predicate landed exactly once. create-or-replace preserves the
-- owner and the ACL, so this migration grants and revokes nothing.

begin;

do $v306_patch_tiers_capability$
declare
  v_def text;
  v_old text:='and coalesce(v_points_mode,''tiers'') = ''tiers''';
  v_new text:='and coalesce(v_points_mode,''tiers'') in (''tiers'',''both'')';
  v_old_count integer;
  v_new_count integer;
begin
  select pg_get_functiondef(
    'public.customer_portal_capabilities(text)'::regprocedure
  ) into strict v_def;

  -- Idempotence: probe for the EXACT text this migration writes, nothing looser. A bare
  -- substring probe ('both' anywhere) would fail OPEN the day any comment or payload key
  -- carries that word — the run would report applied while the predicate stayed unpatched.
  if position(v_new in v_def)>0 then
    raise notice
      'v306: customer_portal_capabilities already admits both-mode; nothing to patch';
    return;
  end if;

  v_old_count:=
    (length(v_def)-length(replace(v_def,v_old,'')))/length(v_old);
  if v_old_count<>1 then
    raise exception
      'unexpected customer_portal_capabilities predecessor (tiers anchor occurrences=%)',
      v_old_count;
  end if;
  if position('security definer' in lower(v_def))=0
     or position('set search_path' in lower(v_def))=0
     or position('app.v32_customer_wallet_context(' in v_def)=0
     or position('''rewards'',' in v_def)=0 then
    raise exception
      'customer_portal_capabilities predecessor lost its reviewed security or payload contracts';
  end if;
  if replace(v_def,v_old,v_new)=v_def then
    raise exception 'v306 replacement left the definition unchanged';
  end if;

  execute replace(v_def,v_old,v_new);

  select pg_get_functiondef(
    'public.customer_portal_capabilities(text)'::regprocedure
  ) into strict v_def;
  v_new_count:=
    (length(v_def)-length(replace(v_def,v_new,'')))/length(v_new);
  v_old_count:=
    (length(v_def)-length(replace(v_def,v_old,'')))/length(v_old);
  if v_new_count<>1 or v_old_count<>0 then
    raise exception
      'v306 patch did not land (new=%, old=%)',v_new_count,v_old_count;
  end if;
end
$v306_patch_tiers_capability$;

comment on function public.customer_portal_capabilities(text) is
  'v306: tiers is true for points_mode ''tiers'' AND ''both'', so a firm running points and '
  'tiers together shows both programmes. v230/v231: rewards is false in tiers mode so the '
  'surface never offers a redemption the v229 gate refuses, and points_mode is reported so an '
  'absent section can be explained rather than silently dropped.';

commit;
