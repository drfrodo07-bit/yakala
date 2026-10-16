import Foundation

/// Sayfalara enjekte edilen ve oynatılan videoların adreslerini yakalayan betik
enum VideoSniffer {
    static let handlerName = "yakala"

    static let script = #"""
    (function () {
      if (window.__yakalaInstalled) { return; }
      window.__yakalaInstalled = true;
      var seen = {};
      var mediaRe = /\.(m3u8|mp4|m4v|mov|webm|mp3|m4a)(\?|#|$)/i;

      function absolute(u) {
        try { return new URL(u, location.href).href; } catch (e) { return null; }
      }

      function report(u, kind) {
        if (!u) { return; }
        u = absolute(String(u));
        if (!u || u.indexOf('blob:') === 0 || u.indexOf('data:') === 0) { return; }
        if (seen[u]) { return; }
        seen[u] = true;
        try {
          window.webkit.messageHandlers.yakala.postMessage({
            url: u, kind: kind || '', page: location.href, title: document.title || ''
          });
        } catch (e) {}
      }

      function inspect(el) {
        if (!el) { return; }
        if (el.currentSrc) { report(el.currentSrc, 'media'); }
        var s = el.getAttribute && el.getAttribute('src');
        if (s) { report(s, 'media'); }
      }

      var scheduled = false;
      function scan() {
        scheduled = false;
        var nodes = document.querySelectorAll('video, audio, video source, audio source');
        for (var i = 0; i < nodes.length; i++) { inspect(nodes[i]); }
      }
      function scheduleScan() {
        if (!scheduled) { scheduled = true; setTimeout(scan, 400); }
      }

      try {
        var originalFetch = window.fetch;
        if (originalFetch) {
          window.fetch = function (input, init) {
            try {
              var u = (typeof input === 'string') ? input : (input && input.url);
              if (u && mediaRe.test(u)) { report(u, 'network'); }
            } catch (e) {}
            return originalFetch.apply(this, arguments);
          };
        }
      } catch (e) {}

      try {
        var originalOpen = XMLHttpRequest.prototype.open;
        XMLHttpRequest.prototype.open = function (method, url) {
          try { if (url && mediaRe.test(String(url))) { report(url, 'network'); } } catch (e) {}
          return originalOpen.apply(this, arguments);
        };
      } catch (e) {}

      ['play', 'playing', 'loadedmetadata', 'loadstart'].forEach(function (name) {
        document.addEventListener(name, function (ev) { inspect(ev.target); }, true);
      });

      try {
        new MutationObserver(scheduleScan).observe(document.documentElement || document, {
          childList: true, subtree: true, attributes: true, attributeFilter: ['src']
        });
      } catch (e) {}

      document.addEventListener('DOMContentLoaded', scan);
      window.addEventListener('load', scan);
    })();
    """#
}
