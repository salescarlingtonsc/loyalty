-- V233 — the 2026-08-07 outage class, closed for admin sessions too.
--
-- v232 reaps abandoned API transactions (authenticator, 60s). But sessions on the
-- postgres role — dashboard SQL editor, MCP tooling, migrations — had no backstop:
-- one left idle inside a transaction while holding a lock (say, on businesses or a
-- loyalty table) would block API writers exactly like the promotion jam did.
-- 15 minutes is far beyond any legitimate interactive pause between statements in a
-- transaction, and migrations apply as single batches so they never idle mid-transaction.
begin;
alter role postgres set idle_in_transaction_session_timeout = '15min';
commit;
