const shell = "#272038",
  side = "#16131f",
  trim = "#aa8ad9",
  led = "#91e0e1",
  cone = "#403252",
  core = "#b89bd2";
function context(canvas) {
  const dc = canvas.getContext("2d");
  dc.setTransform(1, 0, 0, 1, 0, 0);
  dc.clearRect(0, 0, canvas.width, canvas.height);
  dc.scale(canvas.width / 350, canvas.height / 350);
  return dc;
}
const ellipse = (dc, x, y, rx, ry, fill, stroke, width = 1) => {
  dc.beginPath();
  dc.ellipse(x, y, Math.max(0, rx), Math.max(0, ry), 0, 0, Math.PI * 2);
  if (fill) {
    dc.fillStyle = fill;
    dc.fill();
  }
  if (stroke) {
    dc.strokeStyle = stroke;
    dc.lineWidth = width;
    dc.stroke();
  }
};
const rounded = (dc, x, y, w, h, r, fill, stroke, width = 1) => {
  dc.beginPath();
  dc.roundRect(x, y, w, h, r);
  if (fill) {
    dc.fillStyle = fill;
    dc.fill();
  }
  if (stroke) {
    dc.strokeStyle = stroke;
    dc.lineWidth = width;
    dc.stroke();
  }
};
const line = (dc, x, y, x2, y2, color, width = 1) => {
  dc.beginPath();
  dc.moveTo(x, y);
  dc.lineTo(x2, y2);
  dc.strokeStyle = color;
  dc.lineWidth = width;
  dc.stroke();
};
export function drawUnder(canvas, m, f) {
  const dc = context(canvas);
  drawUnderContext(dc, m, f);
}
export function drawUnderContext(dc, m, f) {
  const p = m.Props;
  if (p <= 0) return;
  dc.globalAlpha = p;
  ellipse(
    dc,
    175,
    351,
    f * (0.325 + 0.1 * Math.max(0, m.Bend)),
    3,
    `rgba(45,34,61,${(24 + Math.max(0, m.Bend) * 35) / 255})`,
  );
  const rock = Math.max(-7.5, Math.min(7.5, m.Rock)),
    other = Math.max(
      -7.5,
      Math.min(7.5, -0.94 * (m.Rock - m.RockSpeed * 0.022)),
    );
  speaker(dc, m, -f * 0.56, rock, f / 132);
  speaker(dc, m, f * 0.56, other, f / 132);
  dc.globalAlpha = 1;
}
function speaker(dc, m, x, angle, scale) {
  const lift =
    (angle >= 0 ? 28 : 25) *
    scale *
    Math.abs(Math.sin((angle * Math.PI) / 180));
  dc.save();
  dc.translate(175 + x, 350 - lift);
  dc.rotate((angle * Math.PI) / 180);
  dc.scale(scale, scale);
  rounded(dc, -25, -90, 49, 90, 8, shell, trim, 2);
  rounded(dc, -21, -86, 41, 82, 5, shell, side);
  rounded(dc, -16, -81, 30, 3.5, 1.7, led);
  ellipse(dc, 0, -63, 8, 8, side, trim, 1.8);
  ellipse(dc, 0, -63, 4.5, 4.5, core);
  ellipse(dc, 0, -28, 18, 18, side, led, 1.7);
  const s = 1 + m.Pulse * 0.065;
  ellipse(dc, 0, -28, 14 * s, 14 * s, cone, trim);
  ellipse(dc, 0, -28, 7 * s, 7 * s, core, trim);
  line(dc, -13, -7, 12, -7, trim);
  dc.restore();
}
const leftLens = new Path2D(
    "M -59,-12 Q -35,-17 -10,-12 L -11,5 Q -13,21 -34,21 Q -55,21 -57,7 Z",
  ),
  rightLens = new Path2D(
    "M 10,-12 Q 34,-16 57,-12 L 55,6 Q 53,21 33,21 Q 13,21 12,5 Z",
  ),
  arms = new Path2D(
    "M -56,-8 Q -66,-11 -73,-8 M 53,-8 Q 62,-14 69,-19 M -11,-6 Q 0,-12 12,-6",
  );
export function drawOver(canvas, m, shape, glasses, ready) {
  const dc = context(canvas),
    p = ready ? 1 : m.Props;
  if (p <= 0 || !glasses) return;
  dc.save();
  dc.translate(175, 350);
  dc.scale(1, 1 - m.Bend);
  dc.translate(-175, -350);
  dc.globalAlpha = p;
  dc.translate(175 + shape.width * 0.008, 350 - shape.height * 0.376);
  dc.rotate((-7 * Math.PI) / 180);
  dc.scale(shape.width / 256, shape.width / 256);
  dc.lineWidth = 2;
  dc.strokeStyle = "#36313f";
  dc.stroke(arms);
  const gradient = dc.createLinearGradient(0, -17, 0, 21);
  gradient.addColorStop(0, "#171527");
  gradient.addColorStop(1, "#343044");
  for (const lens of [leftLens, rightLens]) {
    dc.fillStyle = gradient;
    dc.fill(lens);
    dc.strokeStyle = "#302c3e";
    dc.lineWidth = 1.9;
    dc.stroke(lens);
  }
  dc.globalAlpha = p * 0.3;
  line(dc, -47, -6, -34, -7, "#c4cfdf", 1.9);
  line(dc, 20, -5, 29, -6, "#c4cfdf", 1.9);
  dc.restore();
}
export function drawLamp(canvas, value) {
  const { width, height } = value.frame;
  const ratio = devicePixelRatio || 1;
  if (
    canvas.width !== Math.round(width * ratio) ||
    canvas.height !== Math.round(height * ratio)
  ) {
    canvas.width = Math.round(width * ratio);
    canvas.height = Math.round(height * ratio);
    canvas.style.width = width + "px";
    canvas.style.height = height + "px";
  }
  const dc = canvas.getContext("2d");
  dc.setTransform(ratio, 0, 0, ratio, 0, 0);
  dc.clearRect(0, 0, width, height);
  const m = value.motion ?? {
      Cycle: 0,
      Energy: 0,
      Pulse: 0,
      Props: 0,
      Lamp: 0,
    },
    diameter = Math.max(32, Math.min(72, value.figure * 0.42)),
    s = diameter / 56,
    top = value.top;
  dc.fillStyle = "rgba(10,7,23,.56862745)";
  dc.fillRect(0, 0, width, height);
  const glow = (x, y, rx, ry, color, alpha) => {
    dc.save();
    dc.translate(x, y);
    dc.scale(rx, ry);
    const g = dc.createRadialGradient(0, 0, 0, 0, 0, 1);
    g.addColorStop(0, `rgba(${color},${alpha})`);
    g.addColorStop(0.45, `rgba(${color},${alpha / 2})`);
    g.addColorStop(1, `rgba(${color},0)`);
    ellipse(dc, 0, 0, 1, 1, g);
    dc.restore();
  };
  glow(
    width * 0.05,
    height * 0.65,
    width * 0.75,
    height * 0.8,
    "40,205,240",
    65 / 255,
  );
  glow(
    width * 0.95,
    height * 0.5,
    width * 0.75,
    height * 0.8,
    "224,55,197",
    75 / 255,
  );
  dc.save();
  dc.globalAlpha = 0.62;
  dc.translate(width / 2, top + 44 * s);
  const length = Math.max(1, height - top);
  for (const [i, color] of [
    "246,72,197",
    "72,222,245",
    "174,100,253",
  ].entries()) {
    dc.save();
    dc.rotate(
      (((i - 1) * 38 +
        14 * Math.sin(Math.PI * m.Cycle * 0.5 + i * 1.8) * m.Energy) *
        Math.PI) /
        180,
    );
    const beam = dc.createLinearGradient(0, 0, 0, length);
    beam.addColorStop(0, `rgba(${color},${[110, 95, 100][i] / 255})`);
    beam.addColorStop(1, `rgba(${color},0)`);
    dc.beginPath();
    dc.moveTo(0, 0);
    dc.lineTo(-0.3 * length, length);
    dc.lineTo(0.3 * length, length);
    dc.closePath();
    dc.fillStyle = beam;
    dc.fill();
    dc.restore();
  }
  dc.restore();
  dc.save();
  dc.globalAlpha = 0.5 + 0.5 * m.Pulse;
  glow(
    width / 2,
    top + 44 * s,
    diameter * 0.95,
    diameter * 0.95,
    "147,228,255",
    220 / 255,
  );
  dc.restore();
  dc.save();
  dc.globalAlpha = Math.max(0.3, m.Props);
  dc.translate(width / 2, top);
  dc.rotate((m.Lamp * Math.PI) / 180);
  dc.scale(s, s);
  line(dc, 0, 0, 0, 16, "#aaa0b1");
  dc.translate(0, 44);
  ellipse(dc, 0, 0, 28, 28, shell);
  dc.save();
  dc.beginPath();
  dc.ellipse(0, 0, 28, 28, 0, 0, Math.PI * 2);
  dc.clip();
  const phase = (((value.artTime ?? 0) * 4) % 5) - 2.5;
  for (let row = 0; row < 12; row++)
    for (let col = 0; col < 15; col++) {
      const index =
        (row * 7 + col * 3 + Math.floor(col / 3)) % (value.palette.length - 1);
      dc.fillStyle = value.palette[index];
      dc.fillRect(-37.5 + col * 5 + phase, -30 + row * 5, 4.35, 4.35);
    }
  const shade = dc.createRadialGradient(-10, -12, 0, 0, 0, 34);
  shade.addColorStop(0, "rgba(18,12,27,0)");
  shade.addColorStop(1, "rgba(18,12,27,.392)");
  ellipse(dc, 0, 0, 28, 28, shade);
  dc.restore();
  ellipse(dc, 0, 0, 28, 28, null, trim, 1.5);
  dc.fillStyle = "#fff9ff";
  dc.fill(
    new Path2D(
      "M -10,-23 L -8,-16 L -1,-14 L -8,-12 L -10,-5 L -12,-12 L -19,-14 L -12,-16 Z",
    ),
  );
  dc.restore();
  const figure = value.figureGeometry;
  if (figure && value.motion) {
    dc.save();
    dc.translate(
      m.X / (value.dpi ?? devicePixelRatio),
      m.Y / (value.dpi ?? devicePixelRatio),
    );
    dc.scale(figure.display * figure.mirror, figure.display);
    dc.translate(-175, -350);
    drawUnderContext(dc, m, figure.width);
    dc.restore();
  }
}
