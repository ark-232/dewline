// Docs search: a hand-written index of pages and their headings, filtered in the page. ⌘K, Ctrl-K or / opens it.
// Add a page: one entry, in sidebar order. Add a heading: [text, id], where id is the id of a heading, a table
// row or a folded section on that page.
// k holds extra words a reader might type that are not in the title or headings.
const DOCS = [
  { s: "Start", t: "Overview", u: "/docs/", k: "docs docs index contents",
    h: [["Start", "start"], ["Write", "write"], ["Files and changes", "files-and-changes"], ["Developers", "developers"], ["About", "about"]] },
  { s: "Start", t: "First steps", u: "/docs/first-steps/", k: "install download dmg homebrew brew cask requirements macos 26 apple silicon intel start welcome demo open folder vault new note obsidian notion switching compare quit reopen",
    h: [["Install Dewline", "install"], ["Write your first note", "first-note"], ["See a change", "see-a-change"], ["Open your own folder", "open"], ["Quit and come back", "come-back"], ["Switching from Obsidian or Notion", "switching"]] },
  { s: "Write", t: "Editing", u: "/docs/editing/", k: "live rendering source view preview pane links link previews cards hover vim focus typewriter fold find spelling writing tools word count command palette settings",
    h: [["Live rendering", "live-rendering"], ["Preview beside the text", "preview"], ["Source view", "source"], ["Links", "links"], ["Lists and tasks", "lists"], ["Format and move lines", "format"], ["Paste images", "images"], ["Find", "find"], ["Focus, typewriter and motion", "focus"], ["Folding", "folding"], ["Spelling, Writing Tools and word count", "writing-tools"], ["Vim mode", "vim"], ["Undo", "undo"], ["Command palette", "palette"], ["Settings", "settings"]] },
  { s: "Write", t: "Markdown", u: "/docs/markdown/", k: "syntax wikilinks embeds tags callouts tables tasks footnotes math mermaid front matter code blocks",
    h: [["CommonMark", "commonmark"], ["GitHub extensions", "gfm"], ["Tables", "tables"], ["Task lists", "tasks"], ["Strikethrough", "strikethrough"], ["Footnotes", "footnotes"], ["Front matter", "front-matter"], ["Callouts", "callouts"], ["Highlights and comments", "highlights-comments"], ["Wikilinks", "wikilinks"], ["Embeds and images", "embeds"], ["Tags", "tags"], ["Math", "math"], ["Mermaid diagrams", "mermaid"], ["The diagram types Dewline draws", "mermaid-types"], ["Code blocks", "code"], ["What stays as text", "not-supported"]] },
  { s: "Write", t: "Keyboard", u: "/docs/keyboard/", k: "keyboard shortcuts keys shortcuts hotkeys commands menu bar",
    h: [["Dewline", "dewline"], ["File", "file"], ["Edit", "edit"], ["Format", "format"], ["View", "view"], ["Go", "go"], ["Window", "window"], ["Help", "help"]] },
  { s: "Write", t: "Themes and fonts", u: "/docs/themes-and-fonts/", k: "theme dark light font appearance tidewater nightwatch pairing catalog text size line width",
    h: [["Choose a theme", "choose"], ["Themes", "themes"], ["Choose fonts", "fonts"], ["Editorial", "pairings"], ["The font catalog", "install-fonts"], ["Set the size and width of the text", "page"]] },
  { s: "Write", t: "Export", u: "/docs/export/", k: "html pdf docx word print quick look",
    h: [["Export from the app", "from-the-app"], ["PDF", "pdf"], ["HTML", "html"], ["Word (DOCX)", "docx"], ["What each format keeps", "what-exports"], ["Export from the command line", "command-line"], ["Preview in Finder", "quick-look"]] },
  { s: "Files and changes", t: "Files", u: "/docs/files/", k: "folders vaults obsidian sidebar new note new folder rename move trash duplicate quick open save autosave snapshots earlier versions restore conflicts inbox capture daily note",
    h: [["Make a note", "new"], ["Find a note", "find"], ["Rename, move or delete a note", "manage"], ["How saving works", "saving"], ["Choose between two versions", "conflicts"], ["Go back to an earlier version", "snapshots"], ["Capture to the inbox", "inbox"]] },
  { s: "Files and changes", t: "Agents", u: "/docs/agents/", k: "agent panel chat acp gemini claude code codex cursor hooks keep revert changes decisions another app autosave holds",
    h: [["Keep or revert a change", "review"], ["Which changes are marked", "marked"], ["Chat with your agent", "chat"], ["Mark edits from other agents", "install"], ["Let agents see what you reverted", "decisions"], ["How Dewline knows who wrote it", "naming"], ["The four steps, and the lines one Edit sent", "proof"], ["Which agents are named", "agents"], ["What shows as another app", "unknown"], ["Autosave waits for the agent", "holds"], ["What a hook sends", "what-a-hook-sends"], ["Install the hooks by hand", "by-hand"], ["Remove the hooks", "remove"]] },
  { s: "Files and changes", t: "Collaboration", u: "/docs/collaboration/", k: "live co-editing share invite link join approve guest host waiting peer to peer remove",
    h: [["Invite someone", "invite"], ["Join a shared note", "join"], ["Edit together", "editing-together"], ["Remove someone or stop", "people"], ["What travels and what never does", "what-travels"], ["Limits in 0.1.0", "limits"]] },
  { s: "Developers", t: "CLI", u: "/docs/cli/", k: "command line cli terminal dewline open notify changes capture export mcp doctor editor wait exit codes",
    h: [["Where it lives", "where"], ["Commands", "commands"], ["dewline open", "open"], ["Use it as your editor", "editor"], ["dewline notify", "notify"], ["dewline changes", "changes"], ["dewline capture", "capture"], ["dewline export", "export"], ["dewline mcp", "mcp"], ["dewline doctor", "doctor"], ["Exit codes", "exit-codes"], ["Environment", "environment"], ["Files", "files"]] },
  { s: "Developers", t: "MCP", u: "/docs/mcp/", k: "mcp server mcp agent tools stdio read search backlinks decisions inbox json-rpc schema errors",
    h: [["Add it to your agent", "setup"], ["Claude Code", "claude-code"], ["Codex", "codex"], ["Cursor", "cursor"], ["What the server can reach", "limits"], ["Protocol", "protocol"], ["Tools", "tools"], ["read", "tool-read"], ["search", "tool-search"], ["backlinks", "tool-backlinks"], ["decisions", "tool-decisions"], ["append_to_inbox", "tool-append_to_inbox"], ["Errors", "errors"]] },
  { s: "Developers", t: "URL scheme", u: "/docs/url-scheme/", k: "dewline:// url link open export join demo",
    h: [["dewline://open", "open"], ["dewline://export", "export"], ["dewline://join", "join"], ["dewline://demo", "demo"], ["Path rules", "paths"], ["Errors", "errors"]] },
  { s: "About", t: "Security and privacy", u: "/docs/security/", k: "privacy telemetry network vulnerability report account snapshots jail sandbox license fsl",
    h: [["No account, no telemetry", "no-account"], ["What goes over the network", "network"], ["What stays on disk", "on-disk"],
      ["Threats and controls", "threats"], ["The controls at work", "examples"], ["The MCP server\u2019s roots", "example-mcp"], ["Exporting a hostile note", "example-export"], ["Reporting a vulnerability", "reporting"], ["License", "license"]] },
  { s: "About", t: "Performance", u: "/docs/performance/", k: "perf latency keystroke launch memory budgets perf.sh idle cpu dmg",
    h: [["Budgets", "budgets"], ["What each budget measures", "measures"], ["How a run works", "how-perf-sh-runs"]] },
  { s: "About", t: "Architecture", u: "/docs/architecture/", k: "appkit textkit swift rust core uniffi engine pulldown-cmark blake3 zstd syntect ratex mermaid sparkle loro iroh quick look decisions",
    h: [["The split", "the-split"], ["Rules the code keeps", "rules"], ["The parts", "parts"], ["Editor", "editor"], ["Documents", "documents"], ["Parser", "parser"], ["Merge", "change-engine"], ["Snapshots", "snapshots"], ["Path jail", "jail"], ["Rendering", "rendering"], ["Export", "export"], ["Boundary", "boundary"], ["Command", "command"], ["Quick Look", "quick-look"], ["Updates", "updates"], ["How a save checks the disk", "saves"], ["An outside change, disk to screen", "outside-change"], ["Collaboration", "collaboration"], ["Decision records", "decisions"]] },
];

const dialog = document.getElementById("docs-search");
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
