/* V274: "/" must serve the marketing landing while index.html remains the app.
 *
 * A vercel.json rewrite cannot do this: Vercel resolves the filesystem BEFORE rewrites, and a
 * real /index.html therefore always wins at "/" — which is exactly what the first deploy of the
 * landing page proved in production. Renaming the app's HTML instead is off the table: 203 test
 * and script files reference app/index.html, and the bundle-stamp pipeline writes it.
 *
 * Edge middleware runs BEFORE the filesystem check, so it is the one place this split can live.
 * The matcher pins it to exactly "/": no other route pays the invocation, and the app surfaces
 * (/app, /business, /admin — all rewrites, no filesystem hit) are untouched.
 *
 * Failure is designed to fall OPEN to the app, never to an error page:
 *   - installed customer PWAs open "/?source=pwa" (the manifest start_url) -> return undefined,
 *     which continues to the filesystem and serves index.html, the app, unchanged;
 *   - anything thrown here is caught and also returns undefined -> the app, i.e. yesterday's
 *     behaviour, not a 500 on the domain root;
 *   - hash routes ("/#/wallet/..." from push-notification taps) never reach the server, so the
 *     landing page's own first script forwards them to /app — that path does not pass here.
 *
 * The rewrite is expressed as the x-middleware-rewrite response header, which is the contract
 * @vercel/edge's rewrite() helper emits; it is written directly so this file has zero imports
 * and needs no package.json in the deploy root.
 */
export const config = { matcher: '/' };

export default function middleware(request) {
  try {
    const url = new URL(request.url);
    if (url.searchParams.get('source') === 'pwa') return undefined;
    url.pathname = '/landing.html';
    url.search = '';
    return new Response(null, { headers: { 'x-middleware-rewrite': url.toString() } });
  } catch {
    return undefined;
  }
}
