/* @ds-bundle: {"format":4,"namespace":"Garage","components":[{"name":"Button"},{"name":"Badge"},{"name":"Card"},{"name":"Callout"},{"name":"SearchField"},{"name":"Wordmark"},{"name":"Term"}]} */
(function () {
  var h = window.React.createElement;
  function cx() { return Array.prototype.filter.call(arguments, Boolean).join(" "); }
  function omit(p, keys) { var o = {}; for (var k in p) if (keys.indexOf(k) < 0) o[k] = p[k]; return o; }

  function Button(p) {
    var variant = p.variant || "secondary", size = p.size || "default";
    var rest = omit(p, ["variant", "size", "className", "children", "href", "icon"]);
    var kids = [p.icon ? h("span", { key: "i", className: "g-btn-icon", "aria-hidden": "true" }, p.icon) : null, h("span", { key: "l" }, p.children)];
    var cls = cx("g-btn", "g-btn-" + variant, size === "large" && "g-btn-large", p.className);
    if (p.href) return h("a", Object.assign({ href: p.href, className: cls }, rest), kids);
    return h("button", Object.assign({ type: "button", className: cls }, rest), kids);
  }

  function Badge(p) {
    var tone = p.tone || "neutral";
    var dot = /^corpus-/.test(tone) ? h("span", { className: "g-badge-dot", "aria-hidden": "true" }) : null;
    return h("span", { className: cx("g-badge", "g-badge-" + tone, p.className) }, dot, p.children);
  }

  function Card(p) {
    var Tag = p.href ? "a" : "div";
    return h(Tag, { href: p.href, className: cx("g-card", p.href && "g-card-link", p.selected && "g-card-selected", p.className) },
      p.badge ? h("div", { className: "g-card-badge" }, p.badge) : null,
      p.title ? h("h3", { className: "g-card-title" }, p.title) : null,
      p.children ? h("div", { className: "g-card-body" }, p.children) : null,
      p.footer ? h("div", { className: "g-card-footer" }, p.footer) : null);
  }

  var CALLOUT_WORD = { info: "Note", success: "Done", warning: "Heads up", danger: "Careful" };
  function Callout(p) {
    var tone = p.tone || "info";
    return h("div", { className: cx("g-callout", "g-callout-" + tone, p.className), role: tone === "danger" ? "alert" : "note" },
      h("div", { className: "g-callout-title" }, p.title || CALLOUT_WORD[tone]),
      h("div", { className: "g-callout-body" }, p.children));
  }

  function SearchField(p) {
    var rest = omit(p, ["className", "label"]);
    return h("label", { className: cx("g-search", p.className) },
      h("span", { className: "g-visually-hidden" }, p.label || "Search"),
      h("svg", { className: "g-search-icon", viewBox: "0 0 16 16", width: 16, height: 16, "aria-hidden": "true" },
        h("circle", { cx: 7, cy: 7, r: 5, fill: "none", stroke: "currentColor", strokeWidth: 1.6 }),
        h("path", { d: "M11 11l3.5 3.5", stroke: "currentColor", strokeWidth: 1.6, strokeLinecap: "round" })),
      h("input", Object.assign({ type: "search", className: "g-search-input", placeholder: "Search your corpus" }, rest)));
  }

  function Wordmark(p) {
    var size = p.size || 32, ent = p.edition === "enterprise";
    return h("span", { className: cx("g-wordmark", ent && "g-wordmark-enterprise", p.className), style: { "--g-mark": size + "px" } },
      p.iconSrc ? h("img", { className: "g-wordmark-icon", src: p.iconSrc, width: size, height: size, alt: "" }) : null,
      h("span", { className: "g-wordmark-name" }, "Garage"),
      ent ? h("span", { className: "g-wordmark-edition" }, "Enterprise") : null);
  }

  var termCount = 0;
  function Term(p) {
    var ref = window.React.useRef(null);
    var idRef = window.React.useRef(null);
    if (idRef.current === null) idRef.current = "g-term-tip-" + (++termCount);
    var st = window.React.useState(false), open = st[0], setOpen = st[1];
    var sh = window.React.useState(0), shift = sh[0], setShift = sh[1];
    var bl = window.React.useState(false), below = bl[0], setBelow = bl[1];
    function place() {
      var tip = ref.current && ref.current.querySelector(".g-term-tip");
      if (!tip) return;
      var r = tip.getBoundingClientRect(), w = window.innerWidth, s = 0;
      if (r.left - shift < 16) s = 16 - (r.left - shift); else if (r.right - shift > w - 16) s = w - 16 - (r.right - shift);
      setShift(s); setBelow(r.top < 16);
    }
    window.React.useEffect(function () {
      if (!open) return;
      function away(e) { if (ref.current && !ref.current.contains(e.target)) setOpen(false); }
      function esc(e) { if (e.key === "Escape") setOpen(false); }
      document.addEventListener("click", away); document.addEventListener("keydown", esc);
      return function () { document.removeEventListener("click", away); document.removeEventListener("keydown", esc); };
    }, [open]);
    return h("span", { ref: ref, className: cx("g-term", open && "is-open", below && "g-term-below", p.className), style: { "--g-term-shift": shift + "px" }, onMouseEnter: place, onFocus: place },
      h("button", { type: "button", className: "g-term-trigger", "aria-describedby": idRef.current, "aria-expanded": String(open), onClick: function () { setOpen(!open); place(); } }, p.children),
      h("span", { className: "g-term-tip", role: "tooltip", id: idRef.current },
        h("span", { className: "g-term-tip-name" }, p.term), " ", p.definition));
  }

  window.Garage = Object.assign(window.Garage || {}, { Button: Button, Badge: Badge, Card: Card, Callout: Callout, SearchField: SearchField, Wordmark: Wordmark, Term: Term });
})();
