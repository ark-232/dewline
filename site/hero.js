// Hero visual A. One 10 s loop, built from measured positions so it fits any width.
// The page is drawn finished; the loop runs only with motion allowed, the figure on
// screen and the tab visible.
(() => {
  const root = document.querySelector(".hva");
  if (!root || !root.animate) return;
  const L = 10000, OUTRO = 9300, START = 8600;
  const EASE = "cubic-bezier(0.16, 1, 0.3, 1)";
  const reduce = matchMedia("(prefers-reduced-motion: reduce)");
  let anims = [], seen = false, width = root.clientWidth, timer;

  // frames: [ms, props, easing for the segment that follows]
  const add = (el, frames) => {
    const kf = frames.map(([t, p, e]) => ({ offset: t / L, easing: e || "linear", ...p }));
    if (kf[0].offset > 0) kf.unshift({ ...kf[0], offset: 0, easing: "linear" });
    if (kf[kf.length - 1].offset < 1) kf.push({ ...kf[kf.length - 1], offset: 1 });
    anims.push(el.animate(kf, { duration: L, iterations: Infinity }));
  };

  function build() {
    const stage = root.querySelector(".hva-stage");
    const o = stage.getBoundingClientRect();
    const box = (el) => {
      const r = el.getBoundingClientRect();
      return { x: r.left - o.left, y: r.top - o.top, w: r.width, h: r.height };
    };
    const caret = root.querySelector(".hva-caret");
    const bar = caret.firstElementChild;
    const ch = bar.offsetHeight;
    const lines = [...root.querySelectorAll(".hva-ln")];
    const a = box(root.querySelector(".hva-at")); // before any transform is applied
    const at =(x, y, s = 1) => ({ transform: `translate(${x}px, ${y}px) scaleY(${s})` });

    // Typing: each line is uncovered one character at a time; the caret walks with it.
    let t = 300;
    const first = box(lines[0]);
    let cur = at(first.x, first.y + (first.h - ch) / 2);
    const cf = [[0, cur]];
    lines.forEach((ln, i) => {
      const b = box(ln), n = ln.textContent.length, y = b.y + (b.h - ch) / 2;
      ln.dataset.i = i;
      cf.push([t, cur], [t + 1, at(b.x, y)]);
      cur = at(b.x + b.w, y);
      if (n) {
        const d = n * (+ln.dataset.ms || 9);
        cf[cf.length - 1][2] = `steps(${n}, end)`;
        cf.push([t + d, cur]);
        add(ln, [[t, { clipPath: "inset(0 100% 0 0)" }, `steps(${n}, end)`], [t + d, { clipPath: "inset(0 0% 0 0)" }]]);
        t += d;
      }
      t += 55;
    });

    // The syntax steps aside, except on the caret's own line.
    const G = t + 250;
    const away = { l: "-0.5em, 0", r: "0.5em, 0", u: "0, -0.35em" };
    for (const g of root.querySelectorAll(".hva-g[data-d]")) {
      const s = G + g.closest(".hva-ln").dataset.i * 18;
      add(g, [
        [s, { opacity: 1, transform: "none" }, EASE],
        [s + 260, { opacity: 0, transform: `translate(${away[g.dataset.d]})` }],
      ]);
    }

    // Each source block travels to its rendered twin while the two cross-fade.
    const M = G + 420, DUR = 750;
    const src = root.querySelectorAll(".hva-sb");
    const out = root.querySelector(".hva-out").children;
    [...src].forEach((sb, k) => {
      const a = box(sb), b = box(out[k]);
      const dx = a.x - b.x, dy = a.y - b.y;
      const s = Math.min(1.4, Math.max(0.55, a.h / b.h));
      const m = M + k * 70;
      add(sb, [[m, { transform: "none" }, EASE], [m + DUR, { transform: `translate(${-dx}px, ${-dy}px) scale(${1 / s})` }]]);
      add(sb, [[m, { opacity: 1 }, "ease-out"], [m + 260, { opacity: 0 }]]);
      add(out[k], [[m, { transform: `translate(${dx}px, ${dy}px) scale(${s})` }, EASE], [m + DUR, { transform: "none" }]]);
      add(out[k], [[m + 140, { opacity: 0 }, "ease-out"], [m + 560, { opacity: 1 }]]);
    });
    add(root.querySelector(".hva-out"), [[OUTRO, { opacity: 1 }, "ease-in"], [OUTRO + 400, { opacity: 0 }], [L, { opacity: 0 }]]);

    // The caret follows the last line into the page and blinks there.
    const end = M + (src.length - 1) * 70;
    cf.push([end, cur, EASE], [end + DUR, at(a.x, a.y, a.h / ch)], [OUTRO + 400, at(a.x, a.y, a.h / ch)]);
    cf.push([OUTRO + 401, cf[0][1]]);
    add(caret, cf);
    const blink = [[0, { opacity: 1 }], [end + DUR, { opacity: 1 }, "steps(1, end)"]];
    for (let b = end + DUR + 530, on = 0; b < OUTRO; b += 530, on ^= 1) blink.push([b, { opacity: on }, "steps(1, end)"]);
    blink.push([OUTRO, { opacity: blink[blink.length - 1][1].opacity }, "ease-in"], [OUTRO + 200, { opacity: 0 }], [OUTRO + 500, { opacity: 0 }, "steps(1, end)"], [OUTRO + 501, { opacity: 1 }]);
    add(bar, blink);
  }

  function run() {
    const t = anims.length ? anims[0].currentTime % L : START;
    for (const a of anims) a.cancel();
    anims = [];
    root.classList.toggle("is-live", !reduce.matches);
    if (reduce.matches) return;
    build();
    for (const a of anims) a.currentTime = t;
    sync();
  }
  function sync() {
    const on = seen && !document.hidden && !root.closest(".hero-slot")?.classList.contains("is-paused");
    for (const a of anims) on ? a.play() : a.pause();
  }

  new IntersectionObserver(([e]) => { seen = e.isIntersecting; sync(); }).observe(root);
  document.addEventListener("visibilitychange", sync);
  reduce.addEventListener("change", run);
  // Positions are measured, so rebuild when the width changes or a late font lands.
  const later = () => { clearTimeout(timer); timer = setTimeout(run, 150); };
  new ResizeObserver(() => {
    if (root.clientWidth === width) return;
    width = root.clientWidth;
    later();
  }).observe(root);
  document.fonts.addEventListener("loadingdone", later);
  document.fonts.ready.then(run);
})();
