import koffi from "koffi";
const gdi = koffi.load("gdi32.dll"),
  user = koffi.load("user32.dll");
const Transform = koffi.struct("GptShapeTransform", {
  a: "float",
  b: "float",
  c: "float",
  d: "float",
  x: "float",
  y: "float",
});
const create = gdi.func(
    "intptr_t __stdcall CreateRectRgn(int left,int top,int right,int bottom)",
  ),
  extended = gdi.func(
    "intptr_t __stdcall ExtCreateRegion(GptShapeTransform *matrix,uint32_t count,void *data)",
  ),
  combine = gdi.func(
    "int __stdcall CombineRgn(intptr_t destination,intptr_t first,intptr_t second,int mode)",
  ),
  remove = gdi.func("bool __stdcall DeleteObject(intptr_t object)"),
  set = user.func(
    "int __stdcall SetWindowRgn(intptr_t window,intptr_t region,bool redraw)",
  ),
  get = user.func(
    "int __stdcall GetWindowRgn(intptr_t window,intptr_t region)",
  ),
  equal = gdi.func(
    "bool __stdcall EqualRgn(intptr_t first,intptr_t second)",
  );
export class GdiShape {
  constructor(handle) {
    this.handle = handle;
    this.sources = new Map();
    this.matrices = {};
    this.clip = null;
    this.key = "";
    this.updates = 0;
    this.equivalentUpdates = 0;
    this.totalMs = 0;
    this.maxMs = 0;
  }
  update(packet) {
    if (packet.resources) {
      for (const [name, source] of Object.entries(packet.resources)) {
        if (
          !["girl", "bubble", "tail", "tailNear", "menu"].includes(name) ||
          !Number.isInteger(source.width) ||
          !Number.isInteger(source.height) ||
          source.width < 1 ||
          source.height < 1 ||
          source.width > 8192 ||
          source.height > 8192 ||
          !Array.isArray(source.rects) ||
          source.rects.length > 500000
        )
          throw Error("Invalid shape resource");
        const buffer = encodeRegion(source);
        this.sources.set(name, {
          buffer,
          width: source.width,
          height: source.height,
        });
      }
      this.key = "";
    }
    if (packet.matrices) {
      const matrices = {};
      for (const [name, values] of Object.entries(packet.matrices)) {
        if (
          !this.sources.has(name) ||
          !Array.isArray(values) ||
          values.length !== 6 ||
          !values.every((v) => Number.isFinite(v) && Math.abs(v) <= 100000)
        )
          throw Error("Invalid shape matrix");
        matrices[name] = values;
      }
      this.matrices = matrices;
    }
    return this.apply();
  }
  setClip(rect) {
    const key = JSON.stringify(rect);
    if (key === JSON.stringify(this.clip)) return;
    this.clip = rect;
    this.key = "";
    this.apply();
  }
  apply() {
    const key = JSON.stringify([this.matrices, this.clip]);
    if (key === this.key) return true;
    if (!this.sources.size) return false;
    const started = performance.now(),
      result = create(0, 0, 0, 0);
    if (!result) return false;
    let transferred = false;
    try {
      for (const [name, m] of Object.entries(this.matrices)) {
        const source = this.sources.get(name);
        if (!source || source.buffer.readUInt32LE(8) === 0) continue;
        const part = extended(
          { a: m[0], b: m[1], c: m[2], d: m[3], x: m[4], y: m[5] },
          source.buffer.length,
          source.buffer,
        );
        if (!part) return false;
        try {
          if (combine(result, result, part, 2) === 0) return false;
        } finally {
          remove(part);
        }
      }
      if (this.clip) {
        const clip = create(...this.clip.map(Math.round));
        if (!clip) return false;
        try {
          if (combine(result, result, clip, 1) === 0) return false;
        } finally {
          remove(clip);
        }
      }
      // Different subpixel matrices can produce the exact same integer GDI
      // region. Compare the installed region before requesting another redraw.
      const installed = create(0, 0, 0, 0);
      if (installed) {
        try {
          if (get(this.handle, installed) !== 0 && equal(installed, result)) {
            this.key = key;
            this.equivalentUpdates++;
            return true;
          }
        } finally {
          remove(installed);
        }
      }
      transferred = set(this.handle, result, true) !== 0;
      if (transferred) {
        this.key = key;
        this.updates++;
        const elapsed = performance.now() - started;
        this.totalMs += elapsed;
        this.maxMs = Math.max(this.maxMs, elapsed);
      }
      return transferred;
    } finally {
      if (!transferred) remove(result);
    }
  }
  status() {
    return {
      updates: this.updates,
      equivalentUpdates: this.equivalentUpdates,
      averageMs: this.updates ? this.totalMs / this.updates : 0,
      maxMs: this.maxMs,
      parts: this.sources.size,
    };
  }
}

export function encodeRegion(source) {
  if (
    !Number.isInteger(source.width) ||
    !Number.isInteger(source.height) ||
    source.width < 1 ||
    source.height < 1 ||
    source.width > 8192 ||
    source.height > 8192 ||
    !Array.isArray(source.rects) ||
    source.rects.length > 500000
  )
    throw Error("Invalid shape resource");
  const buffer = Buffer.alloc(32 + source.rects.length * 16);
  buffer.writeUInt32LE(32, 0);
  buffer.writeUInt32LE(1, 4);
  buffer.writeUInt32LE(source.rects.length, 8);
  buffer.writeUInt32LE(source.rects.length * 16, 12);
  buffer.writeInt32LE(source.width, 24);
  buffer.writeInt32LE(source.height, 28);
  source.rects.forEach((r, index) => {
    if (
      !Array.isArray(r) ||
      r.length !== 4 ||
      !r.every(Number.isInteger) ||
      r[0] < 0 ||
      r[1] < 0 ||
      r[2] > source.width ||
      r[3] > source.height ||
      r[2] <= r[0] ||
      r[3] <= r[1]
    )
      throw Error("Invalid shape rectangle");
    r.forEach((v, n) => buffer.writeInt32LE(v, 32 + index * 16 + n * 4));
  });
  return buffer;
}
const pointInside = gdi.func(
  "bool __stdcall PtInRegion(intptr_t region,int x,int y)",
);
export function probeTransformedRegion(source, matrix, points) {
  if (!source.rects.length) return points.map(() => false);
  const bytes = encodeRegion(source),
    r = extended(
      {
        a: matrix[0],
        b: matrix[1],
        c: matrix[2],
        d: matrix[3],
        x: matrix[4],
        y: matrix[5],
      },
      bytes.length,
      bytes,
    );
  if (!r) throw Error("Region transform failed");
  try {
    return points.map((p) => pointInside(r, p[0], p[1]));
  } finally {
    remove(r);
  }
}
