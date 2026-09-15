-- nestly_v966 — a firm that has SPENT its voucher can be given another one.
--
-- FOUND BY ADVERSARIAL PROBE, after v965 closed the "a Stripe promo is never consumed" hole.
-- With consumption finally working for card-billed firms, the probe asked the obvious next
-- question — can this cafe be given a SECOND voucher? — and the answer was no. Not "not yet":
-- never, for the life of the firm, with no way for the console to fix it:
--
--   business_redeem_promo_code_v961     -> the firm's row has consumed_at  -> promo_already_used
--   platform_remove_promo_redemption_v961 -> refuses a consumed row        -> promo_already_used
--
-- Both guards are v961's own and both are individually right: you do not re-spend one code, and
-- you do not delete the history of a discount that was actually given. Together they are a trap.
-- Before v965 it was hidden — Stripe firms never consumed, so they stalled on promo_already_held
-- instead, which is the same dead end wearing a different error.
--
-- This is not what "first payment only" meant. That ruling is about the DURATION of one discount
-- (it comes off one invoice, not every invoice). It was never a lifetime cap of one voucher per
-- business. Vouchers are a recurring instrument: the cafe that got 20% off in January is exactly
-- the cafe you want to send another code to in December.
--
-- WHY A NEW VERB RATHER THAN LOOSENING THE GUARD. Making any consumed promo free the slot
-- automatically would mean a firm silently becomes eligible again the moment its discounted
-- invoice is paid, with nobody deciding that. Issuance is the platform's call everywhere else in
-- v961 (the console mints codes; the merchant only redeems), so releasing is the platform's call
-- too. Default behaviour is unchanged — one voucher — until a super admin says otherwise, with a
-- reason, on the record.
--
-- WHY NOT REUSE "remove". Remove means the redemption should never have counted: it hands the
-- allowance back to the code (redeemed_count - 1) and is refused once the discount is real.
-- Release means the opposite — it DID count, the firm got the money off, and the record stays
-- exactly as it is. Folding the two into one button would corrupt every redeemed_count.

begin;

alter table public.platform_promo_redemptions_v961
  add column if not exists released_at timestamptz,
  add column if not exists released_by uuid references auth.users(id),
  add column if not exists released_reason text;

comment on column public.platform_promo_redemptions_v961.released_at is
  'nestly_v966: set when a super admin closes out a SPENT redemption so the firm may hold a new code. The row stays, redeemed_count stays, history stays; it simply stops being the firm current promo.';

/* nestly_v966: "one live redemption per firm" is also enforced by a partial unique index, and it
   keys on removed_at alone. Without this the release would be cosmetic: the reader would stop
   seeing the spent row, and the insert of the new one would still die on a raw 23505. */
drop index if exists public.platform_promo_redemptions_one_live_v961;
create unique index platform_promo_redemptions_one_live_v961
  on public.platform_promo_redemptions_v961 (business_id)
  where removed_at is null and released_at is null;

/* platform_promo_redemptions_once_v961 (promo_id, business_id) is deliberately NOT widened: one
   voucher code is still one shot per firm, forever. Release frees the firm for a DIFFERENT code.
   The redeem RPC gains an explicit check below so that rule states itself instead of arriving as
   a unique-violation. */

/* nestly_v966: the four readers that mean "the promo this firm is holding right now". The other
   five call sites already add "consumed_at is null", so a released row is invisible to them
   already. Patched by extraction rather than restatement so nothing else in these bodies moves. */
do $patch$
declare
  v_def text;
  v_old text;
  v_new text;
  v_hits integer;
  v_target text;
  v_targets text[] := array[
    'public.business_get_promo_state_v961',
    'public.business_redeem_promo_code_v961',
    'public.platform_remove_promo_redemption_v961',
    'public.platform_list_promo_codes_v961',
    'public.business_redeem_promo_code_v961'
  ];
  v_olds text[] := array[
    'where business_id = p_business and removed_at is null;',
    'where business_id = p_business and removed_at is null for update;',
    'where business_id = p_business and removed_at is null for update;',
    'and r.removed_at is null),',
    E'raise exception \'promo_code_not_found\' using errcode = \'22023\';'
  ];
  v_news text[] := array[
    'where business_id = p_business and removed_at is null and released_at is null;',
    'where business_id = p_business and removed_at is null and released_at is null for update;',
    'where business_id = p_business and removed_at is null and released_at is null for update;',
    'and r.removed_at is null and r.released_at is null),',
    E'raise exception \'promo_code_not_found\' using errcode = \'22023\';\n'
    || E'  end if;\n'
    || E'  /* nestly_v966: a released firm has no current row, so the "this firm already used this\n'
    || E'     code" case no longer meets the guard above. Ask it directly rather than letting the\n'
    || E'     unique index answer with a 23505. */\n'
    || E'  if exists (\n'
    || E'    select 1 from public.platform_promo_redemptions_v961 prior\n'
    || E'     where prior.business_id = p_business and prior.promo_id = v_promo.id\n'
    || E'       and prior.removed_at is null\n'
    || E'  ) then\n'
    || E'    raise exception \'promo_already_used\' using errcode = \'22023\';'
  ];
  i integer;
begin
  for i in 1 .. array_length(v_targets, 1) loop
    v_target := v_targets[i];
    v_old := v_olds[i];
    v_new := v_news[i];
    select pg_get_functiondef(p.oid) into v_def
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = split_part(v_target, '.', 1)
       and p.proname = split_part(v_target, '.', 2);
    if v_def is null then
      raise exception 'v966: % does not exist', v_target;
    end if;
    v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
    if v_hits <> 1 then
      raise exception 'v966: expected exactly 1 occurrence of the current-promo predicate in %, found %',
        v_target, v_hits;
    end if;
    execute replace(v_def, v_old, v_new);
  end loop;
end
$patch$;

create or replace function public.platform_release_promo_redemption_v966(
  p_business uuid, p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_row public.platform_promo_redemptions_v961%rowtype;
begin
  if v_actor is null or not app.is_super_admin() then
    raise exception 'super_admin_required' using errcode = '42501';
  end if;
  if length(btrim(coalesce(p_reason, ''))) not between 3 and 1000 then
    raise exception 'promo_reason_required' using errcode = '22023';
  end if;
  select * into v_row from public.platform_promo_redemptions_v961
   where business_id = p_business and removed_at is null and released_at is null for update;
  if v_row.id is null then
    raise exception 'no_promo_to_release' using errcode = '42704';
  end if;
  /* The discount has not actually been given yet, so there is nothing to close out. Removing it
     is the right verb for that, and it hands the allowance back to the code. */
  if v_row.consumed_at is null then
    raise exception 'promo_not_used_yet' using errcode = '22023';
  end if;

  update public.platform_promo_redemptions_v961
     set released_at = now(), released_by = v_actor, released_reason = btrim(p_reason)
   where id = v_row.id;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'promo_redemption_released', 'platform_promo_redemptions_v961',
    v_row.id, jsonb_build_object('source', 'platform_console_v966', 'reason', btrim(p_reason),
      'promo_id', v_row.promo_id, 'consumed_at', v_row.consumed_at,
      'consumed_discount_cents', v_row.consumed_discount_cents));

  return jsonb_build_object('status', 'ok', 'business_id', p_business,
    'released_redemption_id', v_row.id);
end
$$;

comment on function public.platform_release_promo_redemption_v966(uuid, text) is
  'nestly_v966: super-admin closes out a SPENT promo redemption so the firm can be given a new code. The row, its history and the code redeemed_count are all left alone — unlike remove, which is for a redemption that should never have counted. Refuses one that has not been consumed yet.';

revoke all on function public.platform_release_promo_redemption_v966(uuid, text) from public, anon;
grant execute on function public.platform_release_promo_redemption_v966(uuid, text) to authenticated, service_role;

commit;
