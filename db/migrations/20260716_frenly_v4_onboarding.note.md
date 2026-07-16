# 20260716 frenly_v4_onboarding_rpc (applied remotely)
Root cause of onboarding failure: Postgres applies SELECT policies to rows returned
by INSERT ... RETURNING. businesses select policy = is_salon_member(id), which is
false at first-business creation (no staff row yet) -> 42501 despite insert
with_check(true). Fix: public.create_business(name, slug, industry, modules)
SECURITY DEFINER — atomically inserts business + owner staff + default loyalty
program + audit entry; requires auth.uid(); granted to authenticated only.
App onboarding now calls this RPC (single call, no client-side multi-insert).
