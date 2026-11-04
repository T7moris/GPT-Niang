export function buildGallery({ el, button, command }, state) {
  const header = el("div");
  header.className = "gallery-header";
  el("h2", "选择你喜欢的形象", header);
  button("×", "close-panel", undefined, header).setAttribute(
    "aria-label",
    "关闭形象图库",
  );
  if(state.notice)el('p',state.notice).className='hint';
  const gallery = el("div");
  gallery.className = "gallery";
  for (const c of state.characters) {
    const card = el("div", undefined, gallery);
    card.className = "card" + (state.selected === c.id ? " selected" : "");
    card.dataset.focusKey='character:'+c.id;
    card.tabIndex = c.url ? 0 : -1;
    card.setAttribute("aria-disabled", String(!c.url));
    card.setAttribute("role", "button");
    card.setAttribute(
      "aria-label",
      c.name + (state.selected === c.id ? "，当前使用" : ""),
    );
    card.onclick = () => c.url && command("character-select", c.id);
    card.onkeydown = (event) => {
      if(event.target!==card)return;
      if (c.url && (event.key === "Enter" || event.key === " ")) {
        event.preventDefault();
        void command("character-select", c.id);
      }
    };
    const image = el("img", undefined, card);
    if (c.url) image.src = c.url;
    image.alt = "";
    el("strong", c.name, card);
    el(
      "small",
      !c.url
        ? "图片无法读取，请重新导入"
        : state.selected === c.id
          ? "✓ 当前使用"
          : c.kind === "custom"
            ? "我的导入"
            : "内置角色",
      card,
    );
    if (c.kind === "custom") {
      const remove = button("−", "character-remove", c.id, card);
      remove.className = "remove";
      remove.setAttribute("aria-label", "移除 " + c.name);
      remove.onclick = (event) => {
        event.stopPropagation();
        void command("character-remove", c.id);
      };
    }
  }
  const add = el("button", undefined, gallery);
  add.className = "card add-card";
  add.dataset.action='character-import';add.dataset.focusKey='action:character-import:null';
  add.onclick = () => command("character-import");
  add.setAttribute("aria-label", "添加形象");
  el("b", "+", add);
  el("strong", "添加形象", add);
  const footer = el("div");
  footer.className = "gallery-footer";
  el("span", "添加新形象时，推荐使用透明背景 PNG。", footer);
  const latest = state.removed
    .toSorted((a, b) => new Date(a.removedAt) - new Date(b.removedAt))
    .at(-1);
  if (latest) button("撤销移除", "character-restore", latest.id, footer);
}
