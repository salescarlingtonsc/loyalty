# V156 internal CRM operating guide

Peekaa's platform CRM extends the existing V76/V86 prospect store. It is never
a merchant-owned CRM and never creates a duplicate paying-business record.

## Sales pipeline

Use the existing 17 audited stages and the five operational Kanban lanes. The
mobile List view is an equivalent non-drag control. Add contacts, notes, calls,
meetings, tasks, commercial detail and authorised billing recipients on the
prospect drawer. Finalise/send a quotation from the Subscription documents area.

Moving a card to Client/Won is commercial workflow only. It never grants
entitlement or marks payment. A processed Stripe `invoice.paid` event may move
the opportunity to Client automatically, with an idempotent activity and stage
history record.

## Customer lifecycle

Customer lifecycle is derived from canonical subscription and invoice records:
payment received, onboarding, active, trial, renewal approaching, payment action
required, past due, cancel at period end, paused and cancelled/churned. These
states are not draggable. Follow-up tasks remain manually assignable.

Subscription Operations lists paid-through, next renewal, scheduled end, latest
payment/invoice, delivery state and open follow-up count. Annual 30/14/7-day
tasks are idempotent. Failed/action-required tasks resolve after verified
payment recovery.

## Permission boundary

Super admins and explicitly permitted platform billing/onboarding operators use
guarded RPCs. Sales staff see only assigned prospects. Raw V156 tables have no
anonymous or authenticated table privileges and RLS remains enabled. Merchant
membership does not confer platform CRM access, and CRM assignment does not
confer merchant workspace access.
