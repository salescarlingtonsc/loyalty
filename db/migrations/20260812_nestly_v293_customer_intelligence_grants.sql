-- NESTLY v293: restore Customer Intelligence and verified-relationship sync —
-- (Applied to production 2026-08-12 as the emergency-numbered v284; lands in
--  the repo as v293 because parallel work claimed v284-v292 on main first.)
-- the last four frontend-called RPCs that were deployed without their grants.
--
-- GAP (2026-08-12 product audit, high severity): the business Reports →
-- Customer Intelligence page always error'd its customer-records panel, its
-- Load more and "Export customers CSV" buttons could never work, and the
-- customer wallet's verified-relationship auto-link silently returned
-- backend_not_applied. The audit concluded the backends were "never built".
--
-- THEY WERE BUILT. All four functions exist in production, complete and
-- self-gating (get_customer_intelligence_v83 alone is ~19KB with snapshot
-- pagination, forecast thresholds and methodology payloads; the export pair
-- has expiry + requested_by binding; v81 sync is rate-limited and audited).
-- EXECUTE was granted only to service_role, so PostgREST hid them from the
-- authenticated role and every call returned PGRST202. This is the same
-- systemic missing-GRANT defect v283 fixed for the two customer-claim RPCs —
-- together those six functions are the audit's entire "dead RPC" list.
--
-- A full sweep of every public function with a service_role-only ACL (~95)
-- confirmed the remaining ones are internal_*/service_* machinery, webhook
-- appliers, deprecated *_base versions, purge jobs, and the deliberately
-- edge-gateway-only public paths (join_program, get_booking_availability, …).
-- NOTHING else the frontend calls is affected; nothing else is granted here.
--
-- WHY THIS IS SAFE. Each function authorizes itself:
--   get_customer_intelligence_v83 / create_customer_intelligence_export_v83 /
--   get_customer_intelligence_export_page_v83 require
--   app.has_perm(business,'view_finance') + app.can_see_branch (the same gate
--   as get_revenue_truth_v106), and export pages additionally bind to
--   requested_by = auth.uid() with a 24h expiry.
--   customer_sync_verified_relationships_v81 derives the caller's OWN
--   confirmed email/phone from auth.users, links only a single unclaimed
--   candidate per business, takes the same advisory locks as the exact-claim
--   routes, is rate-limited (20/15min) and idempotent, and audits every link.
-- anon receives nothing; these are post-authentication surfaces.
--
-- Applied to production 2026-08-12 after the rolled-back acceptance suite
-- (db/tests/v293_*) exercised the real functions end to end against prod.

begin;

grant execute on function public.get_customer_intelligence_v83(uuid, uuid, date, date, integer, timestamptz, timestamptz, uuid)
  to authenticated;
grant execute on function public.create_customer_intelligence_export_v83(uuid, uuid, date, date)
  to authenticated;
grant execute on function public.get_customer_intelligence_export_page_v83(uuid, integer, integer)
  to authenticated;
grant execute on function public.customer_sync_verified_relationships_v81(text)
  to authenticated;

commit;
