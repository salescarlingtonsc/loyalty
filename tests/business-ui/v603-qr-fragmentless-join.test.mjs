/* nestly_v603 — "website link works but qrcode does not work."
 *
 * The tappable link under the business QR and the QR itself carried the SAME
 * 'https://www.peekaa.asia/#/join?token=…' URL. A tapped link keeps its fragment, but several
 * camera/scanner apps hand the browser only the part before the '#' — so a scanned phone arrived
 * at the bare marketing page: no business, no error, "nothing pops up". The backend, the token,
 * and the join RPC were all verified working the whole time (v602's lesson, continued).
 *
 * The fix is to keep the token OUT of the fragment in the thing scanners read:
 *   - the QR now encodes 'https://www.peekaa.asia/?token=…' (no '#'),
 *   - landing.html folds ?token= into '/app#/join?token=…' before anything else — including
 *     before the signed-in replace('/app'), which would otherwise eat the token,
 *   - the app shell folds a stray '/app?token=…' the same way, without clobbering real routes.
 *
 * These tests EXECUTE the two inline scripts in a stubbed window (a regex on the source cannot
 * prove order-of-branches behaviour like "signed-in user with a token still reaches the join").
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';

const landing=readFileSync(new URL('../../app/landing.html',import.meta.url),'utf8');
const index=readFileSync(new URL('../../app/index.html',import.meta.url),'utf8');
const app=readFileSync(new URL('../../app/app.js',import.meta.url),'utf8');

const scriptBlock=(html,marker)=>{
  const at=html.indexOf(marker);
  assert.ok(at>=0,`${marker} is present`);
  const open=html.lastIndexOf('<script>',at);
  const close=html.indexOf('</script>',at);
  return html.slice(open+'<script>'.length,close);
};
const landingForward=scriptBlock(landing,'forwardLegacyAppEntriesV274');
const indexFold=scriptBlock(index,'foldQueryJoinTokenV603');

const TOKEN='7bcc46dd6beab634fc8aea68f479c12c62cb8c9e40e2a406132eeb850f6aa54d';

function runScript(source,{hash='',search='',pathname='/',storageKeys=[]}={}){
  const replaced=[];
  const window={
    location:{hash,search,pathname,replace:target=>replaced.push(target)},
    localStorage:{
      get length(){return storageKeys.length},
      key:i=>storageKeys[i]??null
    }
  };
  const context={
    window,
    document:{documentElement:{className:''}}
  };
  vm.runInNewContext(source,vm.createContext(context));
  return replaced;
}

test('landing: a scanned ?token= URL is folded into the join route',()=>{
  assert.deepEqual(
    runScript(landingForward,{search:`?token=${TOKEN}`}),
    [`/app#/join?token=${TOKEN}`]
  );
});

test('landing: a signed-in owner scanning the QR still reaches the join, not the bare app',()=>{
  /* The session branch replaces to '/app' with no route. If it ran before the token branch, a
     signed-in owner's scan would silently lose the scan — the exact "nothing pops up" shape. */
  assert.deepEqual(
    runScript(landingForward,{search:`?token=${TOKEN}`,storageKeys:['sb-gadpooereceldfpfxsod-auth-token']}),
    [`/app#/join?token=${TOKEN}`]
  );
});

test('landing: the historical hash form keeps working, and a garbage token is ignored',()=>{
  assert.deepEqual(
    runScript(landingForward,{hash:`#/join?token=${TOKEN}`}),
    [`/app#/join?token=${TOKEN}`]
  );
  /* not token-shaped → falls through to the plain landing, no redirect */
  assert.deepEqual(runScript(landingForward,{search:'?token=abc'}),[]);
});

test('app shell: /app?token=… is folded into the join route, real routes are never clobbered',()=>{
  assert.deepEqual(
    runScript(indexFold,{pathname:'/app',search:`?token=${TOKEN}`}),
    [`/app#/join?token=${TOKEN}`]
  );
  assert.deepEqual(
    runScript(indexFold,{pathname:'/app',search:`?token=${TOKEN}`,hash:'#/dashboard'}),
    [],'an existing #/ route wins over a stray query token'
  );
});

test('the QR encodes the fragment-free URL; the visible link keeps the canonical hash form',()=>{
  const site=app.slice(app.indexOf('const showJoinQr=async data=>'),app.indexOf('setJoinQrLeadV456(\'Print this QR'));
  /* v606 moved the QR's landing from the root query to the dedicated /join page — still no
     fragment anywhere in the scanned URL. */
  assert.match(site,/const qrContentV603=window\.NestlyNativeBridge\.publicUrl\(`\/join\?token=\$\{encodeURIComponent\(data\.join_token\)\}`\)/,
    'the QR content has no # for a scanner to truncate at');
  assert.match(site,/new QRCode\(qrEl,\{text:qrContentV603,/,'and it is what the QR actually draws');
  assert.match(site,/url=publicAppUrl\(`join\?token=\$\{encodeURIComponent\(data\.join_token\)\}`\)/,
    'the tappable/copyable link is unchanged — fragments are safe when tapped');
  assert.match(site,/href="\$\{esc\(url\)\}"/,'the link row still renders the hash-form url');
});
