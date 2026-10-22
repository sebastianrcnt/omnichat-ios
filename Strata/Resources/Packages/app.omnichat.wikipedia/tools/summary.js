// wikipedia_summary: the lead of a Wikipedia article and its infobox, from the article page (desktop or mobile layout).
window.strataPlugin = async function (args) {
  var root = document.querySelector("#mw-content-text .mw-parser-output") || document.querySelector("#mw-content-text");
  if (!root || document.querySelector(".noarticletext, #noarticletext")) {
    throw new Error("Wikipedia has no article with this title. Check the spelling, or search for the right title first.");
  }
  function text(el) {
    var copy = el.cloneNode(true);
    copy.querySelectorAll("sup.reference, .mw-ref, .reference, style, script, .mw-editsection, .noprint, .bday, [style*='display:none']")
      .forEach(function (n) { n.remove(); });
    // Line breaks and list items would otherwise run words together.
    copy.querySelectorAll("br, li, div, p, dd, dt").forEach(function (n) { n.after(" "); });
    return (copy.textContent || "").replace(/\[\d+\]/g, "").replace(/\s+/g, " ").trim();
  }
  var want = Math.min(10, Math.max(1, parseInt(args.paragraphs, 10) || 3));

  // Lead paragraphs: those before the first section heading.
  var lead = [];
  var nodes = root.querySelectorAll("p, h2");
  for (var i = 0; i < nodes.length && lead.length < want; i++) {
    var n = nodes[i];
    if (n.tagName === "H2") { if (lead.length) break; else continue; }
    if (n.closest("table, .infobox, .hatnote, .mw-empty-elt")) continue;
    var t = text(n);
    if (t.length > 1) lead.push(t);
  }

  var infobox = [];
  var box = root.querySelector("table.infobox");
  if (box) {
    box.querySelectorAll("tr").forEach(function (row) {
      var th = row.querySelector("th"), td = row.querySelector("td");
      if (!th || !td || infobox.length >= 40) return;
      var label = text(th), value = text(td);
      if (label && value) infobox.push({ label: label, value: value.slice(0, 300) });
    });
  }

  var heading = document.querySelector("#firstHeading, .mw-first-heading, h1");
  var result = {
    title: heading ? text(heading) : document.title,
    url: location.href,
    disambiguation: !!document.querySelector("#disambigbox, .disambigbox, .dmbox-disambig"),
    lead: lead,
    infobox: infobox
  };
  // A disambiguation page: the articles it lists, so the next call can pick one.
  if (result.disambiguation) {
    result.options = Array.prototype.filter.call(root.querySelectorAll("li"), function (li) { return !li.closest("#toc, .toc, .navbox"); })
      .slice(0, 25).map(text).filter(function (t) { return t; });
  }
  return result;
};
