// Term tooltips (_includes/term.html). CSS shows a definition on hover and keyboard focus; this adds
// tap-to-toggle for touch screens, Escape to dismiss, and keeps the tip inside the viewport.
(function () {
  var GUTTER = 16;
  function place(term) {
    var tip = term.querySelector('.term-tip');
    if (!tip) return;
    term.style.setProperty('--term-shift', '0px');
    term.classList.remove('term-below');
    var r = tip.getBoundingClientRect();
    var shift = 0;
    if (r.left < GUTTER) shift = GUTTER - r.left;
    else if (r.right > window.innerWidth - GUTTER) shift = window.innerWidth - GUTTER - r.right;
    term.style.setProperty('--term-shift', shift + 'px');
    if (r.top < GUTTER) term.classList.add('term-below');
  }
  function close(term) {
    term.classList.remove('is-open');
    var b = term.querySelector('.term-trigger');
    if (b) b.setAttribute('aria-expanded', 'false');
  }
  function closeAll(except) {
    document.querySelectorAll('.term.is-open').forEach(function (t) { if (t !== except) close(t); });
  }
  document.addEventListener('mouseover', function (e) {
    var term = e.target.closest && e.target.closest('.term');
    if (term) place(term);
  });
  document.addEventListener('focusin', function (e) {
    var term = e.target.closest && e.target.closest('.term');
    if (term) place(term);
  });
  document.addEventListener('click', function (e) {
    var trigger = e.target.closest && e.target.closest('.term-trigger');
    if (!trigger) { closeAll(null); return; }
    var term = trigger.parentNode;
    var open = !term.classList.contains('is-open');
    closeAll(term);
    term.classList.toggle('is-open', open);
    trigger.setAttribute('aria-expanded', String(open));
    if (open) place(term);
  });
  document.addEventListener('keydown', function (e) {
    if (e.key !== 'Escape') return;
    var any = document.querySelector('.term.is-open, .term:focus-within');
    closeAll(null);
    if (any) { any.classList.add('is-dismissed'); }
  });
  document.addEventListener('focusout', function (e) {
    var term = e.target.closest && e.target.closest('.term');
    if (term && !term.contains(e.relatedTarget)) { close(term); term.classList.remove('is-dismissed'); }
  });
  document.addEventListener('mouseout', function (e) {
    var term = e.target.closest && e.target.closest('.term');
    if (term && !term.contains(e.relatedTarget)) term.classList.remove('is-dismissed');
  });
})();
