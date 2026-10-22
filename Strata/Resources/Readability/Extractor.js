// Strata's page text extractor. Injected after Readability.js into every page a fetch view loads; the app calls
// `strataExtract(maxCharacters)` and gets back a JSON string: { title, text, readable, method }.
//
// Flow:
//   0. A site rule (SITES below), when the page's host has one and it finds the article.
//   1. Readability picks the article.
//   2. If it picked only a small part of the page's own prose (sites built from anonymous <div>s, like namu.wiki,
//      can lead it to a footnote block), the page's own text is used instead, without navigation, headers,
//      footers and sidebars, keeping headings and collapsed sections.
//   3. If Readability finds nothing, the same page text is used.
(function () {
  "use strict";

  // Readability's text is kept when it is at least this share of the page's non-link text...
  var MIN_SHARE = 0.3;
  // ...and the check only applies to pages with at least this much non-link text.
  var MIN_PAGE_CHARS = 3000;

  // Page chrome left out of the fallback text.
  var CHROME = "nav, header, footer, aside, [role=navigation], [role=banner], [role=contentinfo], [role=complementary]";

  function squeeze(t) {
    return (t || "").replace(/[ \t ]+/g, " ").replace(/\n[ \t]+/g, "\n").replace(/\n{3,}/g, "\n\n").trim();
  }

  // Text in links: menus, related-article lists and tag clouds are mostly links; prose is mostly not.
  function linkChars(root) {
    var n = 0;
    var links = root.querySelectorAll("a");
    for (var i = 0; i < links.length; i++) n += (links[i].textContent || "").length;
    return n;
  }

  var SKIP = { SCRIPT: 1, STYLE: 1, NOSCRIPT: 1, TEMPLATE: 1, SVG: 1, CANVAS: 1, IFRAME: 1, BUTTON: 1, SELECT: 1, INPUT: 1, TEXTAREA: 1 };
  var BLOCK = { P: 1, DIV: 1, SECTION: 1, ARTICLE: 1, MAIN: 1, UL: 1, OL: 1, LI: 1, DL: 1, DT: 1, DD: 1, TABLE: 1, TR: 1,
                BLOCKQUOTE: 1, PRE: 1, FIGURE: 1, FIGCAPTION: 1, DETAILS: 1, SUMMARY: 1, HR: 1, BR: 1 };

  // Text of a (copied) subtree: block elements become line breaks, headings become Markdown headings and tables
  // become Markdown tables. Built from the tree rather than `innerText`, so collapsed sections are kept
  // (namu.wiki folds most of an article on mobile). `inline` is for a table cell: everything on one line, and a
  // table inside it as "a · b; c · d", since a Markdown cell can't hold a table.
  function textOf(root, cleanHeading, inline) {
    var out = [];
    (function walk(node) {
      for (var c = node.firstChild; c; c = c.nextSibling) {
        if (c.nodeType === 3) { out.push(c.nodeValue.replace(/\s+/g, " ")); continue; }
        if (c.nodeType !== 1) continue;
        var tag = c.tagName.toUpperCase();
        if (SKIP[tag]) continue;
        var heading = /^H([1-6])$/.exec(tag);
        if (heading && !inline) {
          var h = (c.textContent || "").replace(/\s+/g, " ").trim();
          if (cleanHeading) h = cleanHeading(h);
          if (h) out.push("\n\n" + "######".slice(0, +heading[1]) + " " + h + "\n\n");
          continue;
        }
        if (tag === "TABLE") {
          var grid = tableGrid(c, cleanHeading);
          out.push(inline ? " " + grid.map(function (r) { return r.filter(function (x) { return x; }).join(" · "); }).join("; ") + " "
                          : "\n\n" + markdownTable(grid) + "\n\n");
          continue;
        }
        var block = BLOCK[tag];
        if (block) out.push(inline ? " " : "\n");
        walk(c);
        if (block) out.push(inline ? " " : "\n");
      }
    })(root);
    if (inline) return out.join("").replace(/\s+/g, " ").trim();
    return squeeze(out.join("").replace(/ *\n */g, "\n"));
  }

  // A table's cells as rows of text, with merged cells spread out so every column lines up: a cell spanning rows
  // repeats its text below (the value still applies there), one spanning columns leaves the extra columns empty.
  function tableGrid(table, cleanHeading) {
    var grid = [], below = [];
    var rows = table.rows || [];
    for (var r = 0; r < rows.length; r++) {
      var line = [], col = 0;
      var carry = function () {
        while (below[col] && below[col].left > 0) { line[col] = below[col].text; below[col].left--; col++; }
      };
      var cells = rows[r].cells || [];
      for (var i = 0; i < cells.length; i++) {
        carry();
        var text = textOf(cells[i], cleanHeading, true).replace(/\|/g, "\\|");
        var across = Math.min(Math.max(cells[i].colSpan || 1, 1), 50);
        var down = Math.min(Math.max(cells[i].rowSpan || 1, 1), 200);
        for (var k = 0; k < across; k++, col++) {
          line[col] = k === 0 ? text : "";
          if (down > 1) below[col] = { text: line[col], left: down - 1 };
        }
      }
      carry();
      for (var j = 0; j < line.length; j++) if (line[j] === undefined) line[j] = "";
      if (line.some(function (x) { return x; })) grid.push(line);
    }
    return grid;
  }

  // A grid as a Markdown table, its first row as the header. A table with one column or one row is layout (a
  // boxed note, an image with a caption), so it stays plain text.
  function markdownTable(grid) {
    var width = 0;
    for (var i = 0; i < grid.length; i++) width = Math.max(width, grid[i].length);
    if (width < 2 || grid.length < 2) {
      return grid.map(function (r) { return r.filter(function (x) { return x; }).join(" · "); }).join("\n");
    }
    var row = function (r) {
      var cells = [];
      for (var k = 0; k < width; k++) cells.push(r[k] || "");
      return "| " + cells.join(" | ") + " |";
    };
    var lines = [row(grid[0]), row(new Array(width).fill("---"))];
    for (var j = 1; j < grid.length; j++) lines.push(row(grid[j]));
    return lines.join("\n");
  }

  // The body's text without page chrome (nav, header, footer, sidebars), from a copy of the DOM.
  function pageText() {
    if (!document.body) return "";
    var root = document.body.cloneNode(true);
    var total = (root.textContent || "").length;
    var chrome = root.querySelectorAll(CHROME);
    for (var i = 0; i < chrome.length; i++) {
      // Keep a header or footer that wraps most of the page: some sites put the whole layout inside one.
      if ((chrome[i].textContent || "").length > total * 0.5) continue;
      if (chrome[i].parentNode) chrome[i].parentNode.removeChild(chrome[i]);
    }
    return textOf(root);
  }

  function clean(el) { return el ? (el.textContent || "").replace(/\s+/g, " ").trim() : ""; }

  // Site rules, tried before the generic flow. `extract` returns { title, text } or null to fall back to the generic
  // flow. A rule should read only the article, as the site lays it out; the hosts are matched on the page's own
  // location (after redirects).
  var SITES = [
    {
      // Class names are generated and change between builds, so the article is found by its shape: the nearest
      // ancestor of the first section heading that holds most of the sections.
      name: "namu.wiki",
      match: /(^|\.)namu\.wiki$/,
      extract: function () {
        var first = document.querySelector("h2");
        if (!first) return null;
        var body = first;
        while (body.parentElement && body !== document.body && !(body.children.length >= 8 && (body.textContent || "").length > 1000)) {
          body = body.parentElement;
        }
        if (!body || body === document.body) return null;
        var title = clean(document.querySelector("h1")) || document.title;
        var text = textOf(body.cloneNode(true), function (h) { return h.replace(/\[편집\]$/, "").trim(); });
        return { title: title, text: "# " + title + "\n\n" + text };
      }
    },
    {
      name: "naver-news",
      match: /^(n\.news|m\.news|news|m\.sports|sports|m\.entertain|entertain)\.naver\.com$/,
      extract: function () {
        var body = document.querySelector("#dic_area, #newsct_article, #comp_news_article ._article_content, .news_end");
        if (!body) return null;
        var title = clean(document.querySelector("#title_area, .media_end_head_headline, .news_headline .title")) || document.title;
        var press = clean(document.querySelector(".media_end_head_top_logo img[alt]")) ||
                    ((document.querySelector(".media_end_head_top_logo img[alt]") || {}).alt || "");
        var stamp = document.querySelector(".media_end_head_info_datestamp_time, ._ARTICLE_DATE_TIME");
        var date = stamp ? (stamp.getAttribute("data-date-time") || clean(stamp)) : "";
        var meta = [press, date].filter(function (x) { return x; }).join(" · ");
        return { title: title, text: "# " + title + "\n\n" + (meta ? meta + "\n\n" : "") + textOf(body.cloneNode(true)) };
      }
    }
  ];

  function siteRule() {
    var host = (location.hostname || "").toLowerCase();
    for (var i = 0; i < SITES.length; i++) if (SITES[i].match.test(host)) return SITES[i];
    return null;
  }

  window.strataExtract = function (maxCharacters) {
    var cap = maxCharacters > 0 ? maxCharacters : 400000;
    var rule = siteRule();
    if (rule) {
      var site = null;
      try { site = rule.extract(); } catch (e) {}
      if (site && site.text && site.text.length > 200) {
        var t = site.text.length > cap ? site.text.slice(0, cap) : site.text;
        return JSON.stringify({ title: (site.title || document.title || "").slice(0, 300), text: t, readable: true, method: "site:" + rule.name });
      }
    }
    var title = document.title || "";
    var article = null;
    try {
      if (typeof Readability === "function") article = new Readability(document.cloneNode(true)).parse();
    } catch (e) {}
    // The article's own markup, so its headings and tables keep their shape. Parsed into a separate, inert document:
    // nothing in it loads or runs.
    var readerText = "";
    if (article && article.content) {
      try { readerText = textOf(new DOMParser().parseFromString(article.content, "text/html").body); } catch (e) {}
    }
    if (!readerText && article && article.textContent) readerText = squeeze(article.textContent);
    if (article && article.title) title = article.title;

    var text, method;
    if (readerText.length > 0) {
      var page = document.body ? (document.body.textContent || "").length - linkChars(document.body) : 0;
      if (page >= MIN_PAGE_CHARS && readerText.length < page * MIN_SHARE) {
        text = pageText();
        method = "page";
        // The fallback only helps when it actually holds more.
        if (text.length <= readerText.length) { text = readerText; method = "readability"; }
      } else {
        text = readerText;
        method = "readability";
      }
    } else {
      text = pageText();
      method = "page";
    }
    if (text.length > cap) text = text.slice(0, cap);
    return JSON.stringify({ title: String(title || "").slice(0, 300), text: text, readable: method === "readability", method: method });
  };
})();
