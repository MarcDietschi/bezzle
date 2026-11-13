// Bezzle's reader of web pages. It runs in a page laid out at the width a design is wanted at,
// in a world of its own beside the page's scripts, and takes the page apart into what Bezzle
// draws: boxes with their fills, borders, corners and shadows; words in lines, each line where
// the browser set it; pictures; and outlines from SVG. What it cannot take apart, it marks to be
// photographed (see `isolate`).
//
// Everything is measured as the page is laid out with no element turned or moved by a
// transform; each element's transforms are worked out on their own and handed over as a matrix,
// so that Bezzle can turn the layer as the page turns it.
(() => {
  'use strict';
  if (window.__bezzle) return;
  const B = (window.__bezzle = {});

  // MARK: What was only come close to

  let notes = {};
  const note = (what) => { notes[what] = (notes[what] || 0) + 1; };

  // MARK: Colours

  const colorCanvas = document.createElement('canvas');
  colorCanvas.width = colorCanvas.height = 1;
  const cctx = colorCanvas.getContext('2d', { willReadFrequently: true });
  const colorCache = new Map();

  /// A colour as computed styles give it, as four numbers 0…1 in sRGB; transparent for none.
  function rgba(str) {
    if (!str) return [0, 0, 0, 0];
    str = str.trim();
    if (str === 'transparent' || str === 'none' || str === '' || str === 'initial') return [0, 0, 0, 0];
    let c = colorCache.get(str);
    if (c) return c;
    const m = /^rgba?\(\s*([\d.]+)[,\s]+([\d.]+)[,\s]+([\d.]+)(?:\s*[,/]\s*([\d.]+%?))?\s*\)$/.exec(str);
    if (m) {
      const a = m[4] === undefined ? 1 : m[4].endsWith('%') ? parseFloat(m[4]) / 100 : +m[4];
      c = [m[1] / 255, m[2] / 255, m[3] / 255, a];
    } else {
      // Wider notations (oklch, lab, color(display-p3 …)) are drawn and read back.
      let alpha = 1;
      let opaque = str;
      const am = /\/\s*([\d.]+%?)\s*\)$/.exec(str);
      if (am) {
        alpha = am[1].endsWith('%') ? parseFloat(am[1]) / 100 : +am[1];
        opaque = str.replace(/\/\s*[\d.]+%?\s*\)$/, ')');
      }
      cctx.clearRect(0, 0, 1, 1);
      cctx.fillStyle = '#000';
      cctx.fillStyle = opaque;
      cctx.fillRect(0, 0, 1, 1);
      const d = cctx.getImageData(0, 0, 1, 1).data;
      c = [d[0] / 255, d[1] / 255, d[2] / 255, (alpha * d[3]) / 255];
    }
    colorCache.set(str, c);
    return c;
  }

  const colorFunction = /\b(?:rgba?|hsla?|hwb|lab|lch|oklab|oklch|color)\([^()]*\)|\btransparent\b|\bcurrentcolor\b/gi;

  /// A computed value with every colour in it written as rgba(), 0…255, so Bezzle reads one notation.
  function plainColors(str, current) {
    if (!str) return str;
    return str.replace(colorFunction, (c) => {
      const v = /^currentcolor$/i.test(c) ? rgba(current) : rgba(c);
      return `rgba(${v[0] * 255}, ${v[1] * 255}, ${v[2] * 255}, ${v[3]})`;
    });
  }

  // MARK: The page as it is drawn

  /// What an element holds as it is drawn: what an open shadow root holds in its place, and what
  /// a slot is given in place of the slot.
  function kids(node) {
    const src = node.shadowRoot ? node.shadowRoot.childNodes : node.childNodes;
    const out = [];
    for (const c of src) {
      if (c.nodeType === 1 && c.localName === 'slot') {
        const given = c.assignedNodes({ flatten: true });
        for (const g of given.length ? given : c.childNodes) out.push(g);
      } else {
        out.push(c);
      }
    }
    return out;
  }

  function* elements(root) {
    for (const c of kids(root)) {
      if (c.nodeType !== 1) continue;
      yield c;
      yield* elements(c);
    }
  }

  const replaced = new Set(['img', 'svg', 'video', 'canvas', 'iframe', 'embed', 'object', 'input', 'textarea', 'select', 'button', 'math', 'audio', 'meter', 'progress']);
  const skipped = new Set(['script', 'style', 'noscript', 'template', 'head', 'meta', 'link', 'title', 'base', 'datalist', 'bz-pseudo-gone']);

  // MARK: Transforms

  const transforms = new WeakMap();
  const isIdentity = (m) => m.a === 1 && m.b === 0 && m.c === 0 && m.d === 1 && m.e === 0 && m.f === 0;

  /// Notes an element's transforms before they are taken away for measuring, and marks it so they are.
  function keepTransform(el, cs) {
    if (el instanceof SVGElement && el.localName !== 'svg') return;
    // A transform does nothing to an inline box that is not a picture.
    if ((cs.display === 'inline' && !replaced.has(el.localName)) || cs.display === 'none' || cs.display === 'contents') return;
    const t = cs.transform, tr = cs.translate, ro = cs.rotate, sc = cs.scale;
    const none = (v) => !v || v === 'none';
    if (none(t) && none(tr) && none(ro) && none(sc)) return;
    transforms.set(el, { t, tr, ro, sc, origin: cs.transformOrigin });
    el.setAttribute('data-bz-tf', '');
  }

  function cssList(v) { return v.trim().split(/\s+/).join(', '); }

  /// An element's own transform in page coordinates, about its origin, its box as laid out.
  function localMatrix(tf, box) {
    const o = (tf.origin || '0px 0px').split(/\s+/).map(parseFloat);
    const ox = box[0] + (o[0] || 0), oy = box[1] + (o[1] || 0);
    let m = new DOMMatrix().translateSelf(ox, oy);
    try {
      if (tf.tr && tf.tr !== 'none') {
        // Percentages are of the box, which DOMMatrix cannot know.
        const p = tf.tr.trim().split(/\s+/).map((v, i) => (v.endsWith('%') ? `${(parseFloat(v) / 100) * (i === 0 ? box[2] : box[3])}px` : v));
        m.multiplySelf(new DOMMatrix(p.length > 2 ? `translate3d(${p.join(', ')})` : `translate(${p.join(', ')})`));
      }
      if (tf.ro && tf.ro !== 'none') {
        const p = tf.ro.trim().split(/\s+/);
        if (p.length === 1) m.multiplySelf(new DOMMatrix(`rotate(${p[0]})`));
        else if (p.length === 2) {
          const axis = { x: '1, 0, 0', y: '0, 1, 0', z: '0, 0, 1' }[p[0]] || '0, 0, 1';
          m.multiplySelf(new DOMMatrix(`rotate3d(${axis}, ${p[1]})`));
        } else m.multiplySelf(new DOMMatrix(`rotate3d(${p.slice(0, 3).join(', ')}, ${p[3]})`));
      }
      if (tf.sc && tf.sc !== 'none') m.multiplySelf(new DOMMatrix(`scale(${cssList(tf.sc)})`));
      if (tf.t && tf.t !== 'none') m.multiplySelf(new DOMMatrix(tf.t));
    } catch (e) {
      return null;
    }
    m.translateSelf(-ox, -oy);
    if (!m.is2D) note('3d');
    return new DOMMatrix([m.a, m.b, m.c, m.d, m.e, m.f]);
  }

  const flat = (m) => (m && !isIdentity(m) ? [m.a, m.b, m.c, m.d, m.e, m.f] : undefined);

  // MARK: Measuring type

  const ascents = new Map();
  let meter = null;

  function ascentOf(cs) { return metricsOf(cs).a; }

  /// How far below the top of its letters' box a font sets its baseline, and how far below
  /// that the box ends, as WebKit lays it out: measured once a font, in a box apart from the
  /// page so nothing in it moves.
  function metricsOf(cs) {
    const key = `${cs.fontStyle}|${cs.fontWeight}|${cs.fontSize}|${cs.fontFamily}|${cs.fontStretch}|${cs.fontVariationSettings}`;
    let a = ascents.get(key);
    if (a !== undefined) return a;
    if (!meter) {
      meter = document.createElement('bz-meter');
      meter.style.cssText = 'position:absolute!important;left:-30000px!important;top:0!important;visibility:hidden!important;white-space:nowrap!important;line-height:normal!important;margin:0!important;padding:0!important;border:0!important;display:block!important;transform:none!important';
      document.documentElement.appendChild(meter);
    }
    const s = meter.style;
    s.setProperty('font-family', cs.fontFamily, 'important');
    s.setProperty('font-size', cs.fontSize, 'important');
    s.setProperty('font-weight', cs.fontWeight, 'important');
    s.setProperty('font-style', cs.fontStyle, 'important');
    s.setProperty('font-stretch', cs.fontStretch, 'important');
    s.setProperty('font-variation-settings', cs.fontVariationSettings, 'important');
    meter.textContent = '';
    const t = document.createTextNode('H Hxg');
    const probe = document.createElement('bz-probe');
    probe.style.cssText = 'display:inline-block!important;width:0!important;height:0!important;vertical-align:baseline!important';
    meter.append(t, probe);
    const r = document.createRange();
    r.setStart(t, 0);
    r.setEnd(t, 1);
    const rect = r.getClientRects()[0];
    r.setStart(t, 1);
    r.setEnd(t, 2);
    const space = r.getClientRects()[0];
    const base = probe.getBoundingClientRect().bottom;
    const size = parseFloat(cs.fontSize) || 16;
    a = rect ? { a: base - rect.top, d: rect.bottom - base, s: space ? space.width : size * 0.25 } : { a: size * 0.8, d: size * 0.2, s: size * 0.25 };
    ascents.set(key, a);
    return a;
  }

  // MARK: Fonts

  const families = new Map();
  const generic = new Set(['serif', 'sans-serif', 'monospace', 'cursive', 'fantasy', 'system-ui', '-apple-system', 'blinkmacsystemfont', 'ui-sans-serif', 'ui-serif', 'ui-monospace', 'ui-rounded', 'emoji', 'math', 'fangsong']);
  let fontMeasure = null;

  function splitFamilies(list) {
    const out = [];
    for (const m of list.matchAll(/"([^"]*)"|'([^']*)'|([^,]+)/g)) {
      const f = (m[1] ?? m[2] ?? m[3] ?? '').trim();
      if (f) out.push(f);
    }
    return out;
  }

  /// Whether a family is there to draw with, the page's own or one on the Mac: letters in it
  /// come out a different width from those of the generic families.
  function available(family) {
    if (families.has(family)) return families.get(family);
    if (!fontMeasure) fontMeasure = document.createElement('canvas').getContext('2d');
    const sample = 'mmmmmmmmmmlliWW@#0123456789abcdefghijklmnop';
    let yes = false;
    for (const base of ['monospace', 'serif', 'sans-serif']) {
      fontMeasure.font = `72px ${base}`;
      const plain = fontMeasure.measureText(sample).width;
      fontMeasure.font = `72px "${family.replace(/"/g, '\\"')}", ${base}`;
      if (Math.abs(fontMeasure.measureText(sample).width - plain) > 0.01) { yes = true; break; }
    }
    families.set(family, yes);
    return yes;
  }

  function isWebFont(family) {
    const lower = family.toLowerCase();
    for (const f of document.fonts) {
      if (f.status === 'loaded' && f.family.replace(/^["']|["']$/g, '').toLowerCase() === lower) return true;
    }
    return false;
  }

  const iconFamily = /icon|awesome|glyph|material symbols|ionicons|feather|fontello|icomoon|dashicons|genericons|remixicon|tabler|phosphor|lucide|boxicons|themify|simple-line|linearicons|entypo|typicons|octicons|codicon|eicons|socicon|fa-brands|fa-solid|fa-regular/i;
  const privateUse = /[-]|[\u{F0000}-\u{FFFFD}]/u;

  /// Whether words in this style are pictures drawn by an icon font, which Bezzle will not have.
  function isIcon(cs, text) {
    if (text && privateUse.test(text)) return true;
    const first = splitFamilies(cs.fontFamily)[0] || '';
    return iconFamily.test(first);
  }

  // MARK: Box values

  function px(v) { const n = parseFloat(v); return Number.isFinite(n) ? n : 0; }

  /// A short name for what a photograph will show, alike for things drawn alike.
  function hash(s) {
    let h = 5381;
    for (let i = 0; i < s.length; i++) h = ((h * 33) ^ s.charCodeAt(i)) >>> 0;
    return `${h.toString(36)}${s.length.toString(36)}`;
  }

  /// Splits a comma list at its top level, so commas inside functions stay where they are.
  function splitTop(str) {
    const out = [];
    let depth = 0, from = 0, quote = null;
    for (let i = 0; i < str.length; i++) {
      const ch = str[i];
      if (quote) { if (ch === quote && str[i - 1] !== '\\') quote = null; continue; }
      if (ch === '"' || ch === "'") quote = ch;
      else if (ch === '(') depth++;
      else if (ch === ')') depth--;
      else if (ch === ',' && depth === 0) { out.push(str.slice(from, i).trim()); from = i + 1; }
    }
    out.push(str.slice(from).trim());
    return out;
  }

  /// The four corners, each across and down, as laid out: percentages taken of the box, and all
  /// shrunk alike when they would overlap.
  function radii(cs, w, h) {
    const corner = (v) => {
      const p = v.split(/\s+/);
      const one = (s, of) => (s.endsWith('%') ? (parseFloat(s) / 100) * of : px(s));
      return [one(p[0], w), one(p[1] ?? p[0], h)];
    };
    const r = [corner(cs.borderTopLeftRadius), corner(cs.borderTopRightRadius), corner(cs.borderBottomRightRadius), corner(cs.borderBottomLeftRadius)];
    if (r.every((c) => c[0] <= 0 || c[1] <= 0)) return undefined;
    let f = 1;
    const fit = (len, a, b) => { if (a + b > len && a + b > 0) f = Math.min(f, len / (a + b)); };
    fit(w, r[0][0], r[1][0]);
    fit(w, r[3][0], r[2][0]);
    fit(h, r[0][1], r[3][1]);
    fit(h, r[1][1], r[2][1]);
    return r.flatMap((c) => (c[0] <= 0 || c[1] <= 0 ? [0, 0] : [c[0] * f, c[1] * f]));
  }

  function side(width, style, color) {
    const w = px(width);
    if (w <= 0 || style === 'none' || style === 'hidden') return null;
    const c = rgba(color);
    if (c[3] <= 0) return null;
    return { w, s: style, c };
  }

  // MARK: Pictures

  let images = [];
  const imageIndex = new Map();

  function imageID(url) {
    if (!url) return undefined;
    let i = imageIndex.get(url);
    if (i === undefined) {
      i = images.length;
      images.push(url);
      imageIndex.set(url, i);
    }
    return i;
  }

  /// The largest of the pictures an <img> offers, up to three times as wide as it is shown.
  function bestSource(img, shownWidth) {
    let best = img.currentSrc || img.src;
    const set = img.getAttribute('srcset');
    if (!set || img.closest('picture')) return best;
    let bestW = 0;
    for (const part of splitTop(set)) {
      const [u, d] = part.trim().split(/\s+/);
      if (!u) continue;
      let w = 0;
      if (d && d.endsWith('w')) w = parseFloat(d);
      else if (d && d.endsWith('x')) w = parseFloat(d) * (img.naturalWidth || shownWidth);
      else w = img.naturalWidth || shownWidth;
      if (w > bestW && (bestW < shownWidth * 3 || w <= shownWidth * 3)) {
        try { best = new URL(u, document.baseURI).href; bestW = w; } catch (e) {}
      }
    }
    return best;
  }

  function backgroundLayers(cs, el) {
    const image = cs.backgroundImage;
    if (!image || image === 'none') return undefined;
    const list = splitTop(image);
    const pick = (v, i) => { const l = splitTop(v || ''); return l[i % l.length] || ''; };
    const out = [];
    list.forEach((layer, i) => {
      if (layer === 'none') return;
      const l = {
        size: pick(cs.backgroundSize, i),
        x: pick(cs.backgroundPositionX, i),
        y: pick(cs.backgroundPositionY, i),
        rep: pick(cs.backgroundRepeat, i),
        origin: pick(cs.backgroundOrigin, i),
        clip: pick(cs.backgroundClip || cs.webkitBackgroundClip, i),
        blend: pick(cs.backgroundBlendMode, i),
      };
      const url = /^url\(\s*["']?(.*?)["']?\s*\)$/.exec(layer);
      if (url) {
        l.img = imageID(url[1]);
        imageOwners.set(l.img, imageOwners.get(l.img) ?? el);
      } else if (/gradient\(/.test(layer)) {
        l.grad = plainColors(layer, cs.color);
      } else {
        // image-set(), cross-fade(), element(): a picture of the box shows them.
        l.other = layer.slice(0, 40);
      }
      out.push(l);
    });
    return out.length ? out : undefined;
  }

  // MARK: Elements

  let els = [];
  const imageOwners = new Map();
  const ids = new WeakMap();
  function register(el) {
    let id = ids.get(el);
    if (id === undefined) { id = els.length; els.push(el); ids.set(el, id); }
    return id;
  }

  const sx = () => window.scrollX, sy = () => window.scrollY;

  /// A name for the layer an element becomes: what it says it is, or nothing, for Bezzle to name.
  function label(el) {
    const a = el.getAttribute('aria-label') || (el.localName === 'img' ? el.getAttribute('alt') : null) || el.getAttribute('title');
    if (a && a.trim()) return a.trim().slice(0, 60);
    if (el.id && /^[A-Za-z][\w-]{1,40}$/.test(el.id) && !/\d{3,}/.test(el.id)) return el.id;
    for (const c of el.classList) {
      if (c.length < 3 || c.length > 32) continue;
      if (/[:\[\]/@!]|\d{2,}|^(js-|is-|has-|css-|sc-|jsx-|svelte-|tw-|ng-)/.test(c)) continue;
      if (/^-?(flex|grid|block|inline|hidden|relative|absolute|fixed|sticky|static|container|row|col|clearfix|w-|h-|p[xytrbl]?-|m[xytrbl]?-|text-|bg-|border|rounded|shadow|font-|leading-|tracking-|items-|justify-|gap-|space-|z-|top-|left-|right-|bottom-|inset-|overflow|opacity-|transition|duration-|ease-|transform|translate|scale-|rotate-|object-|max-|min-|sr-only|d-|align-|order-|self-|place-|content-|cursor-|select-|pointer-|ring|outline|decoration-|underline|uppercase|lowercase|capitalize|italic|truncate|whitespace|break-|aspect-|shrink|grow|basis-|wrap|nowrap)/.test(c)) continue;
      return c;
    }
    return undefined;
  }

  function isHidden(el, cs, w, h) {
    // Words kept for screen readers only, cut away to nothing.
    if (cs.clip === 'rect(0px, 0px, 0px, 0px)' || (cs.clipPath && /inset\(50%/.test(cs.clipPath))) return true;
    if (w <= 1 && h <= 1 && cs.overflow !== 'visible' && cs.position === 'absolute') return true;
    return false;
  }

  const inlineDisplays = new Set(['inline']);
  const atomicInline = new Set(['inline-block', 'inline-flex', 'inline-grid', 'inline-table', 'ruby']);

  /// The page as items, from an element down.
  function walk(el, parentMatrix, fixed) {
    if (skipped.has(el.localName) || el.hasAttribute('data-bz-hide')) return null;
    const cs = getComputedStyle(el);
    if (cs.display === 'none') return null;
    if (cs.display === 'contents') {
      return { contents: true, kids: content(el, cs, parentMatrix, fixed, null) };
    }
    const opacity = parseFloat(cs.opacity);
    if (opacity <= 0.001) return null;
    const r = el.getBoundingClientRect();
    if (isHidden(el, cs, r.width, r.height)) return null;
    const box = [r.left + sx(), r.top + sy(), r.width, r.height];
    const tf = transforms.get(el);
    let matrix = parentMatrix;
    if (tf) {
      const own = localMatrix(tf, box);
      if (own) matrix = parentMatrix ? parentMatrix.multiply(own) : own;
    }
    const isFixed = fixed || cs.position === 'fixed';
    const item = { t: 'el', id: register(el), tag: el.localName, x: box[0], y: box[1], w: box[2], h: box[3] };
    if (isFixed) item.fixed = true;
    const m = flat(matrix);
    if (m) item.m = m;
    const name = label(el);
    if (name) item.label = name;

    // Where it is painted among its neighbours.
    if (cs.position !== 'static') item.pos = cs.position;
    if (cs.zIndex !== 'auto' && (cs.position !== 'static' || /flex|grid/.test(getComputedStyle(el.parentElement || el).display))) item.z = parseInt(cs.zIndex, 10) || 0;
    if (opacity < 1 || tf || cs.filter !== 'none' || cs.mixBlendMode !== 'normal' || cs.isolation === 'isolate' || (cs.clipPath && cs.clipPath !== 'none')) item.sc = true;
    if (cs.float !== 'none') item.fl = true;
    if (atomicInline.has(cs.display) || (inlineDisplays.has(cs.display) && replaced.has(el.localName))) item.inl = true;

    if (opacity < 1) item.op = opacity;
    if (cs.mixBlendMode !== 'normal') item.blend = cs.mixBlendMode;
    if (cs.filter && cs.filter !== 'none') item.filter = plainColors(cs.filter, cs.color);

    const paints = cs.visibility === 'visible';
    if (!paints) item.hidden = true;
    if (paints) {
      const bg = rgba(cs.backgroundColor);
      if (bg[3] > 0) item.bg = bg;
      const layers = backgroundLayers(cs, el);
      if (layers) item.layers = layers;
      const clip = cs.backgroundClip || cs.webkitBackgroundClip;
      if (/text/.test(clip || '') || /text/.test(cs.webkitBackgroundClip || '')) item.textClip = true;
      const sides = [
        side(cs.borderTopWidth, cs.borderTopStyle, cs.borderTopColor),
        side(cs.borderRightWidth, cs.borderRightStyle, cs.borderRightColor),
        side(cs.borderBottomWidth, cs.borderBottomStyle, cs.borderBottomColor),
        side(cs.borderLeftWidth, cs.borderLeftStyle, cs.borderLeftColor),
      ];
      if (sides.some((s) => s)) item.bd = sides;
      if (cs.boxShadow && cs.boxShadow !== 'none') item.sh = plainColors(cs.boxShadow, cs.color);
      const ow = px(cs.outlineWidth);
      if (cs.outlineStyle !== 'none' && ow > 0) {
        const oc = rgba(cs.outlineColor);
        if (oc[3] > 0) item.ol = { w: ow, s: cs.outlineStyle, c: oc, o: px(cs.outlineOffset) };
      }
      const backdrop = cs.backdropFilter || cs.webkitBackdropFilter;
      if (backdrop && backdrop !== 'none') item.backdrop = backdrop;
      const mask = cs.maskImage || cs.webkitMaskImage;
      if (mask && mask !== 'none') {
        item.shot = 'mask';
        item.key = hash(`${mask}|${cs.maskSize || cs.webkitMaskSize}|${cs.maskPosition || cs.webkitMaskPosition}|${cs.backgroundColor}|${cs.backgroundImage}|${box[2]}x${box[3]}`);
      }
    }
    const rad = radii(cs, box[2], box[3]);
    if (rad) item.rad = rad;
    if (cs.overflowX !== 'visible' || cs.overflowY !== 'visible' || /paint|strict|content/.test(cs.contain || '')) item.clip = true;
    if (cs.clipPath && cs.clipPath !== 'none') item.clipPath = cs.clipPath;
    item.ins = [px(cs.borderTopWidth), px(cs.borderRightWidth), px(cs.borderBottomWidth), px(cs.borderLeftWidth),
                px(cs.paddingTop), px(cs.paddingRight), px(cs.paddingBottom), px(cs.paddingLeft)];

    // What it holds.
    const tag = el.localName;
    if (tag === 'img') {
      if (el.naturalWidth > 0) {
        const src = bestSource(el, box[2]);
        item.img = { src: imageID(src), fit: cs.objectFit, pos: cs.objectPosition, nat: [el.naturalWidth, el.naturalHeight] };
        imageOwners.set(item.img.src, imageOwners.get(item.img.src) ?? el);
      }
      return item;
    }
    if (tag === 'svg') {
      const v = vectors(el, cs, box, item);
      if (v) item.vec = v;
      else {
        item.shot = item.shot || 'svg';
        // Ids and what names them differ from copy to copy of an icon without changing how it looks.
        const markup = el.outerHTML.slice(0, 50000)
          .replace(/\s(id|aria-[\w-]+|data-[\w-]+|role|focusable|tabindex)="[^"]*"/g, '')
          .replace(/url\(\s*['"]?#[^)'"]*['"]?\s*\)/g, 'url(#)').replace(/href="#[^"]*"/g, 'href="#"');
        item.key = hash(`${markup}|${cs.color}|${cs.fill}|${box[2]}x${box[3]}`);
      }
      return item;
    }
    if (tag === 'video') {
      if (el.poster) {
        item.img = { src: imageID(new URL(el.poster, document.baseURI).href), fit: cs.objectFit === 'fill' ? 'contain' : cs.objectFit, pos: cs.objectPosition, nat: [el.videoWidth || box[2], el.videoHeight || box[3]] };
        imageOwners.set(item.img.src, imageOwners.get(item.img.src) ?? el);
      } else item.shot = 'video';
      return item;
    }
    if (tag === 'canvas') {
      if (box[2] <= 0 || box[3] <= 0) return item;
      // Marked for the page's own world, where what it draws is recorded (WebPageGL.js).
      if (!el.hasAttribute('data-bz-canvas')) {
        el.setAttribute('data-bz-canvas', String(item.id));
        afterwards.push(() => el.removeAttribute('data-bz-canvas'));
      }
      // Read back as it was drawn, see-through where it is; a canvas holding pictures from
      // elsewhere cannot be, and is photographed.
      // The moment its picture is taken, for its WebGL to be kept as it was then.
      el.setAttribute('data-bz-canvas-at', String(performance.now() / 1000));
      afterwards.push(() => el.removeAttribute('data-bz-canvas-at'));
      try {
        const data = el.width > 0 && el.height > 0 ? el.toDataURL('image/png') : '';
        if (data.length > 100) {
          item.img = { src: imageID(data), fit: cs.objectFit, pos: cs.objectPosition, nat: [el.width, el.height] };
          imageOwners.set(item.img.src, el);
        }
      } catch (e) {
        item.shot = 'canvas';
      }
      return item;
    }
    if (tag === 'iframe' || tag === 'embed' || tag === 'object' || tag === 'math' || tag === 'audio' || tag === 'meter' || tag === 'progress') {
      if (box[2] > 0 && box[3] > 0) item.shot = 'embed';
      return item;
    }
    if (tag === 'input' || tag === 'textarea' || tag === 'select') {
      field(el, cs, item, box, matrix);
      return item;
    }
    if (item.shot) return item;
    // A custom element drawing what it holds in a shadow of its own no one can look into, such
    // as a video player: only a photograph shows it.
    if (tag.includes('-') && !tag.startsWith('bz-') && !el.shadowRoot && !el.firstElementChild && !el.textContent.trim() && box[2] > 1 && box[3] > 1) {
      item.shot = 'embed';
      return item;
    }
    if (isIcon(cs, el.textContent) && el.textContent.trim() && !el.querySelector('*:not(bz-pseudo)')) {
      item.shot = 'icon';
      item.key = hash(`${el.textContent}|${cs.font}|${cs.fontFamily}|${cs.color}|${box[2]}x${box[3]}`);
      return item;
    }
    const kidsItems = content(el, cs, matrix, isFixed, item);
    const marker = listMarker(el, cs, matrix);
    if (marker) kidsItems.unshift(marker);
    const pseudo = pseudoItems.get(el);
    if (pseudo) {
      if (pseudo.before) kidsItems.unshift(...adopt(pseudo.before, matrix, true));
      if (pseudo.after) kidsItems.push(...adopt(pseudo.after, matrix, false));
    }
    if (kidsItems.length) item.kids = kidsItems;
    return item;
  }

  /// A pseudo-element read apart, taken into its element: turned with it, and painted first or last.
  function adopt(item, matrix, before) {
    const out = item.contents ? item.kids : [item];
    for (const i of out) {
      if (before) i.before = true;
      if (matrix) premultiply(i, matrix);
    }
    return out;
  }

  function premultiply(item, matrix) {
    const own = item.m ? new DOMMatrix(item.m) : new DOMMatrix();
    const m = flat(matrix.multiply(own));
    if (m) item.m = m; else delete item.m;
    for (const k of item.kids || []) premultiply(k, matrix);
  }

  // MARK: Words

  const segmenter = typeof Intl !== 'undefined' && Intl.Segmenter ? new Intl.Segmenter(undefined, { granularity: 'grapheme' }) : null;
  function* graphemes(s) {
    if (segmenter) { for (const g of segmenter.segment(s)) yield [g.index, g.segment]; return; }
    let i = 0;
    for (const ch of s) { yield [i, ch]; i += ch.length; }
  }

  /// What an element holds, in order: elements as items of their own, and words with the inline
  /// elements they run through as texts, each a run of them between two of those items.
  function content(el, cs, matrix, fixed, owner) {
    const out = [];
    let group = null;
    let started = false;
    const start = () => {
      if (!group) group = { parts: [], first: !started };
      return group;
    };
    const flush = (last) => {
      if (group) {
        group.last = last;
        const t = textItem(group, el, cs, matrix);
        if (t) out.push(...t);
        group = null;
      }
    };
    const addElement = (n) => {
      const child = walk(n, matrix, fixed);
      if (!child) return;
      flush(false);
      started = true;
      if (child.contents) out.push(...child.kids);
      else out.push(child);
    };
    const visit = (nodes, inlineOwner) => {
      for (const n of nodes) {
        if (n.nodeType === 3) {
          if (!n.data) continue;
          start().parts.push({ node: n, el: n.parentElement && n.parentElement.localName !== 'slot' ? n.parentElement : (inlineOwner || el) });
          continue;
        }
        if (n.nodeType !== 1 || skipped.has(n.localName) || n.hasAttribute('data-bz-hide')) continue;
        if (n.localName === 'br') { start().parts.push({ br: true, el: n }); continue; }
        if (n.localName === 'wbr') continue;
        const ncs = getComputedStyle(n);
        if (ncs.display === 'none') continue;
        if (ncs.display === 'contents') { visit(kids(n), inlineOwner); continue; }
        const masked = (ncs.maskImage || ncs.webkitMaskImage || 'none') !== 'none';
        const inline = ncs.display === 'inline' && !replaced.has(n.localName) && n.localName !== 'bz-pseudo' &&
          !transforms.has(n) && !(isIcon(ncs, n.textContent) && n.textContent.trim()) && !masked &&
          parseFloat(ncs.opacity) > 0.001;
        if (inline) {
          decorations(n, ncs, matrix, out);
          const pseudo = pseudoItems.get(n);
          if (pseudo && pseudo.before) out.push(...adopt(pseudo.before, matrix, true));
          visit(kids(n), n);
          if (pseudo && pseudo.after) out.push(...adopt(pseudo.after, matrix, false));
          continue;
        }
        addElement(n);
      }
    };
    visit(kids(el), null);
    flush(true);
    return out;
  }

  /// The boxes an inline element draws behind its words, one a line it runs over.
  function decorations(n, ncs, matrix, out) {
    if (ncs.visibility !== 'visible') return;
    const bg = rgba(ncs.backgroundColor);
    const sides = [
      side(ncs.borderTopWidth, ncs.borderTopStyle, ncs.borderTopColor),
      side(ncs.borderRightWidth, ncs.borderRightStyle, ncs.borderRightColor),
      side(ncs.borderBottomWidth, ncs.borderBottomStyle, ncs.borderBottomColor),
      side(ncs.borderLeftWidth, ncs.borderLeftStyle, ncs.borderLeftColor),
    ];
    const layers = backgroundLayers(ncs, n);
    const shadow = ncs.boxShadow && ncs.boxShadow !== 'none' ? plainColors(ncs.boxShadow, ncs.color) : undefined;
    const textClip = /text/.test(ncs.backgroundClip || '') || /text/.test(ncs.webkitBackgroundClip || '');
    if (bg[3] <= 0 && !sides.some((s) => s) && !layers && !shadow) return;
    if (textClip) return;
    const rects = n.getClientRects();
    for (let i = 0; i < rects.length; i++) {
      const r = rects[i];
      if (r.width <= 0 || r.height <= 0) continue;
      const d = { t: 'deco', id: register(n), tag: n.localName, x: r.left + sx(), y: r.top + sy(), w: r.width, h: r.height };
      if (bg[3] > 0) d.bg = bg;
      if (layers) d.layers = layers;
      // Each line's piece has the sides that piece is drawn with.
      const s = sides.slice();
      if (i > 0) s[3] = null;
      if (i < rects.length - 1) s[1] = null;
      if (s.some((x) => x)) d.bd = s;
      if (shadow) d.sh = shadow;
      const rad = radii(ncs, r.width, r.height);
      if (rad) d.rad = rad;
      d.ins = [0, 0, 0, 0, 0, 0, 0, 0];
      const m = flat(matrix);
      if (m) d.m = m;
      if (ncs.opacity < 1) d.op = parseFloat(ncs.opacity);
      out.push(d);
    }
  }

  const styleKeys = new Map();

  /// How the letters of an element look, as Bezzle will want them.
  function letterStyle(el, cs, styles) {
    const decoration = cs.textDecorationLine || cs.webkitTextDecorationLine || cs.textDecoration || '';
    const list = splitFamilies(cs.fontFamily);
    let used = null;
    for (const f of list) {
      if (generic.has(f.toLowerCase())) { used = f; break; }
      if (available(f)) { used = f; break; }
    }
    const s = {
      fam: list,
      used: used || list[list.length - 1] || 'serif',
      web: used ? isWebFont(used) : false,
      wt: parseInt(cs.fontWeight, 10) || 400,
      it: cs.fontStyle !== 'normal',
      size: px(cs.fontSize),
      lh: cs.lineHeight === 'normal' ? undefined : px(cs.lineHeight),
      ls: cs.letterSpacing === 'normal' ? 0 : px(cs.letterSpacing),
      c: rgba(cs.color),
      u: /underline/.test(decoration) || undefined,
      st: /line-through/.test(decoration) || undefined,
      tt: cs.textTransform !== 'none' ? cs.textTransform : undefined,
      sc: /small-caps/.test(cs.fontVariantCaps || cs.fontVariant || '') || undefined,
      ff: cs.fontFeatureSettings !== 'normal' ? cs.fontFeatureSettings : undefined,
      fvn: cs.fontVariantNumeric !== 'normal' ? cs.fontVariantNumeric : undefined,
      fv: cs.fontVariationSettings !== 'normal' ? cs.fontVariationSettings : undefined,
      tsh: cs.textShadow !== 'none' ? plainColors(cs.textShadow, cs.color) : undefined,
      stroke: px(cs.webkitTextStrokeWidth) > 0 ? px(cs.webkitTextStrokeWidth) : undefined,
      va: cs.verticalAlign === 'super' || cs.verticalAlign === 'sub' ? cs.verticalAlign : undefined,
    };
    // Painted with what lies behind: a gradient or a picture, through the letters.
    const fill = cs.webkitTextFillColor;
    if (fill && rgba(fill)[3] === 0 && s.c[3] > 0) s.c = [s.c[0], s.c[1], s.c[2], 0];
    const key = JSON.stringify(s);
    let i = styleKeys.get(key);
    if (i === undefined || styles[i] === undefined || JSON.stringify(styles[i]) !== key) {
      i = styles.length;
      styles.push(s);
      styleKeys.set(key, i);
    }
    return i;
  }

  /// Words running through inline elements, as one text: the letters in runs of one style, and
  /// each line where the browser set it, its baseline and the letters on it.
  function textItem(group, cont, ccs, matrix) {
    styleKeys.clear();
    const styles = [];
    // Words a wide gap apart, as inline boxes with margins between them leave, are texts of their own.
    const pieces = [];
    let runs = [];
    let text = '';
    let lines = [];
    let line = null;
    let pending = null;
    const rtl = ccs.direction === 'rtl';
    const justified = ccs.textAlign === 'justify';
    const range = document.createRange();
    let paint = null;
    const cut = () => {
      pieces.push({ text, runs, lines });
      text = '';
      runs = [];
      lines = [];
      line = null;
      pending = null;
    };

    const append = (s, si) => {
      text += s;
      const last = runs[runs.length - 1];
      if (last && last[1] === si) last[0] += s.length;
      else runs.push([s.length, si]);
    };
    const newLine = (rc) => {
      if (!line) return true;
      if (rc.top >= line.b - 1) return true;
      if (rc.bottom <= line.y + 1) return true;
      if (!rtl && rc.left < line.lastRight - 2 && rc.top > line.y + 0.5) return true;
      if (rtl && rc.right > line.lastLeft + 2 && rc.top > line.y + 0.5) return true;
      return false;
    };

    for (const p of group.parts) {
      if (p.br) {
        if (text && !text.endsWith('\n')) append('\n', runs.length ? runs[runs.length - 1][1] : 0);
        pending = null;
        line = null;
        continue;
      }
      const pcs = getComputedStyle(p.el);
      if (pcs.visibility !== 'visible') continue;
      const si = letterStyle(p.el, pcs, styles);
      if (!paint) {
        const clipper = [p.el, p.el.parentElement, cont].find((e) => e && /text/.test((getComputedStyle(e).backgroundClip || '') + (getComputedStyle(e).webkitBackgroundClip || '')));
        if (clipper) {
          const kcs = getComputedStyle(clipper);
          const r = clipper.getBoundingClientRect();
          paint = { bg: rgba(kcs.backgroundColor), layers: backgroundLayers(kcs, clipper), x: r.left + sx(), y: r.top + sy(), w: r.width, h: r.height };
        }
      }
      const ws = pcs.whiteSpaceCollapse || pcs.whiteSpace;
      const keepSpaces = /pre|preserve|break-spaces/.test(ws) && !/pre-line|preserve-breaks/.test(ws);
      const keepBreaks = keepSpaces || /pre-line|preserve-breaks/.test(ws);
      const ascent = ascentOf(pcs);
      const data = p.node.data;
      for (const [i, g] of graphemes(data)) {
        const space = /^[ \t\n\r\f]+$/.test(g);
        if (space && !keepSpaces) {
          if (keepBreaks && g.includes('\n')) {
            append('\n', si);
            pending = null;
            line = null;
          } else if (text && !text.endsWith('\n')) {
            pending = pending ?? si;
          }
          continue;
        }
        if (g === '\n' || g === '\r\n') {
          append('\n', si);
          pending = null;
          line = null;
          continue;
        }
        range.setStart(p.node, i);
        range.setEnd(p.node, i + g.length);
        const rects = range.getClientRects();
        if (!rects.length) continue;
        const rc = rects[0];
        if (rc.width === 0 && rc.height === 0) continue;
        if (line && !rtl && !newLine(rc)) {
          // What lies between this letter and the last, past the space and the spacing there.
          const m = metricsOf(pcs);
          const size = styles[si].size || 16;
          const extra = rc.left - line.lastRight - (pending !== null ? m.s : 0) - (styles[si].ls || 0);
          if (extra > Math.max(size * 0.6, 8) && !(justified && pending !== null)) cut();
          else if (pending === null && extra > size * 0.12 && !text.endsWith(' ')) pending = si;
        }
        if (newLine(rc)) {
          if (pending !== null && text && !text.endsWith('\n') && !text.endsWith(' ')) append(' ', pending);
          pending = null;
          line = { from: text.length, x: rc.left, y: rc.top, r: rc.right, b: rc.bottom, lastRight: rc.right, lastLeft: rc.left, votes: new Map() };
          lines.push(line);
        } else if (pending !== null) {
          if (!text.endsWith(' ')) append(' ', pending);
          pending = null;
        }
        if (!line) continue;
        append(g, si);
        line.x = Math.min(line.x, rc.left);
        line.y = Math.min(line.y, rc.top);
        line.r = Math.max(line.r, rc.right);
        line.b = Math.max(line.b, rc.bottom);
        line.lastRight = rc.right;
        line.lastLeft = rc.left;
        line.to = text.length;
        if (!(space && keepSpaces)) {
          const base = Math.round((rc.top + ascent) * 4) / 4;
          const v = styles[si].va ? 0.5 : 1;
          line.votes.set(base, (line.votes.get(base) || 0) + v);
        }
      }
    }
    cut();
    const box = cont.getBoundingClientRect();
    const ins = [px(ccs.borderTopWidth), px(ccs.borderRightWidth), px(ccs.borderBottomWidth), px(ccs.borderLeftWidth),
                 px(ccs.paddingTop), px(ccs.paddingRight), px(ccs.paddingBottom), px(ccs.paddingLeft)];
    const kept = pieces.filter((p) => p.text.trim());
    const items = [];
    for (const piece of kept) {
      // Spaces at either end go.
      let { text: words, runs: pieceRuns } = piece;
      const lead = words.length - words.replace(/^[ \n]+/, '').length;
      const trimmed = words.replace(/[ \n]+$/, '');
      let drop = words.length - trimmed.length;
      while (drop > 0 && pieceRuns.length) {
        const last = pieceRuns[pieceRuns.length - 1];
        const take = Math.min(drop, last[0]);
        last[0] -= take;
        drop -= take;
        if (last[0] === 0) pieceRuns.pop();
      }
      let skip = lead;
      while (skip > 0 && pieceRuns.length) {
        const first = pieceRuns[0];
        const take = Math.min(skip, first[0]);
        first[0] -= take;
        skip -= take;
        if (first[0] === 0) pieceRuns.shift();
      }
      words = trimmed.slice(lead);
      const out = [];
      for (const l of piece.lines) {
        if (l.to === undefined) continue;
        let best = null, most = -1;
        for (const [b, n] of l.votes) if (n > most) { most = n; best = b; }
        out.push({ from: Math.max(0, l.from - lead), to: Math.max(0, Math.min(l.to - lead, words.length)), x: l.x + sx(), y: l.y + sy(), w: l.r - l.x, h: l.b - l.y, base: (best ?? l.b) + sy() });
      }
      if (!out.length) continue;
      const item = {
        t: 'text', id: register(cont), text: words, runs: pieceRuns, styles, lines: out,
        cont: {
          x: box.left + sx() + ins[3] + ins[7], y: box.top + sy() + ins[0] + ins[4],
          w: Math.max(0, box.width - ins[1] - ins[3] - ins[5] - ins[7]),
          align: ccs.textAlign, dir: ccs.direction, indent: px(ccs.textIndent),
          wrap: !/nowrap|pre$|^pre$/.test(ccs.whiteSpace) && ccs.textWrap !== 'nowrap' && (ccs.textWrapMode || 'wrap') !== 'nowrap',
        },
        clean: group.first && group.last && kept.length === 1,
      };
      if (paint) item.paint = paint;
      const m = flat(matrix);
      if (m) item.m = m;
      items.push(item);
    }
    return items.length ? items : null;
  }

  // MARK: List markers

  const markers = {
    disc: '•', circle: '◦', square: '▪', 'disclosure-closed': '▸', 'disclosure-open': '▾',
  };

  function roman(n, upper) {
    const t = [[1000, 'm'], [900, 'cm'], [500, 'd'], [400, 'cd'], [100, 'c'], [90, 'xc'], [50, 'l'], [40, 'xl'], [10, 'x'], [9, 'ix'], [5, 'v'], [4, 'iv'], [1, 'i']];
    let s = '';
    for (const [v, r] of t) while (n >= v) { s += r; n -= v; }
    return upper ? s.toUpperCase() : s;
  }

  /// The bullet or number a list item is drawn with, as a text of its own before its words.
  function listMarker(el, cs, matrix) {
    if (cs.display !== 'list-item' || cs.listStyleType === 'none' || cs.visibility !== 'visible') return null;
    if (cs.listStyleImage && cs.listStyleImage !== 'none') { note('list-image'); return null; }
    const type = cs.listStyleType.replace(/^"|"$/g, '');
    let s = markers[type];
    if (!s) {
      const list = el.parentElement;
      let n = 1;
      if (list && list.localName === 'ol') {
        const start = parseInt(list.getAttribute('start') || '1', 10);
        const items = [...list.children].filter((c) => getComputedStyle(c).display === 'list-item');
        const at = items.indexOf(el);
        n = list.hasAttribute('reversed') ? start - at : start + at;
        if (el.hasAttribute('value')) n = parseInt(el.getAttribute('value'), 10);
      } else if (list) {
        n = [...list.children].indexOf(el) + 1;
      }
      switch (type) {
        case 'decimal': s = `${n}.`; break;
        case 'decimal-leading-zero': s = `${n < 10 ? '0' : ''}${n}.`; break;
        case 'lower-alpha': case 'lower-latin': s = `${String.fromCharCode(96 + ((n - 1) % 26) + 1)}.`; break;
        case 'upper-alpha': case 'upper-latin': s = `${String.fromCharCode(64 + ((n - 1) % 26) + 1)}.`; break;
        case 'lower-roman': s = `${roman(n, false)}.`; break;
        case 'upper-roman': s = `${roman(n, true)}.`; break;
        default:
          if (/^".*"$/.test(cs.listStyleType)) s = cs.listStyleType.slice(1, -1);
          else s = `${n}.`;
      }
    }
    // Where its first line is.
    const first = firstLine(el);
    if (!first) return null;
    let mcs = cs;
    try { const m = getComputedStyle(el, '::marker'); if (m && m.color) mcs = m; } catch (e) {}
    const styles = [];
    const si = letterStyle(el, mcs, styles);
    const size = px(mcs.fontSize || cs.fontSize);
    const box = el.getBoundingClientRect();
    const left = box.left + px(cs.borderLeftWidth) + px(cs.paddingLeft);
    const inside = cs.listStylePosition === 'inside';
    const gap = /^[•◦▪▸▾]$/.test(s) ? size * 0.55 : size * 0.3;
    const item = {
      t: 'text', id: register(el), text: s, runs: [[s.length, si]], styles, marker: true,
      lines: [{ from: 0, to: s.length, x: 0, y: first.top + sy(), w: 0, h: first.height, base: first.base + sy() }],
      cont: { x: inside ? left + sx() : left + sx() - gap, y: first.top + sy(), w: 0, align: inside ? 'left' : 'right', dir: cs.direction, wrap: false },
      clean: false,
    };
    const m = flat(matrix);
    if (m) item.m = m;
    return item;
  }

  /// The top and baseline of the first line of words in an element, if it has any.
  function firstLine(el) {
    const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
    const range = document.createRange();
    for (let n = walker.nextNode(); n; n = walker.nextNode()) {
      const i = n.data.search(/\S/);
      if (i < 0) continue;
      range.setStart(n, i);
      range.setEnd(n, i + 1);
      const r = range.getClientRects()[0];
      if (!r) continue;
      const pcs = getComputedStyle(n.parentElement);
      return { top: r.top, height: r.height, base: r.top + ascentOf(pcs) };
    }
    return null;
  }

  // MARK: Fields

  /// What a form field shows: its box, and the words in it or its placeholder.
  function field(el, cs, item, box, matrix) {
    const type = (el.getAttribute('type') || '').toLowerCase();
    const appearance = cs.appearance || cs.webkitAppearance;
    if (el.localName === 'input' && ['checkbox', 'radio', 'range', 'color', 'file', 'date', 'time', 'datetime-local', 'month', 'week'].includes(type) && appearance !== 'none') {
      item.shot = 'control';
      return;
    }
    if (el.localName === 'input' && type === 'hidden') return;
    if (el.localName === 'select' && appearance !== 'none') { item.shot = 'control'; return; }
    if (el.localName === 'input' && type === 'image') {
      item.img = { src: imageID(el.src), fit: 'fill', pos: '50% 50%', nat: [box[2], box[3]] };
      imageOwners.set(item.img.src, el);
      return;
    }
    let value = '';
    let placeholder = false;
    if (el.localName === 'select') value = el.selectedOptions[0] ? el.selectedOptions[0].textContent.trim() : '';
    else value = el.value || '';
    if (type === 'password') value = '•'.repeat(value.length);
    if (!value && el.placeholder) { value = el.placeholder; placeholder = true; }
    if (!value && ['submit', 'reset', 'button'].includes(type)) value = type === 'reset' ? 'Reset' : 'Submit';
    if (!value) return;
    let tcs = cs;
    if (placeholder) { try { tcs = getComputedStyle(el, '::placeholder'); } catch (e) { tcs = cs; } }
    // A placeholder kept out of sight, as under a label that floats over the field, is left out.
    const shown = placeholder && tcs !== cs ? parseFloat(tcs.opacity || '1') : 1;
    if (placeholder && (shown < 0.01 || tcs.visibility === 'hidden' || tcs.display === 'none' || rgba(tcs.color)[3] < 0.01)) return;
    const styles = [];
    const si = letterStyle(el, tcs.color ? tcs : cs, styles);
    if (placeholder && tcs === cs) {
      const c = styles[si].c;
      styles[si].c = [c[0], c[1], c[2], c[3] * 0.55];
    } else if (shown < 1) {
      const c = styles[si].c;
      styles[si].c = [c[0], c[1], c[2], c[3] * shown];
    }
    const ins = item.ins;
    const left = box[0] + ins[3] + ins[7], top = box[1] + ins[0] + ins[4];
    const width = Math.max(0, box[2] - ins[1] - ins[3] - ins[5] - ins[7]);
    const height = Math.max(0, box[3] - ins[0] - ins[2] - ins[4] - ins[6]);
    const { a: ascent, d: descent } = metricsOf(cs);
    const fsize = px(cs.fontSize);
    const lh = cs.lineHeight === 'normal' ? ascent + descent : px(cs.lineHeight);
    const multi = el.localName === 'textarea';
    // One line lies in the middle of the box; a text area's first line at its top.
    const base = multi ? top + (lh - ascent - descent) / 2 + ascent : top + height / 2 + (ascent - descent) / 2;
    const center = ['submit', 'reset', 'button'].includes(type);
    const t = {
      t: 'text', id: register(el), text: value, runs: [[value.length, si]], styles,
      lines: [{ from: 0, to: value.length, x: left, y: base - ascent, w: width, h: fsize * 1.2, base }],
      cont: { x: left, y: top, w: width, align: center ? 'center' : cs.textAlign, dir: cs.direction, wrap: multi },
      clean: true, field: true,
    };
    const m = flat(matrix);
    if (m) t.m = m;
    item.kids = [t];
  }

  // MARK: SVG

  const unsupported = new Set(['text', 'image', 'foreignObject', 'pattern', 'filter']);
  const containers = new Set(['g', 'a', 'switch']);

  /// A length of an SVG shape: as its attribute gives it, or, where it has none, as CSS sizes it.
  function svgLength(el, name) {
    if (!el.hasAttribute(name)) {
      const v = getComputedStyle(el)[name];
      if (v && v !== 'auto' && v !== 'none' && Number.isFinite(parseFloat(v))) return parseFloat(v);
    }
    const a = el[name];
    if (a && a.baseVal !== undefined) {
      try { return a.baseVal.value; } catch (e) {}
    }
    return parseFloat(el.getAttribute(name)) || 0;
  }

  /// A shape's outline as path data in its own coordinates.
  function shapeData(el) {
    const n = (v) => +v.toFixed(4);
    switch (el.localName) {
      case 'path': return el.getAttribute('d') || '';
      case 'rect': {
        const x = svgLength(el, 'x'), y = svgLength(el, 'y'), w = svgLength(el, 'width'), h = svgLength(el, 'height');
        if (w <= 0 || h <= 0) return '';
        const set = (n) => el.hasAttribute(n) || !/^(auto|0px|)$/.test(getComputedStyle(el)[n] || '');
        let rx = set('rx') ? svgLength(el, 'rx') : null, ry = set('ry') ? svgLength(el, 'ry') : null;
        if (rx === null) rx = ry ?? 0;
        if (ry === null) ry = rx;
        rx = Math.min(rx, w / 2); ry = Math.min(ry, h / 2);
        if (rx <= 0 || ry <= 0) return `M${n(x)} ${n(y)}H${n(x + w)}V${n(y + h)}H${n(x)}Z`;
        return `M${n(x + rx)} ${n(y)}H${n(x + w - rx)}A${n(rx)} ${n(ry)} 0 0 1 ${n(x + w)} ${n(y + ry)}V${n(y + h - ry)}A${n(rx)} ${n(ry)} 0 0 1 ${n(x + w - rx)} ${n(y + h)}H${n(x + rx)}A${n(rx)} ${n(ry)} 0 0 1 ${n(x)} ${n(y + h - ry)}V${n(y + ry)}A${n(rx)} ${n(ry)} 0 0 1 ${n(x + rx)} ${n(y)}Z`;
      }
      case 'circle': {
        const cx = svgLength(el, 'cx'), cy = svgLength(el, 'cy'), r = svgLength(el, 'r');
        if (r <= 0) return '';
        return `M${n(cx - r)} ${n(cy)}A${n(r)} ${n(r)} 0 1 0 ${n(cx + r)} ${n(cy)}A${n(r)} ${n(r)} 0 1 0 ${n(cx - r)} ${n(cy)}Z`;
      }
      case 'ellipse': {
        const cx = svgLength(el, 'cx'), cy = svgLength(el, 'cy'), rx = svgLength(el, 'rx'), ry = svgLength(el, 'ry');
        if (rx <= 0 || ry <= 0) return '';
        return `M${n(cx - rx)} ${n(cy)}A${n(rx)} ${n(ry)} 0 1 0 ${n(cx + rx)} ${n(cy)}A${n(rx)} ${n(ry)} 0 1 0 ${n(cx - rx)} ${n(cy)}Z`;
      }
      case 'line':
        return `M${n(svgLength(el, 'x1'))} ${n(svgLength(el, 'y1'))}L${n(svgLength(el, 'x2'))} ${n(svgLength(el, 'y2'))}`;
      case 'polyline':
      case 'polygon': {
        const pts = (el.getAttribute('points') || '').trim().split(/[\s,]+/).map(Number).filter((v) => Number.isFinite(v));
        if (pts.length < 4) return '';
        let d = `M${pts[0]} ${pts[1]}`;
        for (let i = 2; i + 1 < pts.length; i += 2) d += `L${pts[i]} ${pts[i + 1]}`;
        return el.localName === 'polygon' ? d + 'Z' : d;
      }
    }
    return '';
  }

  /// How an SVG viewport's viewBox is laid into a box of `w` by `h`.
  function viewBoxMatrix(svg, w, h, par) {
    const vb = svg.viewBox && svg.viewBox.baseVal;
    if (!vb || !vb.width || !vb.height) return new DOMMatrix();
    const attr = (par || svg.getAttribute('preserveAspectRatio') || 'xMidYMid meet').trim();
    const [align, meetOrSlice] = attr.split(/\s+/);
    let sxv = w / vb.width, syv = h / vb.height;
    if (align !== 'none') {
      const s = meetOrSlice === 'slice' ? Math.max(sxv, syv) : Math.min(sxv, syv);
      sxv = syv = s;
    }
    let tx = -vb.x * sxv, ty = -vb.y * syv;
    if (align !== 'none') {
      const dx = w - vb.width * sxv, dy = h - vb.height * syv;
      if (/xMid/.test(align)) tx += dx / 2; else if (/xMax/.test(align)) tx += dx;
      if (/YMid/.test(align)) ty += dy / 2; else if (/YMax/.test(align)) ty += dy;
    }
    return new DOMMatrix([sxv, 0, 0, syv, tx, ty]);
  }

  function ownTransform(el) {
    try {
      const list = el.transform && el.transform.baseVal;
      if (list && list.numberOfItems) {
        const t = list.consolidate();
        if (t) { const m = t.matrix; return new DOMMatrix([m.a, m.b, m.c, m.d, m.e, m.f]); }
      }
    } catch (e) {}
    return null;
  }

  function referenced(value, root) {
    const m = /url\(\s*["']?#([^"')]+)["']?\s*\)/.exec(value || '');
    if (!m) return null;
    const doc = root.getRootNode ? root.getRootNode() : document;
    return (doc.getElementById ? doc.getElementById(m[1]) : null) || document.getElementById(m[1]);
  }

  /// An SVG gradient as Bezzle wants it: its points in the shape's own user space.
  function svgGradient(g, root, bbox) {
    // Stops and settings may come from the gradient it refers to.
    const chain = [];
    for (let e = g, i = 0; e && i < 8; i++) {
      chain.push(e);
      const href = e.getAttribute('href') || e.getAttribute('xlink:href');
      e = href && href.startsWith('#') ? document.getElementById(href.slice(1)) || (root.getRootNode().getElementById?.(href.slice(1))) : null;
    }
    const attr = (name) => { for (const e of chain) if (e.hasAttribute(name)) return e.getAttribute(name); return null; };
    const stopsOf = chain.find((e) => e.querySelector('stop'));
    if (!stopsOf) return null;
    const stops = [...stopsOf.querySelectorAll('stop')].map((s) => {
      const scs = getComputedStyle(s);
      let off = s.getAttribute('offset') || '0';
      off = off.endsWith('%') ? parseFloat(off) / 100 : parseFloat(off);
      const c = rgba(scs.stopColor || s.getAttribute('stop-color') || 'black');
      const a = parseFloat(scs.stopOpacity || s.getAttribute('stop-opacity') || '1');
      return { o: Math.min(1, Math.max(0, off || 0)), c: [c[0], c[1], c[2], c[3] * (Number.isFinite(a) ? a : 1)] };
    });
    const user = attr('gradientUnits') === 'userSpaceOnUse';
    const num = (name, fallback) => {
      const v = attr(name);
      if (v === null) return fallback;
      if (v.endsWith('%')) return parseFloat(v) / 100 * (user ? 1 : 1);
      return parseFloat(v);
    };
    const toUser = (x, y) => (user ? [x, y] : [bbox.x + x * bbox.width, bbox.y + y * bbox.height]);
    let t = null;
    const gt = attr('gradientTransform');
    if (gt) { try { t = new DOMMatrix(gt.replace(/matrix\(([^)]*)\)/, (m, a) => `matrix(${a.trim().split(/[\s,]+/).join(', ')})`)); } catch (e) { t = null; } }
    const move = (p) => {
      if (!t) return p;
      if (user) { const q = t.transformPoint(new DOMPoint(p[0], p[1])); return [q.x, q.y]; }
      // In bounding-box units, the transform is in those units.
      const u = [(p[0] - bbox.x) / (bbox.width || 1), (p[1] - bbox.y) / (bbox.height || 1)];
      const q = t.transformPoint(new DOMPoint(u[0], u[1]));
      return [bbox.x + q.x * bbox.width, bbox.y + q.y * bbox.height];
    };
    if (g.localName === 'linearGradient') {
      const a = move(toUser(num('x1', 0), num('y1', 0)));
      const b = move(toUser(num('x2', user ? 0 : 1), num('y2', 0)));
      return { k: 'linear', stops, a, b };
    }
    const cx = num('cx', 0.5), cy = num('cy', 0.5), r = num('r', 0.5);
    const c = move(toUser(cx, cy));
    const ex = move(toUser(cx + r, cy));
    const ey = move(toUser(cx, cy + r));
    return { k: 'radial', stops, a: c, b: ex, e: ey };
  }

  /// An SVG as outlines, each in the page's coordinates as laid out; null when it holds what
  /// outlines cannot show, such as text, pictures or filters, or is too much to take apart.
  function vectors(svg, cs, box, item, parOverride, offset) {
    const ins = item ? item.ins : [0, 0, 0, 0, 0, 0, 0, 0];
    const cw = box[2] - ins[1] - ins[3] - ins[5] - ins[7], ch = box[3] - ins[0] - ins[2] - ins[4] - ins[6];
    if (cw <= 0 || ch <= 0) return null;
    const origin = offset || [box[0] + ins[3] + ins[7], box[1] + ins[0] + ins[4]];
    const rootM = new DOMMatrix().translateSelf(origin[0], origin[1]).multiplySelf(viewBoxMatrix(svg, cw, ch, parOverride));
    const paths = [];
    let bad = false;
    const visit = (el, m, inherited, depth) => {
      if (bad || depth > 40) return;
      const name = el.localName;
      if (['defs', 'symbol', 'clipPath', 'mask', 'marker', 'linearGradient', 'radialGradient', 'style', 'title', 'desc', 'metadata', 'script'].includes(name)) return;
      if (unsupported.has(name)) { bad = true; return; }
      const ecs = getComputedStyle(el);
      if (ecs.display === 'none') return;
      const own = el === svg ? null : ownTransform(el);
      let em = own ? m.multiply(own) : m;
      // A clip to the whole of what it holds cuts nothing; any other clip, mask or filter is drawn.
      // The outer SVG's own clip, mask and filter are its element's, which Bezzle draws itself.
      const clip = el === svg ? null : el.getAttribute('clip-path') || (ecs.clipPath !== 'none' ? ecs.clipPath : null);
      if (clip && clip !== 'none') {
        const cp = referenced(clip, svg);
        const shapes = cp ? [...cp.children] : [];
        const full = shapes.length === 1 && shapes[0].localName === 'rect' && !shapes[0].getAttribute('transform');
        if (!full) { bad = true; return; }
      }
      if (el !== svg && ((el.getAttribute('mask') && el.getAttribute('mask') !== 'none') || (ecs.filter && ecs.filter !== 'none'))) { bad = true; return; }
      const opacity = (inherited.op ?? 1) * parseFloat(ecs.opacity || '1');
      const ctx = { ...inherited, op: opacity };
      if (name === 'svg' && el !== svg) {
        const x = svgLength(el, 'x'), y = svgLength(el, 'y');
        const w = el.width && el.width.baseVal ? el.width.baseVal.value : cw;
        const h = el.height && el.height.baseVal ? el.height.baseVal.value : ch;
        em = em.multiply(new DOMMatrix().translateSelf(x, y)).multiply(viewBoxMatrix(el, w, h));
      }
      if (name === 'use') {
        const href = el.getAttribute('href') || el.getAttribute('xlink:href');
        if (!href || !href.startsWith('#')) { bad = true; return; }
        const target = (svg.getRootNode().getElementById ? svg.getRootNode().getElementById(href.slice(1)) : null) || document.getElementById(href.slice(1));
        if (!target) return;
        let um = em.multiply(new DOMMatrix().translateSelf(svgLength(el, 'x'), svgLength(el, 'y')));
        const uctx = { ...ctx, use: ecs };
        if (target.localName === 'symbol') {
          const w = el.hasAttribute('width') ? svgLength(el, 'width') : (target.viewBox?.baseVal?.width || cw);
          const h = el.hasAttribute('height') ? svgLength(el, 'height') : (target.viewBox?.baseVal?.height || ch);
          um = um.multiply(viewBoxMatrix(target, w, h));
          for (const c of target.children) visit(c, um, uctx, depth + 1);
        } else {
          visit(target, um, uctx, depth + 1);
        }
        return;
      }
      if (name === 'svg' || containers.has(name)) {
        for (const c of el.children) visit(c, em, ctx, depth + 1);
        return;
      }
      const d = shapeData(el);
      if (!d) return;
      // Inside a <use>, what a shape does not set itself comes from the <use>.
      const from = (prop) => {
        const v = ecs[prop];
        if (!ctx.use) return v;
        const parent = el.parentElement ? getComputedStyle(el.parentElement)[prop] : null;
        const set = el.hasAttribute(prop.replace(/[A-Z]/g, (c) => '-' + c.toLowerCase())) || el.style[prop];
        return set || v !== parent ? v : ctx.use[prop];
      };
      const fill = from('fill'), stroke = from('stroke');
      const color = from('color');
      const paintOf = (v, alpha) => {
        if (!v || v === 'none') return null;
        if (/^url\(/.test(v)) {
          const g = referenced(v, svg);
          if (!g || !/Gradient$/.test(g.localName)) {
            const fallback = /\)\s+(.+)$/.exec(v);
            if (fallback) { const c = rgba(fallback[1]); return { c: [c[0], c[1], c[2], c[3] * alpha] }; }
            bad = true;
            return null;
          }
          let bbox;
          try { bbox = el.getBBox(); } catch (e) { bbox = { x: 0, y: 0, width: 0, height: 0 }; }
          const grad = svgGradient(g, svg, bbox);
          if (!grad) return null;
          grad.stops.forEach((s) => { s.c[3] *= alpha; });
          return { g: grad };
        }
        const c = rgba(/currentcolor/i.test(v) ? color : v);
        return { c: [c[0], c[1], c[2], c[3] * alpha] };
      };
      const fillPaint = paintOf(fill, parseFloat(from('fillOpacity') || '1'));
      const strokePaint = paintOf(stroke, parseFloat(from('strokeOpacity') || '1'));
      const sw = px(from('strokeWidth') || '1');
      const p = { d, m: [em.a, em.b, em.c, em.d, em.e, em.f] };
      if (fillPaint) p.fill = fillPaint;
      if ((from('fillRule') || '') === 'evenodd') p.rule = 'evenodd';
      if (strokePaint && sw > 0) {
        p.stroke = { paint: strokePaint, w: sw };
        const dash = from('strokeDasharray');
        if (dash && dash !== 'none') { const v = dash.split(/[\s,]+/).map(px); p.stroke.dash = [v[0] || 0, v[1] ?? v[0] ?? 0]; }
        p.stroke.cap = from('strokeLinecap');
        p.stroke.join = from('strokeLinejoin');
      }
      if (opacity < 1) p.op = opacity;
      if (!p.fill && !p.stroke) return;
      paths.push(p);
      if (paths.length > 4000) bad = true;
    };
    visit(svg, rootM, {}, 0);
    if (bad) return null;
    return paths;
  }

  // MARK: Pseudo-elements

  let pseudoItems = new Map();
  /// The elements that stood in for pseudo-elements, by what they stood in for, to stand in again
  /// while one is photographed.
  let standIns = new Map();

  // MARK: Counters

  let counted = null;

  function counterChanges(v) {
    const out = [];
    if (!v || v === 'none') return out;
    const w = v.trim().split(/\s+/);
    for (let i = 0; i < w.length; i++) {
      let n = null;
      if (i + 1 < w.length && /^-?\d+$/.test(w[i + 1])) n = parseInt(w[i + 1], 10);
      out.push([w[i], n]);
      if (n !== null) i++;
    }
    return out;
  }

  /// The values of every counter each pseudo-element sees, worked out through the page in
  /// order as CSS counts: each reset starting a counter for its element and those after it,
  /// each increment adding to the nearest.
  function countAll(root) {
    const seen = new Map();
    const stacks = new Map();
    const snapshot = () => { const o = {}; for (const [k, v] of stacks) if (v.length) o[k] = v.map((x) => x.v); return o; };
    const apply = (cs, parent) => {
      for (const [name, n] of counterChanges(cs.counterReset)) {
        if (name === 'list-item') continue;
        const st = stacks.get(name) || [];
        // A reset by a sibling of the one that made it starts it again rather than nesting.
        if (st.length && st[st.length - 1].owner === parent) st.pop();
        st.push({ v: n ?? 0, owner: parent });
        stacks.set(name, st);
      }
      for (const [name, n] of counterChanges(cs.counterSet)) {
        const st = stacks.get(name);
        if (st && st.length) st[st.length - 1].v = n ?? 0; else stacks.set(name, [{ v: n ?? 0, owner: parent }]);
      }
      for (const [name, n] of counterChanges(cs.counterIncrement)) {
        let st = stacks.get(name);
        if (!st || !st.length) { st = [{ v: 0, owner: parent }]; stacks.set(name, st); }
        st[st.length - 1].v += n ?? 1;
      }
    };
    const visit = (el) => {
      const cs = getComputedStyle(el);
      if (cs.display === 'none') return;
      apply(cs, el.parentElement);
      const entry = {};
      const b = getComputedStyle(el, '::before');
      if (b && b.content && b.content !== 'none' && b.content !== 'normal') { apply(b, el); entry.before = snapshot(); }
      for (const c of kids(el)) if (c.nodeType === 1) visit(c);
      const a = getComputedStyle(el, '::after');
      if (a && a.content && a.content !== 'none' && a.content !== 'normal') { apply(a, el); entry.after = snapshot(); }
      if (entry.before || entry.after) seen.set(el, entry);
      // Counters started inside it end with it.
      for (const st of stacks.values()) while (st.length && st[st.length - 1].owner === el) st.pop();
    };
    visit(root);
    return seen;
  }

  function counterText(n, style) {
    switch ((style || 'decimal').trim()) {
      case 'decimal-leading-zero': return `${n < 10 && n >= 0 ? '0' : ''}${n}`;
      case 'lower-roman': return roman(n, false);
      case 'upper-roman': return roman(n, true);
      case 'lower-alpha': case 'lower-latin': return n > 0 ? String.fromCharCode(96 + ((n - 1) % 26) + 1) : `${n}`;
      case 'upper-alpha': case 'upper-latin': return n > 0 ? String.fromCharCode(64 + ((n - 1) % 26) + 1) : `${n}`;
      case 'disc': return '•';
      case 'circle': return '◦';
      case 'square': return '▪';
      case 'none': return '';
      default: return `${n}`;
    }
  }

  function pseudoContent(host, pcs, which) {
    const c = pcs.content;
    if (!c || c === 'none' || c === 'normal') return null;
    let text = '';
    let url = null;
    const re = /"((?:[^"\\]|\\.)*)"|'((?:[^'\\]|\\.)*)'|url\(\s*["']?(.*?)["']?\s*\)|attr\(\s*([\w-]+)\s*\)|(open-quote|close-quote|no-open-quote|no-close-quote)|(counters?)\(([^)]*)\)/g;
    for (const m of c.matchAll(re)) {
      if (m[1] !== undefined || m[2] !== undefined) text += (m[1] ?? m[2]).replace(/\\(.)/g, '$1');
      else if (m[3] !== undefined) url = m[3];
      else if (m[4] !== undefined) text += host.getAttribute(m[4]) || '';
      else if (m[5] === 'open-quote') text += '“';
      else if (m[5] === 'close-quote') text += '”';
      else if (m[6]) {
        if (!counted) counted = countAll(document.documentElement);
        const values = (counted.get(host) || {})[which === '::before' ? 'before' : 'after'] || {};
        const args = splitTop(m[7]);
        const list = values[args[0].trim()] || [0];
        if (m[6] === 'counter') text += counterText(list[list.length - 1], args[1]);
        else text += list.map((n) => counterText(n, args[2])).join((args[1] || '').replace(/^["']|["']$/g, ''));
      }
    }
    return { text, url };
  }

  function paintsBox(pcs) {
    return rgba(pcs.backgroundColor)[3] > 0 || (pcs.backgroundImage && pcs.backgroundImage !== 'none') ||
      ['Top', 'Right', 'Bottom', 'Left'].some((s) => px(pcs[`border${s}Width`]) > 0 && pcs[`border${s}Style`] !== 'none' && rgba(pcs[`border${s}Color`])[3] > 0) ||
      (pcs.boxShadow && pcs.boxShadow !== 'none') || ((pcs.maskImage || pcs.webkitMaskImage || 'none') !== 'none');
  }

  /// Pseudo-elements, which have no box to measure, are each stood in for by an element styled
  /// as they are, read, and taken away again before the rest of the page is read.
  async function readPseudos(all) {
    const made = [];
    for (const host of all) {
      if (host instanceof SVGElement || replaced.has(host.localName) || host.localName === 'bz-pseudo') continue;
      for (const which of ['::before', '::after']) {
        const pcs = getComputedStyle(host, which);
        if (!pcs || pcs.display === 'none') continue;
        const content = pseudoContent(host, pcs, which);
        if (!content) continue;
        if (!content.text.trim() && !content.url && !paintsBox(pcs)) continue;
        if (pcs.visibility !== 'visible' && !content.text.trim()) continue;
        const stand = document.createElement('bz-pseudo');
        for (let i = 0; i < pcs.length; i++) {
          const p = pcs[i];
          if (p === 'content' || p.startsWith('transition') || p.startsWith('animation')) continue;
          stand.style.setProperty(p, pcs.getPropertyValue(p));
        }
        if (content.url) {
          const img = document.createElement('img');
          img.src = content.url;
          img.style.cssText = 'display:inline-block;vertical-align:baseline;';
          stand.appendChild(img);
          made.push({ host, which, stand, img });
        } else {
          made.push({ host, which, stand });
        }
        if (content.text) stand.appendChild(document.createTextNode(content.text));
        const tf = pcs.transform !== 'none' || (pcs.rotate && pcs.rotate !== 'none') || (pcs.scale && pcs.scale !== 'none') || (pcs.translate && pcs.translate !== 'none');
        if (tf) {
          transforms.set(stand, { t: pcs.transform, tr: pcs.translate, ro: pcs.rotate, sc: pcs.scale, origin: pcs.transformOrigin });
          stand.setAttribute('data-bz-tf', '');
        }
      }
    }
    if (!made.length) return;
    for (const p of made) {
      p.host.setAttribute('data-bz-np', `${p.host.getAttribute('data-bz-np') || ''} ${p.which === '::before' ? 'b' : 'a'}`.trim());
      if (p.which === '::before') p.host.insertBefore(p.stand, p.host.firstChild);
      else p.host.appendChild(p.stand);
    }
    await Promise.all(made.filter((p) => p.img).map((p) => Promise.race([p.img.decode().catch(() => {}), sleep(1500)])));
    for (const p of made) {
      const item = walk(p.stand, null, false);
      if (!item) continue;
      if (!item.label) item.label = p.which === '::before' ? 'before' : 'after';
      item.pseudo = p.which;
      const entry = pseudoItems.get(p.host) || {};
      entry[p.which === '::before' ? 'before' : 'after'] = item;
      pseudoItems.set(p.host, entry);
    }
    for (const p of made) {
      p.stand.remove();
      standIns.set(p.stand, { host: p.host, which: p.which });
    }
    for (const p of made) p.host.removeAttribute('data-bz-np');
  }

  // MARK: Getting the page ready

  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

  /// Waits until nothing in the page has changed for `still` milliseconds, or `most` have gone by.
  const quiet = (still, most) => new Promise((resolve) => {
    let timer = null, cap = null;
    const observer = new MutationObserver(() => { clearTimeout(timer); timer = setTimeout(done, still); });
    function done() { observer.disconnect(); clearTimeout(timer); clearTimeout(cap); resolve(); }
    observer.observe(document.documentElement, { subtree: true, childList: true, attributes: true, characterData: true });
    timer = setTimeout(done, still);
    cap = setTimeout(done, most);
  });

  const banners = [
    '#onetrust-consent-sdk', '#onetrust-banner-sdk', '#CybotCookiebotDialog', '#CybotCookiebotDialogBodyUnderlay', '#cookiebanner', '#cookie-banner',
    '#cookie-notice', '#cookieConsent', '#cookie-consent', '.cookie-banner', '.cookie-consent', '.cookie-notice', '.cc-window', '.cc-banner',
    '#didomi-host', '#didomi-popup', '#usercentrics-root', '#usercentrics-cmp-ui', '#cmpbox', '#cmpbox2', '#cmpwrapper', '.fc-consent-root',
    '#qc-cmp2-container', '#truste-consent-track', '.truste_box_overlay', '[id^="sp_message_container"]', '.osano-cm-window',
    '#hs-eu-cookie-confirmation', '.cky-consent-container', '.cky-overlay', '#moove_gdpr_cookie_info_bar', '.cmplz-cookiebanner',
    '#BorlabsCookieBox', '#borlabs-cookie', '#cookie-law-info-bar', '.iubenda-cs-container', '#iubenda-cs-banner', '#klaro', '.klaro',
    '#ccc', '#termly-code-snippet-support', '#axeptio_overlay', '#tarteaucitronRoot', '.evidon-banner', '#gdpr-cookie-message',
    '#cookie-information-template-wrapper', '#CookieReportsBanner', '.cookiealert', '#cookieChoiceInfo', '#consent_blackbar', '#cookies-banner',
    '#js-cookie-banner', '#credential_picker_container', '#credential_picker_iframe', 'iframe[src*="accounts.google.com/gsi"]',
    '[aria-label*="cookie" i][role="dialog"]', '[aria-label*="consent" i][role="dialog"]', '[aria-describedby*="cookie" i][role="dialog"]',
  ];

  /// Takes away cookie banners and the veils they put over the page, and lets the page scroll again.
  function hideBanners() {
    let hidden = 0;
    for (const sel of banners) {
      let found;
      try { found = document.querySelectorAll(sel); } catch (e) { continue; }
      for (const el of found) { if (!el.hasAttribute('data-bz-hide')) { el.setAttribute('data-bz-hide', ''); hidden++; } }
    }
    // Banners of their own making: fixed along the top or bottom, talking of cookies.
    for (const el of document.querySelectorAll('body *')) {
      const cs = getComputedStyle(el);
      if (cs.position !== 'fixed' && cs.position !== 'sticky') continue;
      const words = el.innerText || '';
      // Short, about cookies, and asking to be agreed to: not a page that only mentions them.
      if (words.length > 1500 || !/cookie|consent|gdpr|datenschutz|privacy|tracking/i.test(words)) continue;
      if (!/accept|agree|allow|akzept|zustimm|einverstanden|erlauben|accepter|j'accepte|autoriser|accett|consenti|\bok\b|got it/i.test(words)) continue;
      const r = el.getBoundingClientRect();
      // A small card is a banner only when it names cookies outright.
      if (r.width < innerWidth * 0.3 && r.height < innerHeight * 0.15 && !/cookie|tracking tech|consent/i.test(words)) continue;
      if (/nav|header/i.test(el.localName) || el.querySelector('nav')) continue;
      el.setAttribute('data-bz-hide', '');
      hidden++;
    }
    for (const el of [document.documentElement, document.body]) {
      if (!el) continue;
      const cs = getComputedStyle(el);
      if (cs.overflowY === 'hidden') setForNow(el, 'overflow-y', 'visible');
      if (cs.position === 'fixed' && el === document.body) setForNow(el, 'position', 'static');
    }
    return hidden;
  }

  /// Loads what the page loads only once it is scrolled to.
  function wakeLazy() {
    for (const img of document.images) {
      if (img.loading === 'lazy') img.loading = 'eager';
      for (const a of ['data-src', 'data-lazy-src', 'data-original', 'data-lazy', 'data-url']) {
        const v = img.getAttribute(a);
        if (v && (!img.getAttribute('src') || /^data:image\/(gif|svg)|placeholder|blank|spacer/i.test(img.getAttribute('src')))) { img.src = v; break; }
      }
      for (const a of ['data-srcset', 'data-lazy-srcset']) {
        const v = img.getAttribute(a);
        if (v && !img.getAttribute('srcset')) { img.srcset = v; break; }
      }
    }
    for (const s of document.querySelectorAll('source[data-srcset]')) if (!s.srcset) s.srcset = s.getAttribute('data-srcset');
    for (const f of document.querySelectorAll('iframe[loading="lazy"]')) f.loading = 'eager';
  }

  /// A page that scrolls inside a box of its own rather than as a whole: that box let out to its
  /// full height, so the page is as tall as what it holds.
  function unrollScroller() {
    const doc = document.scrollingElement || document.documentElement;
    if (doc.scrollHeight > innerHeight * 1.2) return false;
    let best = null, most = 0;
    for (const el of document.querySelectorAll('body *')) {
      if (el.scrollHeight <= el.clientHeight * 1.5 || el.clientHeight < innerHeight * 0.5) continue;
      const cs = getComputedStyle(el);
      if (!/auto|scroll/.test(cs.overflowY)) continue;
      if (el.scrollHeight > most) { most = el.scrollHeight; best = el; }
    }
    if (!best) return false;
    const scroller = best, top = best.scrollTop;
    afterwards.push(() => { scroller.scrollTop = top; });
    for (let e = best; e && e !== document.documentElement; e = e.parentElement) {
      setForNow(e, 'height', 'auto');
      setForNow(e, 'max-height', 'none');
      setForNow(e, 'overflow', 'visible');
    }
    setForNow(document.documentElement, 'height', 'auto');
    setForNow(document.documentElement, 'overflow', 'visible');
    return true;
  }

  function pageHeight() {
    const doc = document.scrollingElement || document.documentElement;
    return Math.max(doc.scrollHeight, document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0, innerHeight);
  }

  let styleSheet = null;

  // MARK: Leaving the page as it was

  /// What reading the page changed in it, each undone by `finish` in turn, the last first, so a
  /// page read as someone left it in a browser is theirs again afterwards: as tall as it was,
  /// scrolled where it was, its banners back, and what moved moving again.
  let afterwards = [];

  /// Sets a style of an element's own until the page has been read.
  function setForNow(el, property, value) {
    const was = el.style.getPropertyValue(property), priority = el.style.getPropertyPriority(property);
    afterwards.push(() => {
      if (was) el.style.setProperty(property, was, priority);
      else el.style.removeProperty(property);
    });
    el.style.setProperty(property, value, 'important');
  }

  function putBack() {
    const undo = afterwards;
    afterwards = [];
    for (let i = undo.length - 1; i >= 0; i--) { try { undo[i](); } catch (e) {} }
  }

  /// Gets the page ready to be read: banners away, everything loaded that waits for scrolling,
  /// fonts and pictures in, and every animation at its end.
  B.prepare = async (opts) => {
    notes = {};
    putBack();
    const [x0, y0] = [window.scrollX, window.scrollY];
    afterwards.push(() => window.scrollTo(x0, y0));
    afterwards.push(() => { for (const el of document.querySelectorAll('[data-bz-hide]')) el.removeAttribute('data-bz-hide'); });
    if (styleSheet) styleSheet.remove();
    styleSheet = document.createElement('style');
    styleSheet.id = 'bz-style';
    styleSheet.textContent = `
      *, *::before, *::after { transition: none !important; caret-color: transparent !important; scroll-behavior: auto !important; }
      html { scroll-behavior: auto !important; }
      [data-bz-hide] { display: none !important; }
      [data-bz-np~="b"]::before, [data-bz-np~="a"]::after { content: none !important; display: none !important; }
      * { content-visibility: visible !important; }
      html, * { scrollbar-width: none !important; }
      ::-webkit-scrollbar { display: none !important; width: 0 !important; height: 0 !important; }
    `;
    (document.head || document.documentElement).appendChild(styleSheet);
    // Until the page's own scripts have built it: the page as the server sent it is often not
    // yet the page that shows.
    const still = Math.min(500, (opts.stepDelay ?? 120) * 4);
    await quiet(still, 3000);
    let hidden = opts.hideBanners ? hideBanners() : 0;
    wakeLazy();
    // A page read as someone left it keeps its scrolling boxes as they are, scrolled where they are.
    if (opts.unroll !== false && unrollScroller()) note('scroller');
    // Down the page and back, a screen at a time, for what loads as it comes into view.
    const limit = opts.maxHeight || 30000;
    const step = Math.max(200, innerHeight * 0.85);
    for (let y = 0; y < Math.min(pageHeight(), limit); y += step) {
      window.scrollTo(0, y);
      await sleep(opts.stepDelay ?? 120);
      wakeLazy();
    }
    window.scrollTo(0, Math.min(pageHeight(), limit));
    await sleep(opts.stepDelay ?? 120);
    window.scrollTo(0, 0);
    await sleep(250);
    if (opts.hideBanners) hidden += hideBanners();
    // The pictures, then the fonts, each given a while.
    const pending = [...document.images].filter((i) => !i.complete).map((i) => i.decode().catch(() => {}));
    await Promise.race([Promise.all(pending), sleep(opts.imageWait ?? 5000)]);
    if (document.fonts) await Promise.race([document.fonts.ready, sleep(5000)]);
    await quiet(still, 2000);
    for (const a of document.getAnimations ? document.getAnimations() : []) {
      const running = a.playState === 'running';
      try {
        const timing = a.effect && a.effect.getComputedTiming ? a.effect.getComputedTiming() : null;
        if (timing && timing.iterations === Infinity) { a.pause(); a.currentTime = 0; } else a.finish();
      } catch (e) {
        try { a.pause(); } catch (e2) {}
      }
      if (running && a.playState === 'paused') afterwards.push(() => a.play());
    }
    // Videos stop where they are, so each photograph of one shows the same frame.
    for (const v of document.querySelectorAll('video')) {
      try {
        if (v.paused) continue;
        v.pause();
        afterwards.push(() => v.play().catch(() => {}));
      } catch (e) {}
    }
    window.scrollTo(0, 0);
    await sleep(100);
    return { hidden, height: pageHeight() };
  };

  // MARK: Reading the page

  /// The page taken apart, as JSON.
  B.capture = async (opts) => {
    els = [];
    images = [];
    imageIndex.clear();
    imageOwners.clear();
    pseudoItems = new Map();
    standIns = new Map();
    counted = null;
    window.scrollTo(0, 0);
    const root = document.documentElement;
    // Transforms first, before they are taken away to measure what they move.
    const all = [root, ...elements(root)];
    for (const el of all) {
      if (el instanceof SVGElement && el.localName !== 'svg') continue;
      keepTransform(el, getComputedStyle(el));
    }
    const flatten = document.createElement('style');
    flatten.id = 'bz-flat';
    flatten.textContent = '[data-bz-tf] { transform: translate(0px) !important; translate: none !important; rotate: none !important; scale: none !important; }';
    (document.head || root).appendChild(flatten);
    let result;
    try {
      await readPseudos(all);
      const html = walk(root, null, false);
      const htmlStyle = getComputedStyle(root);
      const body = document.body;
      const bodyStyle = body ? getComputedStyle(body) : null;
      // The page's background, from the root or else the body, covers the whole canvas.
      let bgFrom = root, bgStyle = htmlStyle;
      if (rgba(htmlStyle.backgroundColor)[3] === 0 && htmlStyle.backgroundImage === 'none' && bodyStyle) { bgFrom = body; bgStyle = bodyStyle; }
      const page = { c: rgba(bgStyle.backgroundColor), layers: backgroundLayers(bgStyle, bgFrom) };
      const strip = (item) => {
        if (!item) return;
        if (item.id === ids.get(bgFrom)) { delete item.bg; delete item.layers; }
        for (const k of item.kids || []) if (k.tag === 'body') strip(k);
      };
      strip(html);
      result = {
        url: location.href, title: document.title, w: document.documentElement.clientWidth || innerWidth, vh: innerHeight,
        h: Math.min(pageHeight(), opts.maxHeight || 30000), fullHeight: pageHeight(),
        bg: page, root: html, images, notes,
        lang: root.lang || undefined,
      };
    } finally {
      flatten.remove();
      for (const el of root.querySelectorAll('[data-bz-tf]')) el.removeAttribute('data-bz-tf');
      if (meter) { meter.remove(); meter = null; }
    }
    return JSON.stringify(result);
  };

  // MARK: Pictures of what cannot be taken apart

  /// An SVG picture laid into an <img>'s box as the page shows it, as outlines in the page's
  /// coordinates; null when it cannot be.
  B.vectorize = (index, svgText) => {
    const owner = imageOwners.get(index);
    if (!owner) return null;
    const holder = document.createElement('bz-vector');
    holder.style.cssText = 'position:absolute!important;left:-30000px!important;top:0!important;visibility:visible!important;display:block!important;';
    const parsed = new DOMParser().parseFromString(svgText, 'image/svg+xml');
    const svg = parsed.documentElement;
    if (!svg || svg.localName !== 'svg' || parsed.querySelector('parsererror')) return null;
    for (const s of svg.querySelectorAll('script')) s.remove();
    for (const e of svg.querySelectorAll('*')) for (const a of [...e.attributes]) if (/^on/i.test(a.name)) e.removeAttribute(a.name);
    const r = owner.getBoundingClientRect();
    const cs = getComputedStyle(owner);
    const ins = [px(cs.borderTopWidth), px(cs.borderRightWidth), px(cs.borderBottomWidth), px(cs.borderLeftWidth), px(cs.paddingTop), px(cs.paddingRight), px(cs.paddingBottom), px(cs.paddingLeft)];
    const cw = r.width - ins[1] - ins[3] - ins[5] - ins[7], chh = r.height - ins[0] - ins[2] - ins[4] - ins[6];
    const node = document.importNode(svg, true);
    // An SVG without a viewBox is drawn at its own size, stretched as an <img> stretches it.
    if (!node.getAttribute('viewBox')) {
      const w = parseFloat(node.getAttribute('width')), h = parseFloat(node.getAttribute('height'));
      if (w > 0 && h > 0) node.setAttribute('viewBox', `0 0 ${w} ${h}`);
    }
    node.setAttribute('width', String(cw));
    node.setAttribute('height', String(chh));
    holder.appendChild(node);
    document.documentElement.appendChild(holder);
    try {
      const fit = owner.localName === 'img' ? cs.objectFit : 'fill';
      const par = fit === 'cover' ? 'xMidYMid slice' : fit === 'contain' || fit === 'scale-down' ? 'xMidYMid meet' : undefined;
      const x = r.left + sx(), y = r.top + sy();
      const out = vectors(node, getComputedStyle(node), [x, y, r.width, r.height], { ins }, owner.localName === 'img' ? par : undefined);
      return out ? JSON.stringify(out) : null;
    } catch (e) {
      return null;
    } finally {
      holder.remove();
    }
  };

  let isolating = null;

  /// Shows only one element, on a plain colour, scrolled into view, so it can be photographed:
  /// all of it, or only its own box without what it holds. Says where it is on the screen and
  /// on the page.
  B.isolate = (id, own, color, pageY) => {
    B.release();
    const el = els[id];
    if (!el) return null;
    // What stood in for a pseudo-element, or is in one, stands in for it again.
    let stand = null;
    for (let e = el; e; e = e.parentElement) { if (standIns.has(e)) { stand = e; break; } }
    if (!el.isConnected && !stand) {
      for (const [s] of standIns) if (s.contains(el)) { stand = s; break; }
    }
    if (stand && !stand.isConnected) {
      const { host, which } = standIns.get(stand);
      if (!host.isConnected) return null;
      host.setAttribute('data-bz-np', which === '::before' ? 'b' : 'a');
      if (which === '::before') host.insertBefore(stand, host.firstChild); else host.appendChild(stand);
    } else stand = null;
    if (!el.isConnected) return null;
    el.setAttribute('data-bz-shot', own ? 'own' : 'all');
    // Shown by a style of its own too, which reaches into a shadow root where the sheet does not.
    const inline = [el.style.getPropertyValue('visibility'), el.style.getPropertyPriority('visibility')];
    el.style.setProperty('visibility', 'visible', 'important');
    for (let a = el.parentElement; a; a = a.parentElement) a.setAttribute('data-bz-anc', '');
    // The colour behind is the page's own background: a layer of its own under the page would
    // have a canvas drawn through a clear surface first, which some do not survive.
    const matte = document.createElement('style');
    matte.textContent = mattes(color);
    document.documentElement.appendChild(matte);
    const sheet = document.createElement('style');
    sheet.textContent = `
      *:not([data-bz-shot]):not([data-bz-shot] *) { visibility: hidden !important; }
      [data-bz-shot] { visibility: visible !important; }
      [data-bz-anc] { opacity: 1 !important; filter: none !important; mix-blend-mode: normal !important; backdrop-filter: none !important; -webkit-backdrop-filter: none !important; }
      [data-bz-shot="own"] * { visibility: hidden !important; }
      [data-bz-shot="own"] { color: transparent !important; -webkit-text-fill-color: transparent !important; text-shadow: none !important; border-color: transparent !important; box-shadow: none !important; outline: none !important; }
    `;
    document.documentElement.appendChild(sheet);
    isolating = { el, matte, sheet, stand, inline };
    const cs = getComputedStyle(el);
    let fixed = false;
    for (let a = el; a; a = a.parentElement) { if (getComputedStyle(a).position === 'fixed') { fixed = true; break; } }
    window.scrollTo(0, 0);
    let r = el.getBoundingClientRect();
    const page = { x: r.left + sx(), y: r.top + sy(), w: r.width, h: r.height };
    if (!fixed) {
      const want = pageY !== undefined ? pageY : page.y - 20;
      window.scrollTo(0, Math.max(0, want));
      r = el.getBoundingClientRect();
    }
    // The colour it lies on, for what is photographed whole, on that.
    let behind = null;
    for (let a = el.parentElement; a && !behind; a = a.parentElement) {
      const c = rgba(getComputedStyle(a).backgroundColor);
      if (c[3] > 0.99) behind = c;
    }
    if (!behind) behind = [1, 1, 1, 1];
    const hex = '#' + behind.slice(0, 3).map((v) => Math.round(v * 255).toString(16).padStart(2, '0')).join('');
    return JSON.stringify({ x: r.left, y: r.top, w: r.width, h: r.height, px: page.x, py: page.y, sy: sy(), fixed, vw: innerWidth, vh: innerHeight, op: parseFloat(cs.opacity), behind: hex });
  };

  /// The plain colour behind an element being photographed.
  B.matte = (color) => { if (isolating) isolating.matte.textContent = mattes(color); };

  function mattes(color) {
    return `html { background: ${color} !important; background-image: none !important; } body { background: transparent !important; background-image: none !important; }`;
  }

  B.release = () => {
    if (!isolating) return;
    isolating.el.removeAttribute('data-bz-shot');
    if (isolating.inline[0]) isolating.el.style.setProperty('visibility', isolating.inline[0], isolating.inline[1]);
    else isolating.el.style.removeProperty('visibility');
    for (const a of document.querySelectorAll('[data-bz-anc]')) a.removeAttribute('data-bz-anc');
    isolating.matte.remove();
    isolating.sheet.remove();
    if (isolating.stand) {
      const s = standIns.get(isolating.stand);
      isolating.stand.remove();
      if (s) s.host.removeAttribute('data-bz-np');
    }
    isolating = null;
  };

  B.finish = () => {
    B.release();
    if (styleSheet) styleSheet.remove();
    styleSheet = null;
    putBack();
  };
})();
