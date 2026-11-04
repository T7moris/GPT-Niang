export const clamp = (x, min, max) => Math.max(min, Math.min(max, x));
export function layout(settings) {
  const display = Math.max(settings.scale, settings.bubbleScale),
    c = settings.scale / display,
    b = settings.bubbleScale / display;
  const girl = {
    left: 350 - 208 * c,
    top: 350 - 208 * c,
    width: 208 * c,
    height: 208 * c,
  };
  return {
    display,
    size: 378 * display,
    girl,
    bubble: {
      left: clamp(girl.left + 104 * c - 246 * b, 0, 350 - 350 * b),
      top: clamp(girl.top - 142 * b, 0, 350 - 239 * b),
      scale: b,
    },
    tail: {
      left: girl.left - 34 * c,
      top: girl.top + 40 * c,
      width: 25 * c,
      height: 18 * c,
    },
    tailNear: {
      left: girl.left,
      top: girl.top + 72 * c,
      width: 17 * c,
      height: 12 * c,
    },
    menu: {
      left: 350 - 30 * c,
      top: girl.top + 20 * c,
      width: 24 * c,
      height: 24 * c,
    },
    mirror: settings.side === "left" ? -1 : 1,
  };
}
export function resizeAnchors(before, after) {
  const next = { ...after },
    oldDisplay = layout(before).display,
    ratio = layout(after).display / oldDisplay;
  if (before.followHost && after.followHost && Math.abs(ratio - 1) > 0.001)
    for (const key of ["left", "right", "bottom"])
      if (next[key] < 0)
        next[key] = Math.round(next[key] * ratio * 1000) / 1000;
  return next;
}
export function placement(frame, s, dpi = 1) {
  const l = layout(s),
    size = l.size * dpi;
  return constrainToFrame(
    frame,
    s,
    {
      x: Math.round(
        s.anchor === "right"
          ? frame.right - size - s.right * dpi
          : frame.left +
              (s.left ??
                Math.max(
                  0,
                  (frame.right - frame.left - size) / dpi - s.right,
                )) *
                dpi,
      ),
      y: Math.round(frame.bottom - size - s.bottom * dpi),
      size: Math.round(size),
    },
    dpi,
  );
}
export function constrainToFrame(frame, s, position, dpi = 1) {
  const l = layout(s),
    g = l.girl,
    f = l.display * dpi,
    left = s.side === "left" ? 350 - g.left - g.width : g.left,
    minX = frame.left - (14 + left) * f,
    maxX = frame.right - (14 + left + g.width) * f;
  return {
    ...position,
    x: Math.round(
      maxX < minX ? (minX + maxX) / 2 : clamp(position.x, minX, maxX),
    ),
    y: Math.round(
      Math.max(
        frame.top - (14 + g.top) * f,
        Math.min(frame.bottom - (14 + g.top + g.height) * f, position.y),
      ),
    ),
  };
}
export function dragPlacement(
  frame,
  s,
  x,
  y,
  dpi = 1,
  cursorX = x + (layout(s).size * dpi) / 2,
  display = layout(s).display,
) {
  const l = layout(s),
    g = l.girl,
    f = display * dpi;
  const middle = frame.left + (frame.right - frame.left) / 2,
    side = cursorX < middle ? "left" : "right";
  const left = side === "left" ? 350 - g.left - g.width : g.left;
  const gx = (14 + left) * f,
    gy = (14 + g.top) * f;
  x = Math.round(
    clamp(
      x,
      frame.left - gx,
      Math.max(frame.left - gx, frame.right - gx - g.width * f),
    ),
  );
  y = Math.round(
    clamp(
      y,
      frame.top - gy,
      Math.max(frame.top - gy, frame.bottom - gy - g.height * f),
    ),
  );
  return {
    x,
    y,
    side,
    left: (x - frame.left) / dpi,
    right: (frame.right - x - 378 * display * dpi) / dpi,
    bottom: (frame.bottom - y - 378 * display * dpi) / dpi,
    anchor: "free",
  };
}
export function snapPlacement(settings) {
  if (settings.side === "left" && settings.left >= 0 && settings.left <= 18)
    return { ...settings, anchor: "left", left: 0 };
  if (settings.side === "right" && settings.right >= 0 && settings.right <= 18)
    return { ...settings, anchor: "right", right: 0 };
  return settings;
}
