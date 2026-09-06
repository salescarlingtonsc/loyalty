/* nestly_v696 — the marketing choice can be saved by a customer who has no preferences row yet,
   instead of failing 42501 forever behind a generic "please try again".

   Audit finding F040 (P2, confirmed read-only against production gadpooereceldfpfxsod on
   2026-09-06 with a rolled-back probe run as the real principal).

   THE DEFECT — a reader that copes with a missing row, and a writer that does not.
     public.customer_get_platform_marketing_preference ends with

       coalesce((select ... from public.customer_registration_preferences p
                  where p.auth_user_id = v_actor),
                jsonb_build_object('opted_in', false, ...))

     so a customer with NO row is told "opted_in: false" and the Profile page renders a live
     checkbox and a Save button. public.customer_set_platform_marketing_preference then did a
     plain UPDATE of that same table and raised 42501 when it matched nothing.

     Only public.customer_register_verified_phone inserts that row. A customer identity created
     by public.customer_create_identity — the QR-join / claim path, which never phone-registers —
     therefore has an identity, a verified business link, a wallet, and no preferences row. For
     that customer the tick could never be saved in either direction: they could not opt in, and
     (had they been opted in through another path) they could not withdraw. The UI showed
     "could not be saved. Please try again." — advice that could never work.

     Production, read-only, 2026-09-02: 1 of 11 active customer_identities is in exactly this
     shape. Live proof, rolled back, run as the real `authenticated` principal:

       preferences rows for a fresh wallet_start identity            -> 0
       save marketing choice with NO preferences row
         -> sqlstate=42501 "customer marketing preference is unavailable"
       positive control: the same call WITH a preferences row
         -> {"outcome": "updated", "opted_in": true}

     One variable changed between the refusal and the success: whether the row happened to exist.

   THE FIX — the write becomes an upsert, at the writer.
     A missing row is the ABSENCE of a recorded decision, not a recorded refusal — the reader has
     always said so by defaulting it to false. So the first save creates the row carrying the
     customer's decision, and every later save updates it. This is the same shape the sibling
     communication-preference writers already use: public.customer_set_communication_preference_v263
     and public.customer_set_all_communications_v263 both INSERT ... ON CONFLICT DO UPDATE, and
     both treat "no row" as the default-on state rather than as an error. It also matches the
     owner's consent ruling (2026-08-09): one tick covers every channel, and the default is on
     unless the customer has said otherwise — a model that cannot work if the customer's first
     recorded "otherwise" is refused.

   THE REFUSAL THAT STAYS. The upsert's DO UPDATE is still predicated on the row belonging to
   this caller (auth_user_id = auth.uid()), and a conflicting row that does not is still refused
   with 42501 and a message that now names the reason. A refusal is never turned into a silent
   success: `found` is still checked and still raises.

   EVERY EVIDENCE GUARANTEE IS PRESERVED, because it was never in this function.
     * app.v92_prepare_platform_marketing_preference (BEFORE INSERT OR UPDATE OF
       platform_marketing_opted_in) stamps marketing_scope_version and marketing_privacy_sha256,
       or nulls them on an opt-out. It is an INSERT trigger too, so the created row is stamped
       exactly like an updated one.
     * app.v92_capture_platform_marketing_consent (AFTER INSERT OR UPDATE OF the same column)
       appends the append-only consent event, verifying the pinned privacy document
       ('2026-08-10', sha 960434af…) and rejecting any source other than 'signup' or
       'customer_profile'. On INSERT its "nothing changed" short-circuit does not apply, so a
       first-time save records an event exactly as a change does.
     * The idempotency contract is untouched: the same key replayed returns the stored answer,
       and the same key with a different answer is still 23505.

   NOT CHANGED, deliberately:
     * public.customer_get_platform_marketing_preference. Its coalesce fallback is correct and
       is what makes "no row" mean "not opted in" for every reader.
     * public.customer_create_identity. Seeding a preferences row at identity creation would work
       too, but it repairs only identities created AFTER the change and leaves the existing ones —
       including the live one — still unable to save. Fixing the writer fixes every customer, past
       and future, which is the defect class rather than the tenant.
     * The v263 communication preferences. They already upsert.
     * No backfill. Nothing is written for anybody: the row appears when, and only when, a
       customer makes a choice. Fabricating a consent row for a customer who never expressed one
       is precisely what must not happen.

   Rollback suite: db/tests/v696_marketing_preference_upsert.sql */
begin;

create or replace function public.customer_set_platform_marketing_preference(
  p_opted_in boolean,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_actor uuid := auth.uid();
  v_identity uuid;
  v_existing public.customer_platform_marketing_consent_events%rowtype;
begin
  if v_actor is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;
  if p_opted_in is null
     or p_idempotency_key is null
     or length(btrim(p_idempotency_key)) < 8 then
    raise exception 'invalid platform marketing preference request' using errcode = '22023';
  end if;
  p_idempotency_key := btrim(p_idempotency_key);
  v_identity := app.v31_current_identity();
  perform pg_advisory_xact_lock(hashtextextended(
    'v92:platform-marketing:' || v_identity::text || ':' || p_idempotency_key, 0
  ));
  select * into v_existing
    from public.customer_platform_marketing_consent_events e
   where e.identity_id = v_identity and e.idempotency_key = p_idempotency_key
   for update;
  if found then
    if v_existing.opted_in is distinct from p_opted_in then
      raise exception 'idempotency key was already used for a different marketing preference'
        using errcode = '23505';
    end if;
    return jsonb_build_object('outcome', 'updated', 'opted_in', v_existing.opted_in);
  end if;
  perform set_config('app.v92_marketing_source', 'customer_profile', true);
  perform set_config('app.v92_marketing_idempotency_key', p_idempotency_key, true);

  /* nestly_v696 (audit F040): this was a bare UPDATE, and a customer whose identity was created
     by the QR-join path has no row to update — only customer_register_verified_phone ever
     inserted one. The reader already treats a missing row as "not opted in", so the first save
     legitimately CREATES the record of the customer's decision. Both v92 triggers fire on INSERT
     as well as UPDATE, so the created row is scope-stamped and its consent event is appended
     exactly as an edit's would be. */
  insert into public.customer_registration_preferences as pref (
    identity_id, auth_user_id, platform_marketing_opted_in, updated_at
  ) values (
    v_identity, v_actor, p_opted_in, now()
  )
  on conflict (identity_id) do update
     set platform_marketing_opted_in = excluded.platform_marketing_opted_in,
         updated_at = excluded.updated_at
   where pref.auth_user_id = v_actor;

  /* Still a refusal, never a silent success: a preferences row that belongs to somebody else
     leaves the upsert matching nothing, and this raises rather than reporting 'updated'. */
  if not found then
    raise exception 'this marketing preference belongs to another sign-in' using errcode = '42501';
  end if;

  perform set_config('app.v92_marketing_source', '', true);
  perform set_config('app.v92_marketing_idempotency_key', '', true);
  return jsonb_build_object('outcome', 'updated', 'opted_in', p_opted_in);
end;
$function$;

/* ACL restated verbatim from production
   ({postgres=X/postgres, service_role=X/postgres, authenticated=X/postgres}). */
revoke all on function public.customer_set_platform_marketing_preference(boolean, text) from public, anon;
grant execute on function public.customer_set_platform_marketing_preference(boolean, text) to authenticated, service_role;

comment on function public.customer_set_platform_marketing_preference(boolean, text) is
  'nestly_v92/v696 records the customer''s platform marketing choice. v696: the write is an upsert, because a customer whose identity came from the QR-join path has no customer_registration_preferences row and could therefore never save the choice in either direction (42501, audit F040). A conflicting row owned by another sign-in is still refused, and the v92 scope-stamp and append-only consent event fire on the created row exactly as on an edited one.';

-- =============================================================================================
-- Prove the change took, in the same transaction that made it.
-- =============================================================================================
do $verify$
declare
  v_def text := pg_get_functiondef(
    'public.customer_set_platform_marketing_preference(boolean,text)'::regprocedure);
begin
  if position('insert into public.customer_registration_preferences' in v_def) = 0
     or position('on conflict (identity_id) do update' in v_def) = 0 then
    raise exception 'nestly_v696: the marketing-choice write is not an upsert'
      using errcode = 'XX001';
  end if;
  /* The row must still be the caller's own. */
  if position('where pref.auth_user_id = v_actor' in v_def) = 0 then
    raise exception 'nestly_v696: the upsert no longer restricts itself to the caller''s own row'
      using errcode = 'XX001';
  end if;
  /* A refusal must still be a refusal. */
  if position('if not found then' in v_def) = 0
     or position('errcode = ''42501''' in v_def) = 0 then
    raise exception 'nestly_v696: a write that matched nothing no longer raises'
      using errcode = 'XX001';
  end if;
  if position('''app.v92_marketing_source'', ''customer_profile''' in v_def) = 0 then
    raise exception 'nestly_v696: the consent evidence source is no longer declared'
      using errcode = 'XX001';
  end if;
  /* The two v92 triggers are what make an INSERT safe here. If either stops covering INSERT,
     a created row would carry no scope stamp or no consent event. */
  if not exists (
    select 1 from pg_trigger t
     where t.tgrelid = 'public.customer_registration_preferences'::regclass
       and not t.tgisinternal
       and t.tgname = 'customer_registration_preferences_v92_prepare'
       and pg_get_triggerdef(t.oid) like '%BEFORE INSERT OR UPDATE OF platform_marketing_opted_in%'
  ) then
    raise exception 'nestly_v696: the scope-stamp trigger no longer covers INSERT'
      using errcode = 'XX001';
  end if;
  if not exists (
    select 1 from pg_trigger t
     where t.tgrelid = 'public.customer_registration_preferences'::regclass
       and not t.tgisinternal
       and t.tgname = 'customer_registration_preferences_v92_evidence'
       and pg_get_triggerdef(t.oid) like '%AFTER INSERT OR UPDATE OF platform_marketing_opted_in%'
  ) then
    raise exception 'nestly_v696: the consent-evidence trigger no longer covers INSERT'
      using errcode = 'XX001';
  end if;
  if exists (select 1 from information_schema.routine_privileges
              where routine_schema = 'public'
                and routine_name = 'customer_set_platform_marketing_preference'
                and grantee in ('anon','PUBLIC')) then
    raise exception 'nestly_v696: the marketing-choice RPC became anonymously reachable'
      using errcode = 'XX001';
  end if;
end
$verify$;

commit;
