import koffi from "koffi";
import { GdiShape } from "./shape.mjs";
import { MouseActivation } from "./mouse-activation.mjs";
import {DesktopLayerRecovery,activateCodexWindow} from './window-policy.mjs';
const user = koffi.load("user32.dll"),
  kernel = koffi.load("kernel32.dll"),
  dwm = koffi.load("dwmapi.dll"),
  gdi = koffi.load("gdi32.dll");
const Rect = koffi.struct("GptRect", {
    left: "int",
    top: "int",
    right: "int",
    bottom: "int",
  }),
  Point = koffi.struct("GptPoint", { x: "int", y: "int" });
const EnumProc = koffi.proto(
  "bool __stdcall GptEnumProc(intptr_t h, intptr_t param)",
);
const EventProc = koffi.proto(
  "void __stdcall GptEventProc(intptr_t hook,uint32_t ev,intptr_t h,int objectId,int childId,uint32_t threadId,uint32_t time)",
);
const fn = (lib, decl) => lib.func(decl);
const u = {
  enum: fn(
    user,
    "bool __stdcall EnumWindows(GptEnumProc *callback, intptr_t param)",
  ),
  visible: fn(user, "bool __stdcall IsWindowVisible(intptr_t h)"),
  iconic: fn(user, "bool __stdcall IsIconic(intptr_t h)"),
  valid: fn(user, "bool __stdcall IsWindow(intptr_t h)"),
  foreground: fn(user, "intptr_t __stdcall GetForegroundWindow()"),
  show: fn(user, 'bool __stdcall ShowWindow(intptr_t h,int command)'),
  activate: fn(user, 'bool __stdcall SetForegroundWindow(intptr_t h)'),
  ancestor: fn(
    user,
    "intptr_t __stdcall GetAncestor(intptr_t h,uint32_t flags)",
  ),
  rect: fn(
    user,
    "bool __stdcall GetWindowRect(intptr_t h,_Out_ GptRect *rect)",
  ),
  cursor: fn(user, "bool __stdcall GetCursorPos(_Out_ GptPoint *point)"),
  key: fn(user, "int16_t __stdcall GetAsyncKeyState(int key)"),
  pid: fn(
    user,
    "uint32_t __stdcall GetWindowThreadProcessId(intptr_t h,_Out_ uint32_t *pid)",
  ),
  title: fn(
    user,
    "int __stdcall GetWindowTextW(intptr_t h,_Out_ uint16_t *text,int max)",
  ),
  cls: fn(
    user,
    "int __stdcall GetClassNameW(intptr_t h,_Out_ uint16_t *text,int max)",
  ),
  dpi: fn(user, "uint32_t __stdcall GetDpiForWindow(intptr_t h)"),
  pos: fn(
    user,
    "bool __stdcall SetWindowPos(intptr_t h,intptr_t after,int x,int y,int width,int height,uint32_t flags)",
  ),
  long: fn(user, "intptr_t __stdcall GetWindowLongPtrW(intptr_t h,int index)"),
  setLong: fn(
    user,
    "intptr_t __stdcall SetWindowLongPtrW(intptr_t h,int index,intptr_t value)",
  ),
  window: fn(user, "intptr_t __stdcall GetWindow(intptr_t h,uint32_t command)"),
  hook: fn(
    user,
    "intptr_t __stdcall SetWinEventHook(uint32_t first,uint32_t last,intptr_t module,GptEventProc *callback,uint32_t processId,uint32_t threadId,uint32_t flags)",
  ),
  unhook: fn(user, "bool __stdcall UnhookWinEvent(intptr_t h)"),
  open: fn(
    kernel,
    "intptr_t __stdcall OpenProcess(uint32_t access,bool inherit,uint32_t pid)",
  ),
  close: fn(kernel, "bool __stdcall CloseHandle(intptr_t h)"),
  image: fn(
    kernel,
    "bool __stdcall QueryFullProcessImageNameW(intptr_t h,uint32_t flags,_Out_ uint16_t *text,_Inout_ uint32_t *length)",
  ),
  session: fn(
    kernel,
    "bool __stdcall ProcessIdToSessionId(uint32_t pid,_Out_ uint32_t *session)",
  ),
  times: fn(
    kernel,
    "bool __stdcall GetProcessTimes(intptr_t h,_Out_ uint64_t *created,_Out_ uint64_t *exited,_Out_ uint64_t *kernel,_Out_ uint64_t *user)",
  ),
  attribute: fn(
    dwm,
    "int __stdcall DwmGetWindowAttribute(intptr_t h,int attr,void *data,int size)",
  ),
  createRegion: fn(
    gdi,
    "intptr_t __stdcall CreateRectRgn(int left,int top,int right,int bottom)",
  ),
  setRegion: fn(
    user,
    "int __stdcall SetWindowRgn(intptr_t h,intptr_t region,bool redraw)",
  ),
  deleteObject: fn(gdi, "bool __stdcall DeleteObject(intptr_t h)"),
  getRegion: fn(user, "int __stdcall GetWindowRgn(intptr_t h,intptr_t region)"),
  regionBounds: fn(
    gdi,
    "int __stdcall GetRgnBox(intptr_t region,_Out_ GptRect *rect)",
  ),
  layered: fn(
    user,
    "bool __stdcall GetLayeredWindowAttributes(intptr_t h,_Out_ uint32_t *key,_Out_ uint8_t *alpha,_Out_ uint32_t *flags)",
  ),
  setAttribute: fn(
    dwm,
    "int __stdcall DwmSetWindowAttribute(intptr_t h,int attr,void *data,int size)",
  ),
};
const readText = (func, h) => {
  const b = Buffer.alloc(4096);
  func(h, b, b.length / 2);
  return b.toString("utf16le").split("\0")[0];
};
export class NativeWindows {
  constructor() {
    const session = [0];
    u.session(process.pid, session);
    this.session = session[0];
    this.callbacks = [];
    this.hooks = [];
    this.processCache = new Map();
    this.clips = new Map();
    this.clipFrames = new Map();
    this.shapes = new Map();
  }
  handle(win) {
    return Number(win.getNativeWindowHandle().readBigUInt64LE());
  }
  frame(h) {
    const b = Buffer.alloc(16);
    if (u.attribute(h, 9, b, 16) === 0)
      return {
        left: b.readInt32LE(0),
        top: b.readInt32LE(4),
        right: b.readInt32LE(8),
        bottom: b.readInt32LE(12),
      };
    const r = {};
    return u.rect(h, r) ? r : null;
  }
  rect(h) {
    const r = {};
    return u.rect(h, r) ? r : null;
  }
  cursor() {
    const p = {};
    return u.cursor(p) ? p : null;
  }
  mouseMask() {
    return (u.key(1) & 0x8000 ? 1 : 0) | (u.key(2) & 0x8000 ? 2 : 0);
  }
  dpi(h) {
    return (u.dpi(h) || 96) / 96;
  }
  title(h) {
    return readText(u.title, h);
  }
  valid(h) {
    return !!h && u.valid(h);
  }
  foreground() {
    return u.ancestor(u.foreground(), 2);
  }
  minimized(h) { return this.valid(h)&&u.iconic(h); }
  restoreWindow(h) { if(this.isCodex(h))u.show(h,9); }
  foregroundWindow(h) { return this.isCodex(h)&&u.activate(h); }
  activateCodex(preferred) { return activateCodexWindow(this,preferred); }
  visible(h) {
    const b = Buffer.alloc(4);
    return (
      this.valid(h) &&
      u.visible(h) &&
      !u.iconic(h) &&
      (u.attribute(h, 14, b, 4) !== 0 || b.readUInt32LE(0) === 0)
    );
  }
  pid(h) {
    const a = [0];
    u.pid(h, a);
    return a[0];
  }
  identity(h) {
    const pid = this.pid(h),
      p = u.open(0x1000, false, pid);
    let started = "0";
    if (p) {
      try {
        const created = [0n],
          exited = [0n],
          kernel = [0n],
          user = [0n];
        if (u.times(p, created, exited, kernel, user))
          started = (BigInt(created[0]) + 504911232000000000n).toString();
      } finally {
        u.close(p);
      }
    }
    return { handle: h, pid, started, visible: this.visible(h) };
  }
  hosts() {
    const rows = [];
    u.enum((h) => {
      if (this.isCodex(h)) rows.push(this.identity(Number(h)));
      return true;
    }, 0);
    return rows;
  }
  isCodex(h) {
    if (!this.valid(h) || this.pid(h) === process.pid) return false;
    const style = Number(u.long(h, -16)),
      ex = Number(u.long(h, -20));
    if (
      ex & 0x80 ||
      ex & 0x08000000 ||
      !(ex & 0x40000) ||
      !(style & 0x10000) ||
      !this.title(h) ||
      readText(u.cls, h) !== "Chrome_WidgetWin_1"
    )
      return false;
    const pid = this.pid(h),
      session = [0];
    u.session(pid, session);
    if (session[0] !== this.session) return false;
    const now = Date.now();
    for (const [id, entry] of this.processCache)
      if (now < entry.at || now - entry.at >= 2000) this.processCache.delete(id);
    const cached = this.processCache.get(pid);
    if (cached) return cached.value;
    const p = u.open(0x1000, false, pid);
    let value = false;
    if (p) {
      try {
        const b = Buffer.alloc(65536),
          size = [32768];
        if (u.image(p, 0, b, size)) {
          const name = b.subarray(0, size[0] * 2).toString("utf16le");
          value =
            /\\(?:Codex|ChatGPT)\.exe$/i.test(name) &&
            (/\\OpenAI\.Codex_/i.test(name) || /\\OpenAI\\Codex\\/i.test(name));
        }
      } finally {
        u.close(p);
      }
    }
    if (this.processCache.size >= 256)
      this.processCache.delete(this.processCache.keys().next().value);
    this.processCache.set(pid, { value, at: now });
    return value;
  }
  findCodex() {
    const active = this.foreground();
    if (this.isCodex(active) && this.visible(active)) return active;
    let found = 0;
    u.enum((h) => {
      if (this.visible(h) && this.isCodex(h)) {
        found = h;
        return false;
      }
      return true;
    }, 0);
    return found;
  }
  move(h, { x, y, width, height }, after = 0) {
    if (this.pid(h) !== process.pid) return false;
    const r = this.rect(h);
    width = width ?? r?.right - r?.left;
    height = height ?? r?.bottom - r?.top;
    // Compare the integer coordinates that SetWindowPos actually receives.
    x = Math.round(x);
    y = Math.round(y);
    width = Math.round(width);
    height = Math.round(height);
    if (
      r &&
      r.left === x &&
      r.top === y &&
      r.right - r.left === width &&
      r.bottom - r.top === height
    )
      return false;
    return u.pos(
      h,
      after,
      x,
      y,
      width,
      height,
      0x614,
    );
  }
  owner(h, owner) {
    if (Number(u.long(h, -8)) !== owner) u.setLong(h, -8, owner);
  }
  noActivate(h) {
    u.setLong(h, -20, Number(u.long(h, -20)) | 0x08000080);
    this.mouseActivation??=new MouseActivation();
    if(!this.mouseActivation.attach(h))throw Error('无法启用挂件鼠标输入');
  }
  topmost(h) {
    return !!(Number(u.long(h, -20)) & 8);
  }
  band(h, topmost) {
    if (this.topmost(h) !== topmost)
      u.pos(h, topmost ? -1 : -2, 0, 0, 0, 0, 0x13);
  }
  desktopBand(h, topmost) {
    this.desktopRecovery??=new DesktopLayerRecovery();
    this.desktopRecovery.synchronize(this,h,topmost);
  }
  reassertTopmost(h) {
    if(this.pid(h)===process.pid)return u.pos(h,-1,0,0,0,0,0x213);
    return false;
  }
  previous(h) {
    for (let n = 0; n < 10000; n++) {
      h = u.window(h, 3);
      if (!h || this.visible(h)) return h;
    }
    return 0;
  }
  above(h, host, companion = 0) {
    if (!this.visible(host)) return false;
    this.owner(h, host);
    this.band(h, this.topmost(host));
    let previous = this.previous(host);
    if (previous === companion) previous = this.previous(previous);
    if (previous === h) return true;
    // Respect unrelated covering windows and ordinary dialogs.
    let scan = previous;
    for (let n = 0; n < 256 && scan; n++) {
      if (scan === h) return true;
      const ex = Number(u.long(scan, -20));
      if ((ex & 0x08000080) !== 0x08000080) break;
      let owner = Number(u.long(scan, -8)),
        related = false;
      for (let d = 0; d < 256 && owner; d++) {
        if (owner === host) {
          related = true;
          break;
        }
        owner = Number(u.long(owner, -8));
      }
      if (!related) break;
      scan = this.previous(scan);
    }
    if (!previous || (!this.topmost(host) && this.topmost(previous)))
      previous = 0;
    return u.pos(h, previous, 0, 0, 0, 0, 0x13);
  }
  listen(listener, { includeOwn = false } = {}) {
    const callback = koffi.register((hook, event, h, objectId, childId) => {
      if (!h || objectId !== 0 || childId !== 0) return;
      try {
        listener(event, Number(h));
      } catch {}
    }, koffi.pointer(EventProc));
    this.callbacks.push(callback);
    for (const [first, last] of [
      [3, 3],
      [0x10, 0x11],
      [0x16, 0x17],
      [0x8000, 0x8003],
      [0x800a, 0x800b],
      [0x8017, 0x8018],
    ])
      this.hooks.push(
        u.hook(first, last, 0, callback, 0, 0, includeOwn ? 0 : 2),
      );
  }
  layer(h) {
    return {
      owner: Number(u.long(h, -8)),
      topmost: this.topmost(h),
      previous: this.previous(h),
    };
  }
  clip(h, frame) {
    this.clipFrames.set(h, frame);
    if (!frame) {
      if (this.shapes.has(h)) {
        this.shapes.get(h).setClip(null);
        return;
      }
      if (this.clips.has(h)) {
        u.setRegion(h, 0, true);
        this.clips.delete(h);
      }
      return;
    }
    const r = this.rect(h);
    if (!r) return;
    let l = Math.max(0, frame.left - r.left),
      t = Math.max(0, frame.top - r.top),
      right = Math.min(r.right - r.left, frame.right - r.left),
      bottom = Math.min(r.bottom - r.top, frame.bottom - r.top);
    if (right <= l || bottom <= t) l = t = right = bottom = 0;
    const key = [l, t, right, bottom].join(",");
    if (this.shapes.has(h)) {
      this.shapes.get(h).setClip([l, t, right, bottom]);
      return;
    }
    if (this.clips.get(h) === key) return;
    const region = u.createRegion(
      Math.round(l),
      Math.round(t),
      Math.round(right),
      Math.round(bottom),
    );
    if (region) {
      if (u.setRegion(h, region, true)) this.clips.set(h, key);
      else u.deleteObject(region);
    }
  }
  updateShape(h, packet) {
    if (this.pid(h) !== process.pid) return false;
    let shape = this.shapes.get(h);
    if (!shape) {
      shape = new GdiShape(h);
      this.shapes.set(h, shape);
    }
    const result = shape.update(packet);
    this.clip(h, this.clipFrames.get(h) ?? null);
    return result;
  }
  shapeStatus(h) {
    return this.shapes.get(h)?.status() ?? null;
  }
  releaseShape(h) {
    this.shapes.delete(h);
    this.clips.delete(h);
    this.clipFrames.delete(h);
  }
  rectangleShape(h, rects, dpi = 1) {
    const names = ["girl", "bubble", "tail", "tailNear", "menu"],
      resources = {},
      matrices = {};
    rects.slice(0, 5).forEach((r, i) => {
      const name = names[i];
      resources[name] = { width: 1, height: 1, rects: [[0, 0, 1, 1]] };
      matrices[name] = [
        r.width * dpi,
        0,
        0,
        r.height * dpi,
        r.x * dpi,
        r.y * dpi,
      ];
    });
    return this.updateShape(h, { resources, matrices });
  }
  restoreLayer(h, state) {
    this.owner(h, 0);
    this.band(h, state.topmost);
    const prior =
      this.valid(state.previous) && state.previous !== h ? state.previous : 0;
    u.pos(h, prior, 0, 0, 0, 0, 0x213);
    this.owner(h, this.valid(state.owner) ? state.owner : 0);
  }
  cloak(h, value) {
    if (!this.valid(h) || this.pid(h) !== process.pid) return false;
    const b = Buffer.alloc(4);
    b.writeInt32LE(value ? 1 : 0);
    return u.setAttribute(h, 13, b, 4) === 0;
  }
  fullyCovered(host) {
    const target = this.rect(host);
    if (!target || target.right <= target.left || target.bottom <= target.top)
      return null;
    const contains = (a, b) =>
      a.left <= b.left &&
      a.top <= b.top &&
      a.right >= b.right &&
      a.bottom >= b.bottom;
    let h = Number(u.window(host, 3)),
      count = 0;
    while (h && count++ < 200) {
      if (this.pid(h) !== process.pid && this.visible(h)) {
        const ex = Number(u.long(h, -20)),
          bounds = this.rect(h);
        if (!(ex & 0xa0) && bounds && contains(bounds, target)) {
          let opaque = true;
          if (ex & 0x80000) {
            const key = [0],
              alpha = [0],
              flags = [0];
            opaque =
              u.layered(h, key, alpha, flags) &&
              !(flags[0] & 1) &&
              (!(flags[0] & 2) || alpha[0] === 255);
          }
          if (opaque) {
            const region = u.createRegion(0, 0, 0, 0);
            if (!region) return null;
            try {
              const type = u.getRegion(h, region);
              if (type === 0) return true;
              if (type === 2) {
                const r = {};
                if (
                  u.regionBounds(region, r) === 2 &&
                  contains(
                    {
                      left: r.left + bounds.left,
                      top: r.top + bounds.top,
                      right: r.right + bounds.left,
                      bottom: r.bottom + bounds.top,
                    },
                    target,
                  )
                )
                  return true;
              }
            } finally {
              u.deleteObject(region);
            }
          }
        }
      }
      h = Number(u.window(h, 3));
    }
    return h ? null : false;
  }
  close() {
    this.desktopRecovery?.close();
    this.mouseActivation?.close();
    for (const h of this.hooks) if (h) u.unhook(h);
    for (const cb of this.callbacks) koffi.unregister(cb);
    this.callbacks = [];
    this.hooks = [];
    this.processCache.clear();
  }
}
