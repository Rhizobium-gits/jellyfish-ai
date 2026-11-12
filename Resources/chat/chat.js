"use strict";
// 会話の表示。アプリ（Swift）が JF.update(payload) でメッセージの一覧を渡す。
// 変わったメッセージだけ作り直す。リンク・ボタンは自分では開かず、アプリに知らせる（アプリが確かめてから開く）
(function () {
  const log = document.getElementById("log");
  const nodes = new Map();
  const images = new Map();   // サムネイル（key → data: の URL。アプリが 1 回だけ送る）
  let stick = true;          // 一番下を見ているか（見ていれば新しいメッセージに追従する）
  let diagramSeq = 0;
  let emptyEl = null;

  const post = (msg) => { try { window.webkit.messageHandlers.jf.postMessage(msg); } catch (e) {} };
  const dark = () => window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches;

  if (typeof mermaid !== "undefined") {
    try {
      mermaid.initialize({
        startOnLoad: false, securityLevel: "strict", htmlLabels: false,
        flowchart: { htmlLabels: false }, theme: dark() ? "dark" : "default",
        fontFamily: "-apple-system, BlinkMacSystemFont, 'Hiragino Sans', sans-serif",
      });
    } catch (e) {}
  }

  function sanitize(html) {
    if (typeof DOMPurify === "undefined") return JFRender.escape(html);
    return DOMPurify.sanitize(html, {
      USE_PROFILES: { html: true, mathMl: true },
      FORBID_TAGS: ["style", "form", "input", "button", "textarea", "select", "iframe", "object", "embed", "video", "audio", "img"],
      // URL として使えるのは http / https / mailto だけ（javascript: や file:・data: は消す）。
      // ほかの属性の値（表の揃えの "right"・数式の属性など）はそのまま（DOMPurify は属性の値もこの式で見るため、既定の形にそろえる）
      ALLOWED_URI_REGEXP: /^(?:(?:https?|mailto):|[^a-z]|[a-z+.\-]+(?:[^a-z+.\-:]|$))/i,
    });
  }

  function div(cls) { const d = document.createElement("div"); if (cls) d.className = cls; return d; }

  function link(text, href) {
    const a = document.createElement("a");
    a.textContent = text;
    a.dataset.href = href;
    a.href = "#";
    return a;
  }

  function mediaEl(m) {
    const box = div("media");
    const thumb = m.thumbKey ? images.get(m.thumbKey) : null;
    if (thumb) {
      const img = document.createElement("img");
      img.className = "thumb";
      img.src = thumb;            // data: だけ（CSP）
      img.alt = m.name || "";
      img.dataset.href = m.link;
      box.appendChild(img);
    }
    const label = div("label");
    if (m.previewLink) {
      label.appendChild(link("🔗 " + (m.host || m.link), m.link));
      label.appendChild(document.createTextNode("  "));
      label.appendChild(link(m.previewLabel || "Show cover", m.previewLink));
    } else {
      label.appendChild(link(m.label || m.name || m.link, m.link));
    }
    box.appendChild(label);
    return box;
  }

  function addCopyButtons(root) {
    root.querySelectorAll("pre").forEach((pre) => {
      if (pre.closest(".diagram")) return;
      const b = document.createElement("span");
      b.className = "copy";
      b.textContent = window.JF_COPY_LABEL || "Copy";
      b.addEventListener("click", (e) => {
        e.preventDefault();
        const code = pre.querySelector("code");
        post({ type: "copy", text: code ? code.textContent : pre.textContent });
        b.textContent = window.JF_COPIED_LABEL || "Copied";
        setTimeout(() => { b.textContent = window.JF_COPY_LABEL || "Copy"; }, 1400);
      });
      pre.appendChild(b);
    });
  }

  async function renderDiagrams(root) {
    if (typeof mermaid === "undefined") return;
    for (const d of root.querySelectorAll(".diagram.pending")) {
      const code = d.querySelector("code");
      const src = code ? code.textContent : "";
      const id = "jfmmd" + (++diagramSeq);
      try {
        const out = await mermaid.render(id, src);
        const svg = typeof DOMPurify !== "undefined"
          ? DOMPurify.sanitize(out.svg, { USE_PROFILES: { svg: true, svgFilters: true } })
          : "";
        d.innerHTML = svg;
        d.classList.remove("pending");
      } catch (e) {
        d.classList.remove("pending");
        d.classList.add("failed");
        const note = div("diagram-note");
        const why = String((e && (e.str || e.message)) || e || "").split("\n")[0].slice(0, 160);
        note.textContent = (window.JF_DIAGRAM_FAILED || "Couldn't draw this diagram") + (why ? " — " + why : "");
        d.appendChild(note);
      }
      // 描けなかったときに mermaid が残す要素を片付ける
      const stray = document.getElementById("d" + id);
      if (stray) stray.remove();
      if (stick) scrollToBottom();
    }
  }

  function build(item) {
    const el = div("item " + item.kind);
    if (item.caption) {
      const c = div("caption");
      c.textContent = item.caption;
      if (item.captionStyle) c.classList.add(item.captionStyle);
      if (item.captionColor) c.style.color = item.captionColor;
      el.appendChild(c);
    }
    const body = div("body");
    if (item.kind === "assistant") {
      body.classList.add("md");
      body.innerHTML = sanitize(JFRender.markdown(item.text));
      addCopyButtons(body);
    } else {
      body.textContent = item.text || "";
    }
    if (item.kind !== "tool" || item.text) el.appendChild(body);
    (item.notes || []).forEach((n) => { const d = div("notes"); d.textContent = n; el.appendChild(d); });
    (item.media || []).forEach((m) => el.appendChild(mediaEl(m)));
    if (item.kind === "assistant") renderDiagrams(body);
    return el;
  }

  function scrollToBottom() { window.scrollTo(0, document.documentElement.scrollHeight); }
  function nearBottom() { return window.innerHeight + window.scrollY >= document.documentElement.scrollHeight - 40; }
  window.addEventListener("scroll", () => { stick = nearBottom(); }, { passive: true });
  // 数式のフォント・図・画像の読み込みや窓の大きさの変化で高さが変わっても、一番下を見ていたなら一番下のままに
  if (typeof ResizeObserver !== "undefined") new ResizeObserver(() => { if (stick) scrollToBottom(); }).observe(log);
  if (document.fonts && document.fonts.ready) document.fonts.ready.then(() => { if (stick) scrollToBottom(); });

  // リンク・サムネイル：アプリに知らせて、アプリが確かめてから開く
  document.addEventListener("click", (e) => {
    const t = e.target.closest("[data-href], a[href]");
    if (!t) return;
    e.preventDefault();
    const href = t.dataset.href || t.getAttribute("href");
    if (href && href !== "#") post({ type: "open", href });
  });

  window.JF = {
    update(p) {
      if (p.labels) {
        window.JF_COPY_LABEL = p.labels.copy; window.JF_COPIED_LABEL = p.labels.copied; window.JF_DIAGRAM_FAILED = p.labels.diagramFailed;
      }
      if (p.accent) document.documentElement.style.setProperty("--accent", p.accent);
      for (const [k, v] of Object.entries(p.images || {})) if (/^data:image\/(png|jpeg);base64,/.test(v)) images.set(k, v);
      const follow = stick || nearBottom();
      const seen = new Set();
      let prev = null;
      for (const item of p.items || []) {
        seen.add(item.id);
        let el = nodes.get(item.id);
        if (!el) { el = build(item); nodes.set(item.id, el); }
        const want = prev ? prev.nextSibling : log.firstChild;
        if (el !== want) log.insertBefore(el, want);
        prev = el;
      }
      for (const [id, el] of nodes) if (!seen.has(id)) { el.remove(); nodes.delete(id); }
      if (!(p.items || []).length) {
        if (!emptyEl) { emptyEl = div("empty"); log.appendChild(emptyEl); }
        emptyEl.textContent = p.empty || "";
      } else if (emptyEl) { emptyEl.remove(); emptyEl = null; }
      if (follow || p.scrollToEnd) { scrollToBottom(); stick = true; }
    },
  };
  post({ type: "ready" });
})();
