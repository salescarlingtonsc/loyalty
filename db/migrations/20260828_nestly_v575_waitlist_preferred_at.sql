-- nestly_v575 — the waitlist records a real date and time.
--
-- Owner: "isn't waitlist supposed to indicate date & time (instead of preferred window)? so when
-- press book — straight away can push to appointment and minimal clicking is required (just need
-- to assign the job to available staff)."
--
-- public.waitlist.preferred held free text ("weekday eve"). No form can act on a phrase, so
-- Waitlist's Book could only ever open an EMPTY appointment and staff retyped what the queue
-- already knew. This adds the instant the walk-in actually wants, which Book hands to the
-- appointment form together with the service — leaving only the team member to choose.
--
-- Additive and backward compatible. The column is NULLABLE and `preferred` is untouched: every
-- row written before v575 keeps its phrase and the readers still print it, they simply cannot
-- offer a one-tap booking for it. No date is ever inferred from the old text.
--
-- Rollback suite: db/tests/v575_waitlist_preferred_at.sql
-- ROLLBACK: dropping the column returns Book to opening an empty form. Nothing else reads it,
-- and no row becomes invalid — `preferred` was never stopped being written by anything else.

begin;

alter table public.waitlist
  add column if not exists preferred_at timestamptz;

comment on column public.waitlist.preferred_at is
  'nestly_v575 - the date and time the walk-in actually wants, so Book can hand it straight to '
  'the appointment form. Nullable: every row written before v575 carries only the free-text '
  'preferred window, and readers fall back to that.';

commit;
