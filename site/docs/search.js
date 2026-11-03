// Docs search: a hand-written index of pages and their headings, filtered in the page. ⌘K, Ctrl-K or / opens it.
// Add a page: one entry, in sidebar order. Add a heading: [text, id], where id is the heading's id on that page.
// k holds extra words a reader might type that are not in the title or headings.
const DOCS = [
  { s: "Start", t: "Overview", u: "/docs/", k: "install download dmg homebrew brew cask requirements macos 26 apple silicon intel updates",
    h: [["Install", "install"], ["Requirements", "requirements"], ["The command", "command"], ["The docs", "sections"], ["More", "more"]] },
  { s: "Start", t: "First steps", u: "/docs/first-steps/", k: "start open folder vault new note", h: [] },
  { s: "Guide", t: "Editing", u: "/docs/editing/", k: "live rendering source view vim focus typewriter", h: [] },
  { s: "Guide", t: "Markdown", u: "/docs/markdown/", k: "syntax wikilinks embeds tags callouts tables tasks footnotes math mermaid front matter", h: [] },
  { s: "Guide", t: "Files and saves", u: "/docs/files/", k: "folders vaults obsidian save snapshots outside changes", h: [] },
  { s: "Guide", t: "Collaboration", u: "/docs/collaboration/", k: "live co-editing invite link peer to peer share", h: [] },
  { s: "Guide", t: "Themes and fonts", u: "/docs/themes-and-fonts/", k: "theme dark light font appearance", h: [] },
  { s: "Guide", t: "Keyboard shortcuts", u: "/docs/keyboard/", k: "keys shortcuts hotkeys command", h: [] },
  { s: "Guide", t: "Export", u: "/docs/export/", k: "html pdf docx word", h: [] },
  { s: "Reference", t: "Command line", u: "/docs/cli/", k: "cli terminal dewline open notify changes capture export mcp doctor editor wait", h: [] },
  { s: "Reference", t: "MCP server", u: "/docs/mcp/", k: "mcp agent tools stdio read search backlinks decisions inbox", h: [] },
  { s: "Reference", t: "Agents and changes", u: "/docs/agents/", k: "hooks claude code codex cursor attribution changes decisions keep revert", h: [] },
  { s: "Reference", t: "URL scheme", u: "/docs/url-scheme/", k: "dewline:// url link open export join", h: [] },
  { s: "Technical", t: "Architecture", u: "/docs/architecture/", k: "appkit textkit swift rust core uniffi engine", h: [] },
  { s: "Technical", t: "Performance", u: "/docs/performance/", k: "perf latency keystroke launch memory budgets measured", h: [] },
  { s: "Technical", t: "Security and privacy", u: "/docs/security/", k: "privacy telemetry network vulnerability report", h: [] },
];

const dialog = document.getElementById("search");
const input = document.getElementById("search-q");
const results = document.getElementById("search-results");
const openers = document.querySelectorAll(".search-open");

const entries = DOCS.flatMap((p) => [
  { title: p.t, where: p.s, url: p.u, hay: `${p.t} ${p.s} ${p.k}`.toLowerCase(), page: true },
  ...p.h.map(([text, id]) => ({ title: text, where: p.t, url: `${p.u}#${id}`, hay: `${text} ${p.t}`.toLowerCase(), page: false })),
]);

function score(e, q, terms) {
  if (!terms.every((t) => e.hay.includes(t))) return 0;
  const title = e.title.toLowerCase();
  let s = 1;
  if (title === q) s += 8;
  else if (title.startsWith(q)) s += 5;
  else if (title.includes(q)) s += 3;
  if (e.page) s += 1;
  return s;
}

function mark(text, terms) {
  const frag = document.createDocumentFragment();
  const lower = text.toLowerCase();
  let i = 0;
  while (i < text.length) {
    let hit = null;
    for (const t of terms) {
      const at = lower.indexOf(t, i);
      if (at !== -1 && (!hit || at < hit[0])) hit = [at, t.length];
    }
    if (!hit) break;
    if (hit[0] > i) frag.append(text.slice(i, hit[0]));
    const m = document.createElement("mark");
    m.textContent = text.slice(hit[0], hit[0] + hit[1]);
    frag.append(m);
    i = hit[0] + hit[1];
  }
  frag.append(text.slice(i));
  return frag;
}

let shown = [];
let active = 0;

function render() {
  const q = input.value.trim().toLowerCase();
  const terms = q.split(/\s+/).filter(Boolean);
  shown = terms.length
    ? entries.map((e) => [score(e, q, terms), e]).filter(([s]) => s > 0).sort((a, b) => b[0] - a[0]).slice(0, 12).map(([, e]) => e)
    : entries.filter((e) => e.page);
  results.replaceChildren();
  if (!shown.length) {
    const li = document.createElement("li");
    li.className = "search-empty";
    li.textContent = `No page or heading matches "${input.value.trim()}".`;
    results.append(li);
  }
  shown.forEach((e, n) => {
    const li = document.createElement("li");
    li.id = `search-r${n}`;
    li.setAttribute("role", "option");
    const a = document.createElement("a");
    a.href = e.url;
    a.tabIndex = -1;
    const b = document.createElement("b");
    b.append(mark(e.title, terms));
    const span = document.createElement("span");
    span.textContent = e.where;
    a.append(b, span);
    li.append(a);
    results.append(li);
  });
  select(0);
}

function select(n) {
  if (!shown.length) {
    input.removeAttribute("aria-activedescendant");
    return;
  }
  active = (n + shown.length) % shown.length;
  for (const li of results.querySelectorAll("[role=option]")) li.setAttribute("aria-selected", "false");
  const li = document.getElementById(`search-r${active}`);
  li.setAttribute("aria-selected", "true");
  li.scrollIntoView({ block: "nearest" });
  input.setAttribute("aria-activedescendant", li.id);
}

function openSearch() {
  if (dialog.open) return;
  input.value = "";
  render();
  dialog.showModal();
  input.setAttribute("aria-expanded", "true");
  input.focus();
}

input.addEventListener("input", render);
input.addEventListener("keydown", (e) => {
  if (e.key === "ArrowDown") { e.preventDefault(); select(active + 1); }
  else if (e.key === "ArrowUp") { e.preventDefault(); select(active - 1); }
  else if (e.key === "Enter" && shown[active]) {
    e.preventDefault();
    dialog.close();
    location.href = shown[active].url;
  }
});
dialog.addEventListener("close", () => input.setAttribute("aria-expanded", "false"));
dialog.addEventListener("click", (e) => {
  if (e.target === dialog) dialog.close();
  if (e.target.closest(".search-close")) dialog.close();
  if (e.target.closest(".search-results a")) dialog.close();
});
for (const b of openers) b.addEventListener("click", openSearch);
addEventListener("keydown", (e) => {
  const typing = e.target.closest?.("input, textarea, select, [contenteditable]");
  if ((e.key === "k" && (e.metaKey || e.ctrlKey)) || (e.key === "/" && !typing && !e.metaKey && !e.ctrlKey)) {
    e.preventDefault();
    openSearch();
  }
});
