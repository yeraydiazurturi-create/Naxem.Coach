/* Nexum · service worker (notificaciones push) */
self.addEventListener("install",e=>{self.skipWaiting()});
self.addEventListener("activate",e=>{e.waitUntil(self.clients.claim())});
self.addEventListener("push",e=>{let d={};try{d=e.data.json()}catch(_){d={title:"Nexum",body:e.data?e.data.text():""}}
e.waitUntil(self.registration.showNotification(d.title||"Nexum",{body:d.body||"",icon:"icon-192.png",badge:"icon-192.png",tag:d.tag||undefined,renotify:!!d.tag,data:{url:d.url||"./"}}))});
self.addEventListener("notificationclick",e=>{e.notification.close();const u=new URL((e.notification.data&&e.notification.data.url)||"./",self.registration.scope).href;
e.waitUntil(self.clients.matchAll({type:"window",includeUncontrolled:true}).then(l=>{for(const c of l){if("focus" in c){c.postMessage({nx:"go",url:u});return c.focus()}}return self.clients.openWindow(u)}))});
