-- FRENLY v22a — close the default-privilege recreation vector in schema `app`.
-- Applied migration name: frenly_v22a_app_default_privileges
--
-- Schema `app` had NO pg_default_acl entry, so every newly created function there fell back to
-- PostgreSQL's built-in default: EXECUTE granted to PUBLIC. That is the exact mechanism by which
-- `app.commission_flat_cents` (v13) was born anon/PUBLIC-executable — the regression v22 fixed.
-- This migration makes future `app` functions BORN LOCKED for the migration-authoring role, so
-- the class of bug cannot recur silently. (The `public` schema's Supabase platform defaults —
-- anon/authenticated/service_role EXECUTE on new functions — are deliberately left untouched:
-- they are the managed platform's API model, controlled by v21's explicit revokes and enforced
-- by db/tests/v21_security_hardening.sql.)

begin;

alter default privileges for role postgres in schema app
  revoke execute on functions from public;

commit;

-- ⚠️ POST-APPLY FINDING (verified on production): this schema-scoped statement is a NO-OP.
-- PostgreSQL semantics: per-schema default-privilege entries are ADDITIVE deltas that start
-- empty — an in-schema REVOKE can only subtract grants previously added by an in-schema
-- ALTER DEFAULT PRIVILEGES entry, and cannot remove the built-in "EXECUTE to PUBLIC" default
-- (pg_default_acl stayed empty for schema app; a probe function was still born
-- PUBLIC-executable). Only the GLOBAL form (no IN SCHEMA) starts from the built-in default.
-- Superseded by 20260719_frenly_v22b_global_function_default_privileges.sql, which performs
-- the effective global revoke. Kept for honest migration history.
