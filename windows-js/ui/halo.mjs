export function drawHalo(canvas, value, image) {
  const { width, height } = value.frame,
    dpr = devicePixelRatio || 1;
  if (
    canvas.width !== Math.round(width * dpr) ||
    canvas.height !== Math.round(height * dpr)
  ) {
    canvas.width = Math.round(width * dpr);
    canvas.height = Math.round(height * dpr);
    canvas.style.width = width + "px";
    canvas.style.height = height + "px";
  }
  const dc = canvas.getContext("2d");
  dc.setTransform(dpr, 0, 0, dpr, 0, 0);
  dc.clearRect(0, 0, width, height);
  if (!image?.complete || !image.naturalWidth || !value.part) return;
  const { matrix: m, width: w, height: h } = value.part,
    mask = document.createElement("canvas");
  mask.width = w;
  mask.height = h;
  const ctx = mask.getContext("2d"),
    fit = Math.min(w / image.naturalWidth, h / image.naturalHeight),
    iw = image.naturalWidth * fit,
    ih = image.naturalHeight * fit;
  ctx.drawImage(image, (w - iw) / 2, (h - ih) / 2, iw, ih);
  ctx.globalCompositeOperation = "source-in";
  const phase = value.paused
      ? (value.phase ?? 0)
      : ((Date.now() - (value.epoch ?? 0)) / 2600) % 1,
    gradient = ctx.createLinearGradient(
      -w * 2 - phase * w,
      0,
      w * 3 - phase * w,
      0,
    );
  for (let cycle = 0; cycle < 5; cycle++)
    for (let n = 0; n < value.palette.length; n++)
      gradient.addColorStop(
        (cycle + n / (value.palette.length - 1)) / 5,
        value.palette[n],
      );
  ctx.fillStyle = gradient;
  ctx.fillRect(0, 0, w, h);
  const dpi = value.dpi;
  dc.save();
  dc.translate(value.windowOffset.x / dpi, value.windowOffset.y / dpi);
  dc.transform(
    m[0] / dpi,
    m[1] / dpi,
    m[2] / dpi,
    m[3] / dpi,
    m[4] / dpi,
    m[5] / dpi,
  );
  dc.globalAlpha = 0.62;
  dc.filter = "blur(" + 7 * value.display + "px)";
  dc.drawImage(mask, 0, 0);
  dc.restore();
}
