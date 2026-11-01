const landing = document.querySelector(".landing");
new IntersectionObserver((entries, observer) => {
  if (entries.some((entry) => entry.isIntersecting)) {
    landing.classList.add("play");
    observer.disconnect();
  }
}, { threshold: 0.5 }).observe(landing);

// The page's dew line: the accent segment is the part of the page on screen, as in the app.
const segment = document.querySelector(".pageline span");
let queued = false;
function place() {
  queued = false;
  const page = document.documentElement.scrollHeight;
  const track = segment.parentElement.clientWidth - 2 * segment.offsetLeft;
  segment.style.width = `${(innerHeight / page) * track}px`;
  segment.style.transform = `translateX(${(scrollY / page) * track}px)`;
}
function queue() {
  if (!queued) {
    queued = true;
    requestAnimationFrame(place);
  }
}
addEventListener("scroll", queue, { passive: true });
addEventListener("resize", queue);
place();

for (const button of document.querySelectorAll("[data-copy]")) {
  const status = button.nextElementSibling;
  button.addEventListener("click", async () => {
    await navigator.clipboard.writeText(document.getElementById(button.dataset.copy).textContent);
    button.textContent = "Copied";
    status.textContent = "Copied";
    setTimeout(() => {
      button.textContent = "Copy";
      status.textContent = "";
    }, 2000);
  });
}
