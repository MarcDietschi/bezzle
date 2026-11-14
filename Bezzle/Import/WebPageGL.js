// Bezzle's recorder of WebGL, in a page it reads or browses: what each WebGL canvas draws, call
// by call, so that a canvas whose picture comes from its shaders alone comes into the design live
// (`ShaderFill`), to be drawn again by Bezzle at any size and any moment. It runs in the page's
// own world before the page's scripts, and changes nothing the page sees but this: a WebGL canvas
// keeps what it drew, so it can be read back whenever Bezzle asks, rather than only in the moment
// it is drawn; and what a page gives `requestAnimationFrame`, `setTimeout` and `setInterval` is
// called through a function of the recorder's, which tells one frame from the next and learns how
// often a page that draws on a timer meant to draw.
//
// `__bezzleGL.scenes()` answers, for each canvas the reader marked (data-bz-canvas), its last
// frame and how it moved over the frames before it: the programs, every draw with its uniforms,
// attributes, indices, textures, blending, tests and masks, pass by pass as the page drew into its
// framebuffers and onto the canvas, and the uniforms that grew steadily with time. A frame is
// what the page drew in one animation frame, or in one task.
//
// A page whose frames build on the frames before them (it reads a texture it drew into the frame
// before) is kept with what those textures held at the moment the reader took the canvas's
// picture: the reader says when (the event `bz-canvas-shot` on the canvas), and the textures are
// read back then.
(() => {
  'use strict';
  const GL1 = window.WebGLRenderingContext;
  if (!GL1 || window.__bezzleGL) return;
  const GL2 = window.WebGL2RenderingContext;
  const protos = [GL1.prototype].concat(GL2 ? [GL2.prototype] : []);

  const ARRAY_BUFFER = 34962, ELEMENT_ARRAY_BUFFER = 34963, UNIFORM_BUFFER = 35345, TEXTURE_2D = 3553, TEXTURE0 = 33984;
  const VERTEX_SHADER = 35633, FRAGMENT_SHADER = 35632, COLOR_BUFFER_BIT = 16384, DEPTH_BUFFER_BIT = 256, STENCIL_BUFFER_BIT = 1024;
  const BLEND = 3042, DEPTH_TEST = 2929, STENCIL_TEST = 2960, CULL_FACE = 2884, SCISSOR_TEST = 3089, POLYGON_OFFSET_FILL = 32823;
  const UNPACK_FLIP_Y = 37440, UNPACK_PREMULTIPLY = 37441, UNPACK_ALIGNMENT = 3317;
  const FRAMEBUFFER = 36160, READ_FRAMEBUFFER = 36008, DRAW_FRAMEBUFFER = 36009, COLOR_ATTACHMENT0 = 36064;
  const WRAPS = { 10497: 'repeat', 33071: 'clamp', 33648: 'mirror' };
  const FILTERS = { 9728: ['nearest'], 9729: ['linear'], 9984: ['nearest', 'nearest'], 9985: ['linear', 'nearest'], 9986: ['nearest', 'linear'], 9987: ['linear', 'linear'] };
  const SAMPLERS = new Set([35678, 35680, 36289, 36298, 36299, 36303, 36306, 36307, 36311]);
  const CUBES = new Set([35680, 36300, 36304, 36312]);
  /// No more draws than these in a frame, and no more of a simulation's state than this, are kept.
  const MOST_DRAWS = 400, MOST_STATE = 12 * 1024 * 1024;

  /// Each context's state as the page set it, and what it drew.
  const states = new WeakMap();
  /// Each canvas's context, as the page asked for it.
  const contexts = new WeakMap();
  /// Each canvas's scene as it was when the reader took its picture.
  const shots = new WeakMap();
  let ids = 0;
  /// Set while the recorder itself calls WebGL, which is not the page's drawing.
  let quiet = false;

  const CANVAS = { canvas: true, key: 'canvas', colors: [], depth: null, stencil: false };

  function state(gl) {
    let s = states.get(gl);
    if (!s) {
      s = {
        programs: new Map(), shaders: new Map(), buffers: new Map(), textures: new Map(), locations: new WeakMap(),
        framebuffers: new Map(), renderbuffers: new Map(),
        program: null, arrayBuffer: null, uniformBuffer: null, bindings: [], vao: null, vaos: new Map(), plain: { attribs: [], elements: null },
        units: [], unit: 0, flipY: false, premultiply: false, alignment: 4,
        blend: false, blendFunc: [1, 0, 1, 0], blendEq: [32774, 32774], blendColor: [0, 0, 0, 0],
        viewport: null, clearColor: [0, 0, 0, 0], clearDepth: 1, clearStencil: 0,
        framebuffer: null, readFramebuffer: null, renderbuffer: null,
        depthTest: false, depthFunc: 513, depthMask: true, depthRange: [0, 1],
        stencilTest: false, stencilFront: { func: 519, ref: 0, mask: 255, write: 255, fail: 7680, zfail: 7680, zpass: 7680 },
        stencilBack: { func: 519, ref: 0, mask: 255, write: 255, fail: 7680, zfail: 7680, zpass: 7680 },
        cullFace: false, cullMode: 1029, frontFace: 2305, colorMask: [true, true, true, true],
        scissorTest: false, scissor: null, offsetFill: false, offset: [0, 0],
        constants: [], frames: [], frame: null, attributes: {},
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
  // A page that draws on a timer says how often it means to: the web view Bezzle reads a page
  // in runs timers slower than a browser's window does, so how often frames really came says
  // nothing. A frame that builds on the frame before is then stepped as often as the page
  // asked for (`rate`), and one drawn in an animation frame sixty times a second.
  let timerEvery = null;
  for (const name of ['setInterval', 'setTimeout']) {
    const original = window[name];
    if (typeof original !== 'function') continue;
    window[name] = function (handler, delay, ...rest) {
      if (typeof handler !== 'function') return original.call(window, handler, delay, ...rest);
      const every = Math.max(0, +delay || 0);
      return original.call(window, function (...args) {
        const before = timerEvery;
        timerEvery = every;
        try { return handler.apply(this, args); } finally { timerEvery = before; }
      }, delay, ...rest);
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
    if (s.frame && (s.frame.ops.length || s.frame.broken)) {
      s.frames.push(s.frame);
      // The last few seconds, to tell what runs with time from what the page moves otherwise.
      const now = performance.now() / 1000;
      while (s.frames.length && (now - s.frames[0].time > 6 || s.frames.length > 480)) s.frames.shift();
    }
    s.frame = { key, time: performance.now() / 1000, ops: [], broken: null, size: [gl.drawingBufferWidth, gl.drawingBufferHeight],
      every: frameStamp !== null ? null : timerEvery };
  }

  /// One more thing the page did in its frame; a frame of more than can be kept is given up.
  function push(f, op) {
    if (f.ops.length >= MOST_DRAWS * 2) { f.broken = f.broken || 'too many draws'; return; }
    f.ops.push(op);
  }

  // MARK: Wrapping

  function wrap(name, after, before) {
    for (const p of protos) {
      const f = p[name];
      if (typeof f !== 'function' || f.__bz) continue;
      const g = function (...args) {
        if (quiet) return f.apply(this, args);
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
    const preserves = !!(webgl && attributes && attributes.preserveDrawingBuffer);
    if (webgl) attributes = Object.assign({}, attributes, { preserveDrawingBuffer: true });
    const ctx = getContext.call(this, type, attributes);
    if (webgl && ctx) {
      const first = !contexts.has(this);
      contexts.set(this, ctx);
      const asked = ctx.getContextAttributes ? ctx.getContextAttributes() : null;
      if (asked && first) {
        state(ctx).attributes = { alpha: asked.alpha !== false, premultipliedAlpha: asked.premultipliedAlpha !== false, antialias: asked.antialias !== false,
          depth: asked.depth !== false, stencil: asked.stencil === true, preserves };
      }
    }
    return ctx;
  };

  wrap('createShader', (s, [type], r) => { if (r) s.shaders.set(r, { type, source: '' }); });
  wrap('shaderSource', (s, [sh, src]) => { const o = s.shaders.get(sh); if (o) o.source = String(src); });
  wrap('createProgram', (s, a, r) => { if (r) s.programs.set(r, { id: ++ids, shaders: [], values: new Map(), attributes: [], samplers: [], blocks: [], cubes: false }); });
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
    o.blocks = [];
    quiet = true;
    try {
      const attributes = gl.getProgramParameter(p, 35721) || 0;
      for (let i = 0; i < attributes; i++) {
        const info = gl.getActiveAttrib(p, i);
        if (info) o.attributes.push({ name: info.name, location: gl.getAttribLocation(p, info.name) });
      }
      const uniforms = gl.getProgramParameter(p, 35718) || 0;
      const infos = [];
      for (let i = 0; i < uniforms; i++) {
        const info = gl.getActiveUniform(p, i);
        infos.push(info);
        if (!info || !SAMPLERS.has(info.type)) continue;
        if (CUBES.has(info.type)) o.cubes = true;
        o.samplers.push({ name: info.name.replace(/\[0\]$/, ''), location: gl.getUniformLocation(p, info.name) });
      }
      // WebGL 2's uniform blocks: where each member lies in the block's bytes.
      const blocks = gl.getActiveUniformBlockName ? gl.getProgramParameter(p, 35382) || 0 : 0;
      for (let b = 0; b < blocks; b++) {
        const list = Array.from(gl.getActiveUniformBlockParameter(p, b, 35395) || []);
        const offsets = gl.getActiveUniforms(p, list, 35387), strides = gl.getActiveUniforms(p, list, 35388);
        const columns = gl.getActiveUniforms(p, list, 35389), rows = gl.getActiveUniforms(p, list, 35390);
        const members = list.map((u, i) => ({ name: infos[u] ? infos[u].name.replace(/\[0\]$/, '') : null, type: infos[u] && infos[u].type, size: infos[u] ? infos[u].size : 0,
          offset: offsets[i], stride: strides[i], column: columns[i], rowMajor: !!rows[i] })).filter((m) => m.name);
        o.blocks.push({ index: b, binding: gl.getActiveUniformBlockParameter(p, b, 35391) || 0, members });
      }
    } finally { quiet = false; }
  });
  wrap('uniformBlockBinding', (s, [p, index, binding]) => { const o = s.programs.get(p); const b = o && o.blocks.find((x) => x.index === index); if (b) b.binding = binding; });
  wrap('useProgram', (s, [p]) => { s.program = p; });
  wrap('getUniformLocation', (s, [p, name], r) => { if (r) s.locations.set(r, { program: p, name: String(name) }); });

  /// A uniform's numbers are never changed in place once set: every draw that saw them keeps them.
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
    const columns = +n[0], rows = +(n[2] || n[0]);
    wrap(`uniformMatrix${n}fv`, (s, [loc, transpose, data, offset, length]) => {
      let list = Array.from(data || [], Number);
      if (offset) list = list.slice(offset, length ? offset + length : undefined);
      // Given row by row: turned into columns, as every matrix is kept.
      if (transpose) {
        const turned = list.slice(), per = columns * rows;
        for (let m = 0; m + per <= list.length; m += per) {
          for (let c = 0; c < columns; c++) for (let r = 0; r < rows; r++) turned[m + c * rows + r] = list[m + r * columns + c];
        }
        list = turned;
      }
      setUniform(s, loc, list);
    });
  }

  // Buffers and where attributes come from.
  wrap('createBuffer', (s, a, r) => { if (r) s.buffers.set(r, { id: ++ids, bytes: new Uint8Array(0), version: 0 }); });
  wrap('bindBuffer', (s, [target, b]) => {
    if (target === ARRAY_BUFFER) s.arrayBuffer = b;
    else if (target === ELEMENT_ARRAY_BUFFER) vao(s).elements = b;
    else if (target === UNIFORM_BUFFER) s.uniformBuffer = b;
  });
  wrap('bindBufferBase', (s, [target, index, b]) => { if (target === UNIFORM_BUFFER) { s.uniformBuffer = b; s.bindings[index] = { buffer: b, offset: 0 }; } });
  wrap('bindBufferRange', (s, [target, index, b, offset]) => { if (target === UNIFORM_BUFFER) { s.uniformBuffer = b; s.bindings[index] = { buffer: b, offset: offset || 0 }; } });
  const bound = (s, target) => (target === ARRAY_BUFFER ? s.arrayBuffer : target === ELEMENT_ARRAY_BUFFER ? vao(s).elements : target === UNIFORM_BUFFER ? s.uniformBuffer : null);
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
    else if (b.held) { b.bytes = b.bytes.slice(); b.held = false; }
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
  const setDivisor = (s, i, d) => { const v = vao(s); v.attribs[i] = Object.assign({}, v.attribs[i], { divisor: d | 0 }); };
  wrap('vertexAttribDivisor', (s, [i, d]) => setDivisor(s, i, d));
  wrap('createVertexArray', (s, a, r) => { if (r) s.vaos.set(r, { attribs: [], elements: null }); });
  wrap('bindVertexArray', (s, [v]) => { s.vao = v; });
  // The same for WebGL 1, through its extensions.
  wrap('getExtension', (s, [name], ext, gl) => {
    if (!ext || ext.__bz) return;
    ext.__bz = true;
    if (/vertex_array_object/i.test(name)) {
      const make = ext.createVertexArrayOES, bind = ext.bindVertexArrayOES;
      ext.createVertexArrayOES = function () { const r = make.call(this); if (r) s.vaos.set(r, { attribs: [], elements: null }); return r; };
      ext.bindVertexArrayOES = function (v) { s.vao = v; return bind.call(this, v); };
    }
    if (/instanced_arrays/i.test(name)) {
      const divisor = ext.vertexAttribDivisorANGLE, drawA = ext.drawArraysInstancedANGLE, drawE = ext.drawElementsInstancedANGLE;
      ext.vertexAttribDivisorANGLE = function (i, d) { setDivisor(s, i, d); return divisor.call(this, i, d); };
      ext.drawArraysInstancedANGLE = function (mode, first, count, n) { try { record(s, gl, mode, first, count, null, n); } catch (e) {} return drawA.call(this, mode, first, count, n); };
      ext.drawElementsInstancedANGLE = function (mode, count, type, offset, n) { try { record(s, gl, mode, 0, count, { type, offset }, n); } catch (e) {} return drawE.call(this, mode, count, type, offset, n); };
    }
    if (/draw_buffers/i.test(name) && ext.drawBuffersWEBGL) {
      const set = ext.drawBuffersWEBGL;
      ext.drawBuffersWEBGL = function (list) { drawBuffers(s, list); return set.call(this, list); };
    }
  });

  // Textures.
  wrap('createTexture', (s, a, r) => { if (r) s.textures.set(r, { id: ++ids, version: 0, source: null }); });
  wrap('deleteTexture', (s, [t]) => { s.textures.delete(t); });
  wrap('activeTexture', (s, [unit]) => { s.unit = unit - TEXTURE0; });
  wrap('bindTexture', (s, [target, t]) => { if (target === TEXTURE_2D) s.units[s.unit] = t; });
  wrap('pixelStorei', (s, [name, value]) => {
    if (name === UNPACK_FLIP_Y) s.flipY = !!value; else if (name === UNPACK_PREMULTIPLY) s.premultiply = !!value; else if (name === UNPACK_ALIGNMENT) s.alignment = value || 4;
  });
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
  wrap('generateMipmap', (s, [target], r, gl) => {
    const t = target === TEXTURE_2D && s.textures.get(s.units[s.unit]);
    if (!t) return;
    t.mipmapped = true;
    // Of a texture the page drew into: made again whenever it is drawn into.
    if (t.drawn) push(frameOf(s, gl), { op: 'mipmap', texture: t });
  });

  /// What a texel of a texture is, from how the page asked for it: its kind for Bezzle
  /// ("rgba8", "r16f"...), with `opaque` for RGB, or nothing for a kind that is not kept.
  const SRGB = new Set([35904, 35905, 35906, 35907]);
  function kindOf(internal, format, type) {
    switch (internal) {
      case 32856: case 35907: case 32854: case 32855: return { kind: 'rgba8' };
      case 32849: case 35905: case 36194: return { kind: 'rgba8', opaque: true };
      case 33321: return { kind: 'r8' };
      case 33323: return { kind: 'rg8' };
      case 34842: return { kind: 'rgba16f' };
      case 34843: case 35898: return { kind: 'rgba16f', opaque: true };
      case 33325: return { kind: 'r16f' };
      case 33327: return { kind: 'rg16f' };
      case 34836: return { kind: 'rgba32f' };
      case 34837: return { kind: 'rgba32f', opaque: true };
      case 33326: return { kind: 'r32f' };
      case 33328: return { kind: 'rg32f' };
    }
    const depth = type === 5126 ? '32f' : type === 5131 || type === 36193 ? '16f' : type === 5121 ? '8' : null;
    if (!depth) return type === 33635 || type === 32819 || type === 32820 ? { kind: 'rgba8', opaque: type === 33635 } : null;
    const f = format || internal;
    if (f === 6408 || f === 35906) return { kind: 'rgba' + depth };
    if (f === 6407 || f === 35904) return { kind: 'rgba' + depth, opaque: true };
    if (f === 6403) return { kind: 'r' + depth };
    if (f === 33319) return { kind: 'rg' + depth };
    return null;
  }

  /// What a texture was given: a picture's address, a picture as it was (kept until asked for),
  /// a video, or numbers from a typed array.
  function sourceOf(s, last, w, h, format, type, internal, offset) {
    try {
      if (last instanceof HTMLImageElement) return { url: last.currentSrc || last.src, w: last.naturalWidth, h: last.naturalHeight };
      if (last instanceof HTMLVideoElement) return { video: last, w: last.videoWidth, h: last.videoHeight };
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
      if (last === null || last === undefined) return { data: null, w, h };
      // Numbers from a typed array, kept as they are until a draw that reads them is kept.
      if (ArrayBuffer.isView(last)) {
        const per = last.BYTES_PER_ELEMENT || 1;
        if (w * h > 4096 * 4096 || last.byteLength > 64 * 1024 * 1024) return { unread: 'pixels too many' };
        const from = last.byteOffset + (offset || 0) * per;
        return { raw: new Uint8Array(last.buffer.slice(from, last.byteOffset + last.byteLength)), w, h, format, type, internal, alignment: s.alignment };
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
    const sized = args.length >= 9;
    t.source = sized ? sourceOf(s, args[8], args[3], args[4], args[6], args[7], args[2], args[9]) : sourceOf(s, args[5], 0, 0, args[3], args[4], args[2]);
    if (sized) t.alloc = { w: args[3], h: args[4], internal: args[2], format: args[6], type: args[7] };
    else t.alloc = { w: t.source.w || 0, h: t.source.h || 0, internal: args[2], format: args[3], type: args[4] };
    t.decodes = SRGB.has(args[2]);
    t.flipY = s.flipY;
    t.premultiply = s.premultiply;
    t.partly = false;
    t.version++;
  });
  wrap('texStorage2D', (s, [target, levels, internal, w, h]) => {
    const t = target === TEXTURE_2D && s.textures.get(s.units[s.unit]);
    if (!t) return;
    t.alloc = { w, h, internal, format: 0, type: 0 };
    t.source = { data: null, w, h };
    t.decodes = SRGB.has(internal);
    t.partly = false;
    t.version++;
  });
  wrap('texSubImage2D', (s, args) => {
    if (args[0] !== TEXTURE_2D) return;
    const t = s.textures.get(s.units[s.unit]);
    if (!t) return;
    t.version++;
    if (args[1] !== 0) return;
    // All of it given anew is as good as texImage2D, which is how WebGL 2 pages fill a texture.
    const sized = args.length >= 9;
    const last = sized ? args[8] : args[6];
    let w = sized ? args[4] : 0, h = sized ? args[5] : 0;
    if (!sized && last) { w = last.naturalWidth || last.videoWidth || last.width || 0; h = last.naturalHeight || last.videoHeight || last.height || 0; }
    const whole = args[2] === 0 && args[3] === 0 && (!t.alloc || !t.alloc.w || (w >= t.alloc.w && h >= t.alloc.h));
    if (!whole) { t.partly = true; return; }
    const internal = t.alloc ? t.alloc.internal : 0;
    t.source = sized ? sourceOf(s, last, w, h, args[6], args[7], internal, args[9]) : sourceOf(s, last, w, h, args[4], args[5], internal);
    if (t.alloc && !t.alloc.w) { t.alloc.w = w; t.alloc.h = h; }
    t.flipY = s.flipY;
    t.premultiply = s.premultiply;
    t.partly = false;
  });
  for (const n of ['compressedTexImage2D', 'compressedTexSubImage2D']) {
    wrap(n, (s, [target]) => { const t = target === TEXTURE_2D && s.textures.get(s.units[s.unit]); if (t) { t.source = { unread: 'a compressed texture' }; t.version++; } });
  }
  for (const n of ['copyTexImage2D', 'copyTexSubImage2D']) {
    wrap(n, (s, [target]) => { const t = target === TEXTURE_2D && s.textures.get(s.units[s.unit]); if (t) { t.source = { unread: 'copied from what was drawn' }; t.version++; } });
  }

  // Framebuffers: what the page draws into when not onto the canvas.
  wrap('createFramebuffer', (s, a, r) => { if (r) s.framebuffers.set(r, { id: ++ids, color: [], depth: null, stencil: false, drawBuffers: null, dst: null }); });
  wrap('deleteFramebuffer', (s, [fb]) => { s.framebuffers.delete(fb); });
  wrap('createRenderbuffer', (s, a, r) => { if (r) s.renderbuffers.set(r, { id: ++ids, w: 0, h: 0, internal: 0 }); });
  wrap('deleteRenderbuffer', (s, [rb]) => { s.renderbuffers.delete(rb); });
  wrap('bindRenderbuffer', (s, [target, rb]) => { s.renderbuffer = rb; });
  wrap('renderbufferStorage', (s, [target, internal, w, h]) => { const rb = s.renderbuffers.get(s.renderbuffer); if (rb) Object.assign(rb, { w, h, internal }); });
  wrap('renderbufferStorageMultisample', (s, [target, samples, internal, w, h]) => { const rb = s.renderbuffers.get(s.renderbuffer); if (rb) Object.assign(rb, { w, h, internal }); });
  wrap('bindFramebuffer', (s, [target, fb]) => {
    if (target === FRAMEBUFFER) { s.framebuffer = fb; s.readFramebuffer = fb; } else if (target === DRAW_FRAMEBUFFER) s.framebuffer = fb; else if (target === READ_FRAMEBUFFER) s.readFramebuffer = fb;
  });
  const framebufferOf = (s, target) => s.framebuffers.get(target === READ_FRAMEBUFFER ? s.readFramebuffer : s.framebuffer);
  function attach(s, target, attachment, what) {
    const fb = framebufferOf(s, target);
    if (!fb) return;
    fb.dst = null;
    if (attachment >= COLOR_ATTACHMENT0 && attachment < COLOR_ATTACHMENT0 + 16) fb.color[attachment - COLOR_ATTACHMENT0] = what;
    else if (attachment === 36096) fb.depth = what;
    else if (attachment === 33306) { fb.depth = what; fb.stencil = !!what; }
    else if (attachment === 36128) fb.stencil = !!what;
  }
  wrap('framebufferTexture2D', (s, [target, attachment, textarget, texture, level]) => {
    const t = texture && s.textures.get(texture);
    attach(s, target, attachment, t ? { texture: t, key: 't' + t.id, other: textarget !== TEXTURE_2D ? 'draws into a cube' : level ? 'draws into a smaller copy of a texture' : null } : null);
  });
  wrap('framebufferTextureLayer', (s, [target, attachment, texture]) => { attach(s, target, attachment, texture ? { key: 'l' + (++ids), other: 'draws into a layer of a texture' } : null); });
  wrap('framebufferRenderbuffer', (s, [target, attachment, rbtarget, rb]) => {
    const r = rb && s.renderbuffers.get(rb);
    attach(s, target, attachment, r ? { renderbuffer: r, key: 'r' + r.id } : null);
  });
  function drawBuffers(s, list) {
    const fb = s.framebuffers.get(s.framebuffer);
    if (!fb) return;
    fb.drawBuffers = Array.from(list || [], (v) => (v >= COLOR_ATTACHMENT0 ? v - COLOR_ATTACHMENT0 : null));
    fb.dst = null;
  }
  wrap('drawBuffers', (s, [list]) => drawBuffers(s, list));

  /// What is drawn into now: the canvas, or a framebuffer's textures, as they are attached at
  /// this moment.
  function destination(s) {
    const fb = s.framebuffer && s.framebuffers.get(s.framebuffer);
    if (!fb) return CANVAS;
    if (fb.dst) return fb.dst;
    const list = fb.drawBuffers || [0];
    const colors = [];
    let other = null;
    list.forEach((slot, i) => {
      const a = slot === null ? null : fb.color[slot];
      if (!a) { if (list.slice(i + 1).some((x) => x !== null && fb.color[x])) other = 'draws into some of its outputs only'; return; }
      if (a.other) other = other || a.other;
      colors.push(a);
    });
    if (!colors.length) other = other || 'draws depth alone';
    if (colors.length > 4) other = other || 'draws into more than four textures';
    fb.dst = { canvas: false, colors, depth: fb.depth ? fb.depth.key : null, stencil: fb.stencil, other,
      key: colors.map((c) => c.key).join(',') + '/' + (fb.depth ? fb.depth.key : '') };
    return fb.dst;
  }
  const mark = (dst) => { for (const c of dst.colors) if (c.texture) c.texture.drawn = true; };

  // How draws lie over each other, and where.
  const CAPS = { [BLEND]: 'blend', [DEPTH_TEST]: 'depthTest', [STENCIL_TEST]: 'stencilTest', [CULL_FACE]: 'cullFace', [SCISSOR_TEST]: 'scissorTest', [POLYGON_OFFSET_FILL]: 'offsetFill' };
  wrap('enable', (s, [cap]) => { if (CAPS[cap]) s[CAPS[cap]] = true; });
  wrap('disable', (s, [cap]) => { if (CAPS[cap]) s[CAPS[cap]] = false; });
  wrap('blendFunc', (s, [a, b]) => { s.blendFunc = [a, b, a, b]; });
  wrap('blendFuncSeparate', (s, [a, b, c, d]) => { s.blendFunc = [a, b, c, d]; });
  wrap('blendEquation', (s, [m]) => { s.blendEq = [m, m]; });
  wrap('blendEquationSeparate', (s, [a, b]) => { s.blendEq = [a, b]; });
  wrap('blendColor', (s, [r, g, b, a]) => { s.blendColor = [+r || 0, +g || 0, +b || 0, +a || 0]; });
  wrap('viewport', (s, [x, y, w, h]) => { s.viewport = [x, y, w, h]; });
  wrap('scissor', (s, [x, y, w, h]) => { s.scissor = [x, y, w, h]; });
  wrap('clearColor', (s, [r, g, b, a]) => { s.clearColor = [r, g, b, a]; });
  wrap('clearDepth', (s, [d]) => { s.clearDepth = Math.min(1, Math.max(0, +d)); });
  wrap('clearStencil', (s, [v]) => { s.clearStencil = v | 0; });
  wrap('depthFunc', (s, [f]) => { s.depthFunc = f; });
  wrap('depthMask', (s, [on]) => { s.depthMask = !!on; });
  wrap('depthRange', (s, [near, far]) => { s.depthRange = [+near, +far]; });
  wrap('colorMask', (s, [r, g, b, a]) => { s.colorMask = [!!r, !!g, !!b, !!a]; });
  wrap('cullFace', (s, [mode]) => { s.cullMode = mode; });
  wrap('frontFace', (s, [mode]) => { s.frontFace = mode; });
  wrap('polygonOffset', (s, [factor, units]) => { s.offset = [+factor, +units]; });
  const faces = (s, face) => (face === 1028 ? [s.stencilFront] : face === 1029 ? [s.stencilBack] : [s.stencilFront, s.stencilBack]);
  wrap('stencilFunc', (s, [func, ref, mask]) => { for (const f of faces(s, 1032)) Object.assign(f, { func, ref: ref | 0, mask: mask & 255 }); });
  wrap('stencilFuncSeparate', (s, [face, func, ref, mask]) => { for (const f of faces(s, face)) Object.assign(f, { func, ref: ref | 0, mask: mask & 255 }); });
  wrap('stencilMask', (s, [mask]) => { for (const f of faces(s, 1032)) f.write = mask & 255; });
  wrap('stencilMaskSeparate', (s, [face, mask]) => { for (const f of faces(s, face)) f.write = mask & 255; });
  wrap('stencilOp', (s, [fail, zfail, zpass]) => { for (const f of faces(s, 1032)) Object.assign(f, { fail, zfail, zpass }); });
  wrap('stencilOpSeparate', (s, [face, fail, zfail, zpass]) => { for (const f of faces(s, face)) Object.assign(f, { fail, zfail, zpass }); });

  function cleared(s, gl, mask, color, depth, stencil) {
    const dst = destination(s);
    mark(dst);
    push(frameOf(s, gl), { op: 'clear', dst, mask, color, depth, stencil, scissor: s.scissorTest && s.scissor ? s.scissor.slice() : null,
      colorMask: s.colorMask.slice(), depthMask: s.depthMask, stencilMask: s.stencilFront.write });
  }
  wrap('clear', null, (s, [mask], gl) => cleared(s, gl, mask, s.clearColor.slice(), s.clearDepth, s.clearStencil));
  // WebGL 2's clears of one buffer.
  for (const n of ['clearBufferfv', 'clearBufferiv', 'clearBufferuiv']) {
    wrap(n, null, (s, [buffer, index, values, offset], gl) => {
      const v = Array.from(values || [], Number).slice(offset || 0);
      if (buffer === 6144) {
        if (index !== 0 || destination(s).colors.length > 1 || n !== 'clearBufferfv') { frameOf(s, gl).broken = frameOf(s, gl).broken || 'clears one of its outputs'; return; }
        cleared(s, gl, COLOR_BUFFER_BIT, v.slice(0, 4), s.clearDepth, s.clearStencil);
      } else if (buffer === 6145) cleared(s, gl, DEPTH_BUFFER_BIT, s.clearColor.slice(), v[0], s.clearStencil);
      else if (buffer === 6146) cleared(s, gl, STENCIL_BUFFER_BIT, s.clearColor.slice(), s.clearDepth, v[0] | 0);
    });
  }
  wrap('clearBufferfi', null, (s, [buffer, index, depth, stencil], gl) => cleared(s, gl, DEPTH_BUFFER_BIT | STENCIL_BUFFER_BIT, s.clearColor.slice(), depth, stencil | 0));
  wrap('blitFramebuffer', null, (s, [sx0, sy0, sx1, sy1, dx0, dy0, dx1, dy1, mask, filter], gl) => {
    if (!(mask & COLOR_BUFFER_BIT)) return;
    const from = s.readFramebuffer && s.framebuffers.get(s.readFramebuffer);
    const f = frameOf(s, gl);
    if (!from || !from.color[0]) { f.broken = f.broken || 'copies from the canvas'; return; }
    const dst = destination(s);
    mark(dst);
    push(f, { op: 'blit', dst, from: from.color[0], source: [sx0, sy0, sx1, sy1], box: [dx0, dy0, dx1, dy1], linear: filter === 9729,
      scissor: s.scissorTest && s.scissor ? s.scissor.slice() : null });
  });
  for (const n of ['readPixels']) wrap(n, null, () => {});

  /// A program's uniform blocks as numbers by member, from the bytes bound to them now: decoded
  /// once for each change of a buffer.
  function blockValues(s, p) {
    const out = [];
    for (const block of p.blocks) {
      const at = s.bindings[block.binding];
      const b = at && s.buffers.get(at.buffer);
      if (!b) continue;
      if (!block.cache || block.cache.buffer !== b || block.cache.version !== b.version || block.cache.offset !== at.offset) {
        block.cache = { buffer: b, version: b.version, offset: at.offset, values: decodeBlock(block, b.bytes, at.offset) };
      }
      for (const pair of block.cache.values) out.push(pair);
    }
    return out;
  }
  const SHAPES = {
    5126: [1, 1, 'f'], 35664: [1, 2, 'f'], 35665: [1, 3, 'f'], 35666: [1, 4, 'f'], 5124: [1, 1, 'i'], 35667: [1, 2, 'i'], 35668: [1, 3, 'i'], 35669: [1, 4, 'i'],
    5125: [1, 1, 'u'], 36294: [1, 2, 'u'], 36295: [1, 3, 'u'], 36296: [1, 4, 'u'], 35670: [1, 1, 'u'], 35671: [1, 2, 'u'], 35672: [1, 3, 'u'], 35673: [1, 4, 'u'],
    35674: [2, 2, 'f'], 35675: [3, 3, 'f'], 35676: [4, 4, 'f'], 35685: [2, 3, 'f'], 35686: [2, 4, 'f'], 35687: [3, 2, 'f'], 35688: [3, 4, 'f'], 35689: [4, 2, 'f'], 35690: [4, 3, 'f'],
  };
  function decodeBlock(block, bytes, base) {
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    const read = (o, kind) => {
      if (o < 0 || o + 4 > view.byteLength) return 0;
      const x = kind === 'f' ? view.getFloat32(o, true) : kind === 'i' ? view.getInt32(o, true) : view.getUint32(o, true);
      return Number.isFinite(x) ? x : 0;
    };
    const out = [];
    for (const m of block.members) {
      const shape = SHAPES[m.type];
      if (!shape) continue;
      const [columns, rows, kind] = shape;
      const values = [];
      for (let e = 0; e < Math.max(1, m.size); e++) {
        const at = base + m.offset + e * (m.stride || 0);
        if (columns === 1) { for (let r = 0; r < rows; r++) values.push(read(at + r * 4, kind)); continue; }
        // Columns one after the other, as every matrix is kept; a row-major block has them across.
        for (let c = 0; c < columns; c++) {
          for (let r = 0; r < rows; r++) values.push(m.rowMajor ? read(at + r * m.column + c * 4, kind) : read(at + c * m.column + r * 4, kind));
        }
      }
      out.push([m.name, values]);
    }
    return out;
  }

  function record(s, gl, mode, first, count, elements, instances) {
    const f = frameOf(s, gl);
    const p = s.programs.get(s.program);
    if (!p || !p.vertex || !p.fragment) return;
    if (p.cubes) f.broken = f.broken || 'cube';
    const dst = destination(s);
    mark(dst);
    const v = vao(s);
    const attributes = {};
    for (const a of p.attributes) {
      if (a.location < 0 || /^gl_/.test(a.name)) continue;
      const at = v.attribs[a.location];
      const b = at && at.enabled && s.buffers.get(at.buffer);
      attributes[a.name] = b
        ? { buffer: b, version: b.version, size: at.size, type: at.type, normalized: at.normalized, stride: at.stride, offset: at.offset, divisor: at.divisor || 0 }
        : { constant: (s.constants[a.location] || [0, 0, 0, 1]).slice() };
    }
    const textures = {};
    for (const u of p.samplers) {
      const unit = (p.values.get(u.name) || p.values.get(u.name + '[0]') || [0])[0] | 0;
      const t = s.textures.get(s.units[unit]);
      textures[u.name] = t ? { texture: t, version: t.version } : null;
    }
    let el = null;
    if (elements) {
      const b = s.buffers.get(v.elements);
      el = b ? { buffer: b, version: b.version, type: elements.type, offset: elements.offset } : null;
      if (!b) f.broken = f.broken || 'indices';
    }
    if (dst.canvas) f.size = [gl.drawingBufferWidth, gl.drawingBufferHeight];
    const uniforms = Array.from(p.values);
    if (p.blocks.length) for (const pair of blockValues(s, p)) uniforms.push(pair);
    const front = s.stencilFront, back = s.stencilBack;
    push(f, {
      op: 'draw', dst, program: p, uniforms, attributes, elements: el,
      mode, first, count, instances: instances === undefined ? null : Math.max(0, instances | 0), textures,
      blend: s.blend ? s.blendFunc.concat(s.blendEq) : null, viewport: s.viewport ? s.viewport.slice() : null,
      // blendColor, where a factor takes it (CONSTANT_COLOR to ONE_MINUS_CONSTANT_ALPHA).
      constant: s.blend && s.blendFunc.some((x) => x >= 32769 && x <= 32772) ? s.blendColor.slice() : null,
      depth: s.depthTest ? [s.depthFunc, s.depthMask, s.depthRange[0], s.depthRange[1]] : null,
      stencil: s.stencilTest ? [front.func, front.ref, front.mask, front.write, front.fail, front.zfail, front.zpass, back.func, back.ref, back.mask, back.write, back.fail, back.zfail, back.zpass] : null,
      cull: s.cullFace ? s.cullMode : 0, clockwise: s.frontFace === 2304,
      mask: s.colorMask.every(Boolean) ? null : s.colorMask.slice(),
      scissor: s.scissorTest && s.scissor ? s.scissor.slice() : null, offset: s.offsetFill && (s.offset[0] || s.offset[1]) ? s.offset.slice() : null,
    });
  }
  wrap('drawArrays', null, (s, [mode, first, count], gl) => record(s, gl, mode, first, count, null));
  wrap('drawElements', null, (s, [mode, count, type, offset], gl) => record(s, gl, mode, 0, count, { type, offset }));
  wrap('drawRangeElements', null, (s, [mode, start, end, count, type, offset], gl) => record(s, gl, mode, 0, count, { type, offset }));
  wrap('drawArraysInstanced', null, (s, [mode, first, count, n], gl) => record(s, gl, mode, first, count, null, n));
  wrap('drawElementsInstanced', null, (s, [mode, count, type, offset, n], gl) => record(s, gl, mode, 0, count, { type, offset }, n));

  // MARK: The scene, for Bezzle

  const MODES = { 0: 'points', 1: 'lines', 2: 'lineLoop', 3: 'lineStrip', 4: 'triangles', 5: 'triangleStrip', 6: 'triangleFan' };
  const FACTORS = {
    0: 'zero', 1: 'one', 768: 'src-color', 769: 'one-minus-src-color', 770: 'src-alpha', 771: 'one-minus-src-alpha',
    772: 'dst-alpha', 773: 'one-minus-dst-alpha', 774: 'dst-color', 775: 'one-minus-dst-color', 776: 'src-alpha-saturate',
    32769: 'constant-color', 32770: 'one-minus-constant-color', 32771: 'constant-alpha', 32772: 'one-minus-constant-alpha',
  };
  const EQUATIONS = { 32774: 'func-add', 32778: 'func-subtract', 32779: 'func-reverse-subtract', 32775: 'min', 32776: 'max' };
  const COMPARES = { 512: 'never', 513: 'less', 514: 'equal', 515: 'lequal', 516: 'greater', 517: 'notequal', 518: 'gequal', 519: 'always' };
  const OPERATIONS = { 0: 'zero', 7680: 'keep', 7681: 'replace', 7682: 'incr', 7683: 'decr', 5386: 'invert', 34055: 'incr-wrap', 34056: 'decr-wrap' };

  /// Numbers a page gave that are none (NaN, Infinity) are nought: they cannot be written down.
  const finite = (list) => (list.every(Number.isFinite) ? list : list.map((x) => (Number.isFinite(x) ? x : 0)));
  const base64 = (bytes) => {
    let s = '';
    for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
    return btoa(s);
  };
  const halfOf = (h) => { const e = (h >> 10) & 31, m = h & 1023, sign = h & 32768 ? -1 : 1; return e === 0 ? sign * m * 2 ** -24 : e === 31 ? (m ? NaN : sign * Infinity) : sign * (1 + m / 1024) * 2 ** (e - 15); };
  /// A float as the 16 bits of a half float, rounded to the nearest.
  const f32 = new Float32Array(1), u32 = new Uint32Array(f32.buffer);
  function halfBits(value) {
    f32[0] = value;
    const x = u32[0], sign = (x >>> 16) & 0x8000, exponent = (x >>> 23) & 0xff;
    let mantissa = x & 0x7fffff;
    if (exponent === 255) return sign | 0x7c00 | (mantissa ? 0x200 : 0);
    const e = exponent - 127 + 15;
    if (e >= 31) return sign | 0x7c00;
    if (e <= 0) {
      if (e < -10) return sign;
      mantissa |= 0x800000;
      const shift = 14 - e, half = mantissa >>> shift, rest = mantissa & ((1 << shift) - 1), middle = 1 << (shift - 1);
      return sign | (half + (rest > middle || (rest === middle && (half & 1)) ? 1 : 0));
    }
    const half = (e << 10) | (mantissa >>> 13), rest = mantissa & 0x1fff;
    return sign | (half + (rest > 0x1000 || (rest === 0x1000 && (half & 1)) ? 1 : 0));
  }

  /// A draw's attribute as numbers, value after value, for as many as it reads.
  function floats(buffer, at, vertices) {
    const per = { 5120: 1, 5121: 1, 5122: 2, 5123: 2, 5124: 4, 5125: 4, 5126: 4, 5131: 2 }[at.type];
    if (!per) return null;
    const stride = at.stride || per * at.size;
    const view = new DataView(buffer.bytes.buffer, buffer.bytes.byteOffset, buffer.bytes.byteLength);
    const out = new Float32Array(vertices * at.size);
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
          case 5131: x = halfOf(view.getUint16(o, true)); break;
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

  /// A typed array a page gave a texture, as texels Bezzle keeps: its kind, and its bytes with
  /// rows from t = 0 up, tightly packed. RGB becomes RGBA, as nothing keeps three channels.
  function texelsOf(raw, flipY, premultiply) {
    const { w, h, format, type } = raw;
    const channels = { 6408: 4, 6407: 3, 6409: 1, 6406: 1, 6410: 2, 6403: 1, 33319: 2, 35906: 4, 35904: 3 }[format];
    const size = type === 5121 ? 1 : type === 5126 ? 4 : type === 5131 || type === 36193 ? 2 : 0;
    if (!channels || !size || !(w > 0 && h > 0)) return null;
    const suffix = size === 1 ? '8' : size === 2 ? '16f' : '32f';
    let kind = null, out = channels;
    if (format === 6409) kind = size === 1 ? 'l8' : null;
    else if (format === 6406) kind = size === 1 ? 'a8' : null;
    else if (format === 6410) kind = size === 1 ? 'la8' : null;
    else if (channels >= 3) { kind = 'rgba' + suffix; out = 4; }
    else kind = (channels === 1 ? 'r' : 'rg') + suffix;
    // Luminance and alpha as floats are spread into RGBA, as WebGL reads them.
    const spread = !kind;
    if (spread) { kind = 'rgba' + suffix; out = 4; }
    const row = w * channels * size;
    const padded = size === 1 ? Math.ceil(row / raw.alignment) * raw.alignment : Math.ceil(row / Math.max(raw.alignment, size)) * Math.max(raw.alignment, size);
    if (raw.raw.byteLength < padded * (h - 1) + row) return null;
    const bytes = new Uint8Array(w * h * out * size);
    const from = new DataView(raw.raw.buffer, raw.raw.byteOffset, raw.raw.byteLength), to = new DataView(bytes.buffer);
    const one = size === 1 ? 255 : size === 2 ? 0x3c00 : 1;
    const get = (o) => (size === 1 ? from.getUint8(o) : size === 2 ? from.getUint16(o, true) : from.getFloat32(o, true));
    const put = (o, v) => { if (size === 1) to.setUint8(o, v); else if (size === 2) to.setUint16(o, v, true); else to.setFloat32(o, v, true); };
    for (let y = 0; y < h; y++) {
      const source = (flipY ? h - 1 - y : y) * padded;
      for (let x = 0; x < w; x++) {
        const i = source + x * channels * size, o = (y * w + x) * out * size;
        if (spread) {
          const l = format === 6406 ? 0 : get(i), a = format === 6406 ? get(i) : format === 6410 ? get(i + size) : one;
          put(o, l); put(o + size, l); put(o + 2 * size, l); put(o + 3 * size, a);
        } else if (channels === 3) {
          put(o, get(i)); put(o + size, get(i + size)); put(o + 2 * size, get(i + 2 * size)); put(o + 3 * size, one);
        } else {
          for (let c = 0; c < channels; c++) put(o + c * size, get(i + c * size));
          if (premultiply && channels === 4 && size === 1) { const a = bytes[o + 3]; for (let c = 0; c < 3; c++) bytes[o + c] = Math.round(bytes[o + c] * a / 255); }
        }
      }
    }
    return { w, h, format: kind, bytes };
  }

  /// Bytes that are a picture as well as numbers (every texel opaque) as a PNG, which every
  /// Bezzle that draws shaders reads; else nothing.
  function pictureOf(texels) {
    const { w, h, format, bytes } = texels;
    if (format !== 'rgba8' && format !== 'l8') return null;
    const img = new ImageData(w, h);
    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) {
        const o = (y * w + x) * 4;
        if (format === 'l8') { const l = bytes[y * w + x]; img.data[o] = l; img.data[o + 1] = l; img.data[o + 2] = l; img.data[o + 3] = 255; continue; }
        if (bytes[o + 3] !== 255) return null;
        img.data[o] = bytes[o]; img.data[o + 1] = bytes[o + 1]; img.data[o + 2] = bytes[o + 2]; img.data[o + 3] = 255;
      }
    }
    const c = document.createElement('canvas');
    c.width = w; c.height = h;
    c.getContext('2d').putImageData(img, 0, 0);
    return { data: c.toDataURL('image/png'), w, h };
  }

  // MARK: A frame as passes

  const draws = (f) => f.draws || (f.draws = f.ops.filter((o) => o.op === 'draw'));

  /// Whether a box covers all of what is drawn into.
  const covers = (box, size) => !box || (box[0] <= 0 && box[1] <= 0 && box[0] + box[2] >= size[0] && box[1] + box[3] >= size[1]);

  function sizeOf(dst, f) {
    if (dst.canvas) return f.size;
    const c = dst.colors[0];
    if (!c) return [0, 0];
    if (c.texture) return c.texture.alloc ? [c.texture.alloc.w, c.texture.alloc.h] : [0, 0];
    return [c.renderbuffer.w, c.renderbuffer.h];
  }

  /// The targets a draw, a copy or a clear reads.
  function reads(item) {
    if (item.blit) return [item.blit.from.key];
    if (!item.draw) return [];
    const out = [];
    for (const t of Object.values(item.draw.textures)) if (t && t.texture.drawn) out.push('t' + t.texture.id);
    return out;
  }

  /// The frame as the passes that make its picture: every run of clears and draws into the same
  /// textures or onto the canvas, without those nothing that shows comes from, and what of the
  /// frame before they need (`live`).
  function passesOf(f) {
    const passes = [];
    let cur = null;
    const open = (dst) => { cur = { dst, clearColor: null, clearDepth: null, clearStencil: null, items: [], mipmaps: [] }; passes.push(cur); return cur; };
    const into = (dst) => (cur && cur.dst.key === dst.key ? cur : open(dst));
    for (const o of f.ops) {
      if (o.op === 'clear') {
        const color = !!(o.mask & COLOR_BUFFER_BIT) && o.colorMask.some(Boolean), depth = !!(o.mask & DEPTH_BUFFER_BIT) && o.depthMask;
        const stencil = !!(o.mask & STENCIL_BUFFER_BIT) && o.stencilMask !== 0;
        if (!color && !depth && !stencil) continue;
        const whole = covers(o.scissor, sizeOf(o.dst, f)) && (!color || o.colorMask.every(Boolean)) && (!stencil || o.stencilMask === 255);
        if (whole) {
          if (!(cur && cur.dst.key === o.dst.key && !cur.items.length)) open(o.dst);
          if (color) cur.clearColor = o.color;
          if (depth) cur.clearDepth = o.depth;
          if (stencil) cur.clearStencil = o.stencil;
        } else {
          into(o.dst).items.push({ clear: o, color, depth, stencil });
        }
      } else if (o.op === 'draw') into(o.dst).items.push({ draw: o });
      else if (o.op === 'blit') into(o.dst).items.push({ blit: o });
      else if (o.op === 'mipmap' && cur) cur.mipmaps.push('t' + o.texture.id);
    }
    // From the last back: a pass is kept when something that shows comes from what it draws into.
    const live = new Set(['canvas']);
    const kept = [];
    for (let i = passes.length - 1; i >= 0; i--) {
      const p = passes[i];
      const outs = p.dst.canvas ? ['canvas'] : p.dst.colors.map((c) => c.key);
      if (!outs.some((k) => live.has(k))) continue;
      if (!p.items.length && !p.clearColor && p.clearDepth === null && p.clearStencil === null) continue;
      kept.unshift(p);
      if (p.clearColor) for (const k of outs) live.delete(k);
      for (const item of p.items) for (const k of reads(item)) live.add(k);
    }
    return { passes: kept, live };
  }

  /// How a frame is put together, with its textures named by where they first come up: two
  /// frames that draw alike, also where a page draws into two textures in turn, have the same.
  function shape(f) {
    if (f.shape) return f.shape;
    const names = new Map();
    const name = (key) => { if (!names.has(key)) names.set(key, names.size); return names.get(key); };
    const parts = [f.size.join('x')];
    for (const o of f.ops) {
      if (o.op === 'mipmap') { parts.push(`M${name('t' + o.texture.id)}`); continue; }
      const dst = o.dst.canvas ? 'c' : o.dst.colors.map((c) => name(c.key)).join(',') + '/' + (o.dst.depth ? name(o.dst.depth) : '');
      if (o.op === 'clear') parts.push(`C${dst}:${o.mask}:${o.scissor}:${o.colorMask}`);
      else if (o.op === 'blit') parts.push(`B${dst}:${name(o.from.key)}:${o.source}:${o.box}`);
      else {
        const attributes = Object.entries(o.attributes).map(([k, a]) => (a.constant ? `${k}=${a.constant}` : `${k}@${a.buffer.id}.${a.version}.${a.size}.${a.type}.${a.stride}.${a.offset}.${a.divisor}`)).join(';');
        const textures = Object.entries(o.textures).map(([k, t]) => (!t ? `${k}-` : t.texture.drawn ? `${k}>${name('t' + t.texture.id)}` : `${k}=${t.texture.id}.${t.version}`)).join(';');
        const elements = o.elements ? `${o.elements.buffer.id}.${o.elements.version}.${o.elements.type}.${o.elements.offset}` : '';
        parts.push(`D${dst}:${o.program.id}:${o.mode}:${o.first}:${o.count}:${o.instances}:${attributes}:${elements}:${textures}:${o.blend}:${o.viewport}:${o.depth}:${o.stencil}:${o.cull}:${o.clockwise}:${o.mask}:${o.scissor}:${o.offset}:${o.uniforms.length}`);
      }
    }
    f.shape = { text: parts.join('|'), names: Array.from(names.keys()) };
    return f.shape;
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
    // What moved, draw by draw.
    const found = [];
    draws(last).forEach((d, i) => {
      const before = frames.map((f) => new Map(draws(f)[i].uniforms));
      for (const [name, values] of d.uniforms) {
        values.forEach((value, k) => {
          const series = before.map((u) => { const v = u.get(name); return v ? v[k] : undefined; });
          if (series.some((x) => x === undefined) || series.every((x) => x === series[0])) return;
          const n = ts.length, mt = ts.reduce((a, b) => a + b) / n, mv = series.reduce((a, b) => a + b) / n;
          let sxx = 0, sxy = 0;
          for (let j = 0; j < n; j++) { sxx += (ts[j] - mt) ** 2; sxy += (ts[j] - mt) * (series[j] - mv); }
          const rate = sxx > 0 ? sxy / sxx : 0;
          const spread = Math.max(...series) - Math.min(...series);
          const off = Math.max(...series.map((x, j) => Math.abs(x - (mv + rate * (ts[j] - mt)))));
          // Frames come a little unevenly: steady is within a fiftieth of how far it went.
          const steady = sxx > 0 && rate !== 0 && off <= Math.max(1e-6, spread * 0.02 + Math.abs(rate) * 0.004);
          const program = d.program.id;
          if (steady && (long || timeLike.test(name))) {
            found.push({ draw: i, program, uniform: name, component: k, start: series[series.length - 1], rate });
          } else if (long) {
            // As it went, at most thirty times a second.
            const times = [], kept = [];
            for (let j = 0; j < n; j++) {
              const t = ts[j] - ts[0];
              if (j > 0 && j < n - 1 && t - times[times.length - 1] < 1 / 30) continue;
              times.push(t);
              kept.push(series[j]);
            }
            found.push({ draw: i, program, uniform: name, component: k, times, values: kept });
          } else {
            unsteady = true;
          }
        });
      }
    });
    // A number that moved alike in every draw of its program (a time all of them are given) is
    // kept once, for the program; one that each draw has its own of (where each of a scene's
    // meshes stands), draw by draw.
    const groups = new Map();
    for (const m of found) {
      const key = m.program + '|' + m.uniform + '|' + m.component;
      if (!groups.has(key)) groups.set(key, []);
      groups.get(key).push(m);
    }
    const same = (a, b) => (a.times ? !!b.times && a.times.length === b.times.length && a.values.every((v, j) => v === b.values[j]) : !b.times && a.start === b.start && a.rate === b.rate);
    for (const list of groups.values()) {
      const first = list[0];
      const having = draws(last).filter((d) => d.program.id === first.program && d.uniforms.some(([name, v]) => name === first.uniform && v.length > first.component)).length;
      const alike = list.length === having && list.every((m) => same(m, first));
      for (const m of alike ? [first] : list) {
        const entry = { program: m.program, uniform: m.uniform, component: m.component };
        if (!alike) entry.draw = m.draw;
        if (m.times) recordings.push(Object.assign(entry, { times: m.times, values: m.values }));
        else clocks.push(Object.assign(entry, { start: m.start, rate: m.rate }));
      }
    }
    return { clocks, recordings, unsteady };
  }

  // What the recorder draws with itself: a clear of part of a target, and a copy from one
  // framebuffer into another (blitFramebuffer).
  const QUAD = base64(new Uint8Array(new Float32Array([-1, -1, 1, -1, -1, 1, -1, 1, 1, -1, 1, 1]).buffer));
  const CLEARING = {
    vertex: 'attribute vec2 a_position;\nuniform float bz_depth;\nvoid main() { gl_Position = vec4(a_position, bz_depth, 1.0); }\n',
    fragment: 'precision highp float;\nuniform vec4 bz_color;\nvoid main() { gl_FragColor = bz_color; }\n',
  };
  const COPYING = {
    vertex: 'attribute vec2 a_position;\nuniform vec4 bz_from;\nvarying vec2 bz_at;\nvoid main() { bz_at = bz_from.xy + (a_position * 0.5 + 0.5) * bz_from.zw; gl_Position = vec4(a_position, 0.0, 1.0); }\n',
    fragment: 'precision highp float;\nuniform sampler2D bz_source;\nvarying vec2 bz_at;\nvoid main() { gl_FragColor = texture2D(bz_source, bz_at); }\n',
  };

  /// What a texture holds now, read back through a framebuffer of the recorder's own, as bytes
  /// of `kind`, rows from the bottom up; nothing where it cannot be read.
  function readBack(gl, texture, w, h, kind) {
    const floating = /f$/.test(kind), channels = /^rgba/.test(kind) ? 4 : /^rg/.test(kind) ? 2 : 1;
    quiet = true;
    const two = !!gl.READ_FRAMEBUFFER;
    const was = gl.getParameter(gl.FRAMEBUFFER_BINDING), wasRead = two ? gl.getParameter(gl.READ_FRAMEBUFFER_BINDING) : null;
    const packed = two ? gl.getParameter(gl.PIXEL_PACK_BUFFER_BINDING) : null, alignment = gl.getParameter(gl.PACK_ALIGNMENT);
    const fb = gl.createFramebuffer();
    try {
      if (packed) gl.bindBuffer(gl.PIXEL_PACK_BUFFER, null);
      gl.pixelStorei(gl.PACK_ALIGNMENT, 1);
      gl.bindFramebuffer(gl.FRAMEBUFFER, fb);
      if (texture) gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, texture, 0);
      else gl.bindFramebuffer(gl.FRAMEBUFFER, null);
      if (texture && gl.checkFramebufferStatus(gl.FRAMEBUFFER) !== gl.FRAMEBUFFER_COMPLETE) return null;
      while (gl.getError() !== gl.NO_ERROR) {}
      if (!floating) {
        const all = new Uint8Array(w * h * 4);
        gl.readPixels(0, 0, w, h, gl.RGBA, gl.UNSIGNED_BYTE, all);
        if (gl.getError() !== gl.NO_ERROR) return null;
        if (channels === 4) return all;
        const out = new Uint8Array(w * h * channels);
        for (let i = 0; i < w * h; i++) for (let c = 0; c < channels; c++) out[i * channels + c] = all[i * 4 + c];
        return out;
      }
      const all = new Float32Array(w * h * 4);
      gl.readPixels(0, 0, w, h, gl.RGBA, gl.FLOAT, all);
      if (gl.getError() !== gl.NO_ERROR) return null;
      if (/32f$/.test(kind)) {
        if (channels === 4) return new Uint8Array(all.buffer);
        const out = new Float32Array(w * h * channels);
        for (let i = 0; i < w * h; i++) for (let c = 0; c < channels; c++) out[i * channels + c] = all[i * 4 + c];
        return new Uint8Array(out.buffer);
      }
      const out = new Uint16Array(w * h * channels);
      for (let i = 0; i < w * h; i++) for (let c = 0; c < channels; c++) out[i * channels + c] = halfBits(all[i * 4 + c]);
      return new Uint8Array(out.buffer);
    } catch (e) {
      return null;
    } finally {
      gl.bindFramebuffer(gl.FRAMEBUFFER, was);
      if (two) gl.bindFramebuffer(gl.READ_FRAMEBUFFER, wasRead);
      gl.deleteFramebuffer(fb);
      gl.pixelStorei(gl.PACK_ALIGNMENT, alignment);
      if (packed) gl.bindBuffer(gl.PIXEL_PACK_BUFFER, packed);
      quiet = false;
    }
  }

  /// A canvas's scene, or why it has none that can be drawn again.
  function scene(canvas) {
    const gl = contexts.get(canvas);
    const s = gl && states.get(gl);
    if (!s) return { why: 'not webgl' };
    // As far as the moment its picture was taken, so that what is kept is what the picture shows.
    const at = parseFloat(canvas.getAttribute('data-bz-canvas-at'));
    const all = s.frames.concat(s.frame ? [s.frame] : []).filter((f) => (f.ops.length || f.broken) && !(f.time > at));
    if (!all.length) return { why: 'nothing drawn' };
    const last = all[all.length - 1];
    if (last.broken) return { why: last.broken };
    const { passes, live } = passesOf(last);
    // Cleared and drawn on no more: what shows is nothing, as the picture of it is.
    if (!passes.some((p) => p.items.length)) return { why: 'nothing drawn' };
    if (passes.reduce((n, p) => n + p.items.length, 0) > MOST_DRAWS) return { why: 'too many draws' };
    for (const p of passes) if (p.dst.other) return { why: p.dst.other };
    // The frames before it that differ from it only in their numbers.
    const run = [];
    for (let i = all.length - 1; i >= 0 && !all[i].broken && shape(all[i]).text === shape(last).text; i--) run.unshift(all[i]);
    const { clocks: clockList, recordings: recorded, unsteady } = motions(run);

    // Where each texture drawn into stands in the frame after this one: a page that draws into
    // two in turn has swapped them since the frame before, and will again.
    const next = new Map();
    if (run.length >= 2) {
      const before = shape(run[run.length - 2]).names, now = shape(last).names;
      before.forEach((key, i) => next.set(key, now[i]));
      const reached = new Set(next.values());
      if (reached.size !== next.size || now.some((key) => !next.has(key))) next.clear();
    }
    const after = (key) => (next.has(key) ? next.get(key) : key);

    // The canvas itself kept from frame to frame (preserveDrawingBuffer) and drawn onto without
    // a clear: a texture that keeps, shown on the canvas at the end.
    const keepsCanvas = live.has('canvas') && s.attributes.preserves;
    const written = new Set();
    for (const p of passes) for (const c of p.dst.colors) written.add(c.key);

    // The textures drawn into or read, each once, in the order they come up.
    const targets = [], targetIndex = new Map(), objects = new Map();
    const target = (key) => {
      if (!targetIndex.has(key)) { targetIndex.set(key, targets.length); targets.push({ key }); }
      return targetIndex.get(key);
    };
    for (const p of passes) {
      for (const c of p.dst.colors) objects.set(c.key, c);
      for (const item of p.items) {
        if (item.blit) objects.set(item.blit.from.key, item.blit.from);
        if (item.draw) for (const t of Object.values(item.draw.textures)) if (t && t.texture.drawn) objects.set('t' + t.texture.id, { texture: t.texture, key: 't' + t.texture.id });
      }
    }
    const depths = new Map();
    const depthOf = (key) => { if (!depths.has(key)) depths.set(key, depths.size); return depths.get(key); };

    const programs = [], programIndex = new Map();
    const programOf = (p) => {
      if (!programIndex.has(p)) { programIndex.set(p, programs.length); programs.push({ vertex: p.vertex, fragment: p.fragment }); }
      return programIndex.get(p);
    };
    const pictures = {}, texels = [], texelIndex = new Map(), videos = new Set();
    const outPasses = [], outDraws = [];
    /// Where each of the page's draws came to stand among the scene's.
    const drawIndex = new Map();
    let bytes = 0, kept = 0;

    /// A texture drawn into in an earlier frame and never since is numbers like any other,
    /// read back now.
    function frozen(key) {
      if (written.has(key) || after(key) !== key) return null;
      const c = objects.get(key);
      const t = c && c.texture;
      if (!t || !t.alloc) return null;
      if (texelIndex.has(key)) return texelIndex.get(key);
      const kind = kindOf(t.alloc.internal, t.alloc.format, t.alloc.type);
      if (!kind) return null;
      const size = t.alloc.w * t.alloc.h * (/^rgba/.test(kind.kind) ? 4 : /^rg/.test(kind.kind) ? 2 : 1) * (/32f$/.test(kind.kind) ? 4 : /16f$/.test(kind.kind) ? 2 : 1);
      if (kept + size > MOST_STATE) return null;
      let object = null;
      for (const [o, v] of s.textures) if (v === t) object = o;
      const read = object && readBack(gl, object, t.alloc.w, t.alloc.h, kind.kind);
      if (!read) return null;
      kept += size;
      texelIndex.set(key, texels.length);
      texels.push({ w: t.alloc.w, h: t.alloc.h, format: kind.kind, bytes: base64(read) });
      return texelIndex.get(key);
    }

    function made(o, size) {
      const p = o.program;
      if (!p.vertex || !p.fragment) return { why: 'program gone' };
      // How many vertices and instances it reaches.
      let indices = null, vertices = o.first + o.count;
      if (o.elements) {
        if (o.elements.buffer.version !== o.elements.version) return { why: 'indices changed' };
        indices = indexList(o.elements.buffer, o.elements, o.count);
        if (!indices) return { why: 'indices' };
        vertices = 0;
        for (const i of indices) if (i + 1 > vertices) vertices = i + 1;
      }
      if (vertices > 400000) return { why: 'too many vertices' };
      const instances = o.instances === null ? 1 : o.instances;
      const attributes = {};
      for (const [name, a] of Object.entries(o.attributes)) {
        if (a.constant) { attributes[name] = { components: a.constant.length, constant: a.constant }; continue; }
        if (a.buffer.version !== a.version) return { why: 'buffers changed' };
        const values = floats(a.buffer, a, a.divisor ? Math.ceil(instances / a.divisor) : vertices);
        if (!values) return { why: 'attributes' };
        bytes += values.byteLength;
        attributes[name] = { components: a.size, values: base64(new Uint8Array(values.buffer)), divisor: a.divisor || undefined };
      }
      const textures = {}, sampling = {}, reads = {}, numbers = {}, decodes = [];
      let flips = false, premultiplies = false;
      // A draw's pictures are turned over all together or not at all: numbers beside a picture
      // that is turned stay numbers, whose rows are already as they were given.
      const turned = Object.values(o.textures).some((t) => t && !t.texture.drawn && t.texture.source && !t.texture.source.raw && !t.texture.source.video && !t.texture.source.unread && t.texture.flipY);
      for (const [name, t] of Object.entries(o.textures)) {
        if (!t) continue;
        const tex = t.texture;
        // WebGL's own: wrapping repeats, and far off it reads smaller copies, which a picture
        // without them shows black for; as browsers do, it is read smoothed then.
        const sm = tex.sampling || { wrapS: 'repeat', wrapT: 'repeat', magnify: 'linear', minify: 'nearest', mipFilter: 'linear' };
        const mip = tex.mipmapped && sm.mipFilter ? sm.mipFilter : undefined;
        const how = { wrapS: sm.wrapS, wrapT: sm.wrapT, magnify: sm.magnify, minify: sm.minify, mipmap: mip };
        if (tex.drawn) {
          const key = 't' + tex.id;
          const still = frozen(key);
          if (still !== null) numbers[name] = still; else reads[name] = target(after(key));
          sampling[name] = how;
          continue;
        }
        if (!tex.source) continue;
        const source = tex.source;
        if (source.unread) return { why: 'texture: ' + source.unread };
        if (tex.partly) return { why: 'texture changed in part' };
        if (source.raw || source.video) {
          // Numbers: a picture where they are one, for every Bezzle to read; else as they are.
          // A video cannot be kept: the frame the page gave its texture last is read back from
          // the texture, the very colours the page drew with, and kept as numbers are.
          if (source.video) videos.add(tex.id);
          if (!tex.texels || tex.texelsVersion !== tex.version) {
            if (source.raw) tex.texels = texelsOf(source, tex.flipY, tex.premultiply);
            else {
              const w = tex.alloc ? tex.alloc.w : 0, h = tex.alloc ? tex.alloc.h : 0;
              if (!(w > 0 && h > 0)) return { why: 'texture: a video with no frame yet' };
              let object = null;
              for (const [key, value] of s.textures) if (value === tex) object = key;
              const read = object && w * h <= 4096 * 4096 ? readBack(gl, object, w, h, 'rgba8') : null;
              tex.texels = read ? { w, h, format: 'rgba8', bytes: read } : null;
            }
            tex.texelsVersion = tex.version;
            tex.picture = tex.texels && !tex.decodes ? pictureOf(tex.texels) : null;
          }
          if (!tex.texels) return { why: source.video ? 'texture: a video whose frame could not be read back' : 'texture: pixels of another kind' };
          if (tex.picture && !turned) {
            pictures[tex.id] = { url: null, data: tex.picture.data, w: tex.picture.w, h: tex.picture.h };
            textures[name] = tex.id;
            // Its rows were turned as it was read, if they were to be.
          } else {
            if (!texelIndex.has(tex)) {
              bytes += tex.texels.bytes.byteLength;
              texelIndex.set(tex, texels.length);
              texels.push({ w: tex.texels.w, h: tex.texels.h, format: tex.texels.format, bytes: base64(tex.texels.bytes) });
            }
            numbers[name] = texelIndex.get(tex);
            if (tex.decodes) decodes.push(name);
          }
          sampling[name] = how;
          continue;
        }
        if (source.data === null && !source.url) continue;   // made and never filled: black
        if (!pictures[tex.id]) pictures[tex.id] = { url: source.url || null, data: source.data || null, w: source.w, h: source.h };
        textures[name] = tex.id;
        flips = flips || !!tex.flipY;
        premultiplies = premultiplies || !!tex.premultiply;
        if (tex.decodes) decodes.push(name);
        sampling[name] = how;
      }
      if (bytes > 24 * 1024 * 1024) return { why: 'too much geometry' };
      const draw = {
        program: programOf(p), uniforms: Object.fromEntries(o.uniforms.map(([k, v]) => [k, finite(v)])), attributes, mode: MODES[o.mode] || 'triangles',
        first: o.first, count: o.count, textures, flipsTextures: flips || undefined, premultipliesTextures: premultiplies || undefined,
        sampling: Object.keys(sampling).length ? sampling : undefined,
        indices: indices ? base64(new Uint8Array(indices.buffer)) : undefined,
        targets: Object.keys(reads).length ? reads : undefined, texels: Object.keys(numbers).length ? numbers : undefined,
        decodes: decodes.length ? decodes : undefined, instances: o.instances === null ? undefined : o.instances,
      };
      if (o.blend) {
        draw.blend = { source: FACTORS[o.blend[0]] || 'one', destination: FACTORS[o.blend[1]] || 'zero', sourceAlpha: FACTORS[o.blend[2]] || 'one',
          destinationAlpha: FACTORS[o.blend[3]] || 'zero', equation: EQUATIONS[o.blend[4]] || 'func-add', equationAlpha: EQUATIONS[o.blend[5]] || 'func-add',
          color: o.constant ? finite(o.constant) : undefined };
      }
      if (o.viewport) draw.viewport = finite(o.viewport.map(Number));
      tests(draw, o, size);
      return { draw };
    }

    /// The tests and masks of a draw, where what it draws into has what they need.
    function tests(draw, o, size) {
      const dst = o.dst;
      const hasDepth = dst.canvas ? s.attributes.depth !== false : !!dst.depth, hasStencil = dst.canvas ? !!s.attributes.stencil : !!dst.stencil;
      if (o.depth && hasDepth) {
        draw.depth = { compare: COMPARES[o.depth[0]] || 'less', writes: o.depth[1] ? undefined : false,
          range: o.depth[2] !== 0 || o.depth[3] !== 1 ? [o.depth[2], o.depth[3]] : undefined };
      }
      if (o.stencil && hasStencil) {
        const face = (k) => ({ compare: COMPARES[o.stencil[k]] || 'always', reference: o.stencil[k + 1], readMask: o.stencil[k + 2], writeMask: o.stencil[k + 3],
          fail: OPERATIONS[o.stencil[k + 4]] || 'keep', depthFail: OPERATIONS[o.stencil[k + 5]] || 'keep', pass: OPERATIONS[o.stencil[k + 6]] || 'keep' });
        const front = face(0), back = face(7);
        draw.stencil = { front, back: JSON.stringify(front) === JSON.stringify(back) ? undefined : back };
      }
      if (o.cull) draw.cull = o.cull === 1028 ? 'front' : o.cull === 1032 ? 'both' : 'back';
      if (o.clockwise) draw.clockwiseFront = true;
      if (o.mask) draw.channels = (o.mask[0] ? 1 : 0) | (o.mask[1] ? 2 : 0) | (o.mask[2] ? 4 : 0) | (o.mask[3] ? 8 : 0);
      if (o.scissor && !covers(o.scissor, size)) draw.scissor = finite(o.scissor.map(Number));
      if (o.offset && o.depth && hasDepth) draw.offset = finite(o.offset);
    }

    /// A clear of part of what is drawn into, as a draw over it.
    function clearing(item, size) {
      const o = item.clear;
      const draw = {
        program: programOf(CLEARING), uniforms: { bz_color: finite(o.color.map(Number)), bz_depth: finite([o.depth * 2 - 1]) },
        attributes: { a_position: { components: 2, values: QUAD } }, mode: 'triangles', first: 0, count: 6, textures: {},
        channels: item.color ? (o.colorMask[0] ? 1 : 0) | (o.colorMask[1] ? 2 : 0) | (o.colorMask[2] ? 4 : 0) | (o.colorMask[3] ? 8 : 0) : 0,
      };
      if (draw.channels === 15) delete draw.channels;
      if (item.depth) draw.depth = { compare: 'always' };
      if (item.stencil) draw.stencil = { front: { compare: 'always', reference: o.stencil, readMask: 255, writeMask: o.stencilMask, fail: 'replace', depthFail: 'replace', pass: 'replace' } };
      if (o.scissor && !covers(o.scissor, size)) draw.scissor = finite(o.scissor.map(Number));
      return draw;
    }

    /// A copy from one framebuffer into another, as a draw that reads the one.
    function copying(o, size) {
      const from = objects.get(o.from.key);
      const source = from.texture ? (from.texture.alloc ? [from.texture.alloc.w, from.texture.alloc.h] : [1, 1]) : [from.renderbuffer.w, from.renderbuffer.h];
      const [sx0, sy0, sx1, sy1] = o.source, [dx0, dy0, dx1, dy1] = o.box;
      // Drawn in the box it lands in, upright there; turned over in what it reads where the
      // page's boxes run the other way.
      const x0 = Math.min(dx0, dx1), y0 = Math.min(dy0, dy1), across = dx1 < dx0, down = dy1 < dy0;
      const fx0 = across ? sx1 : sx0, fx1 = across ? sx0 : sx1, fy0 = down ? sy1 : sy0, fy1 = down ? sy0 : sy1;
      const draw = {
        program: programOf(COPYING), uniforms: { bz_from: [fx0 / source[0], fy0 / source[1], (fx1 - fx0) / source[0], (fy1 - fy0) / source[1]] },
        attributes: { a_position: { components: 2, values: QUAD } }, mode: 'triangles', first: 0, count: 6, textures: {},
        targets: { bz_source: target(after(o.from.key)) },
        sampling: { bz_source: { wrapS: 'clamp', wrapT: 'clamp', magnify: o.linear ? 'linear' : 'nearest', minify: o.linear ? 'linear' : 'nearest' } },
        viewport: [x0, y0, Math.abs(dx1 - dx0), Math.abs(dy1 - dy0)],
      };
      if (o.scissor && !covers(o.scissor, size)) draw.scissor = finite(o.scissor.map(Number));
      return draw;
    }

    // The canvas as a texture that keeps, where the page keeps drawing onto it.
    const canvasTarget = keepsCanvas ? target('canvas') : null;
    for (const p of passes) {
      const size = sizeOf(p.dst, last);
      const pass = { count: 0 };
      if (p.dst.canvas) {
        if (canvasTarget !== null) { pass.colors = [canvasTarget]; pass.depth = depthOf('canvas'); }
      } else {
        pass.colors = p.dst.colors.map((c) => target(after(c.key)));
        if (p.dst.depth) pass.depth = depthOf(after(p.dst.depth));
      }
      if (p.clearColor) pass.clearColor = finite(p.clearColor.map(Number));
      if (p.clearDepth !== null) pass.clearDepth = p.clearDepth;
      if (p.clearStencil !== null) pass.clearStencil = p.clearStencil;
      for (const item of p.items) {
        let draw;
        if (item.draw) {
          const result = made(item.draw, size);
          if (result.why) return result;
          draw = result.draw;
          drawIndex.set(item.draw, outDraws.length);
        } else if (item.clear) {
          if (p.dst.colors.length > 1 && item.color) return { why: 'clears part of several textures' };
          draw = clearing(item, size);
        } else {
          draw = copying(item.blit, size);
        }
        outDraws.push(draw);
        pass.count++;
      }
      if (p.mipmaps.length) pass.mipmaps = Array.from(new Set(p.mipmaps.filter((k) => targetIndex.has(after(k))).map((k) => target(after(k)))));
      outPasses.push(pass);
    }
    if (canvasTarget !== null) {
      outDraws.push({
        program: programOf(COPYING), uniforms: { bz_from: [0, 0, 1, 1] }, attributes: { a_position: { components: 2, values: QUAD } },
        mode: 'triangles', first: 0, count: 6, textures: {}, targets: { bz_source: canvasTarget },
        sampling: { bz_source: { wrapS: 'clamp', wrapT: 'clamp', magnify: 'nearest', minify: 'nearest' } },
      });
      outPasses.push({ count: 1, clearColor: [0, 0, 0, 0] });
    }

    // What each texture is, and for those the frame takes over from the frame before, what they
    // hold now: read back unless the frame's first draw into one looks to cover it anyway.
    const needed = new Set(Array.from(live, after));
    const firstInto = new Map();
    for (const p of passes) {
      const first = p.items[0];
      for (const c of p.dst.colors) {
        const key = after(c.key);
        if (firstInto.has(key)) continue;
        const d = first && first.draw;
        const whole = !!p.clearColor || (!!d && !d.blend && !d.depth && !d.stencil && !d.mask && !d.scissor && covers(d.viewport, sizeOf(p.dst, last))
          && (d.mode === 4 || d.mode === 5 || d.mode === 6) && (d.count === 3 || d.count === 4 || d.count === 6));
        firstInto.set(key, whole);
      }
    }
    const outTargets = [];
    const order = targets.map((t, i) => ({ t, i }));
    for (const { t } of order) {
      if (t.key === 'canvas') {
        const [w, h] = last.size;
        const entry = { w, h, format: 'rgba8', keeps: true };
        if (kept + w * h * 4 <= MOST_STATE) {
          const read = readBack(gl, null, w, h, 'rgba8');
          if (read) { entry.state = base64(read); kept += w * h * 4; }
        }
        outTargets.push(entry);
        continue;
      }
      const c = objects.get(t.key);
      if (!c) return { why: 'a texture drawn into is gone' };
      let w, h, kind;
      if (c.texture) {
        if (!c.texture.alloc) return { why: 'a texture drawn into has no size' };
        ({ w, h } = c.texture.alloc);
        kind = kindOf(c.texture.alloc.internal, c.texture.alloc.format, c.texture.alloc.type);
      } else if (c.renderbuffer) {
        ({ w, h } = c.renderbuffer);
        kind = kindOf(c.renderbuffer.internal, 0, 0);
      }
      if (!kind) return { why: 'draws into a texture of another kind' };
      if (!(w > 0 && h > 0)) return { why: 'a texture drawn into has no size' };
      const entry = { w, h, format: kind.kind, opaque: kind.opaque || undefined, mipmapped: (c.texture && c.texture.mipmapped) || undefined };
      if (needed.has(t.key)) {
        entry.keeps = true;
        const size = w * h * (/^rgba/.test(kind.kind) ? 4 : /^rg/.test(kind.kind) ? 2 : 1) * (/32f$/.test(kind.kind) ? 4 : /16f$/.test(kind.kind) ? 2 : 1);
        let object = null;
        if (c.texture) for (const [o, v] of s.textures) if (v === c.texture) object = o;
        if (object && !firstInto.get(t.key) && kept + size <= MOST_STATE) {
          const read = readBack(gl, object, w, h, kind.kind);
          if (read) { entry.state = base64(read); kept += size; }
        }
      }
      outTargets.push(entry);
    }

    // Programs by their place among this scene's, not the page's.
    const place = (c) => {
      let program = null;
      for (const [p, i] of programIndex) if (p.id === c.program) program = i;
      if (program === null) return null;
      const placed = Object.assign({}, c, { program });
      if (c.draw !== undefined) {
        const at = drawIndex.get(draws(last)[c.draw]);
        if (at === undefined) return null;
        placed.draw = at;
      }
      return placed;
    };
    const clocksOut = clockList.map(place).filter(Boolean), recordingsOut = recorded.map(place).filter(Boolean);
    const turn = targets.map((t) => target(after(t.key)));
    const turns = turn.some((to, i) => to !== i);
    // How often the page meant to draw, where it draws on a timer of four milliseconds or more.
    const rate = last.every !== null && last.every >= 4 ? 1000 / last.every : undefined;
    return { size: last.size, programs, draws: outDraws, passes: outPasses, targets: outTargets.length ? outTargets : undefined,
      texels: texels.length ? texels : undefined, turn: turns ? turn : undefined, rate,
      clocks: clocksOut, recordings: recordingsOut.length ? recordingsOut : undefined,
      pictures, videos: videos.size || undefined, frames: run.length, still: unsteady || undefined, attributes: s.attributes };
  }

  // The reader says when it takes a canvas's picture: its scene is made then, with what its
  // textures hold at that moment.
  document.addEventListener('bz-canvas-shot', (event) => {
    const canvas = event.target;
    if (!(canvas instanceof HTMLCanvasElement)) return;
    try { shots.set(canvas, scene(canvas)); } catch (e) { shots.set(canvas, { why: 'error: ' + e.message }); }
  }, true);

  window.__bezzleGL = {
    /// Every canvas the reader marked, by its mark: its scene as JSON, or why it has none.
    scenes() {
      const out = {};
      for (const canvas of document.querySelectorAll('canvas[data-bz-canvas]')) {
        const mark = canvas.getAttribute('data-bz-canvas');
        try { out[mark] = shots.get(canvas) || scene(canvas); } catch (e) { out[mark] = { why: 'error: ' + e.message }; }
      }
      return JSON.stringify(out);
    },
  };
})();
