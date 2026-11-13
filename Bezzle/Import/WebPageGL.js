// Bezzle's recorder of WebGL, in a page it reads or browses: what each WebGL canvas draws, call
// by call, so that a canvas whose picture comes from its shaders alone comes into the design live
// (`ShaderFill`), to be drawn again by Bezzle at any size and any moment. It runs in the page's
// own world before the page's scripts, and changes nothing the page sees but this: a WebGL canvas
// keeps what it drew, so it can be read back whenever Bezzle asks, rather than only in the moment
// it is drawn.
//
// `__bezzleGL.scenes()` answers, for each canvas the reader marked (data-bz-canvas), its last
// frame and how it moved over the frames before it: the programs, every draw with its uniforms,
// attributes, indices, textures and blending, and the uniforms that grew steadily with time.
(() => {
  'use strict';
  const GL1 = window.WebGLRenderingContext;
  if (!GL1 || window.__bezzleGL) return;
  const GL2 = window.WebGL2RenderingContext;
  const protos = [GL1.prototype].concat(GL2 ? [GL2.prototype] : []);

  const ARRAY_BUFFER = 34962, ELEMENT_ARRAY_BUFFER = 34963, TEXTURE_2D = 3553, TEXTURE0 = 33984;
  const VERTEX_SHADER = 35633, FRAGMENT_SHADER = 35632, COLOR_BUFFER_BIT = 16384;
  const BLEND = 3042, DEPTH_TEST = 2929, UNPACK_FLIP_Y = 37440, UNPACK_PREMULTIPLY = 37441, FRAMEBUFFER = 36160;
  const WRAPS = { 10497: 'repeat', 33071: 'clamp', 33648: 'mirror' };
  const FILTERS = { 9728: ['nearest'], 9729: ['linear'], 9984: ['nearest', 'nearest'], 9985: ['linear', 'nearest'], 9986: ['nearest', 'linear'], 9987: ['linear', 'linear'] };
  const SAMPLERS = new Set([35678, 35680, 36289, 36298, 36299, 36303, 36306, 36307, 36311]);
  const CUBES = new Set([35680, 36300, 36304, 36312]);

  /// Each context's state as the page set it, and what it drew.
  const states = new WeakMap();
  /// Each canvas's context, as the page asked for it.
  const contexts = new WeakMap();
  let ids = 0;

  function state(gl) {
    let s = states.get(gl);
    if (!s) {
      s = {
        programs: new Map(), shaders: new Map(), buffers: new Map(), textures: new Map(), locations: new WeakMap(),
        program: null, arrayBuffer: null, vao: null, vaos: new Map(), plain: { attribs: [], elements: null },
        units: [], unit: 0, flipY: false, premultiply: false, blend: false, blendFunc: [1, 0, 1, 0], blendEq: [32774, 32774],
        viewport: null, clearColor: [0, 0, 0, 0], framebuffer: null, depth: false, constants: [],
        frames: [], frame: null,
      };
      states.set(gl, s);
    }
    return s;
  }

  const vao = (s) => (s.vao && s.vaos.get(s.vao)) || s.plain;

  // MARK: The frames

  /// The frame a draw belongs to: one an animation frame, or else, for pages that draw on a
  /// timer, what one task of the page drew.
  let frameStamp = null, taskKey = null, tasks = 0;
  const raf = window.requestAnimationFrame;
  if (raf) {
    window.requestAnimationFrame = function (callback) {
      return raf.call(window, (ts) => { frameStamp = ts; try { return callback(ts); } finally { frameStamp = null; } });
    };
  }
  const frameKey = () => {
    if (frameStamp !== null) return 'r' + frameStamp;
    if (!taskKey) { taskKey = 't' + (++tasks); queueMicrotask(() => { taskKey = null; }); }
    return taskKey;
  };

  function frameOf(s, gl) {
    const key = frameKey();
    if (!s.frame || s.frame.key !== key) begin(s, gl, key);
    return s.frame;
  }

  function begin(s, gl, key) {
    if (s.frame && (s.frame.draws.length || s.frame.clear || s.frame.broken)) {
      s.frames.push(s.frame);
      // The last few seconds, to tell what runs with time from what the page moves otherwise.
      const now = performance.now() / 1000;
      while (s.frames.length && (now - s.frames[0].time > 6 || s.frames.length > 480)) s.frames.shift();
    }
    s.frame = { key, time: performance.now() / 1000, draws: [], clear: null, broken: null, size: [gl.drawingBufferWidth, gl.drawingBufferHeight] };
  }

  // MARK: Wrapping

  function wrap(name, after, before) {
    for (const p of protos) {
      const f = p[name];
      if (typeof f !== 'function' || f.__bz) continue;
      const g = function (...args) {
        if (before) { try { before(state(this), args, this); } catch (e) {} }
        const r = f.apply(this, args);
        try { after && after(state(this), args, r, this); } catch (e) {}
        return r;
      };
      g.__bz = true;
      p[name] = g;
    }
  }

  const getContext = HTMLCanvasElement.prototype.getContext;
  HTMLCanvasElement.prototype.getContext = function (type, attributes) {
    const webgl = /^(webgl2?|experimental-webgl)$/.test(type);
    if (webgl) attributes = Object.assign({}, attributes, { preserveDrawingBuffer: true });
    const ctx = getContext.call(this, type, attributes);
    if (webgl && ctx) {
      contexts.set(this, ctx);
      const asked = ctx.getContextAttributes ? ctx.getContextAttributes() : null;
      if (asked) state(ctx).attributes = { alpha: asked.alpha !== false, premultipliedAlpha: asked.premultipliedAlpha !== false, antialias: asked.antialias !== false };
    }
    return ctx;
  };

  wrap('createShader', (s, [type], r) => { if (r) s.shaders.set(r, { type, source: '' }); });
  wrap('shaderSource', (s, [sh, src]) => { const o = s.shaders.get(sh); if (o) o.source = String(src); });
  wrap('createProgram', (s, a, r) => { if (r) s.programs.set(r, { id: ++ids, shaders: [], values: new Map(), attributes: [], samplers: [], cubes: false }); });
  wrap('attachShader', (s, [p, sh]) => { const o = s.programs.get(p); if (o && !o.shaders.includes(sh)) o.shaders.push(sh); });
  wrap('linkProgram', (s, [p], r, gl) => {
    const o = s.programs.get(p);
    if (!o) return;
    for (const sh of o.shaders) {
      const shader = s.shaders.get(sh);
      if (!shader) continue;
      if (shader.type === VERTEX_SHADER) o.vertex = shader.source; else if (shader.type === FRAGMENT_SHADER) o.fragment = shader.source;
    }
    o.attributes = [];
    o.samplers = [];
    const attributes = gl.getProgramParameter(p, 35721) || 0;
    for (let i = 0; i < attributes; i++) {
      const info = gl.getActiveAttrib(p, i);
      if (info) o.attributes.push({ name: info.name, location: gl.getAttribLocation(p, info.name) });
    }
    const uniforms = gl.getProgramParameter(p, 35718) || 0;
    for (let i = 0; i < uniforms; i++) {
      const info = gl.getActiveUniform(p, i);
      if (!info || !SAMPLERS.has(info.type)) continue;
      if (CUBES.has(info.type)) o.cubes = true;
      o.samplers.push({ name: info.name.replace(/\[0\]$/, ''), location: gl.getUniformLocation(p, info.name) });
    }
  });
  wrap('useProgram', (s, [p]) => { s.program = p; });
  wrap('getUniformLocation', (s, [p, name], r) => { if (r) s.locations.set(r, { program: p, name: String(name) }); });

  function setUniform(s, loc, values) {
    const at = loc && s.locations.get(loc);
    if (!at) return;
    const o = s.programs.get(at.program);
    if (o) o.values.set(at.name, Array.from(values, Number));
  }
  for (const n of ['1', '2', '3', '4']) {
    for (const t of ['f', 'i', 'ui']) {
      wrap(`uniform${n}${t}`, (s, [loc, ...v]) => setUniform(s, loc, v));
      wrap(`uniform${n}${t}v`, (s, [loc, data, offset, length]) => {
        let list = Array.from(data || [], Number);
        if (offset) list = list.slice(offset, length ? offset + length : undefined);
        setUniform(s, loc, list);
      });
    }
  }
  for (const n of ['2', '3', '4', '2x3', '2x4', '3x2', '3x4', '4x2', '4x3']) {
    wrap(`uniformMatrix${n}fv`, (s, [loc, transpose, data, offset, length]) => {
      let list = Array.from(data || [], Number);
      if (offset) list = list.slice(offset, length ? offset + length : undefined);
      if (transpose) { const at = s.locations.get(loc); if (at) { const o = s.programs.get(at.program); if (o) o.transposed = true; } }
      setUniform(s, loc, list);
    });
  }

  // Buffers and where attributes come from.
  wrap('createBuffer', (s, a, r) => { if (r) s.buffers.set(r, { id: ++ids, bytes: new Uint8Array(0), version: 0 }); });
  wrap('bindBuffer', (s, [target, b]) => {
    if (target === ARRAY_BUFFER) s.arrayBuffer = b;
    else if (target === ELEMENT_ARRAY_BUFFER) vao(s).elements = b;
  });
  const bound = (s, target) => (target === ARRAY_BUFFER ? s.arrayBuffer : target === ELEMENT_ARRAY_BUFFER ? vao(s).elements : null);
  const bytesOf = (data, offset, length) => {
    if (data instanceof ArrayBuffer) return new Uint8Array(data.slice(0));
    if (ArrayBuffer.isView(data)) {
      const per = data.BYTES_PER_ELEMENT || 1;
      const start = data.byteOffset + (offset || 0) * per;
      const end = length ? start + length * per : data.byteOffset + data.byteLength;
      return new Uint8Array(data.buffer.slice(start, end));
    }
    return null;
  };
  wrap('bufferData', (s, [target, data, usage, offset, length]) => {
    const b = s.buffers.get(bound(s, target));
    if (!b) return;
    b.bytes = typeof data === 'number' ? new Uint8Array(data) : bytesOf(data, offset, length) || new Uint8Array(0);
    b.version++;
  });
  wrap('bufferSubData', (s, [target, at, data, offset, length]) => {
    const b = s.buffers.get(bound(s, target));
    const bytes = bytesOf(data, offset, length);
    if (!b || !bytes) return;
    if (at + bytes.length > b.bytes.length) { const grown = new Uint8Array(at + bytes.length); grown.set(b.bytes); b.bytes = grown; }
    b.bytes.set(bytes, at);
    b.version++;
  });
  wrap('vertexAttribPointer', (s, [index, size, type, normalized, stride, offset]) => {
    const v = vao(s);
    v.attribs[index] = Object.assign({}, v.attribs[index], { buffer: s.arrayBuffer, size, type, normalized: !!normalized, stride, offset, integer: false });
  });
  wrap('vertexAttribIPointer', (s, [index, size, type, stride, offset]) => {
    const v = vao(s);
    v.attribs[index] = Object.assign({}, v.attribs[index], { buffer: s.arrayBuffer, size, type, normalized: false, stride, offset, integer: true });
  });
  wrap('enableVertexAttribArray', (s, [i]) => { const v = vao(s); v.attribs[i] = Object.assign({}, v.attribs[i], { enabled: true }); });
  wrap('disableVertexAttribArray', (s, [i]) => { const v = vao(s); v.attribs[i] = Object.assign({}, v.attribs[i], { enabled: false }); });
  for (const n of ['1', '2', '3', '4']) {
    wrap(`vertexAttrib${n}f`, (s, [i, ...v]) => { s.constants[i] = v.map(Number); });
    wrap(`vertexAttrib${n}fv`, (s, [i, v]) => { s.constants[i] = Array.from(v, Number); });
  }
  wrap('vertexAttribDivisor', (s, [i, d]) => { if (d) vao(s).instanced = true; });
  wrap('createVertexArray', (s, a, r) => { if (r) s.vaos.set(r, { attribs: [], elements: null }); });
  wrap('bindVertexArray', (s, [v]) => { s.vao = v; });
  // The same for WebGL 1, through its extension.
  wrap('getExtension', (s, [name], ext) => {
    if (!ext || ext.__bz) return;
    ext.__bz = true;
    if (/vertex_array_object/i.test(name)) {
      const make = ext.createVertexArrayOES, bind = ext.bindVertexArrayOES;
      ext.createVertexArrayOES = function () { const r = make.call(this); if (r) s.vaos.set(r, { attribs: [], elements: null }); return r; };
      ext.bindVertexArrayOES = function (v) { s.vao = v; return bind.call(this, v); };
    }
    if (/instanced_arrays/i.test(name)) {
      const divisor = ext.vertexAttribDivisorANGLE, drawA = ext.drawArraysInstancedANGLE, drawE = ext.drawElementsInstancedANGLE;
      ext.vertexAttribDivisorANGLE = function (i, d) { if (d) vao(s).instanced = true; return divisor.call(this, i, d); };
      ext.drawArraysInstancedANGLE = function (...a) { if (s.frame) s.frame.broken = 'instanced'; return drawA.apply(this, a); };
      ext.drawElementsInstancedANGLE = function (...a) { if (s.frame) s.frame.broken = 'instanced'; return drawE.apply(this, a); };
    }
  });

  // Textures.
  wrap('createTexture', (s, a, r) => { if (r) s.textures.set(r, { id: ++ids, version: 0, source: null }); });
  wrap('activeTexture', (s, [unit]) => { s.unit = unit - TEXTURE0; });
  wrap('bindTexture', (s, [target, t]) => { if (target === TEXTURE_2D) s.units[s.unit] = t; });
  wrap('pixelStorei', (s, [name, value]) => { if (name === UNPACK_FLIP_Y) s.flipY = !!value; else if (name === UNPACK_PREMULTIPLY) s.premultiply = !!value; });
  // How each picture is read, as the page left it; WebGL's own until it says otherwise.
  function parameter(s, [target, name, value]) {
    if (target !== TEXTURE_2D) return;
    const t = s.textures.get(s.units[s.unit]);
    if (!t) return;
    t.sampling = t.sampling || { wrapS: 'repeat', wrapT: 'repeat', magnify: 'linear', minify: 'nearest', mipFilter: 'linear' };
    if (name === 10242) t.sampling.wrapS = WRAPS[value] || 'repeat';
    else if (name === 10243) t.sampling.wrapT = WRAPS[value] || 'repeat';
    else if (name === 10240) t.sampling.magnify = value === 9728 ? 'nearest' : 'linear';
    else if (name === 10241) { const f = FILTERS[value] || ['linear']; t.sampling.minify = f[0]; t.sampling.mipFilter = f[1] || null; }
  }
  wrap('texParameteri', parameter);
  wrap('texParameterf', parameter);
  wrap('generateMipmap', (s, [target]) => { const t = target === TEXTURE_2D && s.textures.get(s.units[s.unit]); if (t) t.mipmapped = true; });

  /// What a texture was made from: a picture's address, or its pixels as a PNG.
  function sourceOf(args) {
    const last = args[args.length - 1];
    try {
      if (last instanceof HTMLImageElement) return { url: last.currentSrc || last.src, w: last.naturalWidth, h: last.naturalHeight };
      if (last instanceof HTMLVideoElement) return { moving: 'video' };
      const c = document.createElement('canvas');
      if (last instanceof HTMLCanvasElement || (window.ImageBitmap && last instanceof ImageBitmap) || (window.OffscreenCanvas && last instanceof OffscreenCanvas)) {
        c.width = last.width; c.height = last.height;
        c.getContext('2d').drawImage(last, 0, 0);
        return { data: c.toDataURL('image/png'), w: c.width, h: c.height };
      }
      if (last instanceof ImageData) {
        c.width = last.width; c.height = last.height;
        c.getContext('2d').putImageData(last, 0, 0);
        return { data: c.toDataURL('image/png'), w: c.width, h: c.height };
      }
      // Pixels given as numbers: texImage2D(target, level, internal, width, height, border, format, type, pixels).
      if (args.length >= 9 && (ArrayBuffer.isView(last) || last === null)) {
        const w = args[3], h = args[4], format = args[6], type = args[7];
        if (!last) return { data: null, w, h };
        if (type !== 5121) return { unread: 'pixels of another kind' };
        const per = format === 6408 ? 4 : format === 6407 ? 3 : format === 6409 || format === 6406 ? 1 : format === 6410 ? 2 : 0;
        if (!per || w * h > 4096 * 4096) return { unread: 'pixels of another kind' };
        const src = new Uint8Array(last.buffer, last.byteOffset, Math.min(last.byteLength, w * h * per));
        const img = new ImageData(w, h);
        for (let i = 0; i < w * h; i++) {
          const o = i * 4, k = i * per;
          if (per === 4) { img.data[o] = src[k]; img.data[o + 1] = src[k + 1]; img.data[o + 2] = src[k + 2]; img.data[o + 3] = src[k + 3]; }
          else if (per === 3) { img.data[o] = src[k]; img.data[o + 1] = src[k + 1]; img.data[o + 2] = src[k + 2]; img.data[o + 3] = 255; }
          else if (format === 6406) { img.data[o + 3] = src[k]; }
          else { img.data[o] = img.data[o + 1] = img.data[o + 2] = src[k]; img.data[o + 3] = per === 2 ? src[k + 1] : 255; }
        }
        c.width = w; c.height = h;
        c.getContext('2d').putImageData(img, 0, 0);
        return { data: c.toDataURL('image/png'), w, h };
      }
    } catch (e) {
      return { unread: 'a picture from elsewhere' };
    }
    return { unread: 'a picture of another kind' };
  }
  wrap('texImage2D', (s, args) => {
    if (args[0] !== TEXTURE_2D || args[1] !== 0) return;
    const t = s.textures.get(s.units[s.unit]);
    if (!t) return;
    t.source = sourceOf(args);
    t.flipY = s.flipY;
    t.premultiply = s.premultiply;
    t.version++;
  });
  wrap('texSubImage2D', (s, args) => {
    const t = s.textures.get(s.units[s.unit]);
    if (t) { t.version++; t.partly = true; }
  });

  // How draws lie over each other, and where.
  wrap('enable', (s, [cap]) => { if (cap === BLEND) s.blend = true; else if (cap === DEPTH_TEST) s.depth = true; });
  wrap('disable', (s, [cap]) => { if (cap === BLEND) s.blend = false; else if (cap === DEPTH_TEST) s.depth = false; });
  wrap('blendFunc', (s, [a, b]) => { s.blendFunc = [a, b, a, b]; });
  wrap('blendFuncSeparate', (s, [a, b, c, d]) => { s.blendFunc = [a, b, c, d]; });
  wrap('blendEquation', (s, [m]) => { s.blendEq = [m, m]; });
  wrap('blendEquationSeparate', (s, [a, b]) => { s.blendEq = [a, b]; });
  wrap('viewport', (s, [x, y, w, h]) => { s.viewport = [x, y, w, h]; });
  wrap('clearColor', (s, [r, g, b, a]) => { s.clearColor = [r, g, b, a]; });
  wrap('bindFramebuffer', (s, [target, fb]) => { if (target === FRAMEBUFFER || target === 36009) s.framebuffer = fb; });
  wrap('clear', null, (s, [mask], gl) => {
    if (s.framebuffer || !(mask & COLOR_BUFFER_BIT)) return;
    // Cleared after drawing: a frame of its own begins.
    if (s.frame && s.frame.draws.length && s.frame.key === frameKey()) begin(s, gl, frameKey() + '+');
    frameOf(s, gl).clear = s.clearColor.slice();
  });

  function record(s, gl, mode, first, count, elements) {
    const f = frameOf(s, gl);
    if (s.framebuffer) { f.broken = f.broken || 'framebuffer'; return; }
    const p = s.programs.get(s.program);
    if (!p || !p.vertex || !p.fragment) return;
    if (p.cubes) f.broken = f.broken || 'cube';
    if (p.transposed) f.broken = f.broken || 'transposed';
    const v = vao(s);
    if (v.instanced) f.broken = f.broken || 'instanced';
    const attributes = {};
    for (const a of p.attributes) {
      if (a.location < 0 || /^gl_/.test(a.name)) continue;
      const at = v.attribs[a.location];
      const b = at && at.enabled && s.buffers.get(at.buffer);
      attributes[a.name] = b
        ? { buffer: b.id, version: b.version, size: at.size, type: at.type, normalized: at.normalized, stride: at.stride, offset: at.offset }
        : { constant: (s.constants[a.location] || [0, 0, 0, 1]).slice() };
    }
    const textures = {};
    for (const u of p.samplers) {
      const unit = (p.values.get(u.name) || p.values.get(u.name + '[0]') || [0])[0] | 0;
      const t = s.textures.get(s.units[unit]);
      textures[u.name] = t ? { id: t.id, version: t.version } : null;
    }
    let el = null;
    if (elements) {
      const b = s.buffers.get(v.elements);
      el = b ? { buffer: b.id, version: b.version, type: elements.type, offset: elements.offset } : null;
      if (!b) f.broken = f.broken || 'indices';
    }
    f.size = [gl.drawingBufferWidth, gl.drawingBufferHeight];
    f.draws.push({
      program: p.id, uniforms: Array.from(p.values, ([k, list]) => [k, list.slice()]), attributes, elements: el,
      mode, first, count, textures, blend: s.blend ? s.blendFunc.concat(s.blendEq) : null,
      viewport: s.viewport ? s.viewport.slice() : null, depth: s.depth,
    });
  }
  wrap('drawArrays', null, (s, [mode, first, count], gl) => record(s, gl, mode, first, count, null));
  wrap('drawElements', null, (s, [mode, count, type, offset], gl) => record(s, gl, mode, 0, count, { type, offset }));
  for (const n of ['drawArraysInstanced', 'drawElementsInstanced', 'drawRangeElements']) {
    wrap(n, null, (s, a, gl) => { const f = frameOf(s, gl); f.broken = f.broken || (n === 'drawRangeElements' ? 'range' : 'instanced'); });
  }

  // MARK: The scene, for Bezzle

  const MODES = { 0: 'points', 1: 'lines', 3: 'lineStrip', 4: 'triangles', 5: 'triangleStrip', 6: 'triangleFan' };
  const FACTORS = {
    0: 'zero', 1: 'one', 768: 'src-color', 769: 'one-minus-src-color', 770: 'src-alpha', 771: 'one-minus-src-alpha',
    772: 'dst-alpha', 773: 'one-minus-dst-alpha', 774: 'dst-color', 775: 'one-minus-dst-color', 776: 'src-alpha-saturate',
    32769: 'constant-color', 32770: 'one-minus-constant-color', 32771: 'constant-alpha', 32772: 'one-minus-constant-alpha',
  };
  const EQUATIONS = { 32774: 'func-add', 32778: 'func-subtract', 32779: 'func-reverse-subtract', 32775: 'min', 32776: 'max' };

  const base64 = (bytes) => {
    let s = '';
    for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
    return btoa(s);
  };

  /// A draw's attribute as numbers, vertex after vertex, for the vertices it draws.
  function floats(buffer, at, vertices) {
    const per = { 5120: 1, 5121: 1, 5122: 2, 5123: 2, 5124: 4, 5125: 4, 5126: 4, 5131: 2 }[at.type];
    if (!per) return null;
    const stride = at.stride || per * at.size;
    const view = new DataView(buffer.bytes.buffer, buffer.bytes.byteOffset, buffer.bytes.byteLength);
    const out = new Float32Array(vertices * at.size);
    const half = (h) => { const e = (h >> 10) & 31, m = h & 1023, sign = h & 32768 ? -1 : 1; return e === 0 ? sign * m * 2 ** -24 : e === 31 ? (m ? NaN : sign * Infinity) : sign * (1 + m / 1024) * 2 ** (e - 15); };
    for (let v = 0; v < vertices; v++) {
      for (let c = 0; c < at.size; c++) {
        const o = at.offset + v * stride + c * per;
        if (o + per > view.byteLength) return null;
        let x;
        switch (at.type) {
          case 5126: x = view.getFloat32(o, true); break;
          case 5120: x = view.getInt8(o); if (at.normalized) x = Math.max(x / 127, -1); break;
          case 5121: x = view.getUint8(o); if (at.normalized) x /= 255; break;
          case 5122: x = view.getInt16(o, true); if (at.normalized) x = Math.max(x / 32767, -1); break;
          case 5123: x = view.getUint16(o, true); if (at.normalized) x /= 65535; break;
          case 5124: x = view.getInt32(o, true); break;
          case 5125: x = view.getUint32(o, true); break;
          case 5131: x = half(view.getUint16(o, true)); break;
        }
        out[v * at.size + c] = x;
      }
    }
    return out;
  }

  function indexList(buffer, el, count) {
    const per = { 5121: 1, 5123: 2, 5125: 4 }[el.type];
    if (!per || el.offset + count * per > buffer.bytes.byteLength) return null;
    const view = new DataView(buffer.bytes.buffer, buffer.bytes.byteOffset, buffer.bytes.byteLength);
    const out = new Uint32Array(count);
    for (let i = 0; i < count; i++) out[i] = per === 1 ? view.getUint8(el.offset + i) : per === 2 ? view.getUint16(el.offset + i * 2, true) : view.getUint32(el.offset + i * 4, true);
    return out;
  }

  /// Whether two frames draw the same things with the same pictures and buffers, so that only
  /// their numbers tell them apart.
  function alike(a, b) {
    if (a.draws.length !== b.draws.length || a.size[0] !== b.size[0] || a.size[1] !== b.size[1]) return false;
    for (let i = 0; i < a.draws.length; i++) {
      const x = a.draws[i], y = b.draws[i];
      if (x.program !== y.program || x.mode !== y.mode || x.first !== y.first || x.count !== y.count) return false;
      if (JSON.stringify(x.attributes) !== JSON.stringify(y.attributes) || JSON.stringify(x.elements) !== JSON.stringify(y.elements)) return false;
      if (JSON.stringify(x.textures) !== JSON.stringify(y.textures) || JSON.stringify(x.blend) !== JSON.stringify(y.blend)) return false;
      if (JSON.stringify(x.viewport) !== JSON.stringify(y.viewport) || x.uniforms.length !== y.uniforms.length) return false;
    }
    return true;
  }

  /// What is named as a page names its time: uTime, iTime, u_time, time, t, uFrame and the like.
  const timeLike = /time$|^(u_?|i)?(t|frame|seconds|clock|elapsed)$/i;

  /// How each number that changed over the frames moved: steadily, a clock the shader's time
  /// can run (as much more each second, across the whole while); some other way, recorded as it
  /// went (`ShaderRecording`); or, over too short a while to tell, held as it was, unless it is
  /// named as time is.
  function motions(frames) {
    const last = frames[frames.length - 1];
    const clocks = [], recordings = [];
    let unsteady = false;
    if (frames.length < 2) return { clocks, recordings, unsteady };
    const ts = frames.map((f) => f.time);
    const span = ts[ts.length - 1] - ts[0];
    const long = frames.length >= 8 && span >= 0.75;
    last.draws.forEach((d, i) => {
      for (const [name, values] of d.uniforms) {
        values.forEach((value, k) => {
          const series = frames.map((f) => { const u = f.draws[i].uniforms.find((e) => e[0] === name); return u ? u[1][k] : undefined; });
          if (series.some((x) => x === undefined) || series.every((x) => x === series[0])) return;
          const n = ts.length, mt = ts.reduce((a, b) => a + b) / n, mv = series.reduce((a, b) => a + b) / n;
          let sxx = 0, sxy = 0;
          for (let j = 0; j < n; j++) { sxx += (ts[j] - mt) ** 2; sxy += (ts[j] - mt) * (series[j] - mv); }
          const rate = sxx > 0 ? sxy / sxx : 0;
          const spread = Math.max(...series) - Math.min(...series);
          const off = Math.max(...series.map((x, j) => Math.abs(x - (mv + rate * (ts[j] - mt)))));
          // Frames come a little unevenly: steady is within a fiftieth of how far it went.
          const steady = sxx > 0 && rate !== 0 && off <= Math.max(1e-6, spread * 0.02 + Math.abs(rate) * 0.004);
          const program = d.program;
          if (out(program, name, k)) return;
          if (steady && (long || timeLike.test(name))) {
            clocks.push({ program, uniform: name, component: k, start: series[series.length - 1], rate });
          } else if (long) {
            // As it went, at most thirty times a second.
            const times = [], kept = [];
            for (let j = 0; j < n; j++) {
              const t = ts[j] - ts[0];
              if (j > 0 && j < n - 1 && t - times[times.length - 1] < 1 / 30) continue;
              times.push(t);
              kept.push(series[j]);
            }
            recordings.push({ program, uniform: name, component: k, times, values: kept });
          } else {
            unsteady = true;
          }
        });
      }
    });
    function out(program, name, k) {
      return clocks.some((c) => c.program === program && c.uniform === name && c.component === k)
        || recordings.some((c) => c.program === program && c.uniform === name && c.component === k);
    }
    return { clocks, recordings, unsteady };
  }

  /// A canvas's scene, or why it has none that can be drawn again.
  function scene(canvas) {
    const gl = contexts.get(canvas);
    const s = gl && states.get(gl);
    if (!s) return { why: 'not webgl' };
    // As far as the moment its picture was taken, so that what is kept is what the picture shows.
    const at = parseFloat(canvas.getAttribute('data-bz-canvas-at'));
    const all = s.frames.concat(s.frame ? [s.frame] : []).filter((f) => (f.draws.length || f.clear || f.broken) && !(f.time > at));
    if (!all.length) return { why: 'nothing drawn' };
    const last = all[all.length - 1];
    if (last.broken) return { why: last.broken };
    // Cleared and drawn on no more: what shows is nothing, as the picture of it is.
    if (!last.draws.length) return { why: 'nothing drawn' };
    if (last.draws.length > 64) return { why: 'too many draws' };
    if (last.draws.length > 1 && last.draws.some((d) => d.depth)) return { why: 'depth' };
    // The frames before it that differ from it only in their numbers.
    const run = [];
    for (let i = all.length - 1; i >= 0 && alike(all[i], last) && !all[i].broken; i--) run.unshift(all[i]);
    const { clocks: clockList, recordings: recorded, unsteady } = motions(run);

    const programs = [], programIndex = new Map();
    const pictures = {};
    const draws = [];
    let bytes = 0;
    for (const d of last.draws) {
      let p = null;
      for (const [, o] of s.programs) if (o.id === d.program) p = o;
      if (!p) return { why: 'program gone' };
      if (!programIndex.has(p.id)) { programIndex.set(p.id, programs.length); programs.push({ vertex: p.vertex, fragment: p.fragment }); }
      // How many vertices it reaches.
      let indices = null, vertices = d.first + d.count;
      if (d.elements) {
        let b = null;
        for (const [, o] of s.buffers) if (o.id === d.elements.buffer) b = o;
        if (!b || b.version !== d.elements.version) return { why: 'indices changed' };
        indices = indexList(b, d.elements, d.count);
        if (!indices) return { why: 'indices' };
        vertices = 0;
        for (const i of indices) if (i + 1 > vertices) vertices = i + 1;
      }
      if (vertices > 400000) return { why: 'too many vertices' };
      const attributes = {};
      for (const [name, a] of Object.entries(d.attributes)) {
        if (a.constant) { attributes[name] = { components: a.constant.length, constant: a.constant }; continue; }
        let b = null;
        for (const [, o] of s.buffers) if (o.id === a.buffer) b = o;
        if (!b || b.version !== a.version) return { why: 'buffers changed' };
        const values = floats(b, a, vertices);
        if (!values) return { why: 'attributes' };
        bytes += values.byteLength;
        attributes[name] = { components: a.size, values: base64(new Uint8Array(values.buffer)) };
      }
      const textures = {}, sampling = {};
      let flips = false, premultiplies = false;
      for (const [name, t] of Object.entries(d.textures)) {
        if (!t) continue;
        let tex = null;
        for (const [, o] of s.textures) if (o.id === t.id) tex = o;
        if (!tex || !tex.source) continue;
        if (tex.source.moving) return { why: 'video texture' };
        if (tex.source.unread) return { why: 'texture: ' + tex.source.unread };
        if (tex.partly) return { why: 'texture drawn into' };
        if (!pictures[tex.id]) pictures[tex.id] = { url: tex.source.url || null, data: tex.source.data || null, w: tex.source.w, h: tex.source.h };
        textures[name] = tex.id;
        flips = flips || !!tex.flipY;
        premultiplies = premultiplies || !!tex.premultiply;
        // WebGL's own: wrapping repeats, and far off it reads smaller copies, which a picture
        // without them shows black for; as browsers do, it is read smoothed then.
        const sm = tex.sampling || { wrapS: 'repeat', wrapT: 'repeat', magnify: 'linear', minify: 'nearest', mipFilter: 'linear' };
        const mip = tex.mipmapped && sm.mipFilter ? sm.mipFilter : undefined;
        sampling[name] = { wrapS: sm.wrapS, wrapT: sm.wrapT, magnify: sm.magnify, minify: sm.minify, mipmap: mip };
      }
      if (bytes > 24 * 1024 * 1024) return { why: 'too much geometry' };
      const draw = {
        program: programIndex.get(p.id), uniforms: Object.fromEntries(d.uniforms), attributes, mode: MODES[d.mode] || 'triangles',
        first: d.first, count: d.count, textures, flipsTextures: flips || undefined, premultipliesTextures: premultiplies || undefined,
        sampling: Object.keys(sampling).length ? sampling : undefined,
        indices: indices ? base64(new Uint8Array(indices.buffer)) : undefined,
      };
      if (d.blend) {
        draw.blend = { source: FACTORS[d.blend[0]] || 'one', destination: FACTORS[d.blend[1]] || 'zero', sourceAlpha: FACTORS[d.blend[2]] || 'one',
          destinationAlpha: FACTORS[d.blend[3]] || 'zero', equation: EQUATIONS[d.blend[4]] || 'func-add', equationAlpha: EQUATIONS[d.blend[5]] || 'func-add' };
      }
      if (d.viewport) draw.viewport = d.viewport;
      draws.push(draw);
    }
    // Programs by their place among this scene's, not the page's.
    const clocksOut = clockList.map((c) => Object.assign({}, c, { program: programIndex.get(c.program) })).filter((c) => c.program !== undefined);
    const recordingsOut = recorded.map((c) => Object.assign({}, c, { program: programIndex.get(c.program) })).filter((c) => c.program !== undefined);
    return { size: last.size, clear: last.clear || undefined, programs, draws, clocks: clocksOut, recordings: recordingsOut.length ? recordingsOut : undefined,
      pictures, frames: run.length, still: unsteady || undefined, attributes: s.attributes };
  }

  window.__bezzleGL = {
    /// Every canvas the reader marked, by its mark: its scene as JSON, or why it has none.
    scenes() {
      const out = {};
      for (const canvas of document.querySelectorAll('canvas[data-bz-canvas]')) {
        try { out[canvas.getAttribute('data-bz-canvas')] = scene(canvas); } catch (e) { out[canvas.getAttribute('data-bz-canvas')] = { why: 'error: ' + e.message }; }
      }
      return JSON.stringify(out);
    },
  };
})();
