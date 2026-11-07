import { buildMenu } from "./menu.mjs";
import { buildGallery } from "./gallery.mjs";
import { buildAudio } from "./audio-panel.mjs";
import {buildUsage} from './usage-panel.mjs';
const panel = document.getElementById("panel"),
  feedback = document.getElementById("feedback");
let state = await window.gpt.ready();
const kind = state.kind;
let busy=state.busy===true;
const busyDisabled=new Map();
const busyCards=new Map();
const editorActions=new Set(['quotes-save','quotes-reset','colors-save']);
let editorSaving=false,editorRevision=0,editorDraft=state.lines??'';
let mount=panel;
let keyboardNavigation=false,pointerPoint=null;
const groupOpeners=new WeakMap();
let hoverTimer=null,hoverTarget=null;
function clearHover(){clearTimeout(hoverTimer);hoverTimer=null;hoverTarget=null;}
let sliding = false,
  activeSlider = null,
  lastMenuHit = null,
  radioGroup = 0;
document.body.classList.toggle("menu", kind === "menu");
document.body.classList.toggle("characters", kind === "characters");
document.body.classList.toggle("editor", kind === "quotes" || kind === "colors");
document.body.classList.toggle('usage',kind==='usage');
const el = (tag, text, parent = mount) => {
  const element = document.createElement(tag);
  if (text !== undefined) element.textContent = text;
  parent.append(element);
  return element;
};
function notify(name,value){void window.gpt.command(name,value).catch(()=>{});}
async function command(name, value) {
  if(busy&&name!=='close-panel'){feedback.textContent='正在处理上一个文件，请稍候。';return null;}
  const editing=editorActions.has(name),revision=editorRevision;
  if(editing&&editorSaving)return null;
  if(editing){editorSaving=true;applyBusy();}
  feedback.textContent='';
  try{
  const result=await window.gpt.command(name,value);
  if (!result?.ok) {
    feedback.textContent = result?.error ?? "操作未完成";
    if((kind==='menu'||kind==='audio')&&!sliding){state=await window.gpt.ready();render();}
    return null;
  }
  if (result.close) {
    notify('close-panel');
    return result;
  }
  if (result.state) {
    if(editing&&revision===editorRevision&&typeof result.state.lines==='string')editorDraft=result.state.lines;
    state = result.state;
    if (!sliding) render();
  } else if (kind === "menu" || kind === "audio") {
    if (
      [
        "quota",
        "quote",
        "refresh-menu",
        "audio-import",
        "audio-preview",
      ].includes(name) &&
      kind === "menu"
    ) {
      notify('close-panel');
      return result;
    }
    state = await window.gpt.ready();
    if (!sliding) render();
  }
  return result;
  }catch(error){feedback.textContent=error?.message??'操作未完成';return null;}
  finally{if(editing){editorSaving=false;applyBusy();}}
}
function button(text, name, value, parent = mount) {
  const b = el("button", text, parent);
  b.dataset.action=name;b.dataset.focusKey='action:'+name+(name==='music'?'':':'+JSON.stringify(value??null));
  b.onclick = () => command(name, value);
  return b;
}
function check(text, key, parent = mount) {
  const label = el("label", undefined, parent);
  label.className = "control";
  const input = el("input", undefined, label);
  input.type = "checkbox";
  input.dataset.focusKey='setting:'+key;
  input.checked = state.settings[key];
  el("span", text, label);
  input.onchange = () => command("settings", { [key]: input.checked });
  return input;
}
function section(text, parent = mount) {
  const details = el("details", undefined, parent);
  details.dataset.key = text;
  const summary = el("summary", text, details);
  summary.dataset.focusKey='group:'+text;
  summary.dataset.icon=({'形象与大小':'appearance','声音与点击':'sound','显示与位置':'position','语录与提醒':'quotes','版本与更新':'update'})[text]??'';
  summary.setAttribute('aria-label',text);
  const content = el("div", undefined, details);
  content.className = "flyout";
  el('div',text,content).className='flyout-heading';
  const openGroup = () => {
    clearHover();
    if (sliding) return;
    for (const sibling of Array.from(details.parentElement?.children??[]))
      if (sibling.tagName === "DETAILS" && sibling !== details)
        sibling.open = false;
    details.open = true;
    positionFlyouts();
  };
  const hoverGroup=()=>{
    if(sliding||keyboardNavigation||details.open)return;
    clearHover();hoverTarget=details;
    hoverTimer=setTimeout(()=>{hoverTimer=null;hoverTarget=null;if(details.isConnected&&!keyboardNavigation&&!sliding)openGroup();},130);
  };
  groupOpeners.set(details,hoverGroup);
  details.addEventListener("mouseenter", event=>{pointerPoint??={x:event.clientX,y:event.clientY};hoverGroup();});
  details.addEventListener('mouseleave',()=>{if(hoverTarget===details)clearHover();});
  summary.addEventListener("click", (event) => {
    event.preventDefault();
    openGroup();
  });
  details.addEventListener("toggle", () => {
    if (details.open) positionFlyouts();
  });
  if (state.verificationSection === text) details.open = true;
  return content;
}
function slider(text, key, min, max, step, parent) {
  const label = el("label", text, parent);
  label.className = "slider";
  el("span", Math.round(state.settings[key] * 100) + "%", label);
  const input = el("input", undefined, label);
  input.type = "range";
  input.dataset.setting = key;
  input.dataset.focusKey='setting:'+key;
  Object.assign(input, { min, max, step, value: state.settings[key] });
  input.setAttribute('aria-label',text);
  const describeValue=()=>{
    input.setAttribute('aria-valuenow',input.value);
    input.setAttribute('aria-valuetext',Math.round(Number(input.value)*100)+'%');
    input.style.setProperty('--range-fill',((Number(input.value)-min)/(max-min)*100)+'%');
  };
  describeValue();
  if(key==='soundVolume')input.disabled=!state.settings.soundOn;
  let timer,
    finishing = false;
  const preview = key === "scale" || key === "bubbleScale";
  const session={input,finish:()=>finish()};
  const begin = () => {
    if(activeSlider===session)return;
    activeSlider?.finish();
    sliding = true;
    activeSlider=session;
    if (preview) {
      document.body.style.opacity = ".85";
      notify("size-preview", {
        active: true,
        bubble: key === "bubbleScale",
      });
    }
  };
  const finish = () => {
    if (activeSlider!==session || finishing) return;
    finishing = true;
    clearTimeout(timer);
    void command("settings", { [key]: Number(input.value) }).finally(() => {
      finishing = false;
      if(activeSlider===session){
        sliding = false;
        activeSlider = null;
        document.body.style.opacity = "1";
        if (preview) notify("size-preview", { active: false });
        render();
      }
    });
  };
  const adjustingKeys=new Set(['ArrowLeft','ArrowRight','ArrowUp','ArrowDown','PageUp','PageDown','Home','End']);
  input.onpointerdown=begin;
  input.onpointerup = finish;
  input.onpointercancel = finish;
  input.onlostpointercapture = finish;
  input.onblur=finish;
  input.onkeydown=event=>{if(adjustingKeys.has(event.key))begin();};
  input.onkeyup=event=>{if(adjustingKeys.has(event.key))finish();};
  input.onchange=()=>{if(!activeSlider){begin();finish();}};
  input.oninput = () => {
    begin();
    describeValue();
    label.querySelector("span").textContent =
      Math.round(input.value * 100) + "%";
    clearTimeout(timer);
    timer = setTimeout(
      () => command("settings", { [key]: Number(input.value) }),
      60,
    );
  };
}
function radio(text, checked, handler, parent) {
  const label = el("label", undefined, parent);
  label.className = "control";
  const input = el("input", undefined, label);
  input.type = "radio";
  input.dataset.focusKey='choice:'+text;
  input.name =
    parent.dataset.radioGroup ??
    (parent.dataset.radioGroup = "choices-" + ++radioGroup);
  input.checked = checked;
  el("span", text, label);
  input.onchange = handler;
}
function render() {
  const open = new Set(
      Array.from(panel.querySelectorAll("details[open]")).map(
        (d) => d.dataset.key,
      ),
    ),
    active = document.activeElement?.dataset.focusKey,
    textSelection=document.activeElement?.tagName==='TEXTAREA'?{start:document.activeElement.selectionStart,end:document.activeElement.selectionEnd,scroll:document.activeElement.scrollTop}:null,
    galleryIndex=Array.from(panel.querySelectorAll('.card[role=button]')).indexOf(document.activeElement?.closest?.('.card')),
    scroll=panel.scrollTop,
    flyoutScroll=new Map(Array.from(panel.querySelectorAll('details')).map(d=>[d.dataset.key,d.querySelector('.flyout')?.scrollTop??0]));
  const menuDraft=kind==='menu'?document.createElement('div'):null;
  if(menuDraft)mount=menuDraft;else panel.replaceChildren();
  busyDisabled.clear();
  busyCards.clear();
  if (kind === "menu") renderMenu();
  else if (kind === "characters") renderCharacters();
  else if (kind === "audio")
    buildAudio({ el, button, check, slider, radio, command }, state);
  else if(kind==='usage')buildUsage({el,button,command},state);
  else renderEditor();
  mount=panel;
  if(menuDraft)patchMenu(panel,menuDraft);
  // Keep feedback inside the menu's native region so Windows cannot clip it.
  if(kind==='menu')panel.append(feedback);
  for (const d of panel.querySelectorAll("details"))
    if (open.has(d.dataset.key)) {
      d.open = true;
      const flyout=d.querySelector('.flyout');if(flyout)flyout.scrollTop=flyoutScroll.get(d.dataset.key)??0;
    }
  panel.scrollTop=scroll;
  applyBusy();
  if(active){
    let focused=Array.from(panel.querySelectorAll('[data-focus-key]')).find(input=>input.dataset.focusKey===active);
    if(!focused&&kind==='characters'&&galleryIndex>=0)focused=panel.querySelector('[data-action=character-restore]')??Array.from(panel.querySelectorAll('.card[role=button]'))[galleryIndex];
    focused?.focus({preventScroll:true});
    if(focused?.tagName==='TEXTAREA'&&textSelection){focused.setSelectionRange(textSelection.start,textSelection.end);focused.scrollTop=textSelection.scroll;}
  }
  if (kind === "menu") {
    const p = state.placement;
    panel.style.left = (p?.mainOffset ?? 0) + "px";
    panel.style.width = (p?.rootWidth ?? 328) + "px";
    document.body.dataset.direction = p?.direction ?? "left";
    positionFlyouts();
  }
}
function patchMenu(target,draft){
  const key=node=>node.nodeType===1?(node.dataset.focusKey??node.dataset.key??node.dataset.setting??''):'';
  const matches=(a,b)=>a&&a.nodeType===b.nodeType&&a.nodeName===b.nodeName&&key(a)===key(b);
  const incoming=Array.from(draft.childNodes);
  for(const [index,next]of incoming.entries()){
    let current=target.childNodes[index];
    if(!matches(current,next)){
      const found=Array.from(target.childNodes).slice(index+1).find(node=>matches(node,next));
      if(found){target.insertBefore(found,current??null);current=found;}
      else{target.insertBefore(next,current??null);continue;}
    }
    if(next.nodeType===3){if(current.nodeValue!==next.nodeValue)current.nodeValue=next.nodeValue;continue;}
    if(next.nodeType!==1)continue;
    for(const attribute of Array.from(current.attributes))if(!next.hasAttribute(attribute.name)&&!(current.tagName==='DETAILS'&&attribute.name==='open'))current.removeAttribute(attribute.name);
    for(const attribute of next.attributes)if(!(current.tagName==='DETAILS'&&attribute.name==='open')&&current.getAttribute(attribute.name)!==attribute.value)current.setAttribute(attribute.name,attribute.value);
    if(current.tagName==='INPUT'){current.checked=next.checked;current.disabled=next.disabled;if(current.value!==next.value)current.value=next.value;if(current.dataset.focusKey?.startsWith('auto-quote:')){current.oninput=next.oninput;current.onchange=next.onchange;}}
    if(current.tagName==='SELECT'){current.disabled=next.disabled;current.onchange=next.onchange;}
    if(current.tagName==='BUTTON'){current.disabled=next.disabled;current.onclick=next.onclick;}
    patchMenu(current,next);
    if(current.tagName==='SELECT')current.value=next.value;
  }
  while(target.childNodes.length>incoming.length)target.lastChild.remove();
}
function applyBusy(){
  for(const control of panel.querySelectorAll('button,input,textarea')){
    if(control.dataset.action==='close-panel')continue;
    if(busy||(editorSaving&&editorActions.has(control.dataset.action))){if(!busyDisabled.has(control))busyDisabled.set(control,control.disabled);control.disabled=true;}
    else if(busyDisabled.has(control)){control.disabled=busyDisabled.get(control);busyDisabled.delete(control);}
  }
  for(const card of panel.querySelectorAll('.card[role=button]')){
    if(busy){if(!busyCards.has(card))busyCards.set(card,{tabIndex:card.tabIndex,disabled:card.getAttribute('aria-disabled')});card.tabIndex=-1;card.setAttribute('aria-disabled','true');}
    else if(busyCards.has(card)){const saved=busyCards.get(card);card.tabIndex=saved.tabIndex;card.setAttribute('aria-disabled',saved.disabled);busyCards.delete(card);}
  }
  if(busy&&!feedback.textContent)feedback.textContent='正在处理文件…';
  else if(!busy&&['正在处理文件…','正在处理上一个文件，请稍候。'].includes(feedback.textContent))feedback.textContent='';
}
function positionFlyouts() {
  if (kind !== "menu") return;
  panel.style.maxHeight=Math.max(1,Math.min(state.placement?.maxHeight??730,innerHeight-8))+"px";
  panel.style.top =
    Math.max(
      4,
      Math.min(
        innerHeight - Math.ceil(panel.getBoundingClientRect().height) - 4,
        state.placement?.anchorY ?? 0,
      ),
    ) + "px";
  const width = Math.min(innerWidth,state.placement?.submenuWidth ?? 300),
    maxHeight = Math.min(600, innerHeight - 8);
  for (const details of panel.querySelectorAll("details[open]")) {
    const content = details.querySelector(":scope > .flyout"),
      summary = details.querySelector(":scope > summary");
    if (!content || !summary) continue;
    content.style.width = width + "px";
    content.style.maxHeight = maxHeight + "px";
    const r = summary.getBoundingClientRect();
    let left =
      state.placement?.direction === "right"
        ? r.right + 10
        : r.left - width - 10;
    if (left < 0) left = r.right + 10;
    if (left + width > innerWidth) left = r.left - width - 10;
    content.style.left = Math.max(0, Math.min(innerWidth - width, left)) + "px";
    content.style.top =
      Math.max(
        4,
        Math.min(
          innerHeight - Math.ceil(content.getBoundingClientRect().height) - 4,
          r.top - 8,
        ),
      ) + "px";
  }
  publishBounds();
}
function publishBounds() {
  const nodes = [panel, ...panel.querySelectorAll("details[open]>.flyout")],
    bounds = nodes
      .filter((n) => n.getClientRects().length)
      .map((n) => {
        const r = n.getBoundingClientRect();
        return { x: r.x, y: r.y, width: r.width, height: r.height };
      });
  notify("menu-bounds", bounds);
}
function renderMenu() {
  buildMenu(
    { el, button, check, section, slider, radio, command },
    state,
    panel,
  );
}
function renderEditor() {
  el(
    "p",
    kind === "quotes"
      ? "一行一句。可以写成「3 | 台词」设置权重；不写权重默认为 1。每条最多 200 字。"
      : "一行一句。仅用于按台词匹配的变色模式；独立随机模式忽略此名单。台词请在我的语录中添加。",
  );
  const lines = el("textarea");
  lines.dataset.focusKey='editor:lines';
  lines.value = editorDraft;
  lines.oninput=()=>{editorDraft=lines.value;editorRevision++;};
  const actions = el("div");
  actions.className = "actions";
  if (kind === "quotes") {
    button('恢复内置','quotes-reset',undefined,actions);
  }
  const save = button('保存',kind==='quotes'?'quotes-save':'colors-save',undefined,actions);
  save.onclick = async () => {
    const revision=editorRevision;
    const result = await command(
      kind === "quotes" ? "quotes-save" : "colors-save",
      lines.value,
    );
    if (result) feedback.textContent = revision===editorRevision?'已保存':'上一版已保存，当前修改尚未保存';
  };
  button("关闭", "close-panel", null, actions);
  if (state.error) feedback.textContent = state.error;
}
function renderCharacters() {
  buildGallery({ el, button, command }, state);
}
document.addEventListener("keydown", (event) => {
  clearHover();
  if(kind==='menu')keyboardNavigation=true;
  if(kind==='menu'&&!sliding){
    const summary=event.target.closest?.('summary'),details=event.target.closest?.('details');
    if(event.key==='ArrowRight'&&summary){
      event.preventDefault();summary.click();details?.querySelector('.flyout button:not(:disabled),.flyout input:not(:disabled)')?.focus();return;
    }
    if((event.key==='Escape'||(event.key==='ArrowLeft'&&!event.target.matches?.('input[type=radio],input[type=text],input[type=number],textarea,select')))&&details?.open){
      event.preventDefault();details.open=false;details.querySelector('summary')?.focus();positionFlyouts();return;
    }
    if(['ArrowUp','ArrowDown'].includes(event.key)&&(summary||event.target.matches?.('button')&&!details)){
      const items=Array.from(panel.querySelectorAll('summary,button')).filter(node=>!node.closest('.flyout'));
      const selected=items.indexOf(summary??event.target);
      event.preventDefault();items[(selected+(event.key==='ArrowDown'?1:items.length-1))%items.length]?.focus();return;
    }
  }
  if (event.key === "Escape") {
    if (sliding) {
      event.preventDefault();
      activeSlider?.finish();
    } else void command("close-panel");
  }
});
document.addEventListener("pointermove", (event) => {
  if (kind !== "menu") return;
  const moved=pointerPoint&&(pointerPoint.x!==event.clientX||pointerPoint.y!==event.clientY);
  pointerPoint={x:event.clientX,y:event.clientY};
  const target = document.elementFromPoint(event.clientX, event.clientY),
    inside = !!target?.closest("#panel,.flyout");
  if(moved&&keyboardNavigation){keyboardNavigation=false;const details=target?.closest('details');if(details&&!sliding)groupOpeners.get(details)?.();}
  if (inside !== lastMenuHit) {
    lastMenuHit = inside;
    notify("menu-hit", inside);
  }
});
document.addEventListener('pointerdown',()=>{clearHover();if(kind==='menu')keyboardNavigation=false;});
window.gpt.onState((value) => {
  state = value;
  if(typeof value.busy==='boolean')busy=value.busy;
  if (!sliding&&!(kind==='usage'&&document.activeElement?.closest('.usage-prices'))) render();
});
panel.addEventListener('focusout',event=>{if(kind==='usage'&&event.target.closest('.usage-prices'))setTimeout(()=>{if(!document.activeElement?.closest('.usage-prices'))render();},0);});
window.gpt.onBusy?.(value=>{busy=value===true;applyBusy();});
panel.addEventListener('scroll',()=>{if(kind==='menu')positionFlyouts();});
window.addEventListener('resize',()=>{if(kind==='menu')positionFlyouts();});
window.addEventListener('blur',()=>{clearHover();activeSlider?.finish();});
if(kind==='menu')new MutationObserver(()=>{
  positionFlyouts();
  if(feedback.textContent)feedback.scrollIntoView({block:'nearest'});
}).observe(feedback,{childList:true,characterData:true,subtree:true});
window.panelVerification=()=>({kind,sliding,busy,editorSaving,keyboardNavigation,active:document.activeElement?.dataset.focusKey,groups:Array.from(panel.querySelectorAll('details[open]')).map(details=>details.dataset.key)});
render();
panel.setAttribute('aria-label',kind==='menu'?'GPT 娘设置':kind==='characters'?'形象图库':kind==='audio'?'点击音效':kind==='usage'?'用量与记账':'语录编辑');
document.body.classList.add('panel-ready');
