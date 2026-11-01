const landing = document.querySelector(".landing");
new IntersectionObserver((entries, observer) => {
  if (entries.some((entry) => entry.isIntersecting)) {
    landing.classList.add("play");
    observer.disconnect();
  }
}, { threshold: 0.5 }).observe(landing);

const header = document.querySelector(".top");
let queued = false;
function mark() {
  queued = false;
  header.classList.toggle("scrolled", scrollY > 0);
}
addEventListener("scroll", () => {
  if (!queued) {
    queued = true;
    requestAnimationFrame(mark);
  }
}, { passive: true });
mark();

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
    copied.textContent = "Copied";
    clearTimeout(timer);
    timer = setTimeout(() => {
      button.textContent = "Copy";
      copied.textContent = "";
    }, 1600);
  });
}
