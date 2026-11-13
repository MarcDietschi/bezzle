// Bezzle's hands in a web page, for an assistant browsing through the AI server (`browse`): what
// the page shows, and the things on it one can press or fill in, numbered; and clicking, typing,
// pressing keys, pointing and scrolling, each with the events a person's pointer and keys send.
// It runs in the reader's world, apart from the page's scripts, on the same elements.
//
// Passwords are not typed here: a person signs in themselves.
(() => {
  'use strict';
  if (window.__bezzleHands) return;
  const H = (window.__bezzleHands = {});

  /// What the last look listed, by its number less one.
  let listed = [];

  const clean = (s) => (s || '').replace(/\s+/g, ' ').trim();
  const cut = (s, n) => (s.length > n ? s.slice(0, n - 1) + '…' : s);

  /// Every element, those in open shadow roots too, in the order of the page.
  function* everything(root = document.documentElement) {
    if (!root) return;
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT);
    for (let el = walker.currentNode; el; el = walker.nextNode()) {
      yield el;
      if (el.shadowRoot) for (const inner of el.shadowRoot.children) yield* everything(inner);
    }
  }

  function shown(el) {
    if (!el.isConnected) return false;
    const r = el.getBoundingClientRect();
    if (r.width < 1 || r.height < 1) return false;
    if (el.checkVisibility && !el.checkVisibility({ opacityProperty: true, visibilityProperty: true })) return false;
    return true;
  }

  function inView(el) {
    const r = el.getBoundingClientRect();
    return r.bottom > 0 && r.right > 0 && r.top < innerHeight && r.left < innerWidth;
  }

  const pressables = [
    'a[href]', 'button', 'input:not([type=hidden])', 'select', 'textarea', 'summary', '[role=button]', '[role=link]', '[role=tab]',
    '[role=menuitem]', '[role=menuitemcheckbox]', '[role=menuitemradio]', '[role=option]', '[role=checkbox]', '[role=radio]',
    '[role=switch]', '[role=combobox]', '[role=treeitem]', '[role=searchbox]', '[role=textbox]', '[contenteditable=""]',
    '[contenteditable=true]', '[tabindex]:not([tabindex="-1"])', '[onclick]',
  ].join(',');

  /// Whether a person could press it or type into it: a control, or what shows a hand to the
  /// pointer where what holds it does not.
  function pressable(el) {
    if (el.matches(pressables)) return true;
    const cs = getComputedStyle(el);
    if (cs.cursor !== 'pointer') return false;
    const up = el.parentElement;
    return !up || getComputedStyle(up).cursor !== 'pointer';
  }

  /// A field for a password or a code sent to the person: never typed into here.
  function secret(el) {
    if (!(el instanceof HTMLInputElement)) return false;
    if ((el.type || '').toLowerCase() === 'password') return true;
    const auto = (el.getAttribute('autocomplete') || '').toLowerCase();
    if (/password|one-time-code|cc-/.test(auto)) return true;
    return /pass(word)?|passwd|pwd|\botp\b|kennwort|mot.de.passe/i.test(`${el.name} ${el.id}`);
  }

  function roleOf(el) {
    if (secret(el)) return 'password';
    const role = el.getAttribute('role');
    if (role) return role;
    const n = el.localName;
    if (n === 'a') return 'link';
    if (n === 'button' || n === 'summary') return 'button';
    if (n === 'select') return 'select';
    if (n === 'textarea') return 'textbox';
    if (n === 'input') {
      const t = (el.type || 'text').toLowerCase();
      if (t === 'checkbox' || t === 'radio') return t;
      if (['submit', 'button', 'reset', 'image'].includes(t)) return 'button';
      if (t === 'range') return 'slider';
      if (t === 'search') return 'searchbox';
      return 'textbox';
    }
    if (el.isContentEditable) return 'textbox';
    return 'clickable';
  }

  function nameOf(el) {
    const by = el.getAttribute('aria-labelledby');
    if (by) {
      const t = clean(by.split(/\s+/).map((id) => document.getElementById(id)).filter(Boolean).map((e) => e.innerText || e.textContent).join(' '));
      if (t) return t;
    }
    const aria = clean(el.getAttribute('aria-label'));
    if (aria) return aria;
    if (el.labels && el.labels.length) {
      const t = clean([...el.labels].map((l) => l.innerText).join(' '));
      if (t) return t;
    }
    if (el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement) {
      const p = clean(el.getAttribute('placeholder'));
      if (p) return p;
      if (['submit', 'button', 'reset'].includes(el.type) && el.value) return clean(el.value);
    }
    if (el instanceof HTMLSelectElement) {
      const chosen = el.selectedOptions && el.selectedOptions[0];
      if (chosen) return clean(chosen.textContent);
    }
    const text = clean(el.innerText || el.textContent);
    if (text) return text;
    const title = clean(el.getAttribute('title'));
    if (title) return title;
    const inner = el.querySelector('img[alt], [aria-label], svg title');
    if (inner) return clean(inner.getAttribute('alt') || inner.getAttribute('aria-label') || inner.textContent);
    return '';
  }

  function describe(el, n) {
    const out = { n, role: roleOf(el), name: cut(nameOf(el), 90) };
    if ((el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement) && !secret(el)) {
      if (el.type === 'checkbox' || el.type === 'radio') out.checked = el.checked;
      else if (el.value) out.value = cut(el.value, 90);
    }
    for (const [attr, key] of [['aria-expanded', 'expanded'], ['aria-selected', 'selected'], ['aria-checked', 'checked'], ['aria-pressed', 'pressed'], ['aria-current', 'current']]) {
      const v = el.getAttribute(attr);
      if (v !== null && v !== 'false') out[key] = v === 'true' ? true : v;
      else if (v === 'false' && key !== 'current') out[key] = false;
    }
    if (el.disabled || el.getAttribute('aria-disabled') === 'true') out.disabled = true;
    if (el.localName === 'a' && el.href && !el.href.startsWith('javascript:')) out.href = el.getAttribute('href');
    if (!inView(el)) out.inView = false;
    return out;
  }

  /// The things one can press or fill in, those in view first, top to bottom and left to right.
  function pressableThings() {
    const found = [];
    const kept = new Set();
    for (const el of everything()) {
      if (!pressable(el) || !shown(el)) continue;
      // What lies in a thing already listed and reads the same is that thing.
      let up = el.parentElement, same = false;
      while (up) {
        if (kept.has(up)) { same = clean(up.innerText) === clean(el.innerText) || roleOf(el) === 'clickable'; break; }
        up = up.parentElement;
      }
      if (same) continue;
      kept.add(el);
      found.push(el);
    }
    const key = (el) => {
      const r = el.getBoundingClientRect();
      return [inView(el) ? 0 : 1, Math.round(r.top / 8), r.left];
    };
    return found.map((el) => [key(el), el]).sort((a, b) => a[0][0] - b[0][0] || a[0][1] - b[0][1] || a[0][2] - b[0][2]).map((p) => p[1]);
  }

  /// The page as an assistant is told of it.
  H.look = (opts) => {
    opts = opts || {};
    const limit = opts.limit || 160;
    const all = pressableThings();
    listed = all.slice(0, limit);
    const dialogs = [...everything()].filter((el) => el.matches('dialog[open], [role=dialog], [role=alertdialog], [aria-modal=true]') && shown(el)).map((el) => cut(nameOf(el), 120));
    const menus = [...everything()].filter((el) => el.matches('[role=menu], [role=listbox]') && shown(el)).map((el) => cut(nameOf(el), 120));
    const doc = document.scrollingElement || document.documentElement;
    const words = cut(clean(document.body ? document.body.innerText : ''), opts.words || 3000);
    return JSON.stringify({
      url: location.href, title: document.title,
      scroll: { y: Math.round(scrollY), height: Math.round(doc.scrollHeight), window: innerHeight, width: innerWidth },
      things: listed.map((el, i) => describe(el, i + 1)),
      more: Math.max(0, all.length - listed.length) || undefined,
      dialogs: dialogs.length ? dialogs : undefined,
      menus: menus.length ? menus : undefined,
      words,
    });
  };

  /// The element `target` names: a number from the last look, or the words on it, those a
  /// person reads first; or a CSS selector.
  function find(target, selector) {
    if (selector) {
      let el = null;
      try { el = document.querySelector(selector); } catch (e) { throw new Error(`${selector} is not a CSS selector.`); }
      if (!el) {
        for (const host of everything()) if (host.shadowRoot) { el = host.shadowRoot.querySelector(selector); if (el) break; }
      }
      if (!el) throw new Error(`Nothing on the page is ${selector}.`);
      return el;
    }
    if (target === undefined || target === null || target === '') throw new Error('Say what to act on: target, a number from the last look or the words on it, or selector.');
    if (typeof target === 'number' || /^\d+$/.test(String(target).trim())) {
      const el = listed[Number(target) - 1];
      if (!el || !el.isConnected) throw new Error(`There is no ${target} in the last look any more: look again.`);
      return el;
    }
    const want = clean(String(target)).toLowerCase();
    const things = pressableThings();
    const named = things.map((el) => [el, nameOf(el).toLowerCase()]);
    const pick = named.find(([, n]) => n === want) || named.find(([, n]) => n.startsWith(want)) || named.find(([, n]) => n.includes(want));
    if (pick) return pick[0];
    // Words on something that is not marked as a control: the smallest that holds them.
    let best = null, area = Infinity;
    for (const el of everything(document.body)) {
      if (!shown(el) || clean(el.innerText).toLowerCase() !== want) continue;
      const r = el.getBoundingClientRect();
      if (r.width * r.height < area) { area = r.width * r.height; best = el; }
    }
    if (best) return best;
    throw new Error(`Nothing on the page reads "${target}". Look again for what is there.`);
  }

  function point(el) {
    if (!inView(el)) el.scrollIntoView({ block: 'center', inline: 'nearest', behavior: 'instant' });
    const r = el.getBoundingClientRect();
    const x = Math.min(Math.max(r.left + r.width / 2, 0), innerWidth - 1), y = Math.min(Math.max(r.top + r.height / 2, 0), innerHeight - 1);
    let hit = document.elementFromPoint(x, y);
    while (hit && hit.shadowRoot) {
      const inner = hit.shadowRoot.elementFromPoint(x, y);
      if (!inner || inner === hit) break;
      hit = inner;
    }
    // What lies over it takes the pointer only when it is part of it.
    if (!hit || !(hit === el || el.contains(hit))) hit = el;
    return { x, y, hit };
  }

  function send(el, type, p, more) {
    const init = Object.assign({ bubbles: true, cancelable: true, composed: true, view: window, clientX: p.x, clientY: p.y, screenX: p.x, screenY: p.y, button: 0, buttons: 0, detail: 1 }, more || {});
    if (type.startsWith('pointer')) {
      return el.dispatchEvent(new PointerEvent(type, Object.assign({ pointerId: 1, pointerType: 'mouse', isPrimary: true, width: 1, height: 1, pressure: init.buttons ? 0.5 : 0 }, init)));
    }
    return el.dispatchEvent(new MouseEvent(type, init));
  }

  function over(p) {
    for (const type of ['pointerover', 'pointerenter', 'mouseover', 'mouseenter', 'pointermove', 'mousemove']) {
      send(p.hit, type, p, type.endsWith('enter') ? { bubbles: false } : {});
    }
  }

  const did = (el) => `${roleOf(el)} "${cut(nameOf(el), 60)}"`;

  H.click = (target, selector) => {
    const el = find(target, selector);
    const p = point(el);
    over(p);
    const down = send(p.hit, 'pointerdown', p, { buttons: 1 }) && send(p.hit, 'mousedown', p, { buttons: 1 });
    if (down) {
      const focusable = p.hit.closest('a[href], button, input, select, textarea, summary, [tabindex], [contenteditable]');
      if (focusable) focusable.focus({ preventScroll: true });
    }
    send(p.hit, 'pointerup', p);
    send(p.hit, 'mouseup', p);
    send(p.hit, 'click', p);
    return `Clicked ${did(el)}.`;
  };

  H.hover = (target, selector) => {
    const el = find(target, selector);
    over(point(el));
    return `Pointed at ${did(el)}.`;
  };

  function key(el, name, type) {
    const codes = { Enter: 'Enter', Escape: 'Escape', Tab: 'Tab', ' ': 'Space', Backspace: 'Backspace', Delete: 'Delete', ArrowDown: 'ArrowDown', ArrowUp: 'ArrowUp', ArrowLeft: 'ArrowLeft', ArrowRight: 'ArrowRight', Home: 'Home', End: 'End', PageDown: 'PageDown', PageUp: 'PageUp' };
    const code = codes[name] || (name.length === 1 ? `Key${name.toUpperCase()}` : name);
    return el.dispatchEvent(new KeyboardEvent(type, { key: name, code, bubbles: true, cancelable: true, composed: true, view: window }));
  }

  const keyNames = { enter: 'Enter', return: 'Enter', escape: 'Escape', esc: 'Escape', tab: 'Tab', space: ' ', backspace: 'Backspace', delete: 'Delete', down: 'ArrowDown', up: 'ArrowUp', left: 'ArrowLeft', right: 'ArrowRight', arrowdown: 'ArrowDown', arrowup: 'ArrowUp', arrowleft: 'ArrowLeft', arrowright: 'ArrowRight', home: 'Home', end: 'End', pagedown: 'PageDown', pageup: 'PageUp' };

  /// A key pressed where the focus is, and what it would do there that the events alone do not:
  /// Enter sends a form or presses a button, Space presses a button.
  function press(name, el) {
    const k = keyNames[String(name).toLowerCase()] || String(name);
    el = el || document.activeElement || document.body;
    while (el && el.shadowRoot && el.shadowRoot.activeElement) el = el.shadowRoot.activeElement;
    const go = key(el, k, 'keydown');
    if (k.length === 1 || k === 'Enter') key(el, k, 'keypress');
    if (go) {
      const control = el.closest && el.closest('button, a[href], summary, [role=button], [role=link], [role=menuitem], [role=option], [role=tab]');
      if (k === 'Enter' && el.form && el instanceof HTMLInputElement) {
        if (el.form.requestSubmit) el.form.requestSubmit(); else el.form.submit();
      } else if ((k === 'Enter' || k === ' ') && control) {
        control.click();
      }
    }
    key(el, k, 'keyup');
    return k;
  }

  H.press = (name) => {
    const k = press(name);
    return `Pressed ${k === ' ' ? 'Space' : k}.`;
  };

  H.type = (target, selector, text, submit, add) => {
    let el = find(target, selector);
    // Words aimed at a label or a box round a field go into the field.
    if (!(el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement || el instanceof HTMLSelectElement || el.isContentEditable)) {
      const inner = (el.control) || el.querySelector('input:not([type=hidden]), textarea, select, [contenteditable=""], [contenteditable=true]');
      if (!inner) throw new Error(`${did(el)} takes no typing.`);
      el = inner;
    }
    if (secret(el)) throw new Error('That is a password field. Bezzle leaves passwords to the person: show the browser (browse with action show) and ask them to sign in there.');
    const p = point(el);
    over(p);
    el.focus({ preventScroll: true });
    if (el instanceof HTMLSelectElement) {
      const want = clean(text).toLowerCase();
      const option = [...el.options].find((o) => clean(o.textContent).toLowerCase() === want || o.value.toLowerCase() === want) ||
        [...el.options].find((o) => clean(o.textContent).toLowerCase().includes(want));
      if (!option) throw new Error(`${did(el)} has no choice "${text}".`);
      el.value = option.value;
    } else if (el.isContentEditable) {
      if (!add) document.execCommand('selectAll', false);
      document.execCommand('insertText', false, text);
    } else {
      const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
      const set = Object.getOwnPropertyDescriptor(proto, 'value').set;
      for (const ch of [...text]) key(el, ch, 'keydown');
      set.call(el, (add ? el.value : '') + text);
      el.dispatchEvent(new InputEvent('input', { bubbles: true, composed: true, inputType: 'insertText', data: text }));
      for (const ch of [...text]) key(el, ch, 'keyup');
    }
    el.dispatchEvent(new Event('change', { bubbles: true }));
    if (submit) press('Enter', el);
    return `Typed into ${did(el)}${submit ? ' and pressed Enter' : ''}.`;
  };

  /// What scrolls: the page, or the biggest box in view that scrolls inside it when the page does not.
  function scroller() {
    const doc = document.scrollingElement || document.documentElement;
    if (doc.scrollHeight > innerHeight + 4) return doc;
    let best = null, most = 0;
    for (const el of everything(document.body)) {
      if (el.scrollHeight <= el.clientHeight + 4 || !inView(el)) continue;
      if (!/auto|scroll/.test(getComputedStyle(el).overflowY)) continue;
      const area = el.clientWidth * el.clientHeight;
      if (area > most) { most = area; best = el; }
    }
    return best || doc;
  }

  H.scroll = (target, selector, to, by) => {
    if (target || selector) {
      const el = find(target, selector);
      el.scrollIntoView({ block: 'center', behavior: 'instant' });
      return `Scrolled ${did(el)} into view.`;
    }
    const box = scroller();
    const view = box === (document.scrollingElement || document.documentElement) ? innerHeight : box.clientHeight;
    let y = box.scrollTop;
    if (to === 'top') y = 0;
    else if (to === 'bottom') y = box.scrollHeight;
    else if (typeof to === 'number') y = to;
    else y += typeof by === 'number' ? by : view * 0.85;
    box.scrollTo({ top: y, behavior: 'instant' });
    return `Scrolled to ${Math.round(box.scrollTop)} of ${Math.round(box.scrollHeight - view)}.`;
  };

  /// What signs a person out, or does something rather than show a page: never offered among the
  /// pages to bring in, since loading it would do it.
  const doing = /(^|[\/_.-])(log-?out|sign-?out|signoff|abmelden|ausloggen|deconnexion|d%C3%A9connexion|disconnetti|esci|delete|remove|unsubscribe)([\/_.?-]|$)|\/api\/|\/auth\//i;
  /// Files that are not pages.
  const files = /\.(pdf|zip|gz|dmg|exe|msi|docx?|xlsx?|pptx?|csv|json|xml|rss|png|jpe?g|gif|webp|avif|svg|mp4|mov|mp3|wav)(\?|$)/i;

  /// The pages of this site that this page links to, each once, in the order a person reads them:
  /// their addresses without the part after #, and what the link says.
  H.pages = (opts) => {
    opts = opts || {};
    const here = new URL(location.href);
    here.hash = '';
    const seen = new Set([here.href]), out = [];
    for (const a of everything(document.documentElement)) {
      if (a.localName !== 'a' || !a.href || a.hasAttribute('download')) continue;
      let url;
      try { url = new URL(a.href, location.href); } catch (e) { continue; }
      if (url.protocol !== here.protocol || (url.protocol !== 'file:' && url.host !== here.host)) continue;
      url.hash = '';
      if (seen.has(url.href) || doing.test(url.pathname + url.search) || files.test(url.pathname)) continue;
      seen.add(url.href);
      const name = cut(nameOf(a) || url.pathname, 90);
      out.push({ url: url.href, name, shown: shown(a) });
      if (out.length >= (opts.limit || 200)) break;
    }
    // What a person sees first comes first; what is hidden, in menus not open, after it.
    return JSON.stringify(out.filter((p) => p.shown).concat(out.filter((p) => !p.shown)));
  };

  /// Waits until the page has stopped changing for `still` milliseconds, or `most` have passed.
  H.settle = (still, most) => new Promise((resolve) => {
    let timer = null;
    const done = () => { observer.disconnect(); clearTimeout(timer); clearTimeout(limit); resolve(true); };
    const observer = new MutationObserver(() => { clearTimeout(timer); timer = setTimeout(done, still); });
    observer.observe(document.documentElement, { subtree: true, childList: true, attributes: true, characterData: true });
    timer = setTimeout(done, still);
    const limit = setTimeout(done, most);
  });
})();
