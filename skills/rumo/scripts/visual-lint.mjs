// visual-lint.mjs - the checks; run it through visual-lint.sh, which resolves Playwright.
import { createRequire } from 'node:module';
import { mkdirSync } from 'node:fs';
import { join, resolve } from 'node:path';

const VIEWPORTS = [
  { name: '390', viewport: { width: 390, height: 844 }, hasTouch: true, isMobile: true, deviceScaleFactor: 2 },
  { name: '1440', viewport: { width: 1440, height: 900 }, hasTouch: false, isMobile: false, deviceScaleFactor: 1 },
];

// ---- in-page functions (serialised by page.evaluate; no outer-scope references) ----

function installHelpers() {
  const describe = (el) => {
    let s = el.tagName.toLowerCase();
    if (el.id) s += '#' + el.id;
    const cls = [...el.classList].slice(0, 2);
    if (cls.length) s += '.' + cls.join('.');
    const t = (el.innerText || '').replace(/\s+/g, ' ').trim();
    if (t) s += ` "${t.slice(0, 30)}"`;
    return s;
  };
  const visible = (el) => {
    const r = el.getBoundingClientRect();
    return (
      r.width > 1 && r.height > 1 &&
      r.bottom > 0 &&
      r.right > 0 && r.left < innerWidth &&
      el.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true, opacityProperty: true, visibilityProperty: true }) &&
      !el.closest('[aria-hidden="true"],[inert]')
    );
  };
  const norm = (t) => (t || '').replace(/\s+/g, ' ').trim();
  const textNodes = (el) => [...el.childNodes].filter((n) => n.nodeType === 3 && n.textContent.trim());
  const ownText = (el) => norm(textNodes(el).map((n) => n.textContent).join(' '));
  // visible elements that directly hold text; form controls keep their text outside the DOM text the rules can measure
  const textEls = () => {
    const out = [];
    for (const el of document.body.querySelectorAll('*')) {
      if (el.closest('script, style, noscript, template, svg, input, textarea, select')) continue;
      if (!textNodes(el).length || !visible(el)) continue;
      out.push(el);
    }
    return out;
  };
  window.__vl = { describe, visible, norm, textNodes, ownText, textEls };
}

function checkHOverflow() {
  const de = document.documentElement;
  // the viewport takes overflow-x from html, or from body when html's is visible
  let vox = getComputedStyle(de).overflowX;
  if (vox === 'visible') vox = getComputedStyle(document.body).overflowX;
  if (vox === 'hidden' || vox === 'clip') return [];
  const cw = de.clientWidth;
  if (de.scrollWidth <= cw) return [];
  const culprits = [];
  for (const e of document.body.querySelectorAll('*')) {
    const r = e.getBoundingClientRect();
    const pr = e.parentElement.getBoundingClientRect();
    if (r.right > cw + 1 && pr.right <= cw + 1) {
      culprits.push({
        el: window.__vl.describe(e),
        detail: `right edge ${Math.round(r.right)} > ${cw}; scrollWidth ${de.scrollWidth}`,
      });
      if (culprits.length === 3) break;
    }
  }
  if (culprits.length) return culprits;
  return [{ el: 'html', detail: `scrollWidth ${de.scrollWidth} > clientWidth ${cw}` }];
}

// styled = appearance none/base-select, or any border/padding/background longhand differs from an unstyled control of the same kind (owner, #55)
function checkNativeControl() {
  const out = [];
  const sel = 'select, input[type=date], input[type=time], input[type=datetime-local], input[type=month], input[type=week]';
  const PROPS = ['Top', 'Right', 'Bottom', 'Left'].flatMap((s) => [`border${s}Width`, `border${s}Style`, `border${s}Color`, `padding${s}`]).concat(['backgroundColor', 'backgroundImage']);
  for (const e of document.querySelectorAll(sel)) {
    if (!window.__vl.visible(e)) continue;
    const cs = getComputedStyle(e);
    const ap = cs.appearance || cs.webkitAppearance;
    if (ap === 'none' || ap === 'base-select') continue;
    // the reference sits in a shadow root next to e: UA styles only (page CSS does not cross the boundary), same inherited context
    // snapshot before inserting the host: a sibling changes :last-child/:only-child/:has(+…) matches
    const snap = Object.fromEntries(PROPS.map((k) => [k, cs[k]]));
    const host = document.createElement('span');
    e.after(host);
    let isDefault;
    try {
      const ref = document.createElement(e.tagName);
      if (e.tagName === 'INPUT') ref.type = e.type;
      ref.disabled = e.disabled; // a disabled control gets UA :disabled colours the enabled reference lacks
      host.attachShadow({ mode: 'open' }).appendChild(ref);
      const rs = getComputedStyle(ref);
      isDefault = PROPS.every((k) => snap[k] === rs[k]);
    } finally {
      host.remove();
    }
    if (isDefault) {
      out.push({
        el: window.__vl.describe(e),
        detail: `unstyled native control (appearance: ${ap}, default border, padding and background); style it or use a designed component`,
      });
    }
  }
  return out;
}

function checkTouchTarget() {
  const SEL = 'a[href], button, input:not([type=hidden]), select, textarea, summary, [role=button], [role=link], [role=tab], [role=menuitem], [role=checkbox], [role=radio], [role=switch], [tabindex]:not([tabindex="-1"])';
  const out = [];
  for (const e of document.querySelectorAll(SEL)) {
    if (!window.__vl.visible(e) || e.disabled) continue;
    if (e.parentElement?.closest(SEL)) continue;
    if (e.tagName === 'A' && getComputedStyle(e).display === 'inline') {
      // exempt only a link inside real prose: the parent's text minus every control in it has a letter or digit (punctuation separators like "Home | About" do not count)
      const clone = e.parentElement?.cloneNode(true);
      if (clone) {
        for (const d of clone.querySelectorAll(SEL)) d.remove();
        if (/[\p{L}\p{N}]/u.test(clone.textContent || '')) continue;
      }
    }
    const r = e.getBoundingClientRect();
    let w = r.width;
    let h = r.height;
    if (e.matches('input[type=checkbox], input[type=radio]') && e.labels?.[0]) {
      const lr = e.labels[0].getBoundingClientRect();
      w = Math.max(w, lr.width);
      h = Math.max(h, lr.height);
    }
    if (w < 43.5 || h < 43.5) {
      out.push({ el: window.__vl.describe(e), detail: `${Math.round(w)}x${Math.round(h)}px < 44px` });
    }
  }
  return out;
}

function checkStickyHeader() {
  const vl = window.__vl;
  const cands = [];
  for (const e of document.body.querySelectorAll('*')) {
    const cs = getComputedStyle(e);
    const pos = cs.position;
    if (pos !== 'fixed' && pos !== 'sticky') continue;
    if (!vl.visible(e)) continue;
    const r = e.getBoundingClientRect();
    // a sticky element with an offset pins later, so it is a header even when it sits below the top at scroll 0
    const pins = r.top <= 1 || (pos === 'sticky' && cs.top !== 'auto');
    if (pins && r.bottom > 0 && r.width >= 0.9 * innerWidth && r.height <= 0.5 * innerHeight) cands.push(e);
  }
  const headers = cands.filter((c) => !cands.some((o) => o !== c && o.contains(c)));
  const alphaOf = (color) => {
    const m = color.match(/\(([^)]*)\)/);
    if (!m) return 1;
    const inner = m[1];
    let a;
    if (inner.includes('/')) a = inner.split('/')[1].trim();
    else {
      const parts = inner.split(',');
      if (parts.length !== 4) return 1;
      a = parts[3].trim();
    }
    const n = a.endsWith('%') ? parseFloat(a) / 100 : parseFloat(a);
    return Number.isNaN(n) ? 1 : n;
  };
  const opaque = (x) => {
    const cs = getComputedStyle(x);
    return cs.opacity === '1' && (alphaOf(cs.backgroundColor) >= 0.99 || cs.backgroundImage !== 'none');
  };
  const hasContent = (n) => {
    if (['IMG', 'VIDEO', 'CANVAS', 'svg', 'IFRAME', 'INPUT', 'BUTTON', 'SELECT', 'TEXTAREA'].includes(n.tagName)) return true;
    for (const c of n.childNodes) if (c.nodeType === 3 && c.textContent.trim()) return true;
    return false;
  };
  const out = [];
  for (const h of headers) {
    const r = h.getBoundingClientRect();
    let ok = opaque(h);
    if (!ok) {
      for (const d of h.querySelectorAll('*')) {
        const dr = d.getBoundingClientRect();
        if (dr.width >= 0.95 * r.width && dr.height >= 0.95 * r.height && opaque(d)) { ok = true; break; }
      }
    }
    if (!ok) {
      const cs = getComputedStyle(h);
      out.push({ el: vl.describe(h), detail: `translucent background ${cs.backgroundColor} (opacity ${cs.opacity})` });
    }
    if (r.top > 1) continue;
    let found = null;
    for (const fx of [0.1, 0.5, 0.9]) {
      for (const y of [r.top + r.height / 2, r.bottom - 2]) {
        const x = r.left + fx * r.width;
        for (const n of document.elementsFromPoint(x, y)) {
          if (n === document.documentElement || n === document.body || n === h || h.contains(n) || n.contains(h)) continue;
          if (hasContent(n)) { found = n; break; }
        }
        if (found) break;
      }
      if (found) break;
    }
    if (found) out.push({ el: vl.describe(h), detail: `covers ${vl.describe(found)}` });
  }
  return out;
}

function checkClippedText() {
  const vl = window.__vl;
  const vw = document.documentElement.clientWidth;
  const root = document.documentElement;
  const cuts = (v) => v === 'hidden' || v === 'clip';
  const scrolls = (v) => v === 'auto' || v === 'scroll';
  // sr-only patterns: the text is hidden on purpose, by clip or clip-path on the element or an ancestor
  const srOnly = (el) => {
    for (let n = el; n && n !== root; n = n.parentElement) {
      const cs = getComputedStyle(n);
      if (cs.clip !== 'auto' && (cs.position === 'absolute' || cs.position === 'fixed')) return true;
      if (/inset\(\s*(50|100)%/.test(cs.clipPath)) return true;
      // a box with no layout of its own (display:contents) or an ancestor that does not clip (a float-only parent
      // collapses to 0 height) hides nothing: only the element itself or a clipping ancestor counts as a 1px box
      if (cs.display !== 'contents' && (n === el || cs.overflowX !== 'visible' || cs.overflowY !== 'visible')) {
        const r = n.getBoundingClientRect();
        if (r.width <= 1 || r.height <= 1) return true;
      }
    }
    return false;
  };
  // deliberate truncation: the full text is exposed in title or aria-label
  const exposed = (el) => {
    const full = vl.norm(el.textContent);
    return [el.getAttribute('title'), el.getAttribute('aria-label')].some((a) => a != null && vl.norm(a) === full);
  };
  const textRect = (el) => {
    let right = -Infinity;
    const range = document.createRange();
    for (const n of vl.textNodes(el)) {
      range.selectNodeContents(n);
      for (const r of range.getClientRects()) if (r.width > 0) right = Math.max(right, r.right);
    }
    return right;
  };
  const out = [];
  const seen = new Set();
  for (const el of vl.textEls()) {
    // text in an inline element is laid out in its nearest non-inline ancestor's line boxes: that box is what clips it
    let box = el;
    while (box !== document.body && getComputedStyle(box).display.startsWith('inline') && box.clientWidth === 0 && box.parentElement) box = box.parentElement;
    if (seen.has(box)) continue;
    if (exposed(el) || exposed(box) || srOnly(el)) continue;
    const cs = getComputedStyle(box);
    const text = `"${(box === el ? vl.ownText(el) : vl.norm(box.innerText)).slice(0, 40)}"`;
    let detail = null;
    if (box !== document.body && box.scrollWidth > box.clientWidth + 1 && (cuts(cs.overflowX) || (cs.textOverflow === 'ellipsis' && !scrolls(cs.overflowX) && cs.overflowX !== 'visible'))) {
      detail = `${text} scrollWidth ${box.scrollWidth} > clientWidth ${box.clientWidth} (overflow-x: ${cs.overflowX}${cs.textOverflow === 'ellipsis' ? ', ellipsis' : ''})`;
    } else if (box !== document.body && box.scrollHeight > box.clientHeight + 1 && cuts(cs.overflowY)) {
      const clamp = cs.webkitLineClamp && cs.webkitLineClamp !== 'none' ? `, line-clamp ${cs.webkitLineClamp}` : '';
      detail = `${text} scrollHeight ${box.scrollHeight} > clientHeight ${box.clientHeight} (overflow-y: ${cs.overflowY}${clamp})`;
    } else {
      // past the viewport's right edge, unless a container below body scrolls or clips it (that container is judged on its own)
      let contained = false;
      for (let n = el; n && n !== document.body && n !== root; n = n.parentElement) {
        const ox = getComputedStyle(n).overflowX;
        if (scrolls(ox) || cuts(ox)) { contained = true; break; }
      }
      const right = contained ? -Infinity : textRect(el);
      if (right > vw + 1) detail = `${text} text right edge ${Math.round(right)} > viewport ${vw}`;
    }
    if (detail) {
      seen.add(box);
      out.push({ el: vl.describe(box), detail });
    }
  }
  return out;
}

function checkContrast() {
  const vl = window.__vl;
  const root = document.documentElement;
  // any CSS colour (rgb, oklch, color-mix…) -> [r, g, b, a] in sRGB, through a 1x1 canvas
  const ctx = document.createElement('canvas').getContext('2d', { willReadFrequently: true });
  const cache = new Map();
  const parse = (c) => {
    if (cache.has(c)) return cache.get(c);
    let v;
    const m = c.match(/^rgba?\(\s*([\d.]+)[,\s]+([\d.]+)[,\s]+([\d.]+)(?:\s*[,/]\s*([\d.]+%?))?\s*\)$/);
    if (m) {
      const a = m[4] == null ? 1 : m[4].endsWith('%') ? parseFloat(m[4]) / 100 : parseFloat(m[4]);
      v = [+m[1], +m[2], +m[3], a];
    } else {
      ctx.clearRect(0, 0, 1, 1);
      ctx.fillStyle = '#000';
      ctx.fillStyle = c;
      ctx.fillRect(0, 0, 1, 1);
      const d = ctx.getImageData(0, 0, 1, 1).data;
      v = [d[0], d[1], d[2], d[3] / 255];
    }
    cache.set(c, v);
    return v;
  };
  const over = (top, a, base) => top.map((t, i) => t * a + base[i] * (1 - a));
  const lum = (c) => {
    const [r, g, b] = c.map((v) => {
      const s = v / 255;
      return s <= 0.04045 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
    });
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
  };
  const hex = (c) => '#' + c.map((v) => Math.round(v).toString(16).padStart(2, '0')).join('');
  // nothing opaque up to the root: the canvas, white unless the page opted into a dark colour scheme
  const rootScheme = getComputedStyle(root).colorScheme || '';
  const darkCanvas = /\bdark\b/.test(rootScheme) && (!/\blight\b/.test(rootScheme) || matchMedia('(prefers-color-scheme: dark)').matches);
  const canvas = darkCanvas ? [18, 18, 18] : [255, 255, 255];

  const groups = new Map();
  for (const el of vl.textEls()) {
    if (el.closest(':disabled, [aria-disabled="true"]')) continue;
    const cs = getComputedStyle(el);
    // chain = el and its ancestors up to the first opaque background
    const layers = [];
    let skip = false;
    let base = null;
    let n = el;
    for (; n; n = n.parentElement) {
      const ncs = getComputedStyle(n);
      if (ncs.backgroundImage !== 'none') { skip = true; break; }
      if (n.getAnimations().some((a) => a.playState === 'running')) { skip = true; break; }
      const bg = parse(ncs.backgroundColor);
      const op = parseFloat(ncs.opacity);
      layers.push({ bg, op });
      if (bg[3] >= 0.999) { base = n; break; }
    }
    if (skip) continue;
    // a translucent ancestor at or above the opaque background blends text and background with what is behind: not computable here
    let blended = false;
    for (let a = base || null; a; a = a.parentElement) {
      if (parseFloat(getComputedStyle(a).opacity) < 1) { blended = true; break; }
    }
    if (blended) continue;
    // composite top-down; static opacity below the opaque background fades that node's layer and the text
    let bgc = base ? layers[layers.length - 1].bg.slice(0, 3) : canvas;
    const upto = base ? layers.length - 1 : layers.length;
    for (let i = upto - 1; i >= 0; i--) {
      let a = layers[i].bg[3];
      for (let j = i; j < upto; j++) a *= layers[j].op;
      if (a > 0) bgc = over(layers[i].bg.slice(0, 3), a, bgc);
    }
    const fg = parse(cs.webkitTextFillColor || cs.color);
    let fa = fg[3];
    for (let j = 0; j < upto; j++) fa *= layers[j].op;
    if (fa <= 0) continue;
    const fgc = over(fg.slice(0, 3), fa, bgc);
    const l1 = lum(fgc);
    const l2 = lum(bgc);
    const ratio = (Math.max(l1, l2) + 0.05) / (Math.min(l1, l2) + 0.05);
    const size = parseFloat(cs.fontSize);
    const bold = (parseInt(cs.fontWeight, 10) || 400) >= 700;
    const min = size >= 24 || (bold && size >= 18.66) ? 3 : 4.5;
    if (ratio >= min) continue;
    const key = hex(fgc) + ' on ' + hex(bgc);
    const g = groups.get(key);
    if (g) g.count++;
    else groups.set(key, { el: vl.describe(el), ratio, min, size, bold, count: 1 });
  }
  const out = [];
  for (const [key, g] of groups) {
    const px = `${Math.round(g.size * 100) / 100}px${g.bold ? ' bold' : ''}`;
    const more = g.count > 1 ? ` (${g.count} elements)` : '';
    // floor, so a ratio just under the threshold never prints as the threshold
    out.push({ el: g.el, detail: `${(Math.floor(g.ratio * 100) / 100).toFixed(2)}:1 < ${g.min}, ${key}, ${px}${more}` });
  }
  return out;
}

// full-page evidence: fonts in, motion off, and the layout width the label claims
function prepareShot() {
  return document.fonts.ready.then(() => {
    const st = document.createElement('style');
    st.textContent = '*, *::before, *::after { animation: none !important; transition: none !important; scroll-behavior: auto !important; caret-color: transparent !important; }';
    document.head.appendChild(st);
    window.scrollTo(0, 0);
    return window.innerWidth;
  });
}

const CHECKS = [
  { rule: 'h-overflow', at: ['390', '1440'], fn: checkHOverflow },
  { rule: 'native-control', at: ['390', '1440'], fn: checkNativeControl },
  { rule: 'touch-target', at: ['390'], fn: checkTouchTarget },
  { rule: 'sticky-header', at: ['390', '1440'], fn: checkStickyHeader },
  { rule: 'clipped-text', at: ['390', '1440'], fn: checkClippedText },
  { rule: 'contrast', at: ['390', '1440'], fn: checkContrast },
];

// ---- runner ----

const firstLine = (e) => String((e && e.message) || e).split('\n')[0];
const usage = () => {
  console.error('usage: visual-lint.mjs --pw-from <dir> [--scheme light|dark|both] [--shots <dir>] [--name <slug>] <url>');
  process.exit(2);
};
const opts = { '--pw-from': null, '--scheme': 'light', '--shots': null, '--name': null };
const rest = [];
for (let a = process.argv.slice(2); a.length; ) {
  const k = a.shift();
  if (k in opts) {
    if (!a.length) usage();
    opts[k] = a.shift();
  } else if (k.startsWith('--')) usage();
  else rest.push(k);
}
const dir = opts['--pw-from'];
const scheme = opts['--scheme'];
const shots = opts['--shots'] ? resolve(opts['--shots']) : null;
if (!dir || rest.length !== 1 || !['light', 'dark', 'both'].includes(scheme)) usage();
if (opts['--name'] != null && !/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(opts['--name'])) usage();
const [url] = rest;
const SCHEMES = scheme === 'both' ? ['light', 'dark'] : [scheme];

// shot name: --name, else the URL path as a slug (a file: URL gives its basename), extension dropped, "/" -> index
const shotName = () => {
  if (opts['--name']) return opts['--name'];
  let p = '';
  try {
    const u = new URL(url);
    p = decodeURIComponent(u.pathname);
    if (u.protocol === 'file:') p = p.split('/').pop();
  } catch {}
  const slug = p.replace(/\.[A-Za-z0-9]{1,5}$/, '').replace(/[^A-Za-z0-9]+/g, '-').replace(/^-+|-+$/g, '').toLowerCase();
  return slug || 'index';
};

let pw;
try {
  pw = createRequire(join(dir, '_.js'))('playwright');
} catch {
  console.error(`visual-lint: env: playwright not found from ${dir}`);
  process.exit(3);
}

let browser;
try {
  browser = await pw.chromium.launch({ headless: true });
} catch (e) {
  console.error(`visual-lint: env: chromium launch failed: ${firstLine(e)}`);
  process.exit(3);
}

let total = 0;
let loadError = null;
try {
  for (const [vp, colorScheme] of VIEWPORTS.flatMap((v) => SCHEMES.map((s) => [v, s]))) {
    const { name, viewport, hasTouch, isMobile, deviceScaleFactor } = vp;
    const label = scheme === 'both' && colorScheme === 'dark' ? `${name}-dark` : name;
    const ctx = await browser.newContext({ viewport, hasTouch, isMobile, deviceScaleFactor, reducedMotion: 'reduce', colorScheme });
    const page = await ctx.newPage();
    try {
      const resp = await page.goto(url, { waitUntil: 'load', timeout: 30000 });
      if (resp && !resp.ok()) {
        loadError = `visual-lint: cannot load ${url}: HTTP ${resp.status()}`;
        break;
      }
    } catch (e) {
      loadError = `visual-lint: cannot load ${url}: ${firstLine(e)}`;
      break;
    }
    await page.waitForLoadState('networkidle', { timeout: 5000 }).catch(() => {});
    try {
      await page.evaluate(installHelpers);
      await page.evaluate(() => window.scrollTo(0, 0));
    } catch (e) {
      loadError = `visual-lint: check failed at @${label}: ${firstLine(e)}`;
      break;
    }
    for (const check of CHECKS) {
      if (!check.at.includes(name)) continue;
      let found;
      try {
        found = await page.evaluate(check.fn);
      } catch (e) {
        loadError = `visual-lint: check failed at @${label}: ${firstLine(e)}`;
        break;
      }
      total += found.length;
      for (const f of found.slice(0, 10)) console.log(`FAIL ${check.rule} @${label} ${f.el} — ${f.detail}`);
      if (found.length > 10) console.log(`FAIL ${check.rule} @${label} … and ${found.length - 10} more`);
    }
    if (loadError) break;
    if (shots) {
      try {
        const w = await page.evaluate(prepareShot);
        if (w !== viewport.width) {
          total += 1;
          console.log(`FAIL shot-width @${label} html — innerWidth ${w} != viewport ${viewport.width}`);
        }
        mkdirSync(shots, { recursive: true });
        const file = join(shots, `${shotName()}-${label}.png`);
        await page.screenshot({ path: file, fullPage: true });
        console.log(`SHOT ${file}`);
      } catch (e) {
        loadError = `visual-lint: shot failed at @${label}: ${firstLine(e)}`;
        break;
      }
    }
    await ctx.close();
  }
} finally {
  await browser.close();
}

if (loadError) {
  console.error(loadError);
  process.exit(2);
}
if (total === 0) {
  console.log(`visual-lint: OK ${url}`);
  process.exit(0);
}
console.log(`visual-lint: ${total} violation(s) at ${url}`);
process.exit(1);
