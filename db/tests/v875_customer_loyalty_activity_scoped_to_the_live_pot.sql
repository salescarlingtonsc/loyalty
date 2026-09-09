-- nestly_v875 rollback suite — the customer's "Loyalty activity" reads the pot their balance reads.
--
-- Run inside a transaction against production and ROLLED BACK. customer_get_loyalty_details
-- needs the customer's own verified session, which no suite can forge, so the ledger arm's
-- predicate is exercised directly against Cubbly SPA customer 268cb96d — the customer whose feed
-- carried eight ±75,877 pot-transfer rows and a retired stamps pot beside a points balance.

\set ON_ERROR_STOP on

begin;

do $suite$
declare
  cb   constant uuid := '8492e8d6-8888-4383-ada0-7e1ed69f0caa';
  cust constant uuid := '268cb96d-e6cc-4217-99f6-884b006ba7a3';
  def text; live uuid; scope text; total_rows integer; visible_rows integer; transfer_rows integer; other_pot_rows integer; n integer := 0;
begin
  def := pg_get_functiondef('public.customer_get_loyalty_details(text,jsonb)'::regprocedure);
  n := n + 1;
  if position('ledger.programme_id is not distinct from v_live' in def) = 0 then raise exception 'G% failed: ledger arm is not pot-scoped', n; end if;
  n := n + 1;
  if position('batch.programme_id is not distinct from v_live' in def) = 0 then raise exception 'G% failed: expiry subqueries are not pot-scoped', n; end if;
  n := n + 1;
  if position('programme pot transfer %' in def) = 0 then raise exception 'G% failed: pot-transfer bookkeeping still shows as activity', n; end if;

  live := app.live_balance_programme_v381(cb);
  scope := app.programme_balance_scope_v312(cb);
  select count(*),
         count(*) filter (where (scope <> 'programme_pot' or programme_id is not distinct from live) and coalesce(reference,'') not like 'programme pot transfer %'),
         count(*) filter (where coalesce(reference,'') like 'programme pot transfer %'),
         count(*) filter (where scope = 'programme_pot' and programme_id is distinct from live)
    into total_rows, visible_rows, transfer_rows, other_pot_rows
    from public.points_ledger where business_id = cb and client_id = cust and entry_type in ('earn','expire','adjust');

  n := n + 1;
  if transfer_rows = 0 then raise exception 'G% failed: negative control — this customer is expected to carry pot-transfer rows', n; end if;
  n := n + 1;
  if visible_rows >= total_rows then raise exception 'G% failed: the predicate hides nothing (% of %)', n, visible_rows, total_rows; end if;
  n := n + 1;
  if visible_rows + transfer_rows + other_pot_rows < total_rows then
    raise exception 'G% failed: rows unaccounted for (visible % + transfers % + other pots % < %)', n, visible_rows, transfer_rows, other_pot_rows, total_rows;
  end if;

  raise notice 'nestly_v875 suite: % assertions passed (% of % rows remain visible)', n, visible_rows, total_rows;
end
$suite$;

rollback;
