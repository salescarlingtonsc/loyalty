'use strict';

const CACHE_PREFIX='nestly-shell-';
const CACHE_VERSION='v3-20260728-auth-controls';
const CACHE_NAME=`${CACHE_PREFIX}${CACHE_VERSION}`;
const APP_SHELL=Object.freeze([
  '/offline.html',
  '/pwa.css',
  '/pwa.js',
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
