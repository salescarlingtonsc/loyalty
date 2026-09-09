-- nestly_v874 — "N of 10 offers live" counts offers that are live NOW.
--
-- WHAT WAS LIVE, AND WHY IT IS WRONG. app.v462_live_offer_count answers the Promotions page's
-- quota card ("2 of 10 offers live"), its meter and "you can publish N more". It counted every
-- active offer with no date test at all, so an offer that ended last month, or one scheduled to
-- start next week, was "live". On Cubbly SPA the card read "2 of 10 offers live" directly under
-- the banner saying customers currently see no offers — the two were reading different
-- definitions of the same word. The customer-facing readers apply starts_at / ends_at; the
-- quota did not.
--
-- THE FIX. One definition of "live": active, started (or no start), and not yet ended (or no
-- end), evaluated at now(). The quota card, the meter and the publish-more line all read this
-- one function, so they move together.

begin;

create or replace function app.v462_live_offer_count(p_business uuid)
returns integer
language sql
stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
  select count(*)::integer
  from public.business_customer_content_v95 content
  where content.business_id = p_business
    and content.content_type = 'offer'
    and content.branch_id is null
    and content.active
    -- nestly_v874: live means live now, the same test the customer-facing readers apply.
    and (content.starts_at is null or content.starts_at <= now())
    and (content.ends_at is null or content.ends_at > now())
$function$;

-- ACL restated verbatim from prod (nestly_v874): owner-only (postgres); callers are server-side.
revoke all on function app.v462_live_offer_count(uuid) from public;

do $verify$
declare v_def text := pg_get_functiondef('app.v462_live_offer_count(uuid)'::regprocedure);
begin
  if position('content.ends_at > now()' in v_def) = 0 or position('content.starts_at <= now()' in v_def) = 0 then
    raise exception 'nestly_v874: live offer count still ignores dates' using errcode = 'XX001';
  end if;
end
$verify$;

commit;
