'use strict';

const CACHE_PREFIX='nestly-shell-';
const CACHE_VERSION='v3-20260728-auth-controls';
const CACHE_NAME=`${CACHE_PREFIX}${CACHE_VERSION}`;
const APP_SHELL=Object.freeze([
  '/offline.html',
  '/pwa.css',
  '/pwa.js',
  '/customer-push.js',
  '/manifest.webmanifest',
  '/icons/nestly-192.png',
  '/icons/nestly-512.png',
  '/icons/apple-touch-icon.png'
]);
const STATIC_PATHS=new Set(APP_SHELL.filter(path=>path!=='/'));
const SENSITIVE_PREFIXES=Object.freeze([
  '/api/','/auth/','/rest/','/rpc/','/storage/','/functions/'
]);

function isSensitive(request,url){
  return request.headers.has('authorization')
    || SENSITIVE_PREFIXES.some(prefix=>url.pathname.startsWith(prefix));
}

self.addEventListener('install',event=>{
  event.waitUntil(caches.open(CACHE_NAME).then(cache=>cache.addAll(APP_SHELL)));
});

self.addEventListener('activate',event=>{
  event.waitUntil((async()=>{
    const keys=await caches.keys();
    await Promise.all(keys
      .filter(key=>key.startsWith(CACHE_PREFIX)&&key!==CACHE_NAME)
      .map(key=>caches.delete(key)));
    await self.clients.claim();
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
        return cache.match('/offline.html');
      }
    })());
    return;
  }

  if(!STATIC_PATHS.has(url.pathname))return;
  event.respondWith((async()=>{
    const cached=await caches.match(request,{cacheName:CACHE_NAME});
    if(cached)return cached;
    return fetch(request);
  })());
});

const CUSTOMER_PUSH_TYPES=new Set([
  'value_expiry',
  'reward_ready',
  'visit_progress',
  'birthday_benefit',
  'booking_request_received',
  'appointment_time_changed'
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
    const title=String(payload.title||'Nestly update').slice(0,120);
    const body=String(payload.body||'Open Nestly to view your update.').slice(0,240);
    const route=customerPushRoute(payload);
    await self.registration.showNotification(title,{
      body,
      icon:'/icons/nestly-192.png',
      badge:'/icons/nestly-192.png',
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
