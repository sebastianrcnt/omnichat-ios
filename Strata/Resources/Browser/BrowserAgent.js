// Strata's browser agent: an indexed view of the page for the model, and actions on those indices (browser_state,
// browser_click, browser_type, ...). It runs in an isolated content world, so the page can neither see it nor change
// it; only the DOM is shared. The state format follows browser-use (MIT, https://github.com/browser-use/browser-use):
// `[index]<tag attr=value />`, text on lines of its own, tabs for nesting, `*[n]` for new elements, `|SCROLL|`.
(function () {
  if (window.__strataAgent) return;

  const S = {
    counter: 0,                 // the last index handed out; the app passes the session's so indices never repeat
    ids: new WeakMap(),         // element -> index, for this document
    latest: new Map(),          // index -> element, of the latest observation only
    offsets: new Map(),         // element -> offset of its frame in the top window
    seen: new WeakSet(),        // elements shown before on this URL (no star)
    lastURL: null,
    docId: Math.random().toString(36).slice(2),
  };

  const SKIP = new Set(["SCRIPT", "STYLE", "NOSCRIPT", "TEMPLATE", "HEAD", "META", "LINK", "TITLE", "PATH", "DEFS", "SYMBOL", "USE", "OPTION", "OPTGROUP", "DATALIST"]);
  const BLOCK = new Set(["ADDRESS", "ARTICLE", "ASIDE", "BLOCKQUOTE", "BR", "DD", "DIV", "DL", "DT", "FIELDSET", "FIGCAPTION", "FIGURE", "FOOTER", "FORM",
    "H1", "H2", "H3", "H4", "H5", "H6", "HEADER", "HR", "LI", "MAIN", "NAV", "OL", "P", "PRE", "SECTION", "TABLE", "TBODY", "THEAD", "TFOOT", "TR",
    "TD", "TH", "UL", "DIALOG", "SUMMARY", "DETAILS", "CAPTION", "LEGEND"]);
  const ROLES = new Set(["button", "link", "checkbox", "radio", "tab", "option", "menuitem", "menuitemcheckbox", "menuitemradio", "combobox",
    "switch", "textbox", "searchbox", "slider", "spinbutton", "treeitem", "gridcell"]);
  const TEXT_INPUTS = new Set(["", "text", "search", "email", "url", "tel", "password", "number", "date", "datetime-local", "month", "time", "week"]);

  const clean = (s) => String(s == null ? "" : s).replace(/\s+/g, " ").trim();
  const cut = (s, n) => (s.length > n ? s.slice(0, n - 1) + "…" : s);

  function viewport() {
    const v = window.visualViewport;
    if (v) return { left: v.offsetLeft, top: v.offsetTop, right: v.offsetLeft + v.width, bottom: v.offsetTop + v.height, width: v.width, height: v.height };
    return { left: 0, top: 0, right: window.innerWidth, bottom: window.innerHeight, width: window.innerWidth, height: window.innerHeight };
  }

  function intersect(a, b) {
    const r = { left: Math.max(a.left, b.left), top: Math.max(a.top, b.top), right: Math.min(a.right, b.right), bottom: Math.min(a.bottom, b.bottom) };
    return r.right > r.left && r.bottom > r.top ? r : null;
  }

  function shifted(r, off) {
    return { left: r.left + off.x, top: r.top + off.y, right: r.right + off.x, bottom: r.bottom + off.y, width: r.width, height: r.height };
  }

  function styleOf(el) {
    try { return el.ownerDocument.defaultView.getComputedStyle(el); } catch (e) { return null; }
  }

  function visibleStyle(el) {
    const st = styleOf(el);
    if (!st) return false;
    // `display: contents` has no box of its own, so checkVisibility says no: its parent decides.
    if (st.display === "contents") return !!el.parentElement && visibleStyle(el.parentElement) && st.visibility !== "hidden";
    if (el.checkVisibility) return el.checkVisibility({ opacityProperty: true, visibilityProperty: true });
    return st.display !== "none" && st.visibility !== "hidden" && st.opacity !== "0";
  }

  // The parent in the flat tree: through slots and out of shadow roots.
  function composedParent(n) {
    if (n.assignedSlot) return n.assignedSlot;
    if (n.parentNode && n.parentNode.nodeType === 11) return n.parentNode.host || null;
    return n.parentNode || null;
  }

  function composedContains(outer, inner) {
    for (let n = inner; n; n = composedParent(n)) if (n === outer) return true;
    return false;
  }

  // The deepest element at a point of `doc`'s viewport, looking into shadow roots.
  function hitAt(doc, x, y) {
    let hit = doc.elementFromPoint(x, y);
    while (hit && hit.shadowRoot) {
      const inner = hit.shadowRoot.elementFromPoint(x, y);
      if (!inner || inner === hit) break;
      hit = inner;
    }
    return hit;
  }

  // Not covered by something else (a modal, a sticky header): a point of its visible part hits it or its inside.
  function reachable(el, clip, off) {
    const doc = el.ownerDocument;
    const w = clip.right - clip.left, h = clip.bottom - clip.top;
    const points = [[0.5, 0.5], [0.25, 0.25], [0.75, 0.75], [0.25, 0.75], [0.75, 0.25]];
    for (const [fx, fy] of points) {
      const hit = hitAt(doc, clip.left + w * fx - off.x, clip.top + h * fy - off.y);
      if (!hit) continue;
      if (hit === el || composedContains(el, hit) || composedContains(hit, el)) return true;
    }
    return false;
  }

  function isEditable(el) {
    if (!el || el.nodeType !== 1) return false;
    const tag = el.tagName;
    if (tag === "TEXTAREA") return !el.disabled && !el.readOnly;
    if (tag === "INPUT") return TEXT_INPUTS.has((el.getAttribute("type") || "").toLowerCase()) && !el.disabled && !el.readOnly;
    return !!el.isContentEditable;
  }

  function interactive(el, tag, st) {
    if (tag === "A") return el.hasAttribute("href") || el.hasAttribute("onclick");
    if (tag === "BUTTON" || tag === "SELECT" || tag === "TEXTAREA" || tag === "SUMMARY") return true;
    if (tag === "INPUT") return (el.getAttribute("type") || "").toLowerCase() !== "hidden";
    if (tag === "LABEL") {
      const c = el.control;
      return !!c && !boxVisible(c);
    }
    const role = (el.getAttribute("role") || "").toLowerCase();
    if (ROLES.has(role)) return true;
    if (el.hasAttribute("onclick")) return true;
    if (el.isContentEditable && !(el.parentElement && el.parentElement.isContentEditable)) return true;
    const tab = el.getAttribute("tabindex");
    if (tab !== null && parseInt(tab, 10) >= 0 && tag !== "BODY" && tag !== "HTML") return true;
    if (st && st.cursor === "pointer") {
      const p = composedParent(el);
      const ps = p && p.nodeType === 1 ? styleOf(p) : null;
      return !ps || ps.cursor !== "pointer";
    }
    return false;
  }

  function boxVisible(el) {
    const r = el.getBoundingClientRect();
    return r.width > 1 && r.height > 1 && visibleStyle(el);
  }

  function scrollInfo(el, st) {
    if (!st) return null;
    const y = el.scrollHeight > el.clientHeight + 4 && /(auto|scroll|overlay)/.test(st.overflowY);
    const x = el.scrollWidth > el.clientWidth + 4 && /(auto|scroll|overlay)/.test(st.overflowX);
    if (!y && !x) return null;
    if (y) {
      const above = Math.round(el.scrollTop), below = Math.max(0, Math.round(el.scrollHeight - el.clientHeight - el.scrollTop));
      return "(" + above + " px above, " + below + " px below)";
    }
    const left = Math.round(el.scrollLeft), right = Math.max(0, Math.round(el.scrollWidth - el.clientWidth - el.scrollLeft));
    return "(scrolls sideways: " + left + " px left, " + right + " px right)";
  }

  function shortHref(el) {
    const raw = el.getAttribute("href");
    if (raw == null) return null;
    if (/^\s*javascript:/i.test(raw)) return "javascript:";
    if (raw.trim() === "#" || raw.trim() === "") return raw.trim() || null;
    try {
      const u = new URL(raw, el.ownerDocument.baseURI);
      const here = new URL(location.href);
      const s = u.origin === here.origin ? u.pathname + u.search + u.hash : u.host + u.pathname + u.search;
      return cut(s, 80);
    } catch (e) { return cut(raw, 80); }
  }

  function attributes(el, tag) {
    const out = [];
    const add = (k, v, n) => { const c = clean(v); if (c) out.push(k + "=" + cut(c, n || 80)); };
    const type = (el.getAttribute("type") || "").toLowerCase();
    if (tag === "INPUT") add("type", type || "text");
    const role = el.getAttribute("role");
    if (role) add("role", role);
    if (tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT" || tag === "BUTTON") add("name", el.getAttribute("name"), 40);
    add("placeholder", el.getAttribute("placeholder"));
    add("aria-label", el.getAttribute("aria-label"));
    if (tag === "TEXTAREA" || (tag === "INPUT" && type !== "checkbox" && type !== "radio" && type !== "submit" && type !== "button" && type !== "file")) {
      add("value", type === "password" ? (el.value ? "••••" : "") : el.value, 120);
    } else if (tag === "INPUT" && (type === "submit" || type === "button")) {
      add("value", el.value);
    } else if (tag === "SELECT") {
      const opts = Array.from(el.options || []);
      const sel = opts[el.selectedIndex];
      if (sel) add("value", sel.text);
      if (opts.length) {
        const names = opts.slice(0, 8).map((o) => clean(o.text)).filter(Boolean).map((t) => cut(t, 30));
        out.push("options=" + names.join("|") + (opts.length > 8 ? "|…+" + (opts.length - 8) : ""));
      }
    }
    if (el.isContentEditable && tag !== "INPUT" && tag !== "TEXTAREA") out.push("contenteditable");
    if (tag === "A") { const h = shortHref(el); if (h) out.push("href=" + h); }
    add("title", el.getAttribute("title"));
    add("alt", el.getAttribute("alt"));
    if (el.checked === true || el.getAttribute("aria-checked") === "true") out.push("checked");
    if (el.getAttribute("aria-selected") === "true") out.push("selected");
    const exp = el.getAttribute("aria-expanded");
    if (exp === "true" || exp === "false") out.push("expanded=" + exp);
    if (el.disabled === true || el.getAttribute("aria-disabled") === "true") out.push("disabled");
    return out;
  }

  function label(el) {
    const tag = el.tagName;
    const pick = [el.getAttribute("aria-label"), tag === "INPUT" || tag === "TEXTAREA" ? el.getAttribute("placeholder") : null,
      tag === "SELECT" ? null : el.innerText, el.getAttribute("title"), el.getAttribute("alt"), el.getAttribute("name"),
      tag === "INPUT" ? el.value : null];
    for (const p of pick) { const c = clean(p); if (c) return cut(c, 40); }
    const img = el.querySelector && el.querySelector("img[alt]");
    if (img && clean(img.alt)) return cut(clean(img.alt), 40);
    return tag.toLowerCase();
  }

  // MARK: Observation

  function observe(opts) {
    const vp = viewport();
    const url = location.href;
    if (S.lastURL !== url) { S.seen = new WeakSet(); }
    const stars = !!opts.markNew && S.lastURL === url;
    S.lastURL = url;
    S.counter = Math.max(S.counter, (opts.startAt || 1) - 1);
    S.offsets = new Map();
    const range = document.createRange();
    const root = { children: [] };
    let pendingBreak = false;
    const visCache = new Map();

    const parentVisible = (el) => {
      if (!el) return false;
      let v = visCache.get(el);
      if (v === undefined) { v = visibleStyle(el); visCache.set(el, v); }
      return v;
    };

    function addText(parent, text, inInteractive) {
      const t = clean(text);
      if (!t) return;
      const last = parent.children[parent.children.length - 1];
      if (last && last.text !== undefined && !pendingBreak) last.text = cut(last.text + " " + t, 1000);
      else parent.children.push({ text: cut(t, 1000) });
      pendingBreak = false;
    }

    function walkChildren(node, parent, ctx) {
      // An element with a shadow root shows its shadow tree (slots pull the light children in).
      const kids = node.shadowRoot ? node.shadowRoot.childNodes : node.childNodes;
      for (const child of kids) walk(child, parent, ctx);
    }

    function walk(node, parent, ctx) {
      if (node.nodeType === 3) {
        if (!node.data.trim()) return;
        const p = node.parentElement;
        if (!parentVisible(p)) return;
        range.selectNodeContents(node);
        const r = range.getBoundingClientRect();
        if (r.width === 0 && r.height === 0) return;
        if (!intersect(shifted(r, ctx.off), ctx.clip)) return;
        addText(parent, node.data, ctx.inInteractive);
        return;
      }
      if (node.nodeType !== 1) return;
      const el = node;
      const tag = el.tagName.toUpperCase();
      if (SKIP.has(tag)) return;
      if (tag === "SLOT") { for (const n of el.assignedNodes({ flatten: true })) walk(n, parent, ctx); return; }
      if (el.checkVisibility && !el.checkVisibility()) { // display: none, the whole subtree
        const st = styleOf(el);
        if (!st || st.display !== "contents") return;
      }
      if (tag === "IFRAME" || tag === "FRAME") { walkFrame(el, parent, ctx); return; }
      const block = BLOCK.has(tag);
      if (block) pendingBreak = true;

      let rect = null, box = null;
      const r = el.getBoundingClientRect();
      if (r.width > 0 && r.height > 0) { rect = shifted(r, ctx.off); box = intersect(rect, ctx.clip); }

      let node2 = null;
      if (box && tag !== "BODY" && tag !== "HTML" && parentVisible(el)) {
        const st = styleOf(el);
        const scroll = scrollInfo(el, st);
        const isInteractive = (!st || st.pointerEvents !== "none") && interactive(el, tag, st);
        if ((isInteractive || scroll) && reachable(el, box, ctx.off)) {
          node2 = { el, tag: tag.toLowerCase(), attrs: attributes(el, tag), scroll, children: [] };
          S.offsets.set(el, ctx.off);
        }
      }
      if ((tag === "IMG" || tag === "SVG") && ctx.inInteractive && box) {
        const alt = tag === "IMG" ? el.getAttribute("alt") : (el.getAttribute("aria-label") || (el.querySelector("title") || {}).textContent);
        if (alt) addText(parent, alt, true);
      }
      if (node2) {
        parent.children.push(node2);
        pendingBreak = false;
        if (tag !== "INPUT" && tag !== "TEXTAREA" && tag !== "SELECT") {
          // A scrolling container clips what's inside it; text inside a control names it (an icon's alt counts too).
          walkChildren(el, node2, { off: ctx.off, clip: node2.scroll ? (intersect(ctx.clip, rect) || ctx.clip) : ctx.clip,
            inInteractive: ctx.inInteractive || !node2.scroll });
        }
        pendingBreak = true;
      } else if (tag !== "INPUT" && tag !== "TEXTAREA" && tag !== "SELECT") {
        walkChildren(el, parent, ctx);
      }
      if (block) pendingBreak = true;
    }

    function walkFrame(frame, parent, ctx) {
      let doc = null;
      try { doc = frame.contentDocument; } catch (e) { doc = null; }
      if (!doc || !doc.body) return;
      const r = frame.getBoundingClientRect();
      if (r.width <= 0 || r.height <= 0) return;
      const off = { x: ctx.off.x + r.left + frame.clientLeft, y: ctx.off.y + r.top + frame.clientTop };
      const frameBox = { left: off.x, top: off.y, right: off.x + frame.clientWidth, bottom: off.y + frame.clientHeight };
      const clip = intersect(ctx.clip, frameBox);
      if (!clip) return;
      walk(doc.body, parent, { off, clip, inInteractive: ctx.inInteractive });
    }

    if (document.body) walk(document.body, root, { off: { x: 0, y: 0 }, clip: vp, inInteractive: false });

    // Render, giving indices in reading order, until the size limit.
    const max = opts.maxChars || 14000;
    const lines = [];
    let size = 0, truncated = false, skipped = 0;
    S.latest = new Map();
    let shown = 0;

    function render(n, depth) {
      const pad = "\t".repeat(depth);
      if (n.text !== undefined) {
        if (truncated) return;
        const line = pad + n.text;
        if (size + line.length + 1 > max) { truncated = true; return; }
        lines.push(line); size += line.length + 1;
        return;
      }
      if (truncated) { skipped += 1; for (const c of n.children) render(c, depth + 1); return; }
      let idx = S.ids.get(n.el);
      if (idx === undefined) { idx = ++S.counter; S.ids.set(n.el, idx); }
      // Text the element already shows needn't be repeated as an attribute.
      const own = n.children.filter((c) => c.text !== undefined).map((c) => c.text).join(" ");
      const attrs = n.attrs.filter((a) => {
        const m = /^(aria-label|title)=(.*)$/.exec(a);
        if (!m || !own) return true;
        const v = m[2].replace(/…$/, "");
        return !(own === v || own.startsWith(v));
      });
      const star = stars && !S.seen.has(n.el) ? "*" : "";
      const line = pad + star + (n.scroll ? "|SCROLL|" : "") + "[" + idx + "]<" + n.tag + (attrs.length ? " " + attrs.join(" ") : "") + " />" + (n.scroll ? " " + n.scroll : "");
      if (size + line.length + 1 > max) { truncated = true; skipped += 1; for (const c of n.children) render(c, depth + 1); return; }
      lines.push(line); size += line.length + 1;
      S.latest.set(idx, n.el);
      S.seen.add(n.el);
      shown += 1;
      for (const c of n.children) render(c, depth + 1);
    }
    for (const c of root.children) render(c, 0);

    const se = document.scrollingElement || document.documentElement;
    const above = Math.round(window.scrollY);
    const below = Math.max(0, Math.round(se.scrollHeight - window.scrollY - vp.height));
    let tree = lines.join("\n");
    if (!tree) tree = "(Nothing is visible in this part of the page.)";
    if (truncated) tree += "\n[Truncated at " + max + " characters: " + skipped + " more elements in view are not listed. Use browser_find to locate text, or scroll a container with browser_scroll and its index.]";
    return {
      url, title: (document.title || "").slice(0, 300), docId: S.docId, counter: S.counter, count: shown,
      scroll: above + " px above, " + below + " px below (viewport " + Math.round(vp.width) + "x" + Math.round(vp.height) + ")",
      below, tree,
    };
  }

  // MARK: Actions

  function lookup(index) {
    const el = S.latest.get(Number(index));
    if (!el) return { error: "stale", message: "[" + index + "] is not in the latest page state." };
    if (!el.isConnected) return { error: "stale", message: "[" + index + "] is no longer on the page." };
    return { el };
  }

  function topRect(el) {
    const r = el.getBoundingClientRect();
    return shifted(r, S.offsets.get(el) || { x: 0, y: 0 });
  }

  function ensureInView(el) {
    const vp = viewport();
    const r = topRect(el);
    if (r.top < vp.top || r.bottom > vp.bottom || r.left < vp.left || r.right > vp.right) {
      try { el.scrollIntoView({ block: "center", inline: "nearest", behavior: "instant" }); } catch (e) { el.scrollIntoView(); }
    }
  }

  function fire(target, type, x, y, view) {
    const base = { bubbles: true, cancelable: true, composed: true, clientX: x, clientY: y, screenX: x, screenY: y, view,
      button: 0, buttons: /down$/.test(type) ? 1 : 0, detail: type === "click" ? 1 : 0 };
    let ev;
    if (/^pointer/.test(type) && view.PointerEvent) {
      ev = new view.PointerEvent(type, Object.assign({ pointerId: 1, pointerType: "touch", isPrimary: true, width: 1, height: 1,
        pressure: type === "pointerdown" ? 0.5 : 0 }, base));
    } else if (/^touch/.test(type)) {
      if (!view.TouchEvent || !view.Touch) return true;
      try {
        const t = new view.Touch({ identifier: 1, target, clientX: x, clientY: y, screenX: x, screenY: y, pageX: x + view.scrollX, pageY: y + view.scrollY });
        const list = type === "touchend" ? [] : [t];
        ev = new view.TouchEvent(type, { bubbles: true, cancelable: true, composed: true, touches: list, targetTouches: list, changedTouches: [t], view });
      } catch (e) { return true; }
    } else {
      ev = new view.MouseEvent(type, base);
    }
    return target.dispatchEvent(ev);
  }

  // A tap as a phone's browser sends it: pointer, touch, then the mouse events and the click (unless a touch handler
  // cancelled them).
  function tap(el) {
    ensureInView(el);
    const doc = el.ownerDocument, view = doc.defaultView;
    const r = el.getBoundingClientRect();
    const vw = view.innerWidth, vh = view.innerHeight;
    const x = Math.min(Math.max(r.left + r.width / 2, 1), vw - 1), y = Math.min(Math.max(r.top + r.height / 2, 1), vh - 1);
    let target = hitAt(doc, x, y);
    if (!target || !(target === el || composedContains(el, target))) target = el;
    fire(target, "pointerover", x, y, view);
    fire(target, "pointerdown", x, y, view);
    const touchOK = fire(target, "touchstart", x, y, view);
    fire(target, "pointerup", x, y, view);
    const endOK = fire(target, "touchend", x, y, view);
    if (!touchOK || !endOK) return;
    fire(target, "mouseover", x, y, view);
    fire(target, "mousedown", x, y, view);
    const focusable = el.closest && el.closest("a[href], button, input, select, textarea, summary, [tabindex], [contenteditable]");
    if (focusable) softFocus(focusable);
    fire(target, "mouseup", x, y, view);
    fire(target, "click", x, y, view);
  }

  function click(a) {
    const f = lookup(a.index);
    if (f.error) return f;
    const el = f.el;
    const name = label(el);
    const tag = el.tagName.toLowerCase();
    tap(el);
    return { ok: true, label: name, tag, docId: S.docId };
  }

  // Focus events without moving the focus: real focus in a hidden view would raise the keyboard over the app (and
  // take the user's typing), so handlers that open a list or a picker on focus run, and the page keeps its focus.
  function softFocus(el) {
    const doc = el.ownerDocument, view = doc.defaultView;
    if (deepActive(doc) === el) return;
    try {
      el.dispatchEvent(new view.FocusEvent("focus", { bubbles: false, composed: true }));
      el.dispatchEvent(new view.FocusEvent("focusin", { bubbles: true, composed: true }));
    } catch (e) {}
  }

  function setNativeValue(el, value) {
    const proto = el.tagName === "TEXTAREA" ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
    const setter = Object.getOwnPropertyDescriptor(proto, "value").set;
    setter.call(el, value);
  }

  function key(el, type, k, code) {
    const view = el.ownerDocument.defaultView;
    const ev = new view.KeyboardEvent(type, { key: k, code, keyCode: code === "Enter" ? 13 : 0, which: code === "Enter" ? 13 : 0,
      bubbles: true, cancelable: true, composed: true, view });
    return el.dispatchEvent(ev);
  }

  function type(a) {
    const f = lookup(a.index);
    if (f.error) return f;
    let el = f.el;
    const text = String(a.text == null ? "" : a.text);
    if (el.tagName === "SELECT") return { error: "usage", message: "[" + a.index + "] is a <select>: use browser_select." };
    if (!isEditable(el)) {
      // A field that opens an editor when tapped (a search bar that turns into an input): tap it, then type into the field that has focus.
      tap(el);
      const active = deepActive(el.ownerDocument);
      if (!isEditable(active)) return { error: "usage", message: "[" + a.index + "] is not a text field, and tapping it did not focus one." };
      el = active;
    }
    const name = label(f.el);
    ensureInView(el);
    softFocus(el);
    const doc = el.ownerDocument, view = doc.defaultView;
    const inputEvent = (type) => new view.InputEvent(type, { bubbles: true, cancelable: type === "beforeinput", composed: true,
      inputType: text ? "insertText" : "deleteContentBackward", data: text || null });
    el.dispatchEvent(inputEvent("beforeinput"));
    if (el.isContentEditable && el.tagName !== "INPUT" && el.tagName !== "TEXTAREA") {
      el.textContent = text;
    } else {
      // The prototype's setter, from this isolated world: the page's own value hooks (React's tracker) don't see the
      // change, so the input event below reads as a real edit to them.
      setNativeValue(el, text);
    }
    el.dispatchEvent(inputEvent("input"));
    const last = text.slice(-1) || "Backspace";
    key(el, "keydown", last, last.length === 1 ? "Key" + last.toUpperCase() : last);
    key(el, "keyup", last, last.length === 1 ? "Key" + last.toUpperCase() : last);
    el.dispatchEvent(new (doc.defaultView.Event)("change", { bubbles: true }));
    let submitted = false;
    if (a.submit) {
      const go = key(el, "keydown", "Enter", "Enter");
      key(el, "keypress", "Enter", "Enter");
      key(el, "keyup", "Enter", "Enter");
      if (go && el.form) {
        try { el.form.requestSubmit(); } catch (e) { try { el.form.submit(); } catch (e2) {} }
      }
      submitted = true;
    }
    const value = el.tagName === "INPUT" || el.tagName === "TEXTAREA" ? el.value : clean(el.innerText);
    return { ok: true, label: name, value: el.type === "password" ? "••••" : cut(String(value), 200), submitted, docId: S.docId };
  }

  function deepActive(doc) {
    let a = doc.activeElement;
    while (a && a.shadowRoot && a.shadowRoot.activeElement) a = a.shadowRoot.activeElement;
    if (a && (a.tagName === "IFRAME" || a.tagName === "FRAME")) { try { return deepActive(a.contentDocument); } catch (e) {} }
    return a;
  }

  function select(a) {
    const f = lookup(a.index);
    if (f.error) return f;
    const el = f.el;
    if (el.tagName !== "SELECT") return { error: "usage", message: "[" + a.index + "] is not a <select>. For a custom list, click it, then click the option." };
    const want = clean(a.option);
    const opts = Array.from(el.options);
    const lower = want.toLowerCase();
    const match = opts.find((o) => clean(o.text) === want) || opts.find((o) => o.value === String(a.option))
      || opts.find((o) => clean(o.text).toLowerCase() === lower) || opts.find((o) => clean(o.text).toLowerCase().includes(lower));
    if (!match) {
      return { error: "usage", message: "[" + a.index + "] has no option \"" + want + "\". Its options: " + opts.slice(0, 40).map((o) => clean(o.text)).join(" | ") };
    }
    softFocus(el);
    el.selectedIndex = match.index;
    const view = el.ownerDocument.defaultView;
    el.dispatchEvent(new view.Event("input", { bubbles: true, composed: true }));
    el.dispatchEvent(new view.Event("change", { bubbles: true }));
    return { ok: true, label: label(el), value: clean(match.text), docId: S.docId };
  }

  function scrollable(el) {
    for (let n = el; n && n.nodeType === 1; n = composedParent(n)) {
      if (n === document.body || n === document.documentElement) return null;
      const st = styleOf(n);
      if (st && ((n.scrollHeight > n.clientHeight + 4 && /(auto|scroll|overlay)/.test(st.overflowY))
        || (n.scrollWidth > n.clientWidth + 4 && /(auto|scroll|overlay)/.test(st.overflowX)))) return n;
    }
    return null;
  }

  // The page's main scrolling area when the document itself doesn't scroll (apps that scroll an inner pane).
  function mainScroller() {
    let best = null, area = 0;
    for (const el of S.latest.values()) {
      const s = scrollable(el);
      if (!s || s.scrollHeight <= s.clientHeight + 4) continue;
      const r = s.getBoundingClientRect();
      if (r.width * r.height > area) { area = r.width * r.height; best = s; }
    }
    return best;
  }

  function scroll(a) {
    const down = a.direction !== "up";
    const pages = Math.min(Math.max(Number(a.pages) || 1, 0.1), 10);
    let target = null, what = "the page";
    if (a.index != null) {
      const f = lookup(a.index);
      if (f.error) return f;
      target = scrollable(f.el);
      if (!target) return { error: "usage", message: "[" + a.index + "] doesn't scroll. Leave out index to scroll the page." };
      what = "[" + a.index + "]";
    }
    const se = document.scrollingElement || document.documentElement;
    if (!target && se.scrollHeight <= window.innerHeight + 4) {
      target = mainScroller();
      if (target) { const i = S.ids.get(target); what = i ? "the page's scrolling area [" + i + "]" : "the page's scrolling area"; }
    }
    const el = target || se;
    const height = target ? target.clientHeight : viewport().height;
    const before = target ? target.scrollTop : window.scrollY;
    const dy = (down ? 1 : -1) * Math.round(height * pages);
    if (target) target.scrollBy({ top: dy, behavior: "instant" }); else window.scrollBy({ top: dy, behavior: "instant" });
    const after = target ? target.scrollTop : window.scrollY;
    const moved = Math.round(Math.abs(after - before));
    return { ok: true, what, moved, down, atEnd: moved < 2, docId: S.docId, max: Math.round(el.scrollHeight - (target ? target.clientHeight : window.innerHeight)) };
  }

  // MARK: Find

  function find(a) {
    const q = clean(a.text).toLowerCase();
    if (!q) return { error: "usage", message: "Give some text to find." };
    const vp = viewport();
    const found = [];
    function deepest(node) {
      // Elements whose text contains the query, none of whose children's does: the tightest places it appears.
      let any = false;
      for (const child of node.children || []) {
        if (SKIP.has(child.tagName.toUpperCase())) continue;
        if (child.shadowRoot) { if (deepest(child.shadowRoot)) any = true; }
        if (clean(child.textContent).toLowerCase().includes(q)) { any = true; if (!deepest(child)) found.push(child); }
        else if (child.tagName === "IFRAME") {
          try { const d = child.contentDocument; if (d && d.body && deepest(d.body)) any = true; } catch (e) {}
        }
      }
      return any;
    }
    if (document.body) deepest(document.body);
    const visible = found.filter((el) => el.checkVisibility ? el.checkVisibility({ visibilityProperty: true }) : true);
    const matches = visible.slice(0, 20).map((el) => {
      const text = clean(el.innerText || el.textContent);
      const at = text.toLowerCase().indexOf(q);
      const from = Math.max(0, at - 60);
      const snippet = (from > 0 ? "…" : "") + text.slice(from, at + q.length + 60) + (at + q.length + 60 < text.length ? "…" : "");
      const r = el.getBoundingClientRect();
      const where = r.bottom < vp.top ? Math.round(vp.top - r.bottom) + " px above"
        : r.top > vp.bottom ? Math.round(r.top - vp.bottom) + " px below" : "in view";
      let index = null;
      for (let n = el; n; n = composedParent(n)) {
        const i = S.ids.get(n);
        if (i !== undefined && S.latest.get(i) === n) { index = i; break; }
      }
      return { snippet: snippet || cut(text, 120), where, index };
    });
    let scrolled = false;
    const pick = Number(a.scrollTo);
    if (pick >= 1 && pick <= Math.min(visible.length, 20)) {
      try { visible[pick - 1].scrollIntoView({ block: "center", behavior: "instant" }); scrolled = true; } catch (e) {}
    }
    return { ok: true, total: visible.length, matches, scrolled, docId: S.docId };
  }

  // MARK: Screenshot marks

  const MARK_COLORS = ["#E5484D", "#0090FF", "#30A46C", "#F76B15", "#8E4EC6", "#D6409F", "#12A594", "#AB6400"];
  let marks = null;

  function mark() {
    unmark();
    // Built with the CSSOM, not markup, so a page's CSP or Trusted Types don't stop it; a closed shadow root keeps
    // the page's styles (and scripts) out.
    const host = document.createElement("div");
    host.style.cssText = "all: initial; position: fixed; inset: 0; pointer-events: none; z-index: 2147483647;";
    const shadow = host.attachShadow({ mode: "closed" });
    for (const [i, el] of S.latest) {
      if (!el.isConnected) continue;
      const r = topRect(el);
      if (r.width <= 0 || r.height <= 0) continue;
      const c = MARK_COLORS[i % MARK_COLORS.length];
      const box = document.createElement("div");
      box.style.cssText = "position: fixed; box-sizing: border-box; left: " + r.left + "px; top: " + r.top + "px; width: " + r.width
        + "px; height: " + r.height + "px; border: 2px solid " + c + ";";
      const tag = document.createElement("span");
      tag.style.cssText = "position: absolute; left: -2px; top: " + (r.top >= 16 ? -16 : 0) + "px; background: " + c
        + "; color: #fff; font: bold 11px/14px -apple-system, Helvetica, sans-serif; padding: 1px 3px; border-radius: 2px;";
      tag.textContent = String(i);
      box.appendChild(tag);
      shadow.appendChild(box);
    }
    document.documentElement.appendChild(host);
    marks = host;
    return { ok: true, count: S.latest.size };
  }

  function unmark() {
    if (marks) { marks.remove(); marks = null; }
    return { ok: true };
  }

  window.__strataAgent = { observe, click, type, select, scroll, find, mark, unmark };
})();
