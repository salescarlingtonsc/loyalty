-- FRENLY v50b - CONTACT-PROOF CONSTRAINT REPAIR (STALE v30 INLINE CHECK)
--
-- Forward-only defect repair. Historical migrations remain immutable.
--
-- ROOT CAUSE:
--   v30 (customer_identity) declared public.customer_contact_proofs.proof_method with
--   an INLINE column check -- `proof_method text not null check (proof_method in
--   ('auth_email_confirmation','email_otp','firm_invitation','support_recovery'))` --
--   which PostgreSQL auto-named `customer_contact_proofs_proof_method_check`, in
--   addition to the separately NAMED `customer_contact_proofs_method_type_check`.
--   c42 (consumer registration) dropped and re-added the NAMED method_type_check to
--   allow (contact_type='phone' AND proof_method='auth_phone_otp'), but never touched
--   the auto-named inline check, so the STALE email-only vocabulary survived.
--
-- CONSEQUENCE:
--   customer_register_verified_phone()'s happy path inserts a phone contact proof with
--   proof_method='auth_phone_otp', which the stale email-only inline check rejects
--   (check_violation). Phone registration is structurally broken -- currently dormant
--   in production only because the customer_phone_registration/customer_phone_otp
--   platform feature flags default OFF. This migration drops ONLY the stale constraint.
--
-- Sibling c42-family vocabulary tables (customer_identities, customer_verified_contacts,
-- customer_links) were swept and carry no equivalent stale duplicate.
--
-- Following the v49a/v50a fail-closed style: prove the exact stale email-only proof_method
-- vocabulary is present (and that method_type_check still carries the correct c42 phone+
-- email definition) via pg_get_constraintdef BEFORE dropping. If either assertion fails,
-- the migration raises and changes nothing. The deparsed constraint text is compared by
-- its required vocabulary content rather than a byte-for-byte string: pg_get_constraintdef
-- output is normalized by the server and its exact parenthesization/cast rendering is
-- version-dependent, so the assertions below fail-closed-prove it is precisely the stale
-- email-only proof_method check (all four email methods, references proof_method, and
-- carries neither the phone method nor a contact_type pairing) without brittleness.

begin;

do $v50b_repair$
declare
  v_stale text;
  v_method_type text;
begin
  select pg_get_constraintdef(c.oid) into v_stale
    from pg_constraint c
   where c.conrelid = 'public.customer_contact_proofs'::regclass
     and c.conname = 'customer_contact_proofs_proof_method_check'
     and c.contype = 'c';
  if v_stale is null then
    raise exception 'v50b: expected stale customer_contact_proofs_proof_method_check is absent; refusing to proceed';
  end if;
  if position('proof_method' in v_stale) = 0
     or position('auth_email_confirmation' in v_stale) = 0
     or position('email_otp' in v_stale) = 0
     or position('firm_invitation' in v_stale) = 0
     or position('support_recovery' in v_stale) = 0
     or position('auth_phone_otp' in v_stale) <> 0
     or position('contact_type' in v_stale) <> 0 then
    raise exception 'v50b: customer_contact_proofs_proof_method_check is not the stale email-only definition: %', v_stale;
  end if;

  select pg_get_constraintdef(c.oid) into v_method_type
    from pg_constraint c
   where c.conrelid = 'public.customer_contact_proofs'::regclass
     and c.conname = 'customer_contact_proofs_method_type_check'
     and c.contype = 'c';
  if v_method_type is null then
    raise exception 'v50b: expected c42 customer_contact_proofs_method_type_check is absent; refusing to proceed';
  end if;
  if position('contact_type' in v_method_type) = 0
     or position('proof_method' in v_method_type) = 0
     or position('auth_phone_otp' in v_method_type) = 0
     or position('auth_email_confirmation' in v_method_type) = 0
     or position('email_otp' in v_method_type) = 0
     or position('firm_invitation' in v_method_type) = 0
     or position('support_recovery' in v_method_type) = 0 then
    raise exception 'v50b: customer_contact_proofs_method_type_check is not the expected c42 combined definition: %', v_method_type;
  end if;

  alter table public.customer_contact_proofs
    drop constraint customer_contact_proofs_proof_method_check;
end
$v50b_repair$;

comment on constraint customer_contact_proofs_method_type_check on public.customer_contact_proofs is
  'Sole proof_method/contact_type allowlist. v30 declared proof_method with an inline (auto-named customer_contact_proofs_proof_method_check) email-only check alongside this named check; c42 rewrote only the named check to admit phone/auth_phone_otp, and v50b dropped the surviving stale inline check so phone registration is no longer structurally rejected.';

commit;
