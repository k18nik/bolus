const CACHE='bolus-shell-v2';
self.addEventListener('install',event=>{event.waitUntil(caches.open(CACHE).then(cache=>cache.addAll(['/','/icon.svg','/mascot-cat.png','/manifest.webmanifest'])).then(()=>self.skipWaiting()));});
self.addEventListener('activate',event=>{event.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(k=>k!==CACHE).map(k=>caches.delete(k)))).then(()=>self.clients.claim()));});
self.addEventListener('fetch',event=>{const url=new URL(event.request.url);if(event.request.method!=='GET'||url.origin!==self.location.origin||url.pathname.startsWith('/api/')||url.searchParams.has('_rsc'))return;
 if(event.request.mode==='navigate'){event.respondWith(fetch(event.request).catch(()=>caches.match('/')));return;}
 if(url.pathname.startsWith('/_next/static/')||url.pathname.startsWith('/icon')||url.pathname==='/mascot-cat.png'){event.respondWith(caches.match(event.request).then(cached=>cached||fetch(event.request).then(response=>{if(response.ok){const copy=response.clone();caches.open(CACHE).then(c=>c.put(event.request,copy));}return response;})));}
});
self.addEventListener('message',event=>{if(event.data?.type==='CACHE_SHELL'&&Array.isArray(event.data.urls)){const urls=event.data.urls.filter(u=>typeof u==='string'&&u.startsWith('/_next/static/'));event.waitUntil(caches.open(CACHE).then(c=>Promise.all(urls.map(u=>c.add(u).catch(()=>{})))));}});
