-- nestly_v521 — redemption being off is a DECISION, never an accident. Plan item B, completed.
--
-- WHAT nestly_v514 ALREADY DID, and what it left. v514 found the owner's photo-1 dead QR: the
-- redemption gate is `coalesce((select redemption_enabled from business_customer_capabilities_v89
-- where business_id = ...), false)`, so a MISSING ROW silently meant OFF. Only 3 of 14 businesses
-- had the row, which is why "Show QR at counter" worked on Cubbly SPA and raised 42501 everywhere
-- else. v514 installed an AFTER INSERT trigger seeding the row ENABLED at business birth, and
-- backfilled every business that had none.
--
-- Measured again today, before writing this: 0 businesses have no capability row, and exactly one
-- (Bistro 999) records an explicit false, which v514 deliberately did not overwrite because an
-- explicit false may be a real decision. So the hole v514 aimed at is closed in the data.
--
-- WHAT WAS STILL OPEN, and it is not the readers. The original plan said "flip the gate from
-- coalesce(...,false) to treating a missing row as enabled". Ten functions read this capability
-- and their join shapes differ — most LEFT JOIN the table and coalesce the NULL, one runs a
-- scalar subselect — so flipping ten bodies is ten chances to change a condition in a way the
-- reader beside it does not share. It is also aimed at a case that can no longer occur:
--
--   * public.business_customer_capabilities_v89 has RLS ON and ZERO policies, and no grants to
--     `authenticated`. No customer and no business user can insert, update or delete a row
--     through the API at all.
--   * No function anywhere deletes from it (checked with pg_get_functiondef across public+app).
--   * The v514 trigger is AFTER INSERT ... FOR EACH ROW on public.businesses, so it fires for
--     every insert path including raw SQL, not just the onboarding RPC.
--
-- A row therefore cannot go missing after birth. What COULD still happen is the second accident,
-- and it is one line: the column's DEFAULT is `false`. Any future insert that names booking and
-- appointment changes but forgets redemption gets a business whose customers silently cannot
-- redeem — the exact failure v514 fixed, arriving through a different door. That default is what
-- this migration changes.
--
--   redemption_enabled  NOT NULL DEFAULT false  ->  NOT NULL DEFAULT true
--
-- Nothing stored moves. NOT NULL is unchanged, so the column can never be NULL and "unspecified"
-- is not a state a reader has to interpret. Bistro 999's explicit false is untouched — a default
-- applies only to an insert that omits the column, and theirs is recorded.
--
-- Booking and appointment changes KEEP their false default. Those surfaces need configuring
-- before they are safe to expose, and switching one on by default would be a different, unasked
-- change. This migration is about redemption only.
--
-- AND THE STANDING GUARD (plan item D). app.customer_redemption_reachable_v521() is the divergence
-- probe as a callable function: for every business it reports what the business surface believes
-- and what the customer surface believes, so the two can be compared in one query rather than
-- reconstructed by hand each time they are suspected of disagreeing. db/tests/v521_*.sql calls it
-- and fails if any business disagrees with itself.

begin;

-- ---------------------------------------------------------------------------------------------
-- B — an insert that says nothing about redemption now means ON
-- ---------------------------------------------------------------------------------------------
alter table public.business_customer_capabilities_v89
  alter column redemption_enabled set default true;

comment on column public.business_customer_capabilities_v89.redemption_enabled is
  'nestly_v521: defaults TRUE. A customer holding a reward they earned should be able to show its QR without an owner first finding a switch; redemption being off must be a recorded decision, not the residue of an insert that forgot to mention it. Booking and appointment changes keep their false default — those surfaces need configuring first.';

-- ---------------------------------------------------------------------------------------------
-- D — the divergence probe, as an object rather than a query someone has to remember
--
-- One row per business. `business_says` is what the workspace reads (the v314 spine); the two
-- customer columns are the other half of the condition every customer surface applies. v514 made
-- loyalty_programs.active follow the spine inside set_programmes_v314, so business_says and
-- customer_programme_live must now agree for every business, forever. Anything else is the blind
-- spot returning, and this function is how it gets noticed in one query instead of one complaint.
-- ---------------------------------------------------------------------------------------------
create or replace function app.customer_redemption_reachable_v521()
returns table(
  business_id uuid,
  business_name text,
  business_says boolean,          -- the workspace's answer: is a programme running?
  customer_programme_live boolean, -- the customer's half: loyalty_programs.active
  customer_can_redeem boolean,     -- the capability the QR path gates on
  agrees boolean                   -- the invariant: the two surfaces answer the same question alike
)
language sql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
  select b.id,
         b.name,
         coalesce(spine.running, false),
         coalesce(lp.active, false),
         coalesce(cap.redemption_enabled, false),
         coalesce(spine.running, false) is not distinct from coalesce(lp.active, false)
    from public.businesses b
    left join public.loyalty_programs lp on lp.business_id = b.id
    left join public.business_customer_capabilities_v89 cap on cap.business_id = b.id
    cross join lateral (
      select bool_or(sp.active) filter (where sp.kind in ('points','stamps')) as running
        from public.business_programmes sp
       where sp.business_id = b.id
    ) spine
$function$;

comment on function app.customer_redemption_reachable_v521() is
  'nestly_v521 (plan item D): the divergence probe that exposed the customer/business blind spot, kept as an object. agrees=false on any row means the workspace and the customer app disagree about whether a programme is running.';

revoke all on function app.customer_redemption_reachable_v521() from public;
grant execute on function app.customer_redemption_reachable_v521() to service_role;

-- ---------------------------------------------------------------------------------------------
-- Prove it took, in the same transaction.
-- ---------------------------------------------------------------------------------------------
do $verify$
declare v_default text; v_n integer;
begin
  select column_default into v_default from information_schema.columns
   where table_schema='public' and table_name='business_customer_capabilities_v89'
     and column_name='redemption_enabled';
  if v_default is distinct from 'true' then
    raise exception 'nestly_v521: redemption_enabled default is % , expected true', coalesce(v_default,'null')
      using errcode='XX001';
  end if;

  -- The invariant v514 installed must still hold at the moment this lands.
  select count(*) into v_n from app.customer_redemption_reachable_v521() r where not r.agrees;
  if v_n <> 0 then
    raise exception 'nestly_v521: % businesses disagree with themselves about whether a programme is running', v_n
      using errcode='XX001';
  end if;
end
$verify$;

commit;
