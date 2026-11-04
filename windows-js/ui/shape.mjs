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
export class ShapePublisher {
  constructor(send) {
    this.send = send;
    this.signature = "";
    this.resources = {};
    this.last = "";
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
    this.last = "";
    return resources;
  }
  update(state, image) {
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
    const key = JSON.stringify(matrices);
    if (resources || key !== this.last) {
      this.last = key;
      this.send({ resources, matrices, details });
    }
  }
}
