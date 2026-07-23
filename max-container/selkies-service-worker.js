"use strict";

self.addEventListener("install", () => {
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(self.clients.claim());
});

self.addEventListener("push", (event) => {
  let payload = {};

  try {
    payload = event.data?.json() || {};
  } catch {
    payload = { body: event.data?.text() || "" };
  }

  const scope = self.registration.scope;
  const icon = new URL("icon.png", scope).href;
  const title = String(payload.title || "Maxofon");
  const options = {
    body: String(payload.body || "Новое сообщение в MAX"),
    data: { url: scope },
    icon,
    badge: icon,
    tag: String(payload.tag || `maxofon-${Date.now()}`),
  };

  event.waitUntil(self.registration.showNotification(title, options));
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const targetUrl = event.notification.data?.url || self.registration.scope;

  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({
      type: "window",
      includeUncontrolled: true,
    });

    for (const client of windows) {
      if (client.url.startsWith(self.registration.scope)) {
        await client.focus();
        if ("navigate" in client && client.url !== targetUrl) {
          await client.navigate(targetUrl);
        }
        return;
      }
    }

    await self.clients.openWindow(targetUrl);
  })());
});
