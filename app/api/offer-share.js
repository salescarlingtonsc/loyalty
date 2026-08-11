'use strict';

/* v268 — the public landing page behind a shared offer link (/o/<offer-id>).
 *
 * Why this page exists at all: everything else the customer app serves is one static index.html
 * behind hash routes, and the crawlers WhatsApp, Facebook and Telegram send to unfurl a link
 * never run JavaScript — so every shared link previewed as generic Peekaa branding no matter
 * what was shared. This function is the one server-rendered surface: it answers the crawler
 * with per-offer Open Graph tags (the offer's own artwork, "offer — Peekaa × firm", validity)
 * and answers a human with the same content plus a scripted hop into the business's page in
 * the app. Crawlers read the tags and stop; humans continue. That split needs no sniffing of
 * who is asking — it falls out of who executes script.
 *
 * Data comes from one anon-callable read-only RPC (offer_share_page_v268) whose visibility
 * conditions mirror the customer promotion list exactly, so unpublishing an offer kills its
 * share preview at the same moment it leaves the app. A miss does not 404 the recipient —
 * the link they were sent still leads somewhere honest: the business's public page when the
 * path carries nothing usable, or the app home when even that is unknown.
 *
 * The artwork is presented UNCROPPED (object-fit: contain) — merchant EDMs have words baked
 * into the image and the standing rule is that uploaded artwork is never cropped or painted
 * over. og:image hands the platform the original file; what a chat app's card crops is the
 * platform's doing on its own copy, not ours.
 */

const SUPABASE_URL = (process.env.PEEKAA_SUPABASE_URL || 'https://gadpooereceldfpfxsod.supabase.co').replace(/\/$/, '');
const SUPABASE_PUBLISHABLE_KEY = process.env.PEEKAA_SUPABASE_PUBLISHABLE_KEY || 'sb_publishable_wDf8p9RghbpM2t7_PfBWKQ_YhYhNEAI';
const CANONICAL_ORIGIN = 'https://www.peekaa.asia';
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function esc(value) {
  return String(value == null ? '' : value).replace(/[&<>"']/g, (c) => (
    { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]
  ));
}

/* Media paths arrive as /storage/v1/... relative to the Supabase project; a crawler needs an
 * absolute URL. Anything that is not a storage path of ours is refused rather than passed
 * through — this function must never become an open redirect for image URLs. */
function absoluteMediaUrl(path) {
  const value = String(path || '');
  return value.startsWith('/storage/v1/object/public/') ? SUPABASE_URL + value : '';
}

function validityText(startsAt, endsAt) {
  const fmt = (iso) => {
    const at = new Date(iso);
    return Number.isNaN(at.getTime()) ? '' : at.toLocaleDateString('en-SG', { day: 'numeric', month: 'long', year: 'numeric', timeZone: 'Asia/Singapore' });
  };
  const starts = startsAt ? fmt(startsAt) : '', ends = endsAt ? fmt(endsAt) : '';
  if (starts && ends) return `Valid ${starts} – ${ends}`;
  if (ends) return `Valid until ${ends}`;
  return starts ? `Valid from ${starts}` : '';
}

async function fetchOffer(offerId) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 4000);
  try {
    const response = await fetch(`${SUPABASE_URL}/rest/v1/rpc/offer_share_page_v268`, {
      method: 'POST',
      headers: { apikey: SUPABASE_PUBLISHABLE_KEY, 'content-type': 'application/json' },
      body: JSON.stringify({ p_offer: offerId }),
      signal: controller.signal
    });
    if (!response.ok) return null;
    const payload = await response.json();
    return payload && typeof payload === 'object' ? payload : null;
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

function redirect(response, target) {
  response.statusCode = 302;
  response.setHeader('Location', target);
  response.setHeader('Cache-Control', 'public, max-age=0, s-maxage=60');
  response.end();
}

function renderPage(offer) {
  const name = String(offer.name || 'Offer');
  const business = String(offer.business_name || '').trim();
  const cobrand = business ? `Peekaa × ${business}` : 'Peekaa';
  const title = `${name} — ${cobrand}`;
  const validity = validityText(offer.starts_at, offer.ends_at);
  const description = [String(offer.tagline || offer.description || '').trim(), validity]
    .filter(Boolean).join(' · ').slice(0, 200) || `An offer from ${business || 'a Peekaa business'}.`;
  const image = absoluteMediaUrl(offer.image_url);
  const logo = absoluteMediaUrl(offer.business_logo_url);
  /* v274 put a marketing landing on "/" (edge middleware) with a script that forwards hash
   * routes to /app. Linking /app directly skips that bounce — one hop, not two. */
  const appUrl = `${CANONICAL_ORIGIN}/app#/b/${encodeURIComponent(String(offer.business_slug || ''))}`;
  const pageUrl = `${CANONICAL_ORIGIN}/o/${encodeURIComponent(String(offer.offer_id || ''))}`;

  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>${esc(title)}</title>
<meta property="og:type" content="website">
<meta property="og:site_name" content="Peekaa">
<meta property="og:title" content="${esc(title)}">
<meta property="og:description" content="${esc(description)}">
<meta property="og:url" content="${esc(pageUrl)}">
${image ? `<meta property="og:image" content="${esc(image)}">
<meta property="og:image:alt" content="${esc(offer.image_alt || name)}">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:image" content="${esc(image)}">` : '<meta name="twitter:card" content="summary">'}
<meta name="twitter:title" content="${esc(title)}">
<meta name="twitter:description" content="${esc(description)}">
<link rel="canonical" href="${esc(pageUrl)}">
<link rel="icon" type="image/png" sizes="32x32" href="/icons/peekaa-32.png">
<style>
body{margin:0;background:#F4F2EE;color:#17161A;font-family:-apple-system,BlinkMacSystemFont,'SF Pro Text','Inter',system-ui,sans-serif;
  display:flex;align-items:center;justify-content:center;min-height:100vh;padding:20px;box-sizing:border-box}
.card{background:#fff;border:1px solid rgba(23,22,26,.06);border-radius:24px;max-width:420px;width:100%;overflow:hidden;
  box-shadow:0 2px 6px rgba(23,22,26,.05),0 18px 44px rgba(23,22,26,.10);text-align:center}
.art{width:100%;background:#FFF0EC}
.art img{display:block;width:100%;max-height:340px;object-fit:contain}
.body{padding:20px 22px 24px}
.marks{display:flex;align-items:center;justify-content:center;gap:10px;margin-bottom:8px}
.marks img{width:40px;height:40px;border-radius:11px;object-fit:cover;border:1px solid #EAE6DF;background:#fff}
.marks span{color:#6B6673;font-size:17px}
.cobrand{font-weight:700;font-size:14px;margin:0 0 12px}
h1{font-size:1.25rem;margin:0 0 6px;letter-spacing:-.02em}
.muted{color:#6B6673;font-size:13px;margin:0 0 18px}
a.btn{display:inline-flex;align-items:center;justify-content:center;min-height:44px;padding:10px 24px;border-radius:100px;
  background:linear-gradient(135deg,#C24135,#9D352C);color:#fff;font-weight:600;text-decoration:none;font-size:14px}
</style>
</head>
<body>
<main class="card">
  ${image ? `<div class="art"><img src="${esc(image)}" alt="${esc(offer.image_alt || name)}"></div>` : ''}
  <div class="body">
    <div class="marks" aria-hidden="true">
      <img src="/icons/peekaa-192.png" alt="">
      <span>×</span>
      ${logo ? `<img src="${esc(logo)}" alt="">` : ''}
    </div>
    <p class="cobrand">${esc(cobrand)}</p>
    <h1>${esc(name)}</h1>
    ${validity ? `<p class="muted">${esc(validity)}</p>` : ''}
    <a class="btn" href="${esc(appUrl)}">View this offer</a>
  </div>
</main>
<script>setTimeout(function(){window.location.replace(${JSON.stringify(appUrl)})},1200);</script>
</body>
</html>`;
}

module.exports = async function offerShareHandler(request, response) {
  if (!['GET', 'HEAD'].includes(request.method || 'GET')) {
    response.statusCode = 405;
    response.setHeader('Allow', 'GET, HEAD');
    response.end();
    return;
  }
  const id = String((request.query && request.query.id) || '').trim().toLowerCase();
  if (!UUID.test(id)) return redirect(response, CANONICAL_ORIGIN + '/');
  const offer = await fetchOffer(id);
  if (!offer || !offer.business_slug) return redirect(response, CANONICAL_ORIGIN + '/');

  response.statusCode = 200;
  response.setHeader('Content-Type', 'text/html; charset=utf-8');
  /* Crawlers re-fetch on every unfurl; five minutes at the edge absorbs a viral share without
   * letting an edited offer stay stale for long. */
  response.setHeader('Cache-Control', 'public, max-age=0, s-maxage=300, stale-while-revalidate=600');
  response.setHeader('X-Content-Type-Options', 'nosniff');
  response.end(request.method === 'HEAD' ? '' : renderPage(offer));
};
