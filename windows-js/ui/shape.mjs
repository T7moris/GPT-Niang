const partIds = {
  girl: "girl",
  bubble: "bubble-animation",
  tail: "tail",
  tailNear: "tail-near",
  menu: "menu-button",
};
export function alphaBounds(bytes,width,height){
  function scan(threshold){
    let left=width,right=-1,top=height,bottom=0;
    for(let y=0;y<height;y++){
      const row=y*width*4+3;let first=0;
      while(first<width&&bytes[row+first*4]<=threshold)first++;
      if(first===width)continue;
      let last=width-1;while(last>first&&bytes[row+last*4]<=threshold)last--;
      left=Math.min(left,first);right=Math.max(right,last);top=Math.min(top,y);bottom=y+1;
    }
    return right<left?null:{left,top,width:right-left+1,height:bottom-top,bottom};
  }
  return scan(12)??scan(10);
}
export function alphaRectangles(bytes, width, height) {
  const rects = [];
  let previous = new Map();
  for (let y = 0; y < height; y++) {
    const current = new Map();
    let x = 0;
    while (x < width) {
      while (x < width && bytes[(y * width + x) * 4 + 3] <= 10) x++;
      if (x >= width) break;
      const start = x;
      while (x < width && bytes[(y * width + x) * 4 + 3] > 10) x++;
      const key = start + ":" + x;
      const prior = previous.get(key);
      if (prior && prior[3] === y) {
        prior[3] = y + 1;
        current.set(key, prior);
      } else {
        const r = [start, y, x, y + 1];
        rects.push(r);
        current.set(key, r);
      }
    }
    previous = current;
  }
  return rects;
}
const RESTING_EDGE_PADDING = 3;

function unscaledMatrix(matrix, press) {
  const [a, , , d, x, y] = matrix;
  const [sx, sy] = press.current;
  const [ox, oy] = press.origin;
  return [a / sx, 0, 0, d / sy, ox + (x - ox) / sx, oy + (y - oy) / sy];
}
function paddedPart(source, matrix, press, padding = 2) {
  const [a, , , d, x, y] = matrix;
  const ends = press ? press.limits.map(([sx, sy]) => {
    const [ox, oy] = press.origin;
    return [sx * a, sy * d, ox + sx * (x - ox), oy + sy * (y - oy)];
  }) : [[a, d, x, y]];
  const bounds = ([left, top, right, bottom]) => {
    const xs = ends.flatMap(([sx, , dx]) => [left * sx + dx, right * sx + dx]);
    const ys = ends.flatMap(([, sy, , dy]) => [top * sy + dy, bottom * sy + dy]);
    return [Math.floor(Math.min(...xs)), Math.floor(Math.min(...ys)),
      Math.ceil(Math.max(...xs)), Math.ceil(Math.max(...ys))];
  };
  const [left, top, right, bottom] = bounds([0, 0, source.width, source.height]);
  // Leave two device pixels for the antialiased fringe and integer GDI rounding.
  const canvas = document.createElement("canvas");
  canvas.width = right - left + 2 * padding;
  canvas.height = bottom - top + 2 * padding;
  const ctx = canvas.getContext("2d", { willReadFrequently: true });
  for (const rect of source.rects) {
    const [x1, y1, x2, y2] = bounds(rect);
    ctx.fillRect(x1 - left, y1 - top, x2 - x1 + 2 * padding, y2 - y1 + 2 * padding);
  }
  return {
    source: { width: canvas.width, height: canvas.height,
      rects: alphaRectangles(ctx.getImageData(0, 0, canvas.width, canvas.height).data, canvas.width, canvas.height) },
    matrix: [1, 0, 0, 1, left - padding, top - padding],
  };
}

export class ShapePublisher {
  constructor(send) {
    this.send = send;
    this.signature = "";
    this.resources = {};
    this.restingResources = {};
    this.last = "";
    this.usingPressRegion = false;
    this.pressBase = null;
    this.enabled = true;
  }
  build(state, image) {
    const density = (innerWidth / 378) * devicePixelRatio,
      l = state.layout,
      sizes = {
        girl: [l.girl.width, l.girl.height],
        bubble: [350 * l.bubble.scale, 239 * l.bubble.scale],
        tail: [l.tail.width, l.tail.height],
        tailNear: [l.tailNear.width, l.tailNear.height],
        menu: [l.menu.width, l.menu.height],
      };
    const signature = JSON.stringify([
      state.settings.characterId,
      density,
      sizes,
      image.naturalWidth,
      image.naturalHeight,
      image.dataset?.maskRevision,
    ]);
    if (signature === this.signature) return null;
    const resources = {};
    for (const [name, size] of Object.entries(sizes)) {
      const canvas = document.createElement("canvas");
      canvas.width = Math.max(1, Math.round(size[0] * density));
      canvas.height = Math.max(1, Math.round(size[1] * density));
      const dc = canvas.getContext("2d", { willReadFrequently: true });
      if (name === "girl") {
        const fit = Math.min(
            canvas.width / image.naturalWidth,
            canvas.height / image.naturalHeight,
          ),
          w = image.naturalWidth * fit,
          h = image.naturalHeight * fit;
        dc.imageSmoothingQuality = "high";
        dc.drawImage(
          image,
          (canvas.width - w) / 2,
          (canvas.height - h) / 2,
          w,
          h,
        );
      } else {
        dc.fillStyle = "#fff";
        dc.strokeStyle = "#fff";
        if (name === "bubble") {
          dc.scale(canvas.width / 350, canvas.height / 239);
          dc.lineWidth = 4;
          dc.lineJoin = "round";
          const path = new Path2D(
            "M 27,85 A 128,79 0 1 1 283,85 A 128,79 0 0 1 196,160 A 20,10 0 0 1 161,164 A 128,79 0 0 1 27,85 Z",
          );
          dc.fill(path);
          dc.stroke(path);
        } else if (name === "menu") {
          dc.beginPath();
          dc.roundRect(
            0,
            0,
            canvas.width,
            canvas.height,
            Math.min(6 * density, canvas.width / 2, canvas.height / 2),
          );
          dc.fill();
        } else {
          dc.beginPath();
          dc.ellipse(
            canvas.width / 2,
            canvas.height / 2,
            canvas.width / 2,
            canvas.height / 2,
            0,
            0,
            Math.PI * 2,
          );
          dc.fill();
        }
      }
      resources[name] = {
        width: canvas.width,
        height: canvas.height,
        rects: alphaRectangles(
          dc.getImageData(0, 0, canvas.width, canvas.height).data,
          canvas.width,
          canvas.height,
        ),
      };
    }
    this.signature = signature;
    this.resources = resources;
    this.restingResources = Object.fromEntries(Object.entries(resources).map(
      ([name, source]) => [name, paddedPart(source, [1, 0, 0, 1, 0, 0], null, RESTING_EDGE_PADDING).source],
    ));
    this.last = "";
    return this.restingResources;
  }
  update(state, image, press) {
    if (!this.enabled || !state || !image.complete || !image.naturalWidth)
      return;
    const resources = this.build(state, image),
      matrices = {},
      details = {};
    for (const [name, id] of Object.entries(partIds)) {
      const element = document.getElementById(id),
        style = getComputedStyle(element),
        r = element.getBoundingClientRect(),
        source = this.resources[name];
      if (!r.width || !r.height) continue;
      const flip = state.layout.mirror < 0,
        a = (r.width * devicePixelRatio) / source.width,
        d = (r.height * devicePixelRatio) / source.height,
        matrix = [
          flip ? -a : a,
          0,
          0,
          d,
          (flip ? r.right : r.left) * devicePixelRatio,
          r.top * devicePixelRatio,
        ];
      details[name] = { matrix, width: source.width, height: source.height };
      if (
        style.visibility === "hidden" ||
        Number(style.opacity) < 0.001 ||
        (name === "menu" &&
          (state.settings.hideMenu ||
            !document.body.classList.contains("hover")))
      )
        continue;
      matrices[name] = matrix;
    }
    if (press) {
      const base = Object.fromEntries(Object.entries(matrices).map(
        ([name, matrix]) => [name, unscaledMatrix(matrix, press)],
      ));
      // Ignore fractional rounding noise from reversing the visual transform.
      const previous = this.pressBase;
      const sameGeometry = previous && previous.origin.every((value, i) => value === press.origin[i])
        && Object.keys(previous.matrices).length === Object.keys(base).length
        && Object.entries(base).every(([name, matrix]) => {
          const old = previous.matrices[name];
          if (!old) return false;
          const { width, height } = this.resources[name];
          return Math.abs(matrix[0] - old[0]) * width < 0.125
            && Math.abs(matrix[3] - old[3]) * height < 0.125
            && Math.abs(matrix[4] - old[4]) < 0.125
            && Math.abs(matrix[5] - old[5]) < 0.125;
        });
      if (resources || !this.usingPressRegion || !sameGeometry) {
        const sweptResources = {}, sweptMatrices = {};
        for (const [name, matrix] of Object.entries(base)) {
          const swept = paddedPart(this.resources[name], matrix, press);
          sweptResources[name] = swept.source;
          sweptMatrices[name] = swept.matrix;
        }
        this.usingPressRegion = true;
        this.pressBase = { origin: press.origin, matrices: base };
        this.send({ resources: sweptResources, matrices: sweptMatrices, details });
      }
    } else {
      const key = JSON.stringify(matrices);
      if (resources || this.usingPressRegion || key !== this.last) {
        const paddedResources = this.usingPressRegion ? this.restingResources : resources;
        const paddedMatrices = Object.fromEntries(Object.entries(matrices).map(([name, matrix]) => {
          const [a, , , d, x, y] = matrix;
          return [name, [a, 0, 0, d, x - RESTING_EDGE_PADDING * a, y - RESTING_EDGE_PADDING * d]];
        }));
        this.usingPressRegion = false;
        this.pressBase = null;
        this.last = key;
        this.send({ resources: paddedResources, matrices: paddedMatrices, details });
      }
    }
  }
}
