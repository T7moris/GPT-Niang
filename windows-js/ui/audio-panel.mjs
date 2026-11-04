export function buildAudio(
  { el, button, check, slider, radio, command },
  state,
) {
  el("h2", "点击音效");
  el("p", "按下和松开可以分别选择 WAV 文件，每段最长 5 秒。");
  check("点击音效", "soundOn");
  slider("音量", "soundVolume", 0, 1, 0.1, document.getElementById("panel"));
  const modes = el("div");
  modes.className = "audio-modes";
  radio(
    "内置音效",
    state.audio.mode === "builtin",
    () => command("audio-mode", "builtin"),
    modes,
  );
  radio(
    "自定义音效",
    state.audio.mode === "custom",
    () => command("audio-mode", "custom"),
    modes,
  );
  for (const [slot, label] of [
    ["press", "按下音效"],
    ["release", "松开音效"],
  ]) {
    const card = el("section");
    card.className = "audio-slot";
    el("strong", label, card);
    const file=el("p", state.audio[slot]?.name ?? "未选择自定义音效", card);
    if(state.audio[slot]?.name)file.title=state.audio[slot].name;
    if (state.audio.errors?.[slot]) {
      const error=el("p", state.audio.errors[slot], card);
      error.className='audio-error';error.setAttribute('role','alert');
    }
    const actions = el("div", undefined, card);
    actions.className = "audio-actions";
    button("选择 WAV…", "audio-import", slot, actions);
    const preview = button("试听", "audio-preview", slot, actions);
    preview.disabled =
      !state.audio[slot] ||
      !!state.audio.errors?.[slot] ||
      !state.settings.soundOn ||
      state.settings.soundVolume <= 0;
    button("设为无声", "audio-clear", slot, actions);
  }
  const actions = el("div");
  actions.className = "actions";
  button("完成", "close-panel", undefined, actions);
  if (state.audio.loadError) {
    const error=el("p",state.audio.loadError);error.className='audio-error';error.setAttribute('role','alert');
  }
}
