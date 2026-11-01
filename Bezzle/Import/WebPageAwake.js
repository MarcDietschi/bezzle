// Run in a page Bezzle reads, before the page's own scripts. Every IntersectionObserver is
// told at once that what it watches is in view, and never that it has left. Pictures that load
// as they are scrolled to load, and what fades or slides in as it comes into view is there,
// wherever on the page it is, when the page is read from its top.
(() => {
  // No scroll bars from the first, so the page is laid out as wide as it is read, scripts and all.
  const bars = document.createElement('style');
  bars.textContent = 'html, * { scrollbar-width: none !important; } ::-webkit-scrollbar { display: none !important; width: 0 !important; height: 0 !important; }';
  (document.head || document.documentElement).appendChild(bars);

  const Native = window.IntersectionObserver;
  if (!Native || Native.__bezzle) return;
  class SeesAll {
    constructor(callback, options) {
      this.callback = callback;
      this.options = options || {};
      this.watched = new Set();
    }
    observe(target) {
      if (!target || this.watched.has(target)) return;
      this.watched.add(target);
      setTimeout(() => {
        if (!this.watched.has(target)) return;
        const r = target.getBoundingClientRect();
        const entry = {
          target, isIntersecting: true, intersectionRatio: 1, time: performance.now(),
          boundingClientRect: r, intersectionRect: r, rootBounds: new DOMRectReadOnly(0, 0, innerWidth, innerHeight),
        };
        try { this.callback.call(this, [entry], this); } catch (e) { setTimeout(() => { throw e; }); }
      }, 0);
    }
    unobserve(target) { this.watched.delete(target); }
    disconnect() { this.watched.clear(); }
    takeRecords() { return []; }
    get root() { return this.options.root || null; }
    get rootMargin() { return this.options.rootMargin || '0px 0px 0px 0px'; }
    get thresholds() { const t = this.options.threshold; return Array.isArray(t) ? t : [t || 0]; }
  }
  SeesAll.__bezzle = true;
  window.IntersectionObserver = SeesAll;

  // A WebGL canvas keeps what it drew, so it can be read back whenever Bezzle asks, rather
  // than only in the moment it is drawn.
  const getContext = HTMLCanvasElement.prototype.getContext;
  HTMLCanvasElement.prototype.getContext = function (type, attributes) {
    if (/^(webgl2?|experimental-webgl)$/.test(type)) attributes = Object.assign({}, attributes, { preserveDrawingBuffer: true });
    return getContext.call(this, type, attributes);
  };
})();
