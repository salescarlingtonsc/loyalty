import {createHash} from 'node:crypto';
import {readFile,writeFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {isDirectCliInvocation} from '../../scripts/quality/is-direct-cli-invocation.mjs';

const APP_URL=new URL('../../app/index.html',import.meta.url);
/* The application script was extracted from index.html into app.js. The .test.mjs files
   pass both files joined; this CLI path must read the same pair or it regenerates a
   fixture from a file that no longer contains the components. */
const APP_SCRIPT_URL=new URL('../../app/app.js',import.meta.url);
const readAppSource=async()=>(await Promise.all([readFile(APP_URL,'utf8'),readFile(APP_SCRIPT_URL,'utf8')])).join('\n');
const FIXTURE_URL=new URL('./v104-promotions-visual.html',import.meta.url);

function sourceBetween(source,start,end){
  const from=source.indexOf(start),to=source.indexOf(end,from+start.length);
  if(from<0||to<=from)throw new Error(`production source section missing: ${start}`);
  return source.slice(from,to).trim();
}

function productionSources(app){
  const style=app.match(/<style>([\s\S]*?)<\/style>/)?.[1];
  if(!style)throw new Error('production inline stylesheet missing');
  const functions=[
    sourceBetween(app,'function promotionDateTextV104','function promotionBoundaryV104'),
    /* v195: the card drops copy this app generated and that only repeats the title or the
       validity row. Those two helpers are production code the card calls, so the fixture must
       carry them or it would render a card production no longer produces. */
    sourceBetween(app,'function customerOfferTaglineV194','function customerOfferDescriptionV195'),
    sourceBetween(app,'function customerOfferDescriptionV195','function showCustomerOfferDetailV173'),
    /* v264: the card now carries a Share button, so the fixture must carry the function that
       draws it or it would render a card production no longer produces. */
    sourceBetween(app,'function customerShareButtonMarkupV264','function customerShareSheetMarkupV264'),
    sourceBetween(app,'function customerPromotionCtaV104','function customerPromotionValidityV104'),
    sourceBetween(app,'function customerPromotionValidityV104','function customerPromotionCardV104'),
    /* nestly_v421: the card now paints its own artwork, blurred, behind a picture that does not
       fill the frame, and passes the url through this CSS-escaping helper to do it. Without it
       here the fixture renders a card production no longer produces — it throws. */
    sourceBetween(app,'function cssUrlValueV421','function customerHomeOfferMarkupV167'),
    sourceBetween(app,'function customerPromotionCardV104','function openCustomerPromotionDetailsV104'),
    sourceBetween(app,'function openCustomerPromotionDetailsV104','function customerMerchantExperienceMarkupV95')
  ];
  return {style,functions};
}

const imageSvg=(from,to)=>`data:image/svg+xml,${encodeURIComponent(
  `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1200 800"><defs><linearGradient id="g" x2="1" y2="1"><stop stop-color="${from}"/><stop offset="1" stop-color="${to}"/></linearGradient></defs><rect width="1200" height="800" fill="url(#g)"/><circle cx="950" cy="160" r="210" fill="white" fill-opacity=".13"/><circle cx="210" cy="650" r="260" fill="white" fill-opacity=".09"/></svg>`
)}`;

export function buildV104PromotionVisualFixture(app){
  const {style,functions}=productionSources(app);
  const sourceBundle=`${style}\n${functions.join('\n')}`;
  const sourceHash=createHash('sha256').update(sourceBundle).digest('hex');
  const longToken='NESTLY-NDP-2026-'+('SAVE30'.repeat(20))+'-HTTPS-EXAMPLE-COM-PROMOTIONS-SPA-RITUAL-60';
  const offers=[
    {
      id:'11111111-1111-4111-8111-111111111111',
      name:'National Day: 30% off Spa Ritual 60',
      description:'Celebrate National Day with 30% off Spa Ritual 60 at Glow Atelier. Book now to enjoy this offer.',
      terms:'One redemption per customer. Advance booking required.',
      image_url:imageSvg('#ed6154','#ffb56d'),
      image_alt:'National Day spa treatment promotion',
      starts_at:'2026-08-01T00:00:00+08:00',
      ends_at:'2026-08-30T23:59:59+08:00',
      metadata:{offer_facts:'30% off Spa Ritual 60',cta:{kind:'book',label:'Book now'}}
    },
    {
      id:'22222222-2222-4222-8222-222222222222',
      name:'Weekday facial upgrade',
      description:`Use coupon ${longToken}`,
      terms:`Show this exact code at the counter: ${longToken}`,
      image_url:imageSvg('#30234f','#8b74cc'),
      image_alt:'Weekday facial promotion',
      starts_at:'2026-08-15T00:00:00+08:00',
      ends_at:'2026-09-15T23:59:59+08:00',
      metadata:{offer_facts:`Coupon ${longToken}`,cta:{kind:'programme',label:'View details'}}
    }
  ];
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="v104-production-source-sha256" content="${sourceHash}">
<title>Peekaa v104 production-render visual acceptance</title>
<style>
${style}
/* Evidence label only. Layout and customer promotion components are production CSS. */
.v104-provenance{margin-bottom:12px;color:var(--muted);font-size:12px;overflow-wrap:anywhere}
</style>
</head>
<body>
<div class="wallet-shell customer-shell"><div class="wallet-inner">
  <p class="v104-provenance">Local production-render harness · source ${sourceHash}</p>
  <header class="customer-programme-compact-head">
    <div class="customer-programme-logo"><span>G</span></div>
    <div class="customer-programme-compact-copy"><h1>Glow Atelier</h1><p>Glow Rewards</p></div>
    <div class="customer-programme-compact-balance"><b>1,240</b><span>points</span></div>
  </header>
  <section class="customer-promotions-section" aria-labelledby="latestOffersTitle">
    <div class="customer-promotions-head"><div><p class="customer-quest-kicker">From Glow Atelier</p><h2 id="latestOffersTitle">Latest offers</h2></div></div>
    <div class="customer-promotions-grid" id="promotionCards"></div>
  </section>
</div></div>
<script>
const PRODUCTION_SOURCE_SHA256=${JSON.stringify(sourceHash)};
const FIXTURE_LONG_TOKEN=${JSON.stringify(longToken)};
const FIXTURE_OFFERS=${JSON.stringify(offers)};
const $=id=>document.getElementById(id);
const esc=value=>String(value??'').replace(/[&<>"']/g,char=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[char]));
const customerMediaUrlV95=value=>String(value||'');
const CUI={
  /* v264: the card draws a Share button through the shared icon set. The fixture stubs the glyph
     rather than inlining customer-ui.js — this evidence is about the promotion CARD's layout and
     wrap behaviour, and a real path would only change the pixels inside a 16px box. */
  icon:(name,options)=>'<svg class="cui-icon" width="'+(((options||{}).size)||20)+'" height="'+(((options||{}).size)||20)+'" viewBox="0 0 24 24" aria-hidden="true"></svg>',
  activateDialog(modal,{onClose,initialFocus}={}){
  const keydown=event=>{if(event.key==='Escape'){event.preventDefault();onClose?.()}};
  document.addEventListener('keydown',keydown);
  requestAnimationFrame(()=>modal.querySelector(initialFocus)?.focus());
  return ()=>{document.removeEventListener('keydown',keydown);modal.remove()};
}};
${functions.join('\n')}
const business={name:'Glow Atelier',slug:'glow-atelier'};
$('promotionCards').innerHTML=FIXTURE_OFFERS.map(offer=>customerPromotionCardV104(offer,business,true)).join('');
document.querySelectorAll('[data-promotion-details]').forEach(button=>button.addEventListener('click',()=>{
  openCustomerPromotionDetailsV104(button.closest('[data-promotion-id]'));
}));
window.v104OpenTerms=(index=0)=>{
  const details=document.querySelectorAll('.customer-promotion-card details')[index];
  if(details)details.open=true;
};
window.v104AcceptanceMetrics=()=>({
  sourceHash:PRODUCTION_SOURCE_SHA256,
  viewport:{clientWidth:document.documentElement.clientWidth,scrollWidth:document.documentElement.scrollWidth},
  cards:[...document.querySelectorAll('.customer-promotion-card')].map(card=>({
    rect:card.getBoundingClientRect().toJSON(),
    validity:card.querySelector('.customer-promotion-validity')?.textContent?.trim(),
    ctaHeight:card.querySelector('.btn')?.getBoundingClientRect().height,
    details:(()=>{
      const details=card.querySelector('details');
      if(!details)return null;
      const rect=details.getBoundingClientRect(),cardRect=card.getBoundingClientRect();
      return {
        open:details.open,
        width:rect.width,
        height:rect.height,
        cardWidth:cardRect.width,
        availableContentWidth:card.querySelector('h3')?.getBoundingClientRect().width||0,
        scrollWidth:details.scrollWidth,
        clientWidth:details.clientWidth,
        scrollHeight:details.scrollHeight,
        clientHeight:details.clientHeight
      };
    })(),
    textOverflow:[...card.querySelectorAll('h3,p,summary,dd')].map(node=>({
      text:node.textContent.trim(),clientWidth:node.clientWidth,scrollWidth:node.scrollWidth,
      clientHeight:node.clientHeight,scrollHeight:node.scrollHeight
    }))
  })),
  longTokenVisible:document.body.textContent.includes(FIXTURE_LONG_TOKEN),
  modal:document.querySelector('#customerPromotionDetailsModal')?{
    role:document.querySelector('#customerPromotionDetailsModal').getAttribute('role'),
    ariaModal:document.querySelector('#customerPromotionDetailsModal').getAttribute('aria-modal'),
    labelledBy:document.querySelector('#customerPromotionDetailsModal').getAttribute('aria-labelledby'),
    activeElement:document.activeElement?.id||'',
    textOverflow:[...document.querySelectorAll('#customerPromotionDetailsModal h2,#customerPromotionDetailsModal p,#customerPromotionDetailsModal dd')].map(node=>({
      text:node.textContent.trim(),clientWidth:node.clientWidth,scrollWidth:node.scrollWidth,
      clientHeight:node.clientHeight,scrollHeight:node.scrollHeight
    }))
  }:null
});
const evidenceParams=new URLSearchParams(location.search);
if(evidenceParams.has('openTerms'))window.v104OpenTerms(Number(evidenceParams.get('openTerms')||0));
if(evidenceParams.get('openModal')==='1'){
  document.querySelector('[data-promotion-details]')?.click();
}
if(evidenceParams.get('evidence')==='1'){
  requestAnimationFrame(()=>requestAnimationFrame(()=>{
    const report=document.createElement('pre');
    report.id='v104AcceptanceReport';
    report.hidden=true;
    report.textContent=JSON.stringify(window.v104AcceptanceMetrics());
    document.body.append(report);
  }));
}
</script>
</body>
</html>
`;
}

export async function currentProductionVisualFixture(){
  return buildV104PromotionVisualFixture(await readAppSource());
}

if(isDirectCliInvocation(import.meta.url)){
  await writeFile(FIXTURE_URL,await currentProductionVisualFixture());
  process.stdout.write(`${fileURLToPath(FIXTURE_URL)}\n`);
}
