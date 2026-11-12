"use strict";
// Markdown を HTML にする（表・数式・図・コードの色分け）。DOM を使わないので、アプリのテストでも JavaScriptCore で動かす。
// 出てきた HTML は chat.js で DOMPurify を通してから画面に入れる。
// - 生の HTML は文字として出す（エージェントの返答にタグが書いてあっても、そのまま見せるだけ）
// - リンクは http / https / mailto だけ。画像は読みに行かず、リンクにする（ネットに取りに行かない）
// - 数式：$…$・\(…\)（文中）、$$…$$・\[…\]（別の行）を KaTeX で。「$5 と $10」のような値段は数式にしない
// - 図・グラフ：```mermaid のコードブロック（フローチャート・シーケンス・円グラフ・xychart など）は chat.js で図にする
(function (root) {
  const esc = (s) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#39;");
  const safeHref = (h) => {
    const s = String(h || "").trim();
    return /^(https?:\/\/|mailto:)/i.test(s) ? s : null;
  };

  function tex(src, display) {
    if (typeof katex === "undefined") return '<code class="math-error">' + esc(src) + "</code>";
    try {
      return katex.renderToString(src, {
        displayMode: display, throwOnError: false, output: "htmlAndMathml",
        strict: "ignore", trust: false, maxSize: 30, maxExpand: 500,
      });
    } catch (e) {
      return '<code class="math-error">' + esc(src) + "</code>";
    }
  }

  const mathBlock = {
    name: "mathBlock", level: "block",
    start(src) { const i = src.search(/\$\$|\\\[/); return i < 0 ? undefined : i; },
    tokenizer(src) {
      const m = /^\$\$([\s\S]+?)\$\$[ \t]*(?:\n|$)/.exec(src) || /^\\\[([\s\S]+?)\\\][ \t]*(?:\n|$)/.exec(src);
      if (m) return { type: "mathBlock", raw: m[0], text: m[1].trim() };
    },
    renderer(t) { return '<div class="math-block">' + tex(t.text, true) + "</div>\n"; },
  };

  const mathInline = {
    name: "mathInline", level: "inline",
    start(src) { const i = src.search(/\$|\\\(/); return i < 0 ? undefined : i; },
    tokenizer(src) {
      let m = /^\$\$([\s\S]+?)\$\$/.exec(src);
      if (m) return { type: "mathInline", raw: m[0], text: m[1].trim(), display: true };
      m = /^\\\(([\s\S]+?)\\\)/.exec(src);
      if (m) return { type: "mathInline", raw: m[0], text: m[1].trim(), display: false };
      // 開く $ の直後と閉じる $ の直前は空白でない・閉じる $ の直後は数字でない（値段を数式にしない）
      m = /^\$(?![\s$])((?:\\.|[^\\$\n])+?)(?<![\s\\])\$(?![0-9])/.exec(src);
      if (m) return { type: "mathInline", raw: m[0], text: m[1], display: false };
    },
    renderer(t) { return t.display ? '<span class="math-block">' + tex(t.text, true) + "</span>" : tex(t.text, false); },
  };

  function langOf(lang) { return String(lang || "").trim().split(/\s+/)[0].toLowerCase(); }

  const renderer = {
    // 生の HTML は文字として
    html(token) { return esc(token.text || token.raw || ""); },
    code(token) {
      const text = token.text || "";
      const l = langOf(token.lang);
      if (l === "mermaid") {
        // 図の元の文はコードの中に置く（属性に入れると、「-->」を含む値を DOMPurify が消してしまう）
        return '<div class="diagram pending"><pre><code>' + esc(text) + "</code></pre></div>\n";
      }
      if (l === "math" || l === "latex" && /^\s*\\begin\{/.test(text)) {
        return '<div class="math-block">' + tex(text, true) + "</div>\n";
      }
      let body = esc(text);
      if (typeof hljs !== "undefined" && l && hljs.getLanguage(l)) {
        try { body = hljs.highlight(text, { language: l, ignoreIllegals: true }).value; } catch (e) { body = esc(text); }
      }
      return '<pre><code class="hljs' + (l ? " language-" + esc(l) : "") + '">' + body + "</code></pre>\n";
    },
    link(token) {
      const inner = this.parser.parseInline(token.tokens || []);
      const href = safeHref(token.href);
      if (!href) return inner;
      return '<a href="' + esc(href) + '"' + (token.title ? ' title="' + esc(token.title) + '"' : "") + ">" + inner + "</a>";
    },
    // 画像は読みに行かない（リンクにする。手元の画像・PDF のファイルは、アプリが文の下にサムネイルで出す）
    image(token) {
      const href = safeHref(token.href);
      const alt = esc(token.text || "");
      return href ? '<a href="' + esc(href) + '">🖼 ' + (alt || esc(href)) + "</a>" : alt;
    },
  };

  let md = null;
  function engine() {
    if (md) return md;
    md = new marked.Marked({ gfm: true, breaks: true, async: false });
    md.use({ extensions: [mathBlock, mathInline], renderer });
    return md;
  }

  function markdown(src) {
    let html = engine().parse(String(src || ""));
    // 横に長い表はその中だけ横にスクロールする
    html = html.replace(/<table>/g, '<div class="table-wrap"><table>').replace(/<\/table>/g, "</table></div>");
    return html;
  }

  root.JFRender = { markdown, escape: esc, safeHref };
})(typeof window !== "undefined" ? window : globalThis);
