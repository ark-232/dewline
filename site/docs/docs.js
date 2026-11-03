// Docs pages: copy buttons, heading anchors, the "On this page" outline and the phone menu.
const live = document.getElementById("copied");

// Copy buttons. A block with prompts copies only its commands (and their backslash continuations), without the
// prompts or the output.
function codeText(code) {
  if (!code.querySelector(".p")) return code.textContent.replace(/\n$/, "");
  const lines = [];
  let continued = false;
  for (const line of code.textContent.split("\n")) {
    const m = /^\$ (.*)$/.exec(line);
    if (m || continued) {
      const text = m ? m[1] : line;
      lines.push(text);
      continued = text.endsWith("\\");
    }
  }
  return lines.join("\n");
}
for (const block of document.querySelectorAll(".code")) {
  const code = block.querySelector("code");
  if (!code) continue;
  const button = document.createElement("button");
  button.type = "button";
  button.className = "copy";
  button.textContent = "Copy";
  button.setAttribute("aria-label", `Copy the ${block.dataset.lang || "code"}`);
  let timer;
  button.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(codeText(code));
    } catch {
      getSelection().selectAllChildren(code);
      return;
    }
    button.textContent = "Copied";
    live.textContent = "Copied";
    clearTimeout(timer);
    timer = setTimeout(() => {
      button.textContent = "Copy";
      live.textContent = "";
    }, 1600);
  });
  block.append(button);
}

// Heading anchors and the outline, from the article's h2 and h3 headings that carry an id.
const headings = [...document.querySelectorAll(".prose h2[id], .prose h3[id]")];
const outline = document.querySelector(".outline");
const outlineLinks = new Map();
for (const h of headings) {
  const anchor = document.createElement("a");
  anchor.className = "anchor";
  anchor.href = `#${h.id}`;
  anchor.textContent = "#";
  anchor.setAttribute("aria-label", `Link to ${h.textContent}`);
  h.prepend(anchor);
}
if (outline && headings.length > 1) {
  const list = document.createElement("ul");
  for (const h of headings) {
    const li = document.createElement("li");
    if (h.tagName === "H3") li.className = "sub";
    const a = document.createElement("a");
    a.href = `#${h.id}`;
    a.textContent = h.textContent.replace(/^#/, "");
    li.append(a);
    list.append(li);
    outlineLinks.set(h, a);
  }
  outline.append(list);

  let current = null;
  let queued = false;
  const mark = () => {
    queued = false;
    const top = parseFloat(getComputedStyle(document.documentElement).scrollPaddingTop) || 80;
    let found = headings[0];
    for (const h of headings) {
      if (h.getBoundingClientRect().top - top <= 8) found = h;
      else break;
    }
    if (innerHeight + scrollY >= document.documentElement.scrollHeight - 4) found = headings[headings.length - 1];
    if (found === current) return;
    outlineLinks.get(current)?.classList.remove("on");
    outlineLinks.get(found).classList.add("on");
    current = found;
  };
  addEventListener("scroll", () => {
    if (!queued) {
      queued = true;
      requestAnimationFrame(mark);
    }
  }, { passive: true });
  addEventListener("resize", mark);
  mark();
} else if (outline) {
  outline.hidden = true;
}

// A link to a folded section, or to something inside one, unfolds it.
function unfoldTarget() {
  const target = location.hash ? document.getElementById(decodeURIComponent(location.hash.slice(1))) : null;
  const fold = target?.closest("details");
  if (fold && !fold.open) {
    fold.open = true;
    target.scrollIntoView();
  }
}
addEventListener("hashchange", unfoldTarget);
unfoldTarget();

// The phone menu opens the docs navigation over the page.
const menu = document.querySelector(".menu");
const nav = document.getElementById("dnav");
if (menu && nav) {
  const setOpen = (open) => {
    nav.classList.toggle("open", open);
    menu.setAttribute("aria-expanded", String(open));
    menu.textContent = open ? "Close" : "Menu";
    document.documentElement.style.overflow = open ? "hidden" : "";
  };
  menu.addEventListener("click", () => setOpen(!nav.classList.contains("open")));
  nav.addEventListener("click", (e) => {
    if (e.target.closest("a")) setOpen(false);
  });
  addEventListener("keydown", (e) => {
    if (e.key === "Escape" && nav.classList.contains("open")) {
      setOpen(false);
      menu.focus();
    }
  });
  matchMedia("(min-width: 56.0625rem)").addEventListener("change", (e) => {
    if (e.matches) setOpen(false);
  });
}
