// Google Analytics for garagerag.app, loaded only after the visitor agrees.
// Nothing is requested from Google until "Allow" is pressed; the choice is kept
// in this browser's localStorage and can be changed from the footer link.
(function () {
  var MEASUREMENT_ID = 'G-85TQVVK80M';
  var KEY = 'garage-analytics-consent';
  var loaded = false;

  function read() {
    try { return window.localStorage.getItem(KEY); } catch (e) { return null; }
  }

  function write(value) {
    try { window.localStorage.setItem(KEY, value); } catch (e) { /* choice lasts this page only */ }
  }

  function load() {
    if (loaded) return;
    loaded = true;
    window.dataLayer = window.dataLayer || [];
    window.gtag = function () { window.dataLayer.push(arguments); };
    window.gtag('js', new Date());
    window.gtag('config', MEASUREMENT_ID);
    var s = document.createElement('script');
    s.async = true;
    s.src = 'https://www.googletagmanager.com/gtag/js?id=' + MEASUREMENT_ID;
    document.head.appendChild(s);
  }

  function banner() { return document.getElementById('analytics-consent'); }

  function show() { var b = banner(); if (b) b.hidden = false; }

  function hide() { var b = banner(); if (b) b.hidden = true; }

  // Global Privacy Control counts as a standing "no".
  var gpc = navigator.globalPrivacyControl === true;
  var choice = read();
  if (choice === 'granted' && !gpc) load();

  document.addEventListener('DOMContentLoaded', function () {
    var allow = document.getElementById('analytics-allow');
    var decline = document.getElementById('analytics-decline');
    var settings = document.getElementById('analytics-settings');
    if (allow) allow.addEventListener('click', function () { write('granted'); hide(); load(); });
    if (decline) decline.addEventListener('click', function () {
      write('denied');
      hide();
      // Already loaded on this page: stop further hits until the next page load.
      if (loaded) window['ga-disable-' + MEASUREMENT_ID] = true;
    });
    if (settings) settings.addEventListener('click', function (e) { e.preventDefault(); show(); });
    if (!gpc && choice !== 'granted' && choice !== 'denied') show();
  });
})();
