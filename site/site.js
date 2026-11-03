const copied = document.getElementById("copied");
for (const button of document.querySelectorAll("[data-copy]")) {
  const code = document.getElementById(button.dataset.copy);
  const iconOnly = button.classList.contains("icon");
  let timer;
  button.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(code.textContent);
    } catch {
      getSelection().selectAllChildren(code);
      return;
    }
    if (iconOnly) button.classList.add("is-done");
    else button.textContent = "Copied";
    copied.textContent = "Copied";
    clearTimeout(timer);
    timer = setTimeout(() => {
      if (iconOnly) button.classList.remove("is-done");
      else button.textContent = "Copy";
      copied.textContent = "";
    }, 1600);
  });
}

// Sections settle in once as they scroll into view.
const reveals = document.querySelectorAll(".reveal, .reveal-list");
if (reveals.length) {
  if ("IntersectionObserver" in window) {
    const seen = new IntersectionObserver((entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        entry.target.classList.add("in");
        seen.unobserve(entry.target);
      }
    }, { rootMargin: "0px 0px -10% 0px", threshold: 0.1 });
    for (const el of reveals) seen.observe(el);
  } else {
    for (const el of reveals) el.classList.add("in");
  }
}
