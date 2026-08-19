'use strict';

const CACHE_PREFIX='nestly-shell-';
const CACHE_VERSION='v13-20260819-w2-polish';
const CACHE_NAME=`${CACHE_PREFIX}${CACHE_VERSION}`;
/* V289 (audit A3, G3b): the app document itself is now part of the shell, so an offline
   navigation lands in Peekaa's own "you're offline" state instead of the standalone fallback
   card. Both entries resolve to the same document (/app is a vercel rewrite of /index.html) and
   both are NAVIGATION targets, which is why they are excluded from STATIC_PATHS below. They are
   stored last and only as a set — see precacheShellDocumentsV289 — so a half-cached shell can
   never be served. */
const SHELL_DOCUMENTS=Object.freeze(['/index.html','/app']);
const APP_SHELL=Object.freeze([
  '/index.html',
  '/app',
  '/offline.html',
  '/pwa.css',
  '/pwa.js',
  '/customer-push.js',
  '/manifest.webmanifest',
  '/brand/peekaa-logo.png',
  '/brand/peekaa-mark.png',
  '/icons/peekaa-32.png',
  '/icons/peekaa-192.png',
  '/icons/peekaa-512.png',
  '/icons/peekaa-512-maskable.png',
  '/icons/apple-touch-icon.png'
]);
const STATIC_PATHS=new Set(APP_SHELL.filter(path=>path!=='/'&&!SHELL_DOCUMENTS.includes(path)));
const SENSITIVE_PREFIXES=Object.freeze([
  '/api/','/auth/','/rest/','/rpc/','/storage/','/functions/'
]);

function isSensitive(request,url){
  return request.headers.has('authorization')
    || SENSITIVE_PREFIXES.some(prefix=>url.pathname.startsWith(prefix));
}

/* V289 (audit A3, G3b). Storing the app document alone would produce a WORSE offline experience
   than the fallback card: index.html paints nothing until its scripts arrive, so a blank white
   page. The scripts are fingerprinted at build time (`npm run bundle-stamp`), so they are read
   out of the shipped document rather than hardcoded here — this stays correct across every
   rebuild. The document is written LAST, so `cache.match('/index.html')` succeeding is proof that
   everything it needs is cached too; if any asset fails, nothing is stored and offline
   navigation keeps returning offline.html exactly as before. */
async function precacheShellDocumentsV289(cache){
  const response=await fetch('/index.html',{cache:'reload'});
  if(!response.ok)throw new Error('shell document unavailable');
  const html=await response.text();
  const assets=new Set();
  for(const match of html.matchAll(/<script[^>]+src="([^"]+)"/g))assets.add(match[1]);
  for(const match of html.matchAll(/<link[^>]+rel="stylesheet"[^>]+href="([^"]+)"/g))assets.add(match[1]);
  /* The router fetches the per-surface chunk by name from this manifest, so an offline shell
     without them would render the "part of the app could not be loaded" card. The workspace
     chunk is deliberately skipped: it is ~1.2MB and every merchant screen needs the network. */
  const chunks=html.match(/id="appSurfaceChunks"[^>]*>\s*(\{[\s\S]*?\})\s*</);
  if(chunks){
    try{
      const manifest=JSON.parse(chunks[1]);
      for(const surface of ['auth','customer'])if(manifest[surface])assets.add(manifest[surface]);
    }catch{}
  }
  await cache.addAll([...assets]);
  for(const document of SHELL_DOCUMENTS){
    await cache.put(document,new Response(html,{headers:{'content-type':'text/html; charset=utf-8'}}));
  }
}

/* V289 (audit A3, G3a): skipWaiting() used to run on EVERY install, which handed control to a new
   worker the moment a deploy landed — mid-OTP, mid-QR scan, mid-form — and made pwa.js's
   isUnsafeToAutoUpdate() guard decorative. The new worker now WAITS. pwa.js sees it
   (registration.waiting / updatefound), auto-applies within ~1.2s when the screen is safe, and
   otherwise shows "A Peekaa update is ready" and waits for the tap. Either path posts
   SKIP_WAITING, which the message handler below still honours — that is the only way a waiting
   worker is promoted now. */
self.addEventListener('install',event=>{
  event.waitUntil((async()=>{
    const cache=await caches.open(CACHE_NAME);
    await cache.addAll(APP_SHELL.filter(path=>!SHELL_DOCUMENTS.includes(path)));
    try{await precacheShellDocumentsV289(cache)}catch{}
  })());
});

self.addEventListener('activate',event=>{
  event.waitUntil((async()=>{
    const keys=await caches.keys();
    const oldShells=keys.filter(key=>key.startsWith(CACHE_PREFIX)&&key!==CACHE_NAME);
    await Promise.all(oldShells.map(key=>caches.delete(key)));
    await self.clients.claim();
    /* V289 (audit A3, G3a): the forced client.navigate() loop is gone. Activation is now only
       ever reached through the guarded applyUpdate() path in pwa.js, so the page that asked for
       the update already knows to reload itself (controllerchange). Re-navigating every window
       from here reloaded tabs that had NOT consented — the second half of the same mid-OTP
       reload. The notification stays: it is how a page learns the shell version changed. */
    if(oldShells.length&&self.clients?.matchAll){
      const clients=await self.clients.matchAll({type:'window',includeUncontrolled:true});
      for(const client of clients){
        client.postMessage?.({
          type:'PEEKAA_SW_ACTIVATED',
          cacheVersion:CACHE_VERSION
        });
      }
    }
  })());
});

self.addEventListener('message',event=>{
  if(event.data?.type==='SKIP_WAITING')self.skipWaiting();
});

self.addEventListener('fetch',event=>{
  const request=event.request;
  if(request.method!=='GET')return;
  const url=new URL(request.url);
  if(url.origin!==self.location.origin||isSensitive(request,url))return;

  if(request.mode==='navigate'){
    event.respondWith((async()=>{
      try{
        return await fetch(request);
      }catch{
        const cache=await caches.open(CACHE_NAME);
        /* V289: prefer Peekaa's own shell — it knows the route, shows the offline banner and
           recovers the moment the connection returns. offline.html remains the answer whenever
           the shell was not cached in full. */
        return (await cache.match('/index.html'))||(await cache.match('/offline.html'));
      }
    })());
    return;
  }

  if(!STATIC_PATHS.has(url.pathname))return;
  event.respondWith((async()=>{
    try{
      return await fetch(request);
    }catch{
      return caches.match(request,{cacheName:CACHE_NAME});
    }
  })());
});

const CUSTOMER_PUSH_TYPES=new Set([
  'value_expiry',
  'reward_ready',
  'visit_progress',
  'birthday_benefit',
  'booking_request_received',
  'appointment_time_changed',
  'promotion_alert'
]);

function customerPushRoute(data){
  const slug=String(data?.business_slug||data?.programme_slug||'').trim();
  if(slug&&/^[a-z0-9][a-z0-9-]{0,79}$/i.test(slug))return `/#/wallet/${encodeURIComponent(slug)}`;
  if(['booking_request_received','appointment_time_changed'].includes(data?.event_type)){
    return '/#/customer/bookings';
  }
  return '/#/customer/messages';
}

self.addEventListener('push',event=>{
  event.waitUntil((async()=>{
    let payload={};
    try{payload=event.data?.json?.()||{}}catch{return}
    if(!CUSTOMER_PUSH_TYPES.has(payload.event_type))return;
    const title=String(payload.title||'Peekaa update').slice(0,120);
    const body=String(payload.body||'Open Peekaa to view your update.').slice(0,240);
    const route=customerPushRoute(payload);
    await self.registration.showNotification(title,{
      body,
      icon:'/icons/peekaa-192.png',
      badge:'/icons/peekaa-32.png',
      tag:String(payload.notification_id||`${payload.event_type}:${payload.business_slug||''}`).slice(0,160),
      renotify:false,
      data:{route,event_type:payload.event_type,business_slug:payload.business_slug||null}
    });
  })());
});

self.addEventListener('notificationclick',event=>{
  event.notification.close();
  event.waitUntil((async()=>{
    const route=customerPushRoute(event.notification.data||{});
    const target=new URL(route,self.location.origin).href;
    const windows=await self.clients.matchAll({type:'window',includeUncontrolled:true});
    const existing=windows.find(client=>new URL(client.url).origin===self.location.origin);
    if(existing){
      if(typeof existing.navigate==='function')await existing.navigate(target);
      await existing.focus();
      return;
    }
    await self.clients.openWindow(target);
  })());
});
