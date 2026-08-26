-- nestly_v520 — a points gift can carry its own expiry.
--
-- OWNER RULING (2026-08-26, photo 2 held against photo 3): the Stamp Card page has a "Reward
-- expiry" control — a gift a customer has EARNED and not yet collected stops waiting after N
-- days — and the owner wants the same idea for points. Asked which clock they meant, the answer
-- was: "for points it would be individual gifts expiry, if dont want to set expiry dont need to
-- indicate, if not can set individual expiry for points gift."
--
-- So: PER GIFT, and OPTIONAL. Not a programme-wide setting, and blank keeps today's behaviour.
--
-- WHY PER GIFT IS THE ONLY HONEST SHAPE FOR POINTS. A stamp gift has an earn INSTANT — a card
-- milestone completes and the gift sits there. A points gift has none: app.reward_availability_v432
-- calls a points gift claimable purely because `pot.balance >= rv.cost_points`, and it stops being
-- claimable the moment the balance drops. There is nothing to start a programme-wide clock from.
-- What CAN expire is the entitlement a customer takes — which is exactly
-- loyalty_rewards.entitlement_expiry_days, a column that has existed since V291, is already
-- rendered to the customer ("Use within N days of claiming", v339/v468), is already returned by
-- the availability core, and was until now only settable from the legacy Loyalty page that the
-- Rewards Programme page replaced. This migration does not invent a clock; it hands the owner the
-- one they already had, on the page they actually work in.
--
-- CONSISTENT WITH nestly_v487. That ruling removed the per-gift "Last day to redeem"
-- (claim_available_until) as redundant, on the grounds that a gift must have ONE clock and the
-- real question is "how long does a customer have to use one they have already earned". This is
-- that clock. The Stamp Card page keeps its programme-wide rule and this field is deliberately
-- NOT offered there — two clocks on one stamp gift is the exact thing v487 deleted.
--
-- THREE THINGS HAVE TO MOVE TOGETHER, and missing any one of them makes the field look like it
-- saves and then quietly do nothing:
--
--   1. THE WRITERS take the value. Both gain `p_entitlement_expiry_days`; the updater also gains
--      `p_clear_expiry_days`, because null already means "say nothing, keep what is stored" for
--      every other optional field here, so clearing has to be an EXPLICIT act (the same rule
--      nestly_v472 established for the end date). The value is written to the live row AND to
--      every reward VERSION the writer already touches — the customer reads the version, not the
--      live row, so writing only one of the two is a field that saves and never arrives.
--
--   2. THE IMMUTABLE GUARD allows it. app.reward_version_immutable_guard() holds an explicit
--      allowlist of the columns business_update_reward_v326 owns; anything outside it is frozen on
--      a published version even with the edit token held. Without adding the column here, editing
--      a published gift's expiry would raise 'published reward configuration is immutable'
--      (restrict_violation). This is the third time this allowlist has had to move with a writer.
--
--   3. THE DRAFT RESYNC compares it. The updater keeps untouched drafts in step with the published
--      row only while every field still matches; leaving the new column out of that comparison
--      would make a draft look "already edited" and silently stop following.
--
-- WHY DROP AND RECREATE RATHER THAN CREATE OR REPLACE. Adding a parameter changes the signature,
-- so CREATE OR REPLACE would leave the OLD function in place beside the new one. Two overloads
-- reachable by the same named arguments is PGRST203, which is exactly how nestly_v410 found every
-- promotion save blocked. One signature only. The grants are reproduced verbatim from the dropped
-- functions (authenticated + service_role EXECUTE, nothing to PUBLIC) and asserted at the end.
--
-- The bodies are SPLICED, not retyped: business_update_reward_v326 is ~6KB of settled
-- SECURITY DEFINER logic across five UPDATE statements, and retyping it to thread one column is
-- the riskiest possible way to thread one column (the v277 lesson). Every anchor asserts its own
-- match count and RAISES on drift, so a body that has moved since this was written fails loudly
-- instead of half-applying.

begin;

-- ---------------------------------------------------------------------------------------------
-- 1 — THE UPDATER
-- ---------------------------------------------------------------------------------------------
do $splice$
declare
  v_def text;
  v_new text;
  v_count integer;
  v_sig constant text :=
    'public.business_update_reward_v326(uuid,uuid,text,integer,text,integer,text,boolean,timestamptz,boolean,text)';

  -- Every anchor, with the number of times it MUST appear.
  v_a_sig constant text := 'p_where_it_works text DEFAULT NULL::text)';
  v_a_decl constant text := '  v_where text;';
  v_a_resolve constant text :=
    '  v_where := case when p_where_it_works is null then v_row.where_it_works'||chr(10)||
    '                  else nullif(btrim(p_where_it_works),'''') end;';
  v_a_set constant text := 'where_it_works=v_where';                       -- 5 UPDATE set-lists
  v_a_resync constant text :=
    '           and draft.where_it_works is not distinct from v_published.where_it_works';
  v_a_audit constant text := '      ''claim_available_until'',v_end_date,'||chr(10)||
                             '      ''published_version_synced'',v_published_synced,';
  v_a_return constant text := '    ''claim_available_until'',v_end_date,'||chr(10)||
                              '    ''published_version_synced'',v_published_synced,';

begin
  v_def := pg_get_functiondef(v_sig::regprocedure);

  if position('p_entitlement_expiry_days' in v_def) > 0 then
    raise notice 'nestly_v520: business_update_reward_v326 already carries the expiry, skipping';
    return;
  end if;

  -- ---- assert every anchor before touching anything ----
  v_count := (length(v_def) - length(replace(v_def, v_a_sig, ''))) / length(v_a_sig);
  if v_count <> 1 then raise exception 'nestly_v520: updater signature anchor matched % times', v_count using errcode='XX001'; end if;
  v_count := (length(v_def) - length(replace(v_def, v_a_decl, ''))) / length(v_a_decl);
  if v_count <> 1 then raise exception 'nestly_v520: updater declare anchor matched % times', v_count using errcode='XX001'; end if;
  v_count := (length(v_def) - length(replace(v_def, v_a_resolve, ''))) / length(v_a_resolve);
  if v_count <> 1 then raise exception 'nestly_v520: updater resolve anchor matched % times', v_count using errcode='XX001'; end if;
  v_count := (length(v_def) - length(replace(v_def, v_a_set, ''))) / length(v_a_set);
  if v_count <> 5 then raise exception 'nestly_v520: expected 5 set-list anchors, found %', v_count using errcode='XX001'; end if;
  v_count := (length(v_def) - length(replace(v_def, v_a_resync, ''))) / length(v_a_resync);
  if v_count <> 1 then raise exception 'nestly_v520: updater resync anchor matched % times', v_count using errcode='XX001'; end if;
  v_count := (length(v_def) - length(replace(v_def, v_a_audit, ''))) / length(v_a_audit);
  if v_count <> 1 then raise exception 'nestly_v520: updater audit anchor matched % times', v_count using errcode='XX001'; end if;
  v_count := (length(v_def) - length(replace(v_def, v_a_return, ''))) / length(v_a_return);
  if v_count <> 1 then raise exception 'nestly_v520: updater return anchor matched % times', v_count using errcode='XX001'; end if;

  v_new := v_def;

  -- signature
  v_new := replace(v_new, v_a_sig,
    'p_where_it_works text DEFAULT NULL::text, p_entitlement_expiry_days integer DEFAULT NULL::integer, p_clear_expiry_days boolean DEFAULT false)');

  -- declare
  v_new := replace(v_new, v_a_decl, '  v_where text;'||chr(10)||'  v_expiry_days integer;');

  -- resolve + validate, immediately after the where_it_works resolution so the two optional
  -- text/number fields are decided in one place
  v_new := replace(v_new, v_a_resolve, v_a_resolve || chr(10) ||
'
  -- nestly_v520: null means "leave what is stored alone" — an older app bundle that does not know
  -- this parameter must not silently wipe an expiry the owner set. Clearing is therefore an
  -- explicit act, the same shape p_clear_end_date has. Zero and negative are refused rather than
  -- coerced: "expires after 0 days" is not a thing an owner means, and silently storing it would
  -- make every gift unusable the instant it is taken.
  if p_entitlement_expiry_days is not null and p_entitlement_expiry_days <= 0 then
    raise exception ''gift expiry must be at least 1 day'' using errcode=''22023'';
  end if;
  v_expiry_days := case when p_clear_expiry_days then null
                        when p_entitlement_expiry_days is not null then p_entitlement_expiry_days
                        else v_row.entitlement_expiry_days end;');

  -- every set-list the writer already touches
  v_new := replace(v_new, v_a_set, 'where_it_works=v_where, entitlement_expiry_days=v_expiry_days');

  -- the draft resync comparison
  v_new := replace(v_new, v_a_resync, v_a_resync || chr(10) ||
'           and draft.entitlement_expiry_days is not distinct from v_published.entitlement_expiry_days');

  -- audit + returned payload
  v_new := replace(v_new, v_a_audit,
    '      ''claim_available_until'',v_end_date,'||chr(10)||
    '      ''entitlement_expiry_days'',v_expiry_days,'||chr(10)||
    '      ''published_version_synced'',v_published_synced,');
  v_new := replace(v_new, v_a_return,
    '    ''claim_available_until'',v_end_date,'||chr(10)||
    '    ''entitlement_expiry_days'',v_expiry_days,'||chr(10)||
    '    ''published_version_synced'',v_published_synced,');

  if v_new = v_def then
    raise exception 'nestly_v520: updater splice produced no change' using errcode='XX001';
  end if;

  execute format('drop function %s', v_sig);
  execute v_new;
end
$splice$;

-- ---------------------------------------------------------------------------------------------
-- 2 — THE CREATOR
-- ---------------------------------------------------------------------------------------------
do $splice$
declare
  v_def text; v_new text; v_count integer;
  v_sig constant text :=
    'public.business_create_reward_v326(uuid,uuid,text,integer,integer,text,text,timestamptz,text)';
  v_a_sig constant text := 'p_where_it_works text DEFAULT NULL::text)';
  v_a_decl constant text := '  v_sort integer;';
  v_a_guard constant text :=
    '  if p_claim_available_until is not null and p_claim_available_until <= now() then'||chr(10)||
    '    raise exception ''a gift end date must be in the future'' using errcode=''22023'';'||chr(10)||
    '  end if;';
  v_a_cols constant text := ',claim_available_until,where_it_works';      -- 2 insert column lists
  v_a_vals constant text := ',nullif(btrim(coalesce(p_where_it_works,'''')),'''')';  -- 2 value lists
  v_a_audit constant text := '      ''claim_available_until'',p_claim_available_until,'||chr(10)||
                             '      ''version_split'',v_split,';
  v_a_return constant text := '    ''claim_available_until'',p_claim_available_until,'||chr(10)||
                              '    ''version_split'',v_split,';
begin
  v_def := pg_get_functiondef(v_sig::regprocedure);
  if position('p_entitlement_expiry_days' in v_def) > 0 then
    raise notice 'nestly_v520: business_create_reward_v326 already carries the expiry, skipping';
    return;
  end if;

  v_count := (length(v_def) - length(replace(v_def, v_a_sig, ''))) / length(v_a_sig);
  if v_count <> 1 then raise exception 'nestly_v520: creator signature anchor matched % times', v_count using errcode='XX001'; end if;
  v_count := (length(v_def) - length(replace(v_def, v_a_decl, ''))) / length(v_a_decl);
  if v_count <> 1 then raise exception 'nestly_v520: creator declare anchor matched % times', v_count using errcode='XX001'; end if;
  v_count := (length(v_def) - length(replace(v_def, v_a_guard, ''))) / length(v_a_guard);
  if v_count <> 1 then raise exception 'nestly_v520: creator guard anchor matched % times', v_count using errcode='XX001'; end if;
  v_count := (length(v_def) - length(replace(v_def, v_a_cols, ''))) / length(v_a_cols);
  if v_count <> 2 then raise exception 'nestly_v520: expected 2 insert column lists, found %', v_count using errcode='XX001'; end if;
  v_count := (length(v_def) - length(replace(v_def, v_a_vals, ''))) / length(v_a_vals);
  if v_count <> 2 then raise exception 'nestly_v520: expected 2 insert value lists, found %', v_count using errcode='XX001'; end if;
  v_count := (length(v_def) - length(replace(v_def, v_a_audit, ''))) / length(v_a_audit);
  if v_count <> 1 then raise exception 'nestly_v520: creator audit anchor matched % times', v_count using errcode='XX001'; end if;
  v_count := (length(v_def) - length(replace(v_def, v_a_return, ''))) / length(v_a_return);
  if v_count <> 1 then raise exception 'nestly_v520: creator return anchor matched % times', v_count using errcode='XX001'; end if;

  v_new := v_def;
  v_new := replace(v_new, v_a_sig,
    'p_where_it_works text DEFAULT NULL::text, p_entitlement_expiry_days integer DEFAULT NULL::integer)');
  v_new := replace(v_new, v_a_decl, '  v_sort integer;'||chr(10)||'  v_expiry_days integer;');
  -- No clear flag on create: there is nothing stored yet to keep or remove, so null simply means
  -- "this gift has no expiry" — which is what every gift created before today has.
  v_new := replace(v_new, v_a_guard, v_a_guard || chr(10) ||
'  if p_entitlement_expiry_days is not null and p_entitlement_expiry_days <= 0 then
    raise exception ''gift expiry must be at least 1 day'' using errcode=''22023'';
  end if;
  v_expiry_days := p_entitlement_expiry_days;');
  v_new := replace(v_new, v_a_cols, ',claim_available_until,where_it_works,entitlement_expiry_days');
  v_new := replace(v_new, v_a_vals, v_a_vals || ',v_expiry_days');
  v_new := replace(v_new, v_a_audit,
    '      ''claim_available_until'',p_claim_available_until,'||chr(10)||
    '      ''entitlement_expiry_days'',v_expiry_days,'||chr(10)||
    '      ''version_split'',v_split,');
  v_new := replace(v_new, v_a_return,
    '    ''claim_available_until'',p_claim_available_until,'||chr(10)||
    '    ''entitlement_expiry_days'',v_expiry_days,'||chr(10)||
    '    ''version_split'',v_split,');

  if v_new = v_def then
    raise exception 'nestly_v520: creator splice produced no change' using errcode='XX001';
  end if;

  execute format('drop function %s', v_sig);
  execute v_new;
end
$splice$;

-- ---------------------------------------------------------------------------------------------
-- 3 — THE GUARD'S ALLOWLIST. Without this line the field saves on a draft and raises
--     restrict_violation on every published gift, which is the majority of them.
-- ---------------------------------------------------------------------------------------------
do $guard$
declare
  v_def text; v_new text;
  v_anchor constant text := '    ''claim_available_until'',''where_it_works''];';
begin
  v_def := pg_get_functiondef('app.reward_version_immutable_guard()'::regprocedure);
  if position('entitlement_expiry_days' in v_def) > 0 then
    raise notice 'nestly_v520: the guard already allows entitlement_expiry_days, skipping';
    return;
  end if;
  if (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor) <> 1 then
    raise exception 'nestly_v520: the guard allowlist anchor did not match exactly once — it has drifted'
      using errcode='XX001';
  end if;
  v_new := replace(v_def, v_anchor,
    '    ''claim_available_until'',''where_it_works'','||chr(10)||
    '    -- nestly_v520: the owner sets a points gift''''s own expiry from the Rewards Programme page,'||chr(10)||
    '    -- so business_update_reward_v326 now owns this column too.'||chr(10)||
    '    ''entitlement_expiry_days''];');
  execute v_new;
end
$guard$;

-- ---------------------------------------------------------------------------------------------
-- 4 — GRANTS, reproduced exactly as the dropped functions carried them.
-- ---------------------------------------------------------------------------------------------
revoke all on function public.business_create_reward_v326(uuid,uuid,text,integer,integer,text,text,timestamptz,text,integer) from public;
revoke all on function public.business_update_reward_v326(uuid,uuid,text,integer,text,integer,text,boolean,timestamptz,boolean,text,integer,boolean) from public;
grant execute on function public.business_create_reward_v326(uuid,uuid,text,integer,integer,text,text,timestamptz,text,integer) to authenticated, service_role;
grant execute on function public.business_update_reward_v326(uuid,uuid,text,integer,text,integer,text,boolean,timestamptz,boolean,text,integer,boolean) to authenticated, service_role;

comment on function public.business_update_reward_v326(uuid,uuid,text,integer,text,integer,text,boolean,timestamptz,boolean,text,integer,boolean) is
  'nestly_v520: a points gift carries its own optional expiry (entitlement_expiry_days) — how many days a customer has to use one they have taken. Null keeps what is stored; p_clear_expiry_days removes it.';

-- ---------------------------------------------------------------------------------------------
-- 5 — PROVE THE CODE CHANGE TOOK, in the same transaction.
-- ---------------------------------------------------------------------------------------------
do $verify$
declare v_n integer;
begin
  -- exactly one overload of each, or PostgREST answers PGRST203 instead of saving a gift
  select count(*) into v_n from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='business_update_reward_v326';
  if v_n <> 1 then raise exception 'nestly_v520: % overloads of business_update_reward_v326 — PGRST203 waiting to happen', v_n using errcode='XX001'; end if;
  select count(*) into v_n from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='business_create_reward_v326';
  if v_n <> 1 then raise exception 'nestly_v520: % overloads of business_create_reward_v326', v_n using errcode='XX001'; end if;

  if position('entitlement_expiry_days=v_expiry_days' in
        pg_get_functiondef('public.business_update_reward_v326(uuid,uuid,text,integer,text,integer,text,boolean,timestamptz,boolean,text,integer,boolean)'::regprocedure)) = 0 then
    raise exception 'nestly_v520: the updater does not write the expiry' using errcode='XX001';
  end if;
  if position('entitlement_expiry_days' in
        pg_get_functiondef('public.business_create_reward_v326(uuid,uuid,text,integer,integer,text,text,timestamptz,text,integer)'::regprocedure)) = 0 then
    raise exception 'nestly_v520: the creator does not write the expiry' using errcode='XX001';
  end if;
  if position('entitlement_expiry_days' in
        pg_get_functiondef('app.reward_version_immutable_guard()'::regprocedure)) = 0 then
    raise exception 'nestly_v520: the guard still freezes the expiry on a published gift' using errcode='XX001';
  end if;
end
$verify$;

commit;
