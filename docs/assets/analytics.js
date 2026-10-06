// Download events for Google Analytics, loaded by _layouts/default.html on garagerag.app only.
//
// Every way to get Garage (the installer, a release page, TestFlight, the Mac App Store, the Windows
// alpha) sends one `download` event, named by `method`, so one key event in GA counts them all and
// its breakdown says which way people chose. Links are classified at click time, because
// download.js rewrites the landing page's buttons after the page loads.
(function () {
  'use strict';

  var APP_STORE_ID = 'id6811306880';

  function classify(url) {
    var host = url.hostname;
    var path = url.pathname;
    if (host === 'testflight.apple.com') { return 'testflight'; }
    if (host === 'apps.apple.com') { return path.indexOf(APP_STORE_ID) !== -1 ? 'app_store' : null; }
    if (host === 'github.com' || host === 'objects.githubusercontent.com') {
      if (!/\/garage-rag\/releases(\/|$)/.test(path)) { return null; }
      var file = /\/releases\/download\/[^/]+\/([^/]+)$/.exec(path);
      if (!file) { return 'release_page'; }
      var ext = /\.([a-z0-9]+)$/i.exec(file[1]);
      return ext ? ext[1].toLowerCase() : 'file';
    }
    return null;
  }

  function platform(method, url) {
    if (method === 'exe' || method === 'msi' || /windows/i.test(url.pathname + location.pathname)) { return 'windows'; }
    return 'macos';
  }

  function onClick(event) {
    var a = event.target.closest && event.target.closest('a[href]');
    if (!a || typeof window.gtag !== 'function') { return; }
    var url;
    try { url = new URL(a.href, location.href); } catch (e) { return; }
    var method = classify(url);
    if (!method) { return; }
    window.gtag('event', 'download', {
      method: method,
      platform: platform(method, url),
      link_id: a.id || undefined,
      link_url: url.href
    });
  }

  document.addEventListener('click', onClick, true);
  document.addEventListener('auxclick', function (event) { if (event.button === 1) { onClick(event); } }, true);
})();
