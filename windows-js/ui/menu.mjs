let intervalDraft = null, intervalDirty = false, intervalSaved = null;
export function buildMenu(
  { el, button, check, section, slider, radio, command },
  state,
  panel,
) {
  const header = el("div");
  header.className = "menu-heading";
  el("strong", "GPT 娘", header);
  el("span", state.settings.followHost ? "跟随 Codex" : "桌面模式", header);
  const quick = el("div");
  quick.className = "quick-actions";
  button(
    !state.scene.collapsed && state.scene.mode === "quota"
      ? "收起额度"
      : "查看额度",
    "quota",
    undefined,
    quick,
  );
  button("换一句台词", "quote", undefined, quick);
  const music = button(
    state.music ? "关闭律动" : "音乐律动",
    "music",
    !state.music,
    quick,
  );
  music.classList.toggle("active", state.music);
  music.setAttribute("aria-pressed", String(state.music));
  button("刷新额度", "refresh-menu", undefined, quick);
  button('用量与记账…','usage',undefined,quick);
  el("hr");
  const appearance = section("形象与大小");
  button("更换形象…", "characters", undefined, appearance);
  const presets = el("div", undefined, appearance);
  presets.className = "size-presets";
  for (const [name, scale] of [
    ["小", 0.8],
    ["标准", 1],
    ["大", 1.4],
  ]) {
    const b = button(name, "settings", { scale }, presets);
    b.classList.toggle(
      "selected",
      Math.abs(state.settings.scale - scale) < 0.001,
    );
  }
  slider("人物大小", "scale", 0.6, 2.5, 0.1, appearance);
  slider("气泡大小", "bubbleScale", 0.6, 2.5, 0.1, appearance);
  check("隐藏设置按钮", "hideMenu", appearance);
  el("div", "隐藏后仍可右键角色打开设置。", appearance).className = "hint";
  const sound = section("声音与点击");
  check("点击音效", "soundOn", sound);
  slider("音量", "soundVolume", 0, 1, 0.1, sound);
  button("自定义音效…", "audio", undefined, sound);
  el("hr", undefined, sound);
  check("点角色也切换内容", "bubbleTapAdvance", sound);
  el("div", "开启后依次切换：额度 → 语录 → 收起。", sound).className = "hint";
  check('点角色连续换语录', 'characterQuoteRepeat', sound);
  el('div', '开启后优先使用：首次查看额度，之后连续换语录；点气泡仍可收起。', sound).className = 'hint';
  const position = section("显示与位置");
  radio(
    "仅在 Codex 窗口内",
    state.settings.followHost,
    () => command("settings", { followHost: true }),
    position,
  );
  radio(
    "整个桌面自由拖动",
    !state.settings.followHost,
    () => command("settings", { followHost: false }),
    position,
  );
  if (!state.settings.followHost) check("始终置顶", "desktopTopmost", position);
  el("hr", undefined, position);
  button("恢复右下角位置", "reset-position", undefined, position);
  const quotes = section("语录与提醒");
  button("编辑我的语录…", "quotes", undefined, quotes);
  el("hr", undefined, quotes);
  check("开启自动语录", "autoQuoteEnabled", quotes);
  const intervals = el("div", undefined, quotes);
  intervals.className = "intervals";
  for (const [name, seconds] of [
    ["1 分钟", 60],
    ["5 分钟", 300],
    ["15 分钟", 900],
  ])
    radio(
      name,
      state.settings.autoQuoteIntervalSeconds === seconds,
      () => command("settings", { autoQuoteIntervalSeconds: seconds }),
      intervals,
    );
  if(!intervalDraft || !intervalDirty && intervalSaved!==state.settings.autoQuoteIntervalSeconds){
    const seconds=state.settings.autoQuoteIntervalSeconds;
    const unit=seconds%3600===0?'hours':seconds%60===0?'minutes':'seconds';
    intervalDraft={raw:String(seconds/({hours:3600,minutes:60,seconds:1}[unit])),unit};
    intervalSaved=seconds;
  }
  const custom=el('div',undefined,quotes);custom.className='auto-quote-custom';
  const intervalLabel=el('label','自定义间隔',custom),value=el('input',undefined,intervalLabel);
  value.type='text';value.inputMode='decimal';value.maxLength=12;value.value=intervalDraft.raw;
  value.dataset.focusKey='auto-quote:value';value.setAttribute('aria-label','自动语录自定义间隔');
  value.oninput=event=>{intervalDraft.raw=event.currentTarget.value;intervalDirty=true;};
  const unit=el('select',undefined,custom);unit.dataset.focusKey='auto-quote:unit';unit.setAttribute('aria-label','自动语录时间单位');
  for(const [id,name]of [['seconds','秒'],['minutes','分钟'],['hours','小时']]){const option=el('option',name,unit);option.value=id;}
  unit.value=intervalDraft.unit;
  unit.onchange=event=>{intervalDraft.unit=event.currentTarget.value;intervalDirty=true;};
  const apply=button('应用间隔','auto-quote-interval',undefined,custom);
  apply.onclick=async()=>{const submitted={...intervalDraft},result=await command('auto-quote-interval',submitted);if(result&&JSON.stringify(submitted)===JSON.stringify(intervalDraft))intervalDirty=false;};
  el('div','支持 10 秒至 24 小时，也可输入 1.5 分钟等小数。',quotes).className='hint';
  el("div", "仅在挂件可见且空闲时显示。", quotes).className = "hint";
  el("hr", undefined, quotes);
  check("回答结束提醒", "taskCompletionBubble", quotes);
  const update = section("版本与更新");
  el("div", "当前版本 " + state.version, update).className = "hint";
  const updating=['checking','downloading','preparing','installing'].includes(state.update.status);
  const updateButton=button(updating?'正在处理更新…':"检查并更新", "update-check", undefined, update);
  updateButton.disabled=updating;
  const label = el("label", undefined, update);
  label.className = "control";
  const input = el("input", undefined, label);
  input.type = "checkbox";
  input.dataset.focusKey='setting:updateAutomatic';
  input.checked = state.update.automatic !== false;
  el("span", "自动更新", label);
  input.onchange = () => command("update-automatic", input.checked);
  const updateStatus=el("div", state.update.message ?? "尚未检查更新", update);
  updateStatus.className='hint update-status';updateStatus.dataset.status=state.update.status??'idle';
  el("hr");
  const footer=el('div');footer.className='menu-footer';
  const restart=button(state.restarting?'正在重启…':'重启 GPT 娘','restart',undefined,footer);
  restart.disabled=state.restarting===true||updating;
  const exit = button("退出 GPT 娘", "exit",undefined,footer);
  exit.className = "exit-action";
  const shortcut=el('span',undefined,footer);shortcut.className='shortcut-hint';
  el('kbd','Esc',shortcut);el('span','关闭',shortcut);
}
