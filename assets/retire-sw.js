'use strict'

// Retire the pre-Zig PWA without leaving its cached application shell in control.
self.addEventListener('install', (event) => {
  event.waitUntil(self.skipWaiting())
})

self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    try {
      const names = await caches.keys()
      await Promise.all(names.map((name) => caches.delete(name)))
    } catch {}

    try {
      await self.clients.claim()
      const windows = await self.clients.matchAll({
        type: 'window',
        includeUncontrolled: true,
      })
      await Promise.all(windows.map((client) => client.navigate('/').catch(() => undefined)))
    } catch {}

  })())
})

// While activation completes, bypass every retired cache and use the Zig server.
self.addEventListener('fetch', (event) => {
  event.respondWith(fetch(event.request))
})
