// Loaded in <head> without defer on the landing, so .motion is set before first paint.
// Docs pages load it with defer; everything below is safe on either.
(() => {
  const root = document.documentElement;
  const motion = matchMedia("(prefers-reduced-motion: no-preference)").matches;
  if (motion) root.classList.add("motion");

  function copyButtons() {
    const copied = document.getElementById("copied");
    for (const button of document.querySelectorAll("[data-copy]")) {
      const code = document.getElementById(button.dataset.copy);
      let timer;
      button.addEventListener("click", async () => {
        try {
          await navigator.clipboard.writeText(code.textContent);
        } catch {
          getSelection().selectAllChildren(code);
          return;
        }
        button.textContent = "Copied";
        if (copied) copied.textContent = "Copied";
        clearTimeout(timer);
        timer = setTimeout(() => {
          button.textContent = "Copy";
          if (copied) copied.textContent = "";
        }, 1600);
      });
    }
  }

  function headerRule() {
    const top = document.querySelector(".top");
    if (!top) return;
    const update = () => top.classList.toggle("scrolled", scrollY > 8);
    addEventListener("scroll", update, { passive: true });
    update();
  }

  // A capture below the fold rests 24 px low and rises once when 20% of it is in view.
  function reveals() {
    if (!motion || !("IntersectionObserver" in window)) return;
    const io = new IntersectionObserver((entries) => {
      for (const e of entries) {
        if (!e.isIntersecting) continue;
        e.target.classList.remove("pending");
        io.unobserve(e.target);
      }
    }, { threshold: 0.2 });
    for (const el of document.querySelectorAll(".reveal")) {
      if (el.getBoundingClientRect().top < innerHeight) continue;
      el.classList.add("pending");
      io.observe(el);
    }
  }

  // The changes demo: frame 1 at rest, frame 2 600 ms after half the figure is in view,
  // frame 3 1600 ms later. With Reduce Motion it holds frame 2 and offers steps.
  function demo() {
    const fig = document.querySelector("[data-demo]");
    if (!fig) return;
    const frames = [...fig.querySelectorAll(".frames picture")];
    const caption = fig.querySelector("[data-caption]");
    const steps = [...fig.querySelectorAll("[data-steps] button")];
    const show = (n) => {
      frames.forEach((f, i) => {
        f.classList.toggle("on", i === n);
        if (i === n) f.removeAttribute("aria-hidden"); else f.setAttribute("aria-hidden", "true");
      });
      caption.textContent = frames[n].dataset.caption;
      steps.forEach((b, i) => b.setAttribute("aria-pressed", String(i === n)));
    };
    if (!motion || !("IntersectionObserver" in window)) {
      fig.querySelector("[data-steps]").hidden = false;
      steps.forEach((b, i) => b.addEventListener("click", () => show(i)));
      return;
    }
    let timers = [];
    const play = () => {
      timers.forEach(clearTimeout);
      show(0);
      timers = [setTimeout(() => show(1), 600), setTimeout(() => show(2), 2200)];
    };
    show(0);
    const replay = fig.querySelector("[data-replay]");
    replay.hidden = false;
    replay.querySelector("button").addEventListener("click", play);
    const io = new IntersectionObserver((entries) => {
      if (!entries.some((e) => e.isIntersecting)) return;
      io.disconnect();
      play();
    }, { threshold: 0.5 });
    io.observe(fig);
  }

  function init() {
    copyButtons();
    headerRule();
    reveals();
    demo();
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();
})();
