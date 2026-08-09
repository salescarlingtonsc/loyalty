-- Nestly v264 — a customer sharing a promotion is a recordable event.
--
-- Owner: "i need a share button for promotions - to share to social media / whatsapp / FB / IG /
-- tiktok/wechat/ telegram - so customers can help businesses to share."
--
-- The last clause is the point: the business is meant to BENEFIT. A share the firm cannot see is
-- a feature nobody can judge, so the share is recorded on the same product-adoption spine as every
-- other customer event. v100's contract has two halves and both must agree — the client allowlist
-- (PRODUCT_INTERACTION_EVENTS_V100) and this taxonomy row, or the write is refused with 22023.
--
-- What is recorded is deliberately thin: the business, and which channel the customer chose
-- (native share sheet, WhatsApp, Telegram, Facebook, copy link). No recipient, no message, no
-- contact — the app never learns who a customer shared with, and the OS share sheet does not tell
-- it. business_scope_required is true because a promotion always belongs to one firm.
--
-- Nothing here can complete a share: this is evidence of an INTENT to share, recorded when the
-- customer picks a channel. Whether they went on to post it is not knowable from inside a web app,
-- and the description says so rather than letting a reader assume a delivery guarantee.

begin;

insert into public.product_adoption_event_taxonomy_v100
  (event_name, source_authority, actor_scope, required_module, required_mode,
   business_scope_required, economic_event, description)
values
  ('customer.promotion_shared', 'client', 'customer', null, null,
   true, false,
   'Verified customer chose a channel to share a promotion. Records the business and the channel '
   'only — never the recipient, the message, or whether the post was completed.')
on conflict (event_name) do nothing;

commit;
