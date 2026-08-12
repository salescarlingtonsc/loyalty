import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

const html=await readFile(new URL('../../app/index.html',import.meta.url),'utf8');
const js=await readFile(new URL('../../app/app.js',import.meta.url),'utf8');
const app=html+'\n'+js;

/* v286 (audit): a blocked jsQR CDN used to surface as 'Camera access was not available' on the
   camera path and 'That image could not be read' on the photo path — two wrong diagnoses for one
   missing decoder. Both paths now name the real failure and offer a retry that re-runs the load. */
test('a failed decoder load is reported as a decoder failure, not a camera or photo failure',()=>{
  assert.match(js,/const DECODER_LOAD_FAILURE='The scanner could not load\. Check your connection and try again\.'/);
  assert.match(js,/const loadDecoder=async\(\)=>\{try\{await loadScannerLibrary\(\);return true\}catch\{return false\}\}/);
  // camera path: decoder guard runs BEFORE getUserMedia is ever called, and leaves a live retry.
  assert.match(js,/if\(!await loadDecoder\(\)\)\{[\s\S]{0,200}?cameraLabel\.textContent=ct\('retry'\);[\s\S]{0,80}?status\.textContent=ct\(DECODER_LOAD_FAILURE\);return;/);
  assert.match(js,/status\.textContent=ct\(DECODER_LOAD_FAILURE\);return\}[\s\S]{0,120}?createImageBitmap\(file\)/);
  // the camera catch no longer swallows the loader rejection.
  assert.doesNotMatch(js,/await loadScannerLibrary\(\);\s*stream=await navigator\.mediaDevices\.getUserMedia/);
  assert.doesNotMatch(js,/await loadScannerLibrary\(\);\s*const bitmap=await createImageBitmap/);
  // the genuine camera-denied and no-camera-API messages are unchanged.
  assert.match(js,/Camera access was not available\. Choose a QR image or paste the QR link\./);
  assert.match(js,/Camera is unavailable in this browser\. Choose a QR image or paste the QR link\./);
});

test('pasting a QR link and pressing Enter submits it',()=>{
  assert.match(js,/pasteValue\.onkeydown=event=>\{if\(event\.key==='Enter'\)\{event\.preventDefault\(\);accept\(pasteValue\.value\)\}\}/);
  assert.match(js,/#customerJoinScannerConfirm'\)\.onclick=\(\)=>accept\(pasteValue\.value\)/);
});

test('the un-joinable QR outcome offers a way out and clears the dead token',()=>{
  assert.match(js,/clearWriteAttempt\('nestly\.customer\.joinQr'\);rememberPendingCustomerJoinToken\(''\);\s*status\.innerHTML='This programme could not be joined\./);
  assert.match(js,/could not be joined[\s\S]{0,200}?href="#\/customer\/programmes"[\s\S]{0,40}?Back to programmes<\/a>/);
});

test('the scanner spotlight shadow is clipped to the video frame',()=>{
  assert.match(html,/\.scanner-frame\{[^}]*overflow:hidden/);
  assert.match(html,/\.scanner-frame::after\{[^}]*box-shadow:0 0 0 999px/);
});

/* v286 pinned the EN-only state and demanded ct() routing the day a second locale arrived.
   v293 added zh-CN + ms, so the sheet's user-facing strings now go through ct() and the
   status assignments carry ct(...) — the pin flips to assert the multilingual contract. */
test('the customer surface is multilingual and the scanner sheet is routed through ct()',()=>{
  assert.match(js,/const CUSTOMER_LOCALES=Object\.freeze\(\['en','zh-CN','ms','ta'\]\)/);
  assert.match(js,/\$\{esc\(ct\('Scan the business QR'\)\)\}/);
  assert.match(js,/status\.textContent=ct\(DECODER_LOAD_FAILURE\)/);
  assert.match(js,/status\.textContent=ct\('Point the camera at the business QR\.'\)/);
});
