// Builds site/changelog.html from CHANGELOG.md (the single source).
//
//   node Scripts/make-changelog-page.mjs           write site/changelog.html
//   node Scripts/make-changelog-page.mjs --check   exit 1 when the committed page is out of date (used by CI)
//
//   node Scripts/make-changelog-page.mjs --section 0.2.2   print the entry that holds that version (release notes)
//
// CHANGELOG.md format:  "## <label> - <YYYY-MM-DD>", then "### New | Faster | Changed | Fixed" groups
// (in that order), then "- " bullets. Only `code` is allowed inside a bullet; everything else is escaped.
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const srcFile = join(root, 'CHANGELOG.md');
const outFile = join(root, 'site', 'changelog.html');
const GROUPS = ['New', 'Faster', 'Changed', 'Fixed'];
const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];

const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const inline = (s) => esc(s).replace(/`([^`]+)`/g, '<code>$1</code>');
const slug = (s) => s.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
/** "2026-10-11" -> "11 October 2026". Done by hand so the result never depends on the machine's locale. */
function longDate(iso) {
  const [y, m, d] = iso.split('-').map(Number);
  return `${d} ${MONTHS[m - 1]} ${y}`;
}

function parse(md) {
  const entries = [];
  let entry = null;
  let group = null;
  md.replace(/\r\n/g, '\n').split('\n').forEach((line, i) => {
    const fail = (msg) => {
      throw new Error(`CHANGELOG.md line ${i + 1}: ${msg}`);
    };
    if (!line.trim() || line.startsWith('# ')) return;
    let m;
    if ((m = /^## (.+) - (\d{4}-\d{2}-\d{2})$/.exec(line))) {
      entry = { label: m[1], date: m[2], groups: [] };
      group = null;
      entries.push(entry);
    } else if ((m = /^### (.+)$/.exec(line))) {
      if (!entry) fail('a group needs a version heading before it');
      if (!GROUPS.includes(m[1])) fail(`unknown group "${m[1]}" (use ${GROUPS.join(', ')})`);
      if (entry.groups.length && GROUPS.indexOf(entry.groups.at(-1).name) >= GROUPS.indexOf(m[1])) fail('groups must be in the order New, Faster, Changed, Fixed');
      group = { name: m[1], items: [] };
      entry.groups.push(group);
    } else if ((m = /^- (.+)$/.exec(line))) {
      if (!group) fail('a bullet needs a group before it');
      group.items.push(m[1]);
    } else fail(`cannot read "${line}"`);
  });
  if (!entries.length) throw new Error('CHANGELOG.md has no versions');
  return entries;
}

const GH =
  '<svg class="fill" viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M12 .5C5.65.5.5 5.65.5 12c0 5.08 3.29 9.39 7.86 10.91.58.1.79-.25.79-.56v-2c-3.2.7-3.87-1.37-3.87-1.37-.52-1.33-1.28-1.69-1.28-1.69-1.04-.71.08-.7.08-.7 1.15.08 1.76 1.18 1.76 1.18 1.03 1.76 2.69 1.25 3.35.96.1-.74.4-1.25.73-1.54-2.55-.29-5.24-1.28-5.24-5.69 0-1.26.45-2.28 1.18-3.09-.12-.29-.51-1.46.11-3.05 0 0 .97-.31 3.17 1.18a11 11 0 0 1 5.77 0c2.2-1.49 3.17-1.18 3.17-1.18.63 1.59.23 2.76.11 3.05.74.81 1.18 1.83 1.18 3.09 0 4.42-2.69 5.39-5.25 5.68.41.36.78 1.06.78 2.14v3.17c0 .31.21.67.8.56A11.5 11.5 0 0 0 23.5 12C23.5 5.65 18.35.5 12 .5z"/></svg>';

function page(entries) {
  const arts = entries
    .map((e, n) => {
      const id = `v-${slug(e.label)}`;
      const groups = e.groups
        .map(
          (g) =>
            `    <section class="rel-group" aria-labelledby="${id}-${slug(g.name)}"><h3 id="${id}-${slug(g.name)}" class="${slug(g.name)}">${g.name}</h3><ul>${g.items.map((t) => `<li>${inline(t)}</li>`).join('')}</ul></section>`,
        )
        .join('\n');
      return `<article class="release" id="${id}" aria-labelledby="${id}-h">
  <header class="rel-head">
    <h2 id="${id}-h">${esc(e.label)}</h2>
    <p><time datetime="${e.date}">${longDate(e.date)}</time>${n === 0 ? ' <span class="chip">Latest</span>' : ''}</p>
  </header>
  <div class="rel-body">
${groups}
  </div>
</article>`;
    })
    .join('\n');
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src 'self' data:; style-src 'self'; script-src 'self'; base-uri 'none'; form-action 'none'">
<title>Shrike changelog: what changed in each version</title>
<meta name="description" content="What is new in each version of Shrike, the free image viewer for Mac. Newest version first.">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<meta name="theme-color" content="#F3F3F3" media="(prefers-color-scheme: light)">
<meta name="theme-color" content="#202020" media="(prefers-color-scheme: dark)">
<link rel="canonical" href="https://voydapps.github.io/shrike/changelog.html">
<link rel="icon" href="favicon.svg" type="image/svg+xml">
<link rel="icon" href="favicon.ico" sizes="48x48">
<link rel="apple-touch-icon" href="apple-touch-icon.png">
<meta property="og:type" content="website">
<meta property="og:site_name" content="Shrike">
<meta property="og:title" content="Shrike changelog: what changed in each version">
<meta property="og:description" content="What is new in each version of Shrike, the free image viewer for Mac. Newest version first.">
<meta property="og:url" content="https://voydapps.github.io/shrike/changelog.html">
<meta property="og:image" content="https://voydapps.github.io/shrike/og.png">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:image:alt" content="Shrike app icon and the words: a fast image viewer for Mac">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="Shrike changelog: what changed in each version">
<meta name="twitter:description" content="What is new in each version of Shrike, the free image viewer for Mac. Newest version first.">
<meta name="twitter:image" content="https://voydapps.github.io/shrike/og.png">
<meta name="twitter:image:alt" content="Shrike app icon and the words: a fast image viewer for Mac">
<link rel="stylesheet" href="style.css">
<script src="site.js" defer></script>
</head>
<body>
<!-- Generated from CHANGELOG.md by Scripts/make-changelog-page.mjs. Do not edit by hand. -->
<a class="skip" href="#main">Skip to main content</a>

<header class="site-header">
  <div class="wrap">
    <a class="brand" href="./"><img src="favicon.svg" alt="" width="28" height="28">Shrike</a>
    <nav class="nav" aria-label="Main">
      <a class="text" href="./#features">Features</a>
      <a class="text" href="./#install">Install</a>
      <a class="text" href="./#faq">FAQ</a>
      <a class="text" href="changelog.html" aria-current="page">Changelog</a>
      <a class="text" href="https://github.com/voydapps/shrike">GitHub</a>
      <button class="icon-btn" id="theme" type="button" aria-pressed="false" aria-label="Dark theme" hidden>
        <svg class="sun" viewBox="0 0 24 24" aria-hidden="true" focusable="false"><circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/></svg>
        <svg class="moon" viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M20 14.5A8 8 0 0 1 9.5 4a8 8 0 1 0 10.5 10.5z"/></svg>
      </button>
      <a class="icon-btn" href="https://github.com/voydapps/shrike" aria-label="Shrike on GitHub">
        ${GH}
      </a>
    </nav>
  </div>
</header>

<main id="main">
<section aria-labelledby="h-changelog">
  <div class="wrap narrow">
    <a class="back" href="./">Back to the home page</a>
    <h1 id="h-changelog">Changelog</h1>
    <p class="intro">What changed in each version of Shrike. Newest first. For downloads, see the <a href="https://github.com/voydapps/shrike/releases">releases page</a>.</p>
${arts}
  </div>
</section>
</main>

<footer class="site-footer">
  <div class="wrap">
    <div class="fcols">
      <div>
        <a class="brand" href="./"><img src="favicon.svg" alt="" width="24" height="24">Shrike</a>
        <p>Fast, free image viewer for Mac.</p>
      </div>
      <nav aria-label="Project">
        <h2>Project</h2>
        <ul>
          <li><a href="https://github.com/voydapps/shrike">GitHub repository</a></li>
          <li><a href="https://github.com/voydapps/shrike/releases">Releases</a></li>
          <li><a href="changelog.html">Changelog</a></li>
          <li><a href="https://github.com/voydapps/shrike/issues">Report a problem</a></li>
          <li><a href="https://github.com/voydapps/shrike/blob/main/LICENSE">Source code license (MIT)</a></li>
        </ul>
      </nav>
      <nav aria-label="Get started">
        <h2>Get started</h2>
        <ul>
          <li><a href="https://github.com/voydapps/shrike/releases/latest/download/Shrike.dmg">Download for Mac</a></li>
          <li><a href="./#install">How to install</a></li>
          <li><a href="./#faq">FAQ</a></li>
        </ul>
      </nav>
    </div>
    <p class="small legal">MIT License. &copy; 2026 voyd. Made by voyd. Mac and macOS are trademarks of Apple Inc. Shrike is not affiliated with Apple.</p>
  </div>
</footer>

</body>
</html>
`;
}

/** "0.2" becomes [0,2,0]. Used to find the entry whose label ("0.2.0 to 0.2.5" or "0.1") holds a version. */
const nums = (v) => {
  const p = v.split('.').map(Number);
  while (p.length < 3) p.push(0);
  return p;
};
const cmp = (a, b) => a[0] - b[0] || a[1] - b[1] || a[2] - b[2];
function holds(label, version) {
  const [lo, hi = lo] = label.split(' to ');
  const v = nums(version);
  return cmp(nums(lo), v) <= 0 && cmp(v, nums(hi)) <= 0;
}

const sectionAt = process.argv.indexOf('--section');
if (sectionAt > 0) {
  // --section <version>: print the entry that holds this version as Markdown (for the GitHub release notes).
  const version = process.argv[sectionAt + 1] ?? '';
  const e = /^\d+(\.\d+){1,2}$/.test(version) ? parse(readFileSync(srcFile, 'utf8')).find((x) => holds(x.label, version)) : null;
  if (!e) {
    console.error(`CHANGELOG.md has no entry for version "${version}".`);
    process.exit(1);
  }
  console.log(e.groups.map((g) => `### ${g.name}\n${g.items.map((t) => `- ${t}`).join('\n')}`).join('\n\n'));
  process.exit(0);
}

const html = page(parse(readFileSync(srcFile, 'utf8')));
if (process.argv.includes('--check')) {
  let have = '';
  try {
    have = readFileSync(outFile, 'utf8').replace(/\r\n/g, '\n');
  } catch {
    /* a missing file counts as out of date */
  }
  if (have !== html) {
    console.error('site/changelog.html is out of date. Run:  node Scripts/make-changelog-page.mjs');
    process.exit(1);
  }
  console.log('site/changelog.html is up to date.');
} else {
  writeFileSync(outFile, html);
  console.log(`Wrote site/changelog.html (${(html.length / 1024).toFixed(1)} KB).`);
}
