/* nestly_v810 — the ACL migration nestly_v804 deferred, and the credit-note history the console
   was guessing at.

   Two unrelated-looking items that are the same shape: a fact the server owns, and a client (a
   browser session, or a browser's ROLE) that was allowed to stand in for it.

   ==============================================================================================
   PART 1 — four public functions carry EXECUTE for `anon`, guarded only by their own body.
   ==============================================================================================
   nestly_v804's header states the position this migration now discharges:

     "public.staff_list_customers_v129 keeps its EXECUTE grant to anon exactly as it is — an anon
      caller is already refused by its own `auth.uid() is null` guard on the first statement, and
      re-grants belong to a migration that is about ACLs, not to this one."

   This is that migration, and v129 is not alone. Scanned read-only against production
   (gadpooereceldfpfxsod) on 2026-10-07 — every function in `public` that anon can EXECUTE and
   whose body refuses `auth.uid() is null`:

     select p.oid::regprocedure::text, has_function_privilege('anon',p.oid,'EXECUTE'), p.proacl
       from pg_proc p join pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public'
        and has_function_privilege('anon',p.oid,'EXECUTE')
        and p.prosrc ~* 'auth\.uid\(\)\s+is\s+null';

   Four rows, and only four:

     public.get_campaign_results(uuid)
       acl {postgres=X/postgres,authenticated=X/postgres,=X/postgres,anon=X/postgres,
            service_role=X/postgres}                         -- anon AND PUBLIC
     public.get_dashboard_summary(uuid,date,date,uuid)
       acl {anon=X/postgres,postgres=X/postgres,authenticated=X/postgres,
            service_role=X/postgres}                          -- anon
     public.get_reports_summary_v94_base(uuid,date,date,uuid)
       acl {postgres=X/postgres,anon=X/postgres,authenticated=X/postgres,service_role=X/postgres,
            =X/postgres}                                      -- anon AND PUBLIC
     public.staff_list_customers_v129(uuid,text,integer,integer,integer)
       acl {postgres=X/postgres,service_role=X/postgres,authenticated=X/postgres,=X/postgres,
            anon=X/postgres}                                  -- anon AND PUBLIC

   information_schema.routine_privileges agrees: PUBLIC is a distinct grantee row on three of the
   four, so `revoke ... from anon` alone would leave anon executing them through PUBLIC. Both are
   revoked here, and authenticated/service_role are restated so the revoke cannot silently take a
   legitimate caller's access with it.

   PROVEN READ-ONLY BEFORE REVOKING (the revoke must not be able to change what a caller can
   WRITE, only what a caller can reach). All four are provolatile='s' (STABLE — a volatile
   function is the only kind Postgres lets write) and none contains an INSERT/UPDATE/DELETE/MERGE
   token:

     select p.provolatile, p.prosrc ~* '\m(insert|update|delete|merge)\M' from pg_proc p ...
       -> ('s',false) x4

   And their guards, read from prosrc on production, are genuine refusals, not advisories:

     get_dashboard_summary          if auth.uid() is null or not app.has_perm(p_business,
                                      'view_sales') or not app.can_module(...) -> 42501
     get_reports_summary_v94_base   if auth.uid() is null or not app.has_perm(...) -> 42501
     staff_list_customers_v129      if auth.uid() is null or not app.can_module_read(
                                      p_business,'clients') -> 42501
     get_campaign_results           if auth.uid() is null or not (app.is_super_admin() or ...)
                                      -> 42501

   NOTE ON get_campaign_results — its guard is NOT the first statement. It first SELECTs the
   campaign row and raises 'campaign not found' (22023) when there is none, THEN checks the
   caller. Against an anon caller that is a campaign-id existence oracle: 22023 means "no such
   campaign", any other outcome means "this campaign exists". The guard is not weakened here (a
   refusal is never weakened by this migration); the grant that let an unauthenticated caller
   reach the oracle at all is what is removed.

   NO CALLER IS BROKEN. Scanned on production: no function in `public` or `app` calls any of the
   four except app.ci_visit_registry_v699 / app.v176_sales_window / app.v177_sales_window, none
   of which is anon-executable, and get_reports_summary_v94_base has zero callers at all. A
   SECURITY DEFINER caller executes as its own definer regardless of these grants.

   WHY THE ESTATE-WIDE SCAN IS FATAL ONLY ON PRODUCTION. The executed-SQL harness restores a
   `pg_dump --no-privileges` snapshot and then runs `grant all on all functions in schema public
   to anon` (scripts/db-tests/baseline-grants.sql, and its header explains why: without it the
   harness would be STRICTER than production, which is the dangerous direction for an isolation
   test). In that cluster every public function is anon-executable by construction — the scan
   returns 60+ names there and can say nothing about this defect class. The verify block below
   therefore runs the estate-wide scan as a fatal assertion where real ACL history exists and as
   a notice where it does not; the four per-function assertions are fatal everywhere and are what
   proves the migration itself replayed. The class-level claim is carried by the production scan
   quoted above, re-runnable at any time with the query at the top of this header.

   EXPOSURE STATEMENT ⚖️ — no data was exposed. Every one of the four refuses an anon session on
   its own, so the grant was defence-in-depth that had already been spent, not an open door: the
   only observable difference is get_campaign_results' existence oracle above, which leaks the
   existence of a campaign UUID an attacker would already have to possess. What changes is that
   the refusal is now enforced by the ACL as well as by the body, so a future edit to any of these
   bodies cannot re-open an anon path by accident.

   ==============================================================================================
   PART 2 — audit finding F121: the console derives credit-note history from ONE PAGE.
   ==============================================================================================
   public.platform_issue_credit_note_v147 requires the CUMULATIVE credited tax on an invoice —
   this credit plus every non-reversed credit note already issued against it — to satisfy

     v_credited_tax + p_tax_cents = round((v_credited_subtotal + p_subtotal_cents)
                                          * invoice.tax_cents / invoice.subtotal_cents)

   Because round(a)+round(b) is not always round(a+b), a second partial credit whose tax was
   proportioned from its own subtotal in isolation could be a cent out and be refused. The client
   arithmetic was corrected in creditNoteCumulativeTaxCents() — but its INPUT, the already-
   credited totals, was reconstructed in the browser from the sibling documents that happened to
   be loaded in the books view, which is:

     * a PAGE. platform_get_accounting_books_v147 takes p_limit and returns the newest documents
       by (issue_date desc, document_number desc). An older credit note that fell off the page is
       invisible to the browser and the running total silently starts from a smaller number.
     * a DIFFERENT definition of "reversed". The browser filters on a `reversed` field of the row;
       the server's own subquery excludes a credit note only when a `journal_voucher` exists whose
       original_document is that credit note. Two readers, two rules, one of them not the writer's.

   So the client could satisfy its own idea of the cumulative total and still be refused by the
   server's. This adds the small, STABLE, super-admin read the console should have been asking —
   public.platform_invoice_credit_note_totals_v810(uuid) — whose credited-totals subquery is the
   SAME expression platform_issue_credit_note_v147 checks against, so agreement is structural
   rather than coincidental. app/platform-console.js prefers it and falls back to the loaded
   window only if the read fails, so a transport failure degrades to today's behaviour instead of
   blocking the credit note.

   The read adds no capability: it is guarded exactly like every sibling platform_* function
   (auth.uid() is not null AND app.is_super_admin(), 42501), returns only figures the same
   super-admin already sees on the books screen, and writes nothing.

   Rollback suite: db/tests/v810_acl_and_credit_note_history.sql
*/
begin;

-- ==============================================================================================
-- PART 1 — the ACLs. Revoke from BOTH anon and PUBLIC; restate the legitimate grants.
-- ==============================================================================================
revoke all on function public.get_campaign_results(uuid) from public, anon;
revoke all on function public.get_dashboard_summary(uuid,date,date,uuid) from public, anon;
revoke all on function public.get_reports_summary_v94_base(uuid,date,date,uuid) from public, anon;
revoke all on function public.staff_list_customers_v129(uuid,text,integer,integer,integer) from public, anon;

grant execute on function public.get_campaign_results(uuid) to authenticated, service_role;
grant execute on function public.get_dashboard_summary(uuid,date,date,uuid) to authenticated, service_role;
grant execute on function public.get_reports_summary_v94_base(uuid,date,date,uuid) to authenticated, service_role;
grant execute on function public.staff_list_customers_v129(uuid,text,integer,integer,integer) to authenticated, service_role;

-- ==============================================================================================
-- PART 2 — the credit-note history the console needs, from the authority that enforces it.
-- ==============================================================================================
create or replace function public.platform_invoice_credit_note_totals_v810(p_invoice uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_invoice public.platform_financial_documents_v147%rowtype;
  v_credited_subtotal bigint;
  v_credited_tax bigint;
  v_credited_total bigint;
begin
  -- Guarded exactly as every sibling public.platform_*_v147 function is.
  if auth.uid() is null or not app.is_super_admin() then
    raise exception 'super-admin access is required' using errcode='42501';
  end if;

  select * into v_invoice
    from public.platform_financial_documents_v147
   where id = p_invoice and document_type = 'invoice';
  if not found then
    raise exception 'invoice was not found' using errcode='22023';
  end if;

  -- The SAME expression platform_issue_credit_note_v147 computes v_credited_subtotal /
  -- v_credited_tax with: credit notes against this invoice, excluding any that a journal_voucher
  -- has reversed. Copied deliberately rather than approximated — the point of this read is that
  -- the console asks the writer's own question.
  select coalesce(sum(document.subtotal_cents),0),
         coalesce(sum(document.tax_cents),0),
         coalesce(sum(document.total_cents),0)
    into v_credited_subtotal, v_credited_tax, v_credited_total
    from public.platform_financial_documents_v147 document
   where document.original_document = p_invoice
     and document.document_type = 'credit_note'
     and not exists (select 1
                       from public.platform_financial_documents_v147 reversal
                      where reversal.original_document = document.id
                        and reversal.document_type = 'journal_voucher');

  return jsonb_build_object(
    'invoice_id', v_invoice.id,
    'invoice_subtotal_cents', v_invoice.subtotal_cents,
    'invoice_tax_cents', v_invoice.tax_cents,
    'credited_subtotal_cents', v_credited_subtotal,
    'credited_tax_cents', v_credited_tax,
    'credited_total_cents', v_credited_total);
end
$$;

revoke all on function public.platform_invoice_credit_note_totals_v810(uuid) from public, anon, authenticated;
grant execute on function public.platform_invoice_credit_note_totals_v810(uuid) to authenticated;

-- ==============================================================================================
-- In-transaction verification. Nothing below writes; a failure aborts the migration.
-- ==============================================================================================
do $verify$
declare
  v_sig text;
  v_oid oid;
  v_missing text := '';
begin
  -- 1. anon (and PUBLIC) can no longer reach any of the four.
  foreach v_sig in array array[
    'public.get_campaign_results(uuid)',
    'public.get_dashboard_summary(uuid,date,date,uuid)',
    'public.get_reports_summary_v94_base(uuid,date,date,uuid)',
    'public.staff_list_customers_v129(uuid,text,integer,integer,integer)'
  ] loop
    v_oid := v_sig::regprocedure::oid;
    if has_function_privilege('anon', v_oid, 'EXECUTE') then
      raise exception 'v810: anon still holds EXECUTE on %', v_sig;
    end if;
    if not has_function_privilege('authenticated', v_oid, 'EXECUTE') then
      raise exception 'v810: the revoke took authenticated EXECUTE with it on %', v_sig;
    end if;
    if not has_function_privilege('service_role', v_oid, 'EXECUTE') then
      raise exception 'v810: the revoke took service_role EXECUTE with it on %', v_sig;
    end if;
  end loop;

  -- 2. No public function anywhere is left in the anomalous shape this migration exists to
  --    close. This is a fatal gate against a production-shaped ACL set, and a notice against
  --    the executed-SQL harness — NOT a softened assertion, but the only honest one there.
  --    scripts/db-tests/baseline-grants.sql deliberately runs `grant all on all functions in
  --    schema public to anon` after restoring a pg_dump --no-privileges snapshot, because the
  --    snapshot discards the accumulated effect of every REVOKE ever run against production.
  --    In that cluster EVERY public function is anon-executable by construction and the scan
  --    can say nothing about this defect class. The sentinel is a function whose own migration
  --    revoked anon and whose revoke therefore survives only where real ACL history does.
  if has_function_privilege('anon',
       'public.platform_get_accounting_books_v147(date,date,integer)'::regprocedure, 'EXECUTE') then
    raise notice
      'v810: skipping the estate-wide anon scan — this cluster blanket-grants public functions '
      'to anon (see scripts/db-tests/baseline-grants.sql); the per-function assertions above '
      'still hold and are what proves this migration replayed correctly';
  else
    select string_agg(p.oid::regprocedure::text, ', ')
      into v_missing
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and has_function_privilege('anon', p.oid, 'EXECUTE')
       and p.prosrc ~* 'auth\.uid\(\)\s+is\s+null';
    if v_missing is not null then
      raise exception 'v810: anon still executes session-guarded function(s): %', v_missing;
    end if;
  end if;

  -- 3. The new read exists, is STABLE, is SECURITY DEFINER, pins its search_path, and is not
  --    reachable by anon or PUBLIC.
  v_oid := 'public.platform_invoice_credit_note_totals_v810(uuid)'::regprocedure::oid;
  if (select provolatile from pg_proc where oid = v_oid) <> 's' then
    raise exception 'v810: the credit-note totals read must be STABLE';
  end if;
  if not (select prosecdef from pg_proc where oid = v_oid) then
    raise exception 'v810: the credit-note totals read must be SECURITY DEFINER';
  end if;
  if not exists (select 1 from pg_proc
                  where oid = v_oid
                    and proconfig @> array['search_path=pg_catalog, public, app, pg_temp']) then
    raise exception 'v810: the credit-note totals read did not pin its search_path (%)',
      (select proconfig::text from pg_proc where oid = v_oid);
  end if;
  if has_function_privilege('anon', v_oid, 'EXECUTE') then
    raise exception 'v810: anon must not execute the credit-note totals read';
  end if;
  if not has_function_privilege('authenticated', v_oid, 'EXECUTE') then
    raise exception 'v810: authenticated must execute the credit-note totals read';
  end if;
  if not (select prosrc from pg_proc where oid = v_oid) ~ 'app\.is_super_admin\(\)' then
    raise exception 'v810: the credit-note totals read lost its super-admin guard';
  end if;
end
$verify$;

commit;
