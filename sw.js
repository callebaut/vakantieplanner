// Service worker: cachet de app-shell zodat de planner offline opent.
// Strategie: network-first voor same-origin GET-requests, met cache-fallback.
// Online krijg je dus altijd de nieuwste versie; offline de laatst gecachte.
// Supabase-calls (ander domein) worden bewust niet onderschept.
const CACHE = 'vakantieplanner-v1';
const ASSETS = [
  '.',
  'index.html',
  'manifest.webmanifest',
  'favicon.ico',
  'icons/favicon-16x16.png',
  'icons/favicon-32x32.png',
  'icons/apple-touch-icon.png',
  'icons/icon-192.png',
  'icons/icon-512.png'
];

self.addEventListener('install', (e)=>{
  e.waitUntil(
    caches.open(CACHE).then(c=>c.addAll(ASSETS)).then(()=>self.skipWaiting())
  );
});

self.addEventListener('activate', (e)=>{
  e.waitUntil(
    caches.keys()
      .then(keys=>Promise.all(keys.filter(k=>k!==CACHE).map(k=>caches.delete(k))))
      .then(()=>self.clients.claim())
  );
});

self.addEventListener('fetch', (e)=>{
  const url = new URL(e.request.url);
  if(e.request.method!=='GET' || url.origin!==location.origin) return;
  e.respondWith(
    fetch(e.request).then(res=>{
      const copy = res.clone();
      caches.open(CACHE).then(c=>c.put(e.request, copy));
      return res;
    }).catch(()=>
      caches.match(e.request, {ignoreSearch:true}).then(r=>r || caches.match('index.html'))
    )
  );
});
