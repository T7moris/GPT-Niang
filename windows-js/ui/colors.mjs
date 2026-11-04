import { palettes } from "../src/core/colors.mjs";
const mix = (hex, other, amount) =>
  "#" +
  [1, 3, 5]
    .map((n) =>
      Math.round(
        parseInt(hex.slice(n, n + 2), 16) * (1 - amount) +
          parseInt(other.slice(n, n + 2), 16) * amount,
      )
        .toString(16)
        .padStart(2, "0"),
    )
    .join("");
export function colorRoles(palette) {
  return {
    accent: palette,
    ink: palette.map((c) => mix(c, "#271938", 0.44)),
    surface: palette.map((c) => mix(c, "#ffffff", 0.92)),
  };
}
export function applyColors(state) {
  const scope = state.music
      ? state.musicColor
        ? "full"
        : "none"
      : state.colors.scope,
    roles = colorRoles(state.music ? palettes.rainbow : state.colors.palette),
    gradient = (colors) => "linear-gradient(90deg," + colors.join(",") + ")";
  const svg = document.querySelector("#bubble svg"),
    defs = svg.querySelector("defs");
  for (const [role, colors] of Object.entries(roles)) {
    let target = document.getElementById("flow-" + role);
    if (!target) {
      target = document.createElementNS(
        "http://www.w3.org/2000/svg",
        "linearGradient",
      );
      target.id = "flow-" + role;
      target.setAttribute("spreadMethod", "repeat");
      const move = document.createElementNS(
        "http://www.w3.org/2000/svg",
        "animateTransform",
      );
      for (const [k, v] of Object.entries({
        attributeName: "gradientTransform",
        type: "translate",
        from: "0 0",
        to: "-1 0",
        dur: "2.6s",
        repeatCount: "indefinite",
      }))
        move.setAttribute(k, v);
      target.append(move);
      colors.forEach((c, i) => {
        const stop = document.createElementNS(
          "http://www.w3.org/2000/svg",
          "stop",
        );
        stop.setAttribute("offset", String(i / (colors.length - 1)));
        target.append(stop);
      });
      defs.append(target);
    }
    target
      .querySelectorAll("stop")
      .forEach((stop, i) => stop.setAttribute("stop-color", colors[i]));
  }
  if (state.colors.paused) svg.pauseAnimations();
  else svg.unpauseAnimations();
  const full = scope === "full" && !state.music,
    shape = document.getElementById("bubble-shape");
  shape.setAttribute("stroke", full ? "url(#flow-accent)" : "#745A98");
  shape.setAttribute("fill", full ? "url(#flow-surface)" : "#fff");
  for (const id of ["tail", "tail-near"]) {
    const tail = document.getElementById(id);
    tail.style.borderColor = full ? "transparent" : "#745A98";
    tail.style.background = full
      ? gradient(roles.surface) +
        " padding-box, " +
        gradient(roles.accent) +
        " border-box"
      : "#fff";
    tail.classList.toggle("flow-fill", full);
  }
  for (const node of document.querySelectorAll(
    "#quote,#header,#refresh,.row-left",
  )) {
    const active =
      node.id === "quote"
        ? scope !== "none"
        : full &&
          (!node.classList.contains("row-left") ||
            node.style.color === "rgb(116, 90, 152)");
    node.classList.toggle("flow-text", active);
    node.style.backgroundImage = active ? gradient(roles.ink) : "";
  }
  for (const bar of document.querySelectorAll(".bar")){
    const active=full&&bar.style.backgroundColor==='rgb(155, 134, 193)';
    bar.style.backgroundImage=active?gradient(roles.accent):'';
    bar.classList.toggle('flow-fill',active);
  }
  const tint = document.getElementById("girl-color");
  tint.style.backgroundImage = gradient(roles.accent);
  tint.style.display = scope === "full" ? "block" : "none";
  tint.style.opacity = state.music ? ".27" : ".34";
  document.getElementById("menu-button").style.background = full
    ? gradient(roles.surface)
    : "#EDE7F6";
}
