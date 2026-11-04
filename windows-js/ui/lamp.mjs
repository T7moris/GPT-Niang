import { drawLamp } from "./music-art.mjs";
import { drawHalo } from "./halo.mjs";
const canvas = document.getElementById("lamp");
let current = null,
  image = null,
  lastPaint = 0;
window.gpt.onLamp((value) => {
  current = value;
  if (value.image) {
    image = new Image();
    image.src = value.image.url;
  }
  if (value.mode === "hidden") {
    canvas.getContext("2d").clearRect(0, 0, canvas.width, canvas.height);
    return;
  }
  if (value.mode !== "halo") drawLamp(canvas, value);
});
function frame(now) {
  if (current?.mode === "halo" && now - lastPaint >= 1000 / 30) {
    lastPaint = now;
    drawHalo(canvas, current, image);
  }
  requestAnimationFrame(frame);
}
requestAnimationFrame(frame);
