import Foundation

/// Sayfalara enjekte edilen betikler: video yakalama, tam ekranı Yakala oynatıcısına yönlendirme, koyu sayfa, okuma modu
enum VideoSniffer {
    static let handlerName = "yakala"

    static func script(takeover: Bool) -> String {
        "window.__yakalaTakeover = \(takeover ? "true" : "false");\n" + coreScript
    }

    private static let coreScript = #"""
    (function () {
      if (window.__yakalaInstalled) { return; }
      window.__yakalaInstalled = true;
      var seen = {};
      var mediaRe = /\.(m3u8|mp4|m4v|mov|webm|mp3|m4a)(\?|#|$)/i;
      var playlistRe = /\.m3u8(\?|#|$)/i;
      var lastPlaylist = null;
      var lastMedia = null;

      function absolute(u) {
        try { return new URL(u, location.href).href; } catch (e) { return null; }
      }

      function post(message) {
        try { window.webkit.messageHandlers.yakala.postMessage(message); } catch (e) {}
      }

      function report(u, kind, duration) {
        if (!u) { return; }
        u = absolute(String(u));
        if (!u || u.indexOf('blob:') === 0 || u.indexOf('data:') === 0) { return; }
        if (playlistRe.test(u)) { lastPlaylist = u; } else { lastMedia = u; }
        var key = u + '|' + (duration ? Math.round(duration) : '');
        if (seen[key]) { return; }
        seen[key] = true;
        post({ type: 'media', url: u, kind: kind || '', page: location.href, title: document.title || '', duration: duration || 0 });
      }

      function sourceOf(el) {
        var s = (el && (el.currentSrc || el.src)) || '';
        if (s && s.indexOf('blob:') !== 0 && s.indexOf('data:') !== 0) { return absolute(s); }
        return lastPlaylist || lastMedia;
      }

      function inspect(el) {
        if (!el) { return; }
        var d = (el.duration && isFinite(el.duration)) ? el.duration : 0;
        if (el.currentSrc) { report(el.currentSrc, 'media', d); }
        var s = el.getAttribute && el.getAttribute('src');
        if (s) { report(s, 'media', d); }
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
              if (u && mediaRe.test(u)) { report(u, 'network', 0); }
            } catch (e) {}
            return originalFetch.apply(this, arguments);
          };
        }
      } catch (e) {}

      try {
        var originalOpen = XMLHttpRequest.prototype.open;
        XMLHttpRequest.prototype.open = function (method, url) {
          try { if (url && mediaRe.test(String(url))) { report(url, 'network', 0); } } catch (e) {}
          return originalOpen.apply(this, arguments);
        };
      } catch (e) {}

      ['loadedmetadata', 'loadstart', 'durationchange'].forEach(function (name) {
        document.addEventListener(name, function (ev) { inspect(ev.target); }, true);
      });

      document.addEventListener('playing', function (ev) {
        var v = ev.target;
        inspect(v);
        var src = sourceOf(v);
        if (src) {
          post({ type: 'playing', url: src, page: location.href, title: document.title || '',
                 duration: (v.duration && isFinite(v.duration)) ? v.duration : 0 });
        }
      }, true);

      // --- Tam ekran isteğini Yakala oynatıcısına yönlendir (reklamlar hariç) ---
      function takeover(video) {
        if (!window.__yakalaTakeover || !video) { return false; }
        var d = (video.duration && isFinite(video.duration)) ? video.duration : 0;
        if (d > 0 && d < 60) { return false; } // kısa video: muhtemelen reklam
        var src = sourceOf(video);
        if (!src) { return false; }
        try { video.pause(); } catch (e) {}
        post({ type: 'fullscreen', url: src, time: video.currentTime || 0, duration: d,
               page: location.href, title: document.title || '' });
        return true;
      }

      function videoIn(el) {
        if (!el) { return null; }
        if (el.tagName === 'VIDEO') { return el; }
        return el.querySelector ? el.querySelector('video') : null;
      }

      try {
        var enter = HTMLVideoElement.prototype.webkitEnterFullscreen;
        if (enter) {
          HTMLVideoElement.prototype.webkitEnterFullscreen = function () {
            if (takeover(this)) { return; }
            return enter.apply(this, arguments);
          };
        }
        var enter2 = HTMLVideoElement.prototype.webkitEnterFullScreen;
        if (enter2) {
          HTMLVideoElement.prototype.webkitEnterFullScreen = function () {
            if (takeover(this)) { return; }
            return enter2.apply(this, arguments);
          };
        }
        ['requestFullscreen', 'webkitRequestFullscreen', 'webkitRequestFullScreen'].forEach(function (name) {
          var original = Element.prototype[name];
          if (!original) { return; }
          Element.prototype[name] = function () {
            if (takeover(videoIn(this))) { return Promise.resolve(); }
            return original.apply(this, arguments);
          };
        });
      } catch (e) {}

      document.addEventListener('webkitbeginfullscreen', function (ev) {
        var v = ev.target;
        if (v && v.tagName === 'VIDEO' && takeover(v)) {
          try { v.webkitExitFullscreen(); } catch (e) {}
        }
      }, true);

      try {
        new MutationObserver(scheduleScan).observe(document.documentElement || document, {
          childList: true, subtree: true, attributes: true, attributeFilter: ['src']
        });
      } catch (e) {}

      document.addEventListener('DOMContentLoaded', scan);
      window.addEventListener('load', scan);
    })();
    """#

    static let darkCSS = """
    html { filter: invert(0.92) hue-rotate(180deg) !important; background-color: #fff !important; }
    img, video, picture, canvas, iframe, embed, object, svg image, [style*="background-image"] {
      filter: invert(1) hue-rotate(180deg) !important;
    }
    """

    static func darkModeScript(enabled: Bool) -> String {
        let css = darkCSS.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "`", with: "")
        return """
        (function () {
          var id = 'yakala-dark-style';
          var existing = document.getElementById(id);
          if (\(enabled ? "true" : "false")) {
            if (!existing) {
              var style = document.createElement('style');
              style.id = id;
              style.textContent = `\(css)`;
              (document.head || document.documentElement).appendChild(style);
            }
          } else if (existing) {
            existing.remove();
          }
        })();
        """
    }

    static let readerScript = #"""
    (function () {
      var best = null, score = 0;
      var candidates = document.querySelectorAll('article, main, [role=main], .post, .entry-content, .article, .content, div, section');
      for (var i = 0; i < candidates.length; i++) {
        var el = candidates[i];
        var ps = el.querySelectorAll(':scope > p, :scope > div > p');
        var len = 0;
        for (var j = 0; j < ps.length; j++) { len += (ps[j].innerText || '').length; }
        if (len > score) { score = len; best = el; }
      }
      var root = best || document.body;
      var items = [];
      var nodes = root.querySelectorAll('h1, h2, h3, p, li, blockquote');
      for (var k = 0; k < nodes.length && items.length < 800; k++) {
        var t = (nodes[k].innerText || '').trim();
        if (t.length > 1) { items.push({ tag: nodes[k].tagName.toLowerCase(), text: t }); }
      }
      return JSON.stringify({ title: document.title || '', items: items });
    })();
    """#
}
