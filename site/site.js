// Theme toggle. The page works without this file.
(function () {
  var d = document, r = d.documentElement, b = d.getElementById('theme'), K = 'shrike-theme';
  function apply(t) {
    r.dataset.theme = t;
    b.setAttribute('aria-pressed', t === 'dark');
  }
  function isDark() {
    return r.dataset.theme ? r.dataset.theme === 'dark' : matchMedia('(prefers-color-scheme: dark)').matches;
  }
  if (b) {
    try { var s = localStorage.getItem(K); if (s === 'dark' || s === 'light') apply(s); } catch { /* no storage */ }
    if (!r.dataset.theme) b.setAttribute('aria-pressed', isDark());
    b.hidden = false;
    b.addEventListener('click', function () {
      var t = isDark() ? 'light' : 'dark';
      apply(t);
      try { localStorage.setItem(K, t); } catch { /* no storage */ }
    });
  }
})();

// Screenshot viewer: opens every .zoom link in a large dialog. Without JS the link opens the image.
(function () {
  var d = document, links = [].slice.call(d.querySelectorAll('a.zoom'));
  if (!links.length || !d.createElement('dialog').showModal) return;
  var dlg = d.createElement('dialog'), cur = 0, from = null, x0 = null;
  dlg.className = 'viewer';
  dlg.setAttribute('aria-label', 'Screenshot viewer');
  dlg.innerHTML =
    '<div class="v-top"><span class="v-count" aria-live="polite"></span>' +
    '<button type="button" class="v-btn v-close" aria-label="Close"><svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M6 6l12 12M18 6L6 18"/></svg></button></div>' +
    '<figure class="v-fig"><img alt=""><figcaption></figcaption></figure>' +
    '<button type="button" class="v-btn v-prev" aria-label="Previous screenshot"><svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M15 5l-7 7 7 7"/></svg></button>' +
    '<button type="button" class="v-btn v-next" aria-label="Next screenshot"><svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M9 5l7 7-7 7"/></svg></button>';
  d.body.appendChild(dlg);
  var img = dlg.querySelector('img'), cap = dlg.querySelector('figcaption'), cnt = dlg.querySelector('.v-count');
  function info(a) {
    var t = a.querySelector('img'), card = a.closest('.card'), h = card && card.querySelector('h3');
    // The link target is the full-size WebP of the thumbnail.
    var s = a.getAttribute('href');
    return { src: s, alt: t.alt, cap: h ? h.textContent : t.alt };
  }
  function show(i) {
    cur = (i + links.length) % links.length;
    var o = info(links[cur]);
    img.src = o.src; img.alt = o.alt; cap.textContent = o.cap;
    cnt.textContent = (cur + 1) + ' / ' + links.length;
    [cur - 1, cur + 1].forEach(function (n) { new Image().src = info(links[(n + links.length) % links.length]).src; });
  }
  function open(i) {
    from = d.activeElement;
    show(i);
    d.documentElement.classList.add('viewing');
    dlg.showModal();
  }
  links.forEach(function (a, i) {
    a.addEventListener('click', function (e) { e.preventDefault(); open(i); });
  });
  dlg.addEventListener('close', function () {
    d.documentElement.classList.remove('viewing');
    img.removeAttribute('src');
    if (from && from.focus) from.focus();
  });
  dlg.addEventListener('click', function (e) {
    var t = e.target;
    if (t.closest('.v-close') || t === dlg || t.classList.contains('v-fig')) dlg.close();
    else if (t.closest('.v-prev')) show(cur - 1);
    else if (t.closest('.v-next')) show(cur + 1);
  });
  dlg.addEventListener('keydown', function (e) {
    if (e.key === 'ArrowLeft') { show(cur - 1); e.preventDefault(); }
    else if (e.key === 'ArrowRight') { show(cur + 1); e.preventDefault(); }
    else if (e.key === 'Tab') {
      var f = [].slice.call(dlg.querySelectorAll('button')), n = f.indexOf(d.activeElement);
      var j = e.shiftKey ? n - 1 : n + 1;
      if (n < 0 || j < 0 || j >= f.length) { f[(j + f.length) % f.length || 0].focus(); e.preventDefault(); }
    }
  });
  dlg.addEventListener('touchstart', function (e) {
    var z = window.visualViewport && window.visualViewport.scale > 1.05;
    x0 = e.touches.length === 1 && !z ? e.touches[0].clientX : null;
  }, { passive: true });
  dlg.addEventListener('touchend', function (e) {
    if (x0 === null) return;
    var dx = e.changedTouches[0].clientX - x0;
    x0 = null;
    if (Math.abs(dx) > 50) show(cur + (dx < 0 ? 1 : -1));
  });
})();
