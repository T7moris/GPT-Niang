import { applyColors } from "./colors.mjs";
import { MusicMotion, clamp } from "./music-motion.mjs";
import { drawUnder, drawOver } from "./music-art.mjs";
import { ClickSequence } from "./click-audio.mjs";
import { ShapePublisher, alphaBounds } from "./shape.mjs";
import { FrameStats } from "./frame-stats.mjs";
const $ = (id) => document.getElementById(id),
  stage = $("stage"),
  root = $("root"),
  bubble = $("bubble"),
  bubbleAnimation = $("bubble-animation"),
  girl = $("girl"),
  girlWrap = $("girl-wrap"),
  scene = $("scene"),
  quote = $("quote"),
  menu = $("menu-button");
let state = null,
  rendererNotified = false,
  lastCollapsed = true,
  lastPreview = false,
  lastRevision = -1,
  press = false,
  pointer = null,
  dragging = false,
  ignore = false,
  alpha = null,
  bounds = null,
  lastImage = "",
  soundKey = "",
  soundBuffers = {},
  audioContext = null,
  source = null,
  motion = null,
  audio = null,
  audioAt = 0,
  lastFrame = performance.now(),
  artTime = 0,
  appearanceReady = false,
  grab = null,
  holdCursor = null,
  lastMusic = false,
  frameStats = { frames: 0, maxGap: 0 },
  currentPose = { x: 1, y: 1 },
  pressAnimation = null,
  bubbleHideTimer = null,
  quotaKey = '',
  quotaRows = [];
const bubblePath = new Path2D(
    "M 27,85 A 128,79 0 1 1 283,85 A 128,79 0 0 1 196,160 A 20,10 0 0 1 161,164 A 128,79 0 0 1 27,85 Z",
  ),
  hitCanvas = document.createElement("canvas"),
  hitContext = hitCanvas.getContext("2d");
const shapePublisher = new ShapePublisher((value) => window.gpt.shape(value));
const frameMonitor = new FrameStats();
let lastFrameReport = 0;
girlWrap.title = girl.title;
function box(element, value) {
  for (const k of ["left", "top", "width", "height"])
    if (value[k] !== undefined) element.style[k] = value[k] + "px";
}
function rootTransform() {
  root.style.transform = `scale(${(state?.layout.mirror ?? 1) * currentPose.x},${currentPose.y})`;
}
function animatePress(down) {
  press = down;
  pressAnimation?.cancel();
  const from = { ...currentPose },
    to = down ? { x: 1.05, y: 0.88 } : { x: 1, y: 1 },
    started = performance.now();
  let cancelled = false;
  pressAnimation = {
    cancel: () => {
      cancelled = true;
    },
  };
  function step(now) {
    if (cancelled) return;
    const t = Math.min(1, (now - started) / 220),
      ease = bezier(t, 0.34, 1.56, 0.64, 1);
    currentPose = {
      x: from.x + (to.x - from.x) * ease,
      y: from.y + (to.y - from.y) * ease,
    };
    rootTransform();
    if (t < 1) requestAnimationFrame(step);
  }
  requestAnimationFrame(step);
}
function bezier(t, x1, y1, x2, y2) {
  const curve = (v, a, b) =>
    3 * (1 - v) ** 2 * v * a + 3 * (1 - v) * v * v * b + v ** 3;
  let l = 0,
    h = 1,
    v = t;
  for (let n = 0; n < 20; n++) {
    v = (l + h) / 2;
    if (curve(v, x1, x2) < t) l = v;
    else h = v;
  }
  return curve(v, y1, y2);
}
function bubbleTransition(open) {
  clearTimeout(bubbleHideTimer);bubbleHideTimer=null;
  const entries = [
    [bubbleAnimation, open ? 260 : 100],
    [$("tail"), open ? 130 : 200],
    [$("tail-near"), open ? 0 : 300],
  ];
  for (const [el, delay] of entries) {
    el.getAnimations().forEach((a) => a.cancel());
    if (open) el.style.visibility = "visible";
    el.animate(
      open
        ? [
            { opacity: 0, scale: 0.7 },
            { opacity: 1, scale: 1 },
          ]
        : [
            { opacity: 1, scale: 1 },
            { opacity: 0, scale: 0.7 },
          ],
      {
        duration: open ? 200 : 180,
        delay,
        easing: "cubic-bezier(.25,.1,.25,1)",
        fill: "both",
      },
    );
  }
  scene.getAnimations().forEach(animation=>animation.cancel());
  scene.animate(
    open ? [{ opacity: 0 }, { opacity: 1 }] : [{ opacity: 1 }, { opacity: 0 }],
    { duration: open ? 160 : 160, delay: open ? 360 : 0, fill: "both" },
  );
  if (!open)
    bubbleHideTimer=setTimeout(() => {
      bubbleHideTimer=null;
      if (state?.scene.collapsed && !state.scene.preview)
        for (const [el] of entries) el.style.visibility = "hidden";
    }, 510);
}
function installImage(image) {
  if (!image || lastImage === image.url) return;
  lastImage = image.url;
  alpha=null;bounds=null;motion=null;grab=null;holdCursor=null;
  girl.onload = () => {
    const canvas = document.createElement("canvas");
    canvas.width = girl.naturalWidth;
    canvas.height = girl.naturalHeight;
    const ctx = canvas.getContext("2d", { willReadFrequently: true });
    ctx.drawImage(girl, 0, 0);
    alpha = ctx.getImageData(0, 0, canvas.width, canvas.height);
    girl.dataset.maskRevision=String(Number(girl.dataset.maskRevision??0)+1);
    const pixels=alphaBounds(alpha.data,canvas.width,canvas.height);
    if(!pixels){bounds=null;return;}
    const max = Math.max(canvas.width, canvas.height),
      ox = (max - canvas.width) / 2,
      oy = (max - canvas.height) / 2;
    bounds = {
      left: (ox + pixels.left) / max,
      top: (oy + pixels.top) / max,
      width: pixels.width / max,
      height: pixels.height / max,
      bottom: (oy + pixels.bottom) / max,
    };
    if (state) render(state);
    if(!rendererNotified){rendererNotified=true;void window.gpt.command('renderer-ready').catch(()=>{rendererNotified=false;});}
  };
  girl.src = image.url;
  $("girl-color").style.maskImage = `url("${image.url}")`;
}
async function preloadAudio(value) {
  const key = JSON.stringify(value);
  if (key === soundKey) return;
  soundKey = key;
  clickSounds.stop();soundBuffers={};
  if (!audioContext) audioContext = new AudioContext();
  const prepared = {},decoded=new Map();
  for (const slot of ["press", "release"])
    for (const preview of [false, true]) {
      const id = preview ? "preview-" + slot : slot;
      try {
        const data = (preview ? value.previewSlots : value.slots)?.[slot];
        if(data&&!decoded.has(data))decoded.set(data,audioContext.decodeAudioData(
          Uint8Array.from(atob(data.split(',')[1]),c=>c.charCodeAt(0)).buffer));
        prepared[id]=data?await decoded.get(data):null;
      } catch {
        prepared[id] = null;
      }
    }
  if (key !== soundKey) return;
  clickSounds.stop();
  soundBuffers = prepared;
}
const clickSounds = new ClickSequence({
  play: (id) => {
    try {
      if (audioContext.state === "suspended") void audioContext.resume().catch(()=>{});
      source = audioContext.createBufferSource();
      source.buffer = soundBuffers[id];
      const gain = audioContext.createGain();
      gain.gain.value = state.settings.soundVolume;
      source.connect(gain).connect(audioContext.destination);
      const active=source;
      active.onended=()=>{active.disconnect?.();gain.disconnect?.();if(source===active)source=null;active.onended=null;};
      source.start();
    } catch {}
  },
  stop: () => {
    try {
      const active=source;active?.stop();active?.onended?.();
    } catch {}
    source = null;
  },
  available: (id) => !!soundBuffers[id],
  duration: (id) => soundBuffers[id]?.duration ?? 0,
  enabled: () => state?.settings.soundOn && state.settings.soundVolume > 0,
});
function play(slot, preview = false) {
  if (preview) clickSounds.preview(slot);
  else if (slot === "press") clickSounds.press();
  else clickSounds.release();
}
const quoteFitCache = new Map();
const quoteMeasureContext=document.createElement('canvas').getContext('2d');
function fitQuote(text, profiles) {
  const profile = profiles?.quotes?.find(
      (q) =>
        q.text === text &&
        q.text.replace(/\s/g, "") === q.display.replace(/\s/g, ""),
    ),
    display = profile?.display ?? text;
  quote.textContent = display;
  quote.title = text;
  const ctx=quoteMeasureContext,measurements=new Map();let measuredSize=0;
  let best = quoteFitCache.get(display);
  function measure(size, width) {
    if(measuredSize!==size){ctx.font=`700 ${size}px "Microsoft YaHei UI"`;measuredSize=size;}
    let widths=measurements.get(size);if(!widths){widths=new Map();measurements.set(size,widths);}
    const textWidth=text=>{let value=widths.get(text);if(value===undefined){value=ctx.measureText(text).width;widths.set(text,value);}return value;};
    const lines = [];
    for (const para of display.split("\n")) {
      let line = "";
      for (const char of Array.from(para)) {
        if (line && textWidth(line + char) > width) {
          lines.push(line);
          line = char;
        } else line += char;
      }
      lines.push(line);
    }
    const h = lines.length * size * 1.15;
    if (h > 134) return null;
    const lineWidths = lines.map(textWidth),
      max = Math.max(...lineWidths),
      min = Math.min(...lineWidths);
    for (let i = 0; i < lines.length; i++) {
      const y =
        Math.abs((i - (lines.length - 1) / 2) * size * 1.15) + size * 0.43;
      if ((lineWidths[i] / 2) ** 2 / 116 ** 2 + (y * y) / 67 ** 2 > 1) return null;
    }
    if (display.includes("\n") && lines.length !== display.split("\n").length)
      return null;
    return {
      size,
      width,
      score:
        size * 10 -
        Math.max(0, lines.length - 2) * 26 -
        (lines.length - 1) * 8 -
        (max ? 1 - min / max : 0) * 55,
    };
  }
  if (!best && profile?.layout)
    best = measure(profile.layout.fontSize, profile.layout.width);
  if (!best)
    for (let size = 32; size >= 6; size--) {
      if (best && best.score > size * 10) break;
      for (let width = 236; width >= 140; width -= 8) {
        const candidate = measure(size, width);
        if (candidate && (!best || candidate.score > best.score))
          best = candidate;
      }
    }
  best ??= { size: 6, width: 236 };
  quoteFitCache.set(display, best);
  if (quoteFitCache.size > 200)
    quoteFitCache.delete(quoteFitCache.keys().next().value);
  scene.style.left = 155 - best.width / 2 + "px";
  scene.style.top = "18px";
  scene.style.width = best.width + "px";
  scene.style.height = "134px";
  quote.style.width = best.width + "px";
  quote.style.fontSize = best.size + "px";
}
function render(value) {
  const previousAudio=state?.audio;
  value = {
    ...state,
    ...value,
    audio: value.audio ?? state?.audio,
    quoteLayouts: value.quoteLayouts ?? state?.quoteLayouts,
  };
  if (state && (state.settings.soundOn !== value.settings.soundOn ||
      state.settings.soundVolume !== value.settings.soundVolume)) clickSounds.stop();
  if(pointer&&(value.temporary||value.blocked||!value.visible||(state&&state.music!==value.music)))cancelPointer();
  state = value;
  const l = value.layout;
  box(girlWrap, l.girl);
  box($("tail"), l.tail);
  box($("tail-near"), l.tailNear);
  box(menu, l.menu);
  box(bubble, l.bubble);
  bubble.style.transform = `scale(${l.bubble.scale})`;
  stage.style.transform = `scale(${window.innerWidth / 378})`;
  rootTransform();
  scene.style.transform = `scaleX(${l.mirror})`;
  menu.style.transform = `scaleX(${l.mirror})`;
  menu.classList.toggle("hidden", value.settings.hideMenu);
  document.body.classList.toggle("temporary", value.temporary);
  document.body.classList.toggle("paused", value.colors.paused);
  const shown = !value.scene.collapsed || value.scene.preview,
    wasShown = !lastCollapsed || lastPreview;
  if (shown !== wasShown) {
    bubbleTransition(shown);
  } else if (lastRevision < 0 && !shown) {
    for (const el of [bubbleAnimation, $("tail"), $("tail-near")])
      el.style.visibility = "hidden";
  }
  lastCollapsed = value.scene.collapsed;
  lastPreview = value.scene.preview;
  if (
    value.scene.revision !== lastRevision &&
    lastRevision >= 0 &&
    shown &&
    wasShown
  ) {
    scene.getAnimations().forEach((a) => a.cancel());
    scene.animate(
      [
        { opacity: 1, offset: 0 },
        { opacity: 0, offset: 120 / 280 },
        { opacity: 1, offset: 1 },
      ],
      { duration: 280, fill: "both" },
    );
  }
  const isQuote = value.scene.mode !== "quota";
  $("quota").style.display = isQuote ? "none" : "block";
  quote.style.display = isQuote ? "block" : "none";
  if (isQuote) {
    bubble.title = value.scene.text;
    if (lastRevision !== value.scene.revision)
      fitQuote(value.scene.text, value.quoteLayouts);
  } else {
    box(scene, { left: 63, top: 22, width: 184, height: 115 });
    const nextQuotaKey=JSON.stringify(value.quota);
    if(nextQuotaKey!==quotaKey){
    quotaKey=nextQuotaKey;
    $("header").textContent = value.quota.header;
    $("header").title = value.quota.headerTooltip;
    let index=0;
    for (const row of value.quota.rows) {
      if (!row.visible) continue;
      let element=quotaRows[index++];
      if(!element){element=document.createElement('div');quotaRows.push(element);
      element.className = "quota-row";
      element.innerHTML =
        '<div class="row-top"><span class="row-label"></span><span class="row-left"></span></div><div class="track"><div class="bar"></div></div><div class="reset"></div>';
      $("rows").append(element);}
      element.querySelector(".row-label").textContent = row.label;
      const left = element.querySelector(".row-left");
      left.textContent = row.leftText;
      left.style.color = row.valueColor;
      const bar = element.querySelector(".bar");
      bar.style.backgroundImage='';bar.classList.remove('flow-fill');
      bar.style.width = row.bar + "%";
      bar.style.background = row.barColor;
      const reset = element.querySelector(".reset");
      reset.textContent = row.resetText;
      reset.title = row.tooltip ?? "";
    }
    while(quotaRows.length>index)quotaRows.pop().remove();
    }
    bubble.title = value.quota.tooltip;
  }
  if (value.image) installImage(value.image);
  if (value.audio&&value.audio!==previousAudio) void preloadAudio(value.audio);
  applyColors(value);
  if (value.music && !motion && bounds) {
    startMusic();
  } else if (!value.music && lastMusic) {
    motion = null;
    holdCursor=null;grab=null;
    girlWrap.style.transform = "";
    $("under").getContext("2d").clearRect(0, 0, 700, 700);
    $("over").getContext("2d").clearRect(0, 0, 700, 700);
  }
  lastMusic = value.music;
  lastRevision = value.scene.revision;
  if (motion) musicLayout();
}
function girlHit(x, y) {
  if (!alpha) return false;
  const rect = girl.getBoundingClientRect();
  if (x < rect.left || x >= rect.right || y < rect.top || y >= rect.bottom)
    return false;
  const width = girl.clientWidth,
    height = girl.clientHeight,
    fit = Math.min(width / alpha.width, height / alpha.height);
  let localX = (x - rect.left)*width/rect.width;
  if (state.layout.mirror < 0) localX = width - localX;
  const px = Math.floor((localX - (width - alpha.width * fit) / 2) / fit),
    py = Math.floor(((y - rect.top)*height/rect.height - (height - alpha.height * fit) / 2) / fit);
  return (
    px >= 0 &&
    py >= 0 &&
    px < alpha.width &&
    py < alpha.height &&
    alpha.data[(py * alpha.width + px) * 4 + 3] > 10
  );
}
function bubbleHit(x, y) {
  if (state.scene.collapsed && !state.scene.preview) return false;
  const rect = bubbleAnimation.getBoundingClientRect(),
    localX = ((x - rect.left) * 350) / rect.width,
    localY = ((y - rect.top) * 239) / rect.height;
  if (
    hitContext.isPointInPath(
      bubblePath,
      state.layout.mirror < 0 ? 350 - localX : localX,
      localY,
    )
  )
    return true;
  return [$("tail"), $("tail-near")].some((el) => {
    const r = el.getBoundingClientRect();
    return (
      ((x - r.left - r.width / 2) / (r.width / 2)) ** 2 +
        ((y - r.top - r.height / 2) / (r.height / 2)) ** 2 <=
      1
    );
  });
}
function targetAt(x, y) {
  if (!state || state.temporary) return "";
  const rect = menu.getBoundingClientRect();
  if (
    !state.settings.hideMenu &&
    document.body.classList.contains("hover") &&
    x >= rect.left &&
    x <= rect.right &&
    y >= rect.top &&
    y <= rect.bottom
  )
    return "menu";
  const refresh = $("refresh").getBoundingClientRect();
  if (
    !state.scene.collapsed &&
    state.scene.mode === "quota" &&
    x >= refresh.left &&
    x <= refresh.right &&
    y >= refresh.top &&
    y <= refresh.bottom
  )
    return "refresh";
  if (bubbleHit(x, y)) return "bubble";
  return girlHit(x, y) ? "role" : "";
}
let hoverTimer = null;
function setHover(visible) {
  if (visible) {
    clearTimeout(hoverTimer);
    hoverTimer = null;
    document.body.classList.add("hover");
  } else if (hoverTimer === null)
    hoverTimer = setTimeout(() => {
      hoverTimer = null;
      document.body.classList.remove("hover");
    }, 180);
}
function hitUpdate(event) {
  if (!state) return;
  const target = targetAt(event.clientX, event.clientY),
    inside = !!target || !!pointer;
  setHover(!!target || !!pointer);
  if (inside !== ignore) {
    ignore = inside;
    window.gpt.hit(inside);
  }
  return target;
}
document.addEventListener("pointermove", (event) => {
  if(pointer&&event.pointerId!==pointer.id)return;
  hitUpdate(event);
  if (pointer?.target === "role")
    window.gpt.drag({ op: "move", x: event.screenX, y: event.screenY,id:pointer.id });
});
document.addEventListener("pointerdown", (event) => {
  if(pointer)return;
  const target = hitUpdate(event);
  if (!target) return;
  if (event.button === 2) {
    event.preventDefault();
    void window.gpt.command("menu");
    return;
  }
  if (event.button !== 0) return;
  pointer = { x: event.screenX, y: event.screenY, target, id: event.pointerId };
  event.target.setPointerCapture(event.pointerId);
  if (target === "role") {
    holdCursor=null;
    window.gpt.drag({ op: "arm", x: event.screenX, y: event.screenY,id:pointer.id });
    if (motion) {
      const id = pointer.id,heldMotion=motion;
      void window.gpt.pointer().then((p) => {
        if (pointer?.id === id && motion===heldMotion&&!motion.Held&&state.music&&p?.cursor) beginHold(p.cursor);
      }).catch(()=>{if(pointer?.id===id)cancelPointer();});
    } else animatePress(true);
    play("press");
  }
});
document.addEventListener("pointerup", (event) => {
  if (!pointer || event.pointerId !== pointer.id) return;
  const saved = pointer;
  pointer = null;
  if (saved.target === "role") {
    if (motion) {
      motion.release();
      grab = null;
      holdCursor=null;
    } else animatePress(false);
    play("release");
    window.gpt.drag({ op: "end" });
  } else if(targetAt(event.clientX,event.clientY)===saved.target)
    void window.gpt.command(
      saved.target === "menu"
        ? "menu"
        : saved.target === "refresh"
          ? "refresh"
          : saved.target,
    );
  hitUpdate(event);
});
function cancelPointer(event) {
  if (!pointer||(event&&event.pointerId!==pointer.id)) return;
  pointer = null;
  animatePress(false);
  clickSounds.stop();
  if (motion?.Held) motion.release();
  grab=null;
  holdCursor=null;
  dragging = false;
  window.gpt.drag({ op: "cancel" });
}
document.addEventListener('lostpointercapture',cancelPointer);
document.addEventListener('pointercancel',cancelPointer);
window.addEventListener('blur',()=>cancelPointer());
document.addEventListener('visibilitychange',()=>{if(document.hidden)cancelPointer();});
document.addEventListener("contextmenu", (event) => event.preventDefault());
document.addEventListener("pointerleave", () => {
  if (!pointer) {
    setHover(false);
    ignore = false;
    window.gpt.hit(false);
  }
});
function musicLayout() {
  if (!motion || !bounds) return;
  const g = state.layout.girl,
    alphaWidth = g.width * bounds.width,
    alphaHeight = g.height * bounds.height;
  girlWrap.style.left = 175 - g.width * (bounds.left + bounds.width / 2) + "px";
  girlWrap.style.top = 350 - g.height * bounds.bottom + "px";
  girlWrap.style.transformOrigin = `${g.width * (bounds.left + bounds.width / 2)}px ${g.height * bounds.bottom}px`;
  girlWrap.style.transform = `scaleY(${1 - motion.Bend})`;
  return {
    width: alphaWidth,
    height: alphaHeight,
    rect: {
      left: parseFloat(girlWrap.style.left),
      top: parseFloat(girlWrap.style.top),
      width: g.width,
      height: g.height,
    },
  };
}
function startMusic() {
  if (!bounds || !state.frame || !state.normal) return;
  const g = state.layout.girl,
    f = state.layout.display * state.dpi,
    alphaWidth = g.width * bounds.width * f,
    footX =
      state.layout.mirror > 0
        ? g.left + g.width * (bounds.left + bounds.width / 2)
        : 350 - g.left - g.width * (bounds.left + bounds.width / 2),
    footY = g.top + g.height * bounds.bottom;
  motion = new MusicMotion(
    (state.position?.left ?? state.normal.x) -
      state.frame.left +
      (14 + footX) * f,
    (state.position?.top ?? state.normal.y) -
      state.frame.top +
      (14 + footY) * f,
    state.frame.width,
    state.frame.height,
    alphaWidth,
    state.dpi,
  );
  motion.FigureHeight = g.height * bounds.height * f;
  appearanceReady = false;
  artTime = 0;
  lastFrame = performance.now();
}
function beginHold(point) {
  holdCursor=point;
  const f = state.frame;
  grab = {
    x: motion.X - (point.x - f.left),
    y:
      motion.Y -
      (point.y - f.top) -
      Math.min(52 * state.dpi, motion.FigureWidth * 0.45),
    at: performance.now(),
  };
  motion.beginHold(point.x, point.y);
}
function moveHold(point) {
  if (!grab) return;
  const now = performance.now(),
    dt = clamp((now - grab.at) / 1000, 0, 0.12);
  grab.at = now;
  motion.moveHeld(
    point.x - state.frame.left + grab.x,
    point.y - state.frame.top + grab.y,
    dt,
    point.x,
    point.y,
  );
}
function animation(now) {
  const elapsed = Math.max(0, (now - lastFrame) / 1000);
  lastFrame = now;
  frameMonitor.sample(now, !!state?.visible && !state.blocked);
  if (now - lastFrameReport >= 1000) {
    lastFrameReport = now;
    window.gpt.performance(frameMonitor.read());
  }
  if (motion && state?.music) {
    const a = audio && now - audioAt < 250 ? audio.snapshot : {},
      nativeNow = audio ? audio.nowMs + (now - audioAt) : 0,
      locked = a.RhythmLocked && a.PeriodMs > 0,
      phase = locked ? 1 + (nativeNow - a.NextBeatAtMs) / a.PeriodMs : 0,
      paused =
        !state.visible ||
        state.blocked ||
        state.temporary ||
        (!state.scene.collapsed && !motion.Held && motion.Phase >= 2);
    const g = state.layout.girl,
      f = state.layout.display * state.dpi,
      figure = g.width * bounds.width * f;
    if (
      Math.abs(motion.Width - state.frame.width) > 0.5 ||
      Math.abs(motion.Floor - state.frame.height) > 0.5 ||
      Math.abs(motion.FigureWidth - figure) > 0.5
    )
      motion.resize(state.frame.width, state.frame.height, figure, state.dpi);
    const cursor=holdCursor??audio?.cursor;
    if (motion.Held && !paused && cursor) moveHold(cursor);
    motion.step(
      Math.min(0.12, elapsed),
      paused,
      locked,
      phase,
      (a.PeriodMs ?? 0) / 1000,
      1,
      elapsed,
    );
    if (!paused && !locked && a.SourceProcessId && a.Sequence > 0)
      motion.respondToOnset((nativeNow - a.BeatAtMs) / 1000, a.Strength);
    if (motion.Props >= 1) appearanceReady = true;
    const shape = musicLayout();
    if (!paused && (motion.Energy > 0.005 || motion.Pulse > 0.005))
      artTime += Math.min(0.12, elapsed) * (0.3 + 0.7 * motion.Energy);
    // Decorative speakers are painted on the click-through room surface below the character.
    drawOver(
      $("over"),
      motion,
      shape,
      state.settings.characterId === "gpt-dragon",
      appearanceReady,
    );
    if (!paused) {
      const x = motion.X - (14 + 175) * f,
        y = motion.Y - (14 + 350) * f;
      window.gpt.music({
        x,
        y,
        motion: {
          X: motion.X,
          Y: motion.Y,
          Bend: motion.Bend,
          Rock: motion.Rock,
          RockSpeed: motion.RockSpeed,
          Lamp: motion.Lamp,
          Cycle: motion.Cycle,
          Energy: motion.Energy,
          Pulse: motion.Pulse,
          Props: motion.Props,
          Held: motion.Held,
          Phase: motion.Phase,
          Impacts: motion.Impacts,
          Vx: motion.Vx,
          Vy: motion.Vy,
        },
        artTime,
        figure: {
          width: shape.width,
          height: shape.height,
          display: state.layout.display,
          mirror: state.layout.mirror,
        },
        paused,
        audio: a,
      });
    }
    frameStats.frames++;
    frameStats.maxGap = Math.max(frameStats.maxGap, elapsed * 1000);
  }
  shapePublisher.update(state, girl);
  requestAnimationFrame(animation);
}
window.gpt.onState(render);
window.gpt.onGeometry((value) => {
  if(!state)return;
  if(value.layout&&JSON.stringify(value.layout)!==JSON.stringify(state.layout))render({...state,...value,image:null,audio:null});
  else state={...state,...value,image:null};
});
window.addEventListener("resize", () => {
  stage.style.transform = `scale(${window.innerWidth / 378})`;
});
window.gpt.onAudio((value) => {
  if (value.preview) play(value.preview, true);
  else {
    audio = value;
    audioAt = performance.now();
  }
});
window.gpt.onPointer?.(value=>{
  if(pointer?.target!=='role'||pointer.id!==value?.id||!motion||!state?.music||!Number.isFinite(value?.cursor?.x)||!Number.isFinite(value?.cursor?.y))return;
  holdCursor=value.cursor;
  if(value.start&&!motion.Held)beginHold(value.cursor);
});
render(await window.gpt.ready());
requestAnimationFrame(animation);
window.widgetVerification = () => ({
  ok: !!state && girl.complete && girl.naturalWidth > 0 && !!alpha,
  image: { width: girl.naturalWidth, height: girl.naturalHeight },
  scene: state.scene,
  layout: state.layout,
  quota: state.quota,
  frameStats,
  frameTiming: frameMonitor.read(),
  bounds,
  motion:motion?{Held:motion.Held,X:motion.X,Y:motion.Y,FigureWidth:motion.FigureWidth,FigureHeight:motion.FigureHeight}:null,
  audio: {
    context: audioContext?.state,
    press: !!soundBuffers.press,
    release: !!soundBuffers.release,
    pressDuration: soundBuffers.press?.duration,
    releaseDuration: soundBuffers.release?.duration,
  },
  settings: state.settings,
  powerShell: false,
});
