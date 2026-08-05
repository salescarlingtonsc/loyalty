-- Peekaa V156B first-contact prospect channel tolerance
-- Owner 2026-08-05: Super Admin must be able to save a new first-contact
-- prospect when the company and primary contact name are known before an email
-- or phone number is available. Secondary/non-primary contacts still require a
-- reachable channel.

begin;

alter table public.sme_prospect_contacts
  drop constraint if exists sme_prospect_contacts_channel_check;

alter table public.sme_prospect_contacts
  add constraint sme_prospect_contacts_channel_check
  check (is_primary or email is not null or phone is not null);

comment on constraint sme_prospect_contacts_channel_check
  on public.sme_prospect_contacts
  is 'V156B permits a first-contact primary named contact before email/phone are known; non-primary contacts still require a channel.';

commit;
