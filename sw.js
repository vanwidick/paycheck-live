/* Paycheck Live service worker (v2.0.0, TessDesk-style): versioned offline app shell, stale-while-revalidate.
   version.json, /api, /qr.png and /get always go to the network. localStorage (punches/settings) is never touched. */
const C='paycheck-v'+'2.0.15';
const FILES=['paycheck-live.html','paycheck-test.html','manifest-live.json','manifest-test.json','icon-live-192.png','icon-test-192.png','icon-live-512.png','icon-test-512.png','icon-live-maskable-512.png','icon-test-maskable-512.png','BebasNeue.woff2'];
self.addEventListener('install',e=>{e.waitUntil(caches.open(C).then(c=>c.addAll(FILES)).then(()=>self.skipWaiting()));});
self.addEventListener('activate',e=>{e.waitUntil(caches.keys().then(ks=>Promise.all(ks.filter(k=>k.indexOf('paycheck-v')===0&&k!==C).map(k=>caches.delete(k)))).then(()=>self.clients.claim()));});
self.addEventListener('fetch',e=>{ const req=e.request, url=new URL(req.url);
  if (req.method!=='GET' || url.origin!==self.location.origin) return;
  if (/^(\/paycheck-live)?\/(api|qr\.png|get)(\/|$)/.test(url.pathname) || /\/version\.json$/.test(url.pathname)) return;
  e.respondWith(caches.open(C).then(c=>c.match(req,{ignoreSearch:req.mode==='navigate'}).then(hit=>{
    const net=fetch(req).then(r=>{ if (r&&r.ok) c.put(req.mode==='navigate'?new Request(url.origin+url.pathname):req, r.clone()); return r; }).catch(()=>hit||Response.error());
    return hit||net; })));
});
