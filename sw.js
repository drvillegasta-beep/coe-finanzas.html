// COE Finanzas · service worker: avisos push en computadora y teléfono
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));
self.addEventListener('push', e => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch { d = { body: e.data ? e.data.text() : '' }; }
  // Solo el logo, el motivo (título) y de qué se trata (cuerpo)
  e.waitUntil(self.registration.showNotification(d.title || 'Aviso pendiente', {
    body: d.body || '', tag: d.tag || 'coe-fin', renotify: true, requireInteraction: true,
    icon: 'assets/icon-192.png', badge: 'assets/icon-192.png', silent: false, vibrate: [200, 100, 200],
    data: { url: d.url || './coe-finanzas-v3.html#dash' }
  }));
});
self.addEventListener('notificationclick', e => {
  e.notification.close();
  const url = new URL((e.notification.data && e.notification.data.url) || './coe-finanzas-v3.html#dash', self.location.href).href;
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(ws => {
    for (const w of ws) if (w.url.includes('coe-finanzas-v3.html')) { w.focus(); w.postMessage({ tipo: 'abrir', url }); return; }
    return self.clients.openWindow(url);
  }));
});
