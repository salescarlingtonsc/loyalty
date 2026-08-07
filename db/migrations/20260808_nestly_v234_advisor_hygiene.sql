-- V234 — close the two remaining advisor findings from the post-outage deep audit.
begin;

-- (1) The one function in the whole database without a pinned search_path. It is a pure
--     IMMUTABLE category→account-code mapping with no table access, so the exposure was
--     theoretical — pinned anyway so the advisor stays at zero and the next real case
--     is not lost in noise.
alter function app.platform_expense_account_v147(text) set search_path = pg_catalog, app, pg_temp;

-- (2) The only two tables without a primary key (both currently empty; v154 is the
--     superseded predecessor of v155). A promotion may appear at most once per branch
--     scope row, so (promotion_id, branch_id) is the natural key.
alter table public.promotion_branch_scopes_v154 add primary key (promotion_id, branch_id);
alter table public.promotion_branch_scopes_v155 add primary key (promotion_id, branch_id);

commit;
