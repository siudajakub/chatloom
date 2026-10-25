// Deterministic timeline for README demo mockups.
//
// A scene calls `scene(durationMs, [[atMs, fn], ...])`. render.mjs then calls
// `window.__seek(t)` for each frame with increasing t: steps with at <= t run
// once, in order, and every CSS animation or transition is paused and set to
// the virtual time since the step that started it. Nothing depends on the
// wall clock, so every run produces the same frames.

const $ = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];

const births = new WeakMap();
const updaters = [];
let steps = [];
let next = 0;
let now = 0;

function adopt(at) {
  document.body.getBoundingClientRect(); // flush styles so transitions exist
  for (const a of document.getAnimations()) {
    if (!births.has(a)) {
      births.set(a, at);
      a.pause();
    }
  }
}

window.scene = (duration, list) => {
  window.__duration = duration;
  steps = list.slice().sort((a, b) => a[0] - b[0]);
};

window.__seek = (t) => {
  while (next < steps.length && steps[next][0] <= t) {
    const [at, fn] = steps[next++];
    now = at;
    fn();
    adopt(at);
  }
  now = t;
  for (const u of updaters) u(t);
  adopt(t);
  for (const a of document.getAnimations()) {
    a.currentTime = Math.max(0, t - births.get(a));
  }
};

// Run fn(progress 0..1) on every frame between at and at + dur.
function during(at, dur, fn) {
  updaters.push((t) => {
    if (t < at) return;
    fn(Math.min(1, (t - at) / dur));
  });
}

// Type text into el starting at `at`, `cps` characters per second.
function type(el, text, at, cps = 16, caret = true) {
  const node = typeof el === 'string' ? $(el) : el;
  during(at, (text.length / cps) * 1000, (p) => {
    const n = Math.round(text.length * p);
    node.innerHTML = escapeHtml(text.slice(0, n)) + (caret && p < 1 ? '<span class="caret"></span>' : '');
  });
  return at + (text.length / cps) * 1000;
}

function escapeHtml(s) {
  return s.replace(/[&<>]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' })[c]);
}

// Finger tap (or long press with hold = true) at the centre of an element or at x, y.
function tap(target, hold = false) {
  let x, y;
  if (Array.isArray(target)) [x, y] = target;
  else {
    const r = (typeof target === 'string' ? $(target) : target).getBoundingClientRect();
    x = r.left + r.width / 2;
    y = r.top + r.height / 2;
  }
  const d = document.createElement('div');
  d.className = hold ? 'touch hold' : 'touch';
  d.style.left = x + 'px';
  d.style.top = y + 'px';
  document.body.appendChild(d);
}

function html(str) {
  const t = document.createElement('template');
  t.innerHTML = str.trim();
  return t.content.firstElementChild;
}

Object.assign(window, { $, $$, during, type, tap, html });
