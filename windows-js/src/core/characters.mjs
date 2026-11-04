import fs from "node:fs";
import path from "node:path";
import { randomUUID } from "node:crypto";
import sharp from "sharp";
import bmp from "bmp-js";
import {execFile} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import { readJson, writeJson, inside } from "./storage.mjs";
const validName = (x) => typeof x === "string" && x.trim() && x.length <= 80;
export class Characters {
  constructor(appDir, dataDir) {
    this.assets = path.join(appDir, "assets");
    this.directory = path.join(dataDir, "characters");
    this.file = path.join(dataDir, "characters.json");
    this.images=new Map();this.imageJobs=new Map();this.imageBytes=0;
  }
  catalog(file = this.file) {
    if (!fs.existsSync(file))
      return { version: 1, characters: [], removed: [] };
    if (fs.statSync(file).size > 1048576) throw Error("角色清单过大。");
    const v = readJson(file);
    if (v?.version !== 1 || !Array.isArray(v.characters))
      throw Error("角色清单格式无效。");
    return { ...v, removed: Array.isArray(v.removed) ? v.removed : [] };
  }
  list() {
    const rows = [
        {
          id: "gpt-dragon",
          name: "龙娘1",
          kind: "built-in",
          path: path.join(this.assets, "gpt-dragon-niang-bust.png"),
        },
      ],
      seen = new Set(["gpt-dragon"]);
    for (const builtin of [true, false]) {
      let entries = [];
      try {
        entries = this.catalog(
          builtin ? path.join(this.assets, "characters.json") : this.file,
        ).characters;
      } catch {}
      for (const e of entries) {
        if (
          !(builtin ? /^[a-z][a-z0-9-]{0,63}$/ : /^custom-[a-f0-9]{32}$/).test(
            e?.id,
          ) ||
          seen.has(e.id) ||
          !validName(e.name) ||
          typeof e.file !== "string" ||
          (!builtin && e.file !== e.id + ".png")
        )
          continue;
        try {
          const file = inside(builtin ? this.assets : this.directory, e.file);
          if (!fs.existsSync(file)) continue;
          rows.push({
            id: e.id,
            name: e.name.trim(),
            kind: builtin ? "built-in" : "custom",
            path: file,
          });
          seen.add(e.id);
        } catch {}
      }
    }
    return rows;
  }
  selected(id) {
    const rows = this.list();
    return rows.find((r) => r.id === id) ?? rows[0];
  }
  async display(id, { thumbnail = false } = {}) {
    const row = typeof id === "object" ? id : this.selected(id),key=this.revision(row)+':'+thumbnail;
    const cached=this.images.get(key);
    if(cached){this.images.delete(key);this.images.set(key,cached);return {id:row.id,name:row.name,url:cached};}
    let job=this.imageJobs.get(key);
    if(!job){job=this.decodeDisplay(row,thumbnail);this.imageJobs.set(key,job);}
    try{
      const url=await job;
      if(!this.images.has(key)&&url.length<=8*1024*1024){
        while(this.images.size&&(this.images.size>=32||this.imageBytes+url.length>8*1024*1024)){
          const oldest=this.images.keys().next().value;this.imageBytes-=this.images.get(oldest).length;this.images.delete(oldest);
        }
        this.images.set(key,url);this.imageBytes+=url.length;
      }
      return {id:row.id,name:row.name,url};
    }finally{if(this.imageJobs.get(key)===job)this.imageJobs.delete(key);}
  }
  revision(row){
    const stat=fs.statSync(row.path,{bigint:true});return row.path+':'+stat.size+':'+stat.mtimeNs+':'+stat.ctimeNs;
  }
  async decodeDisplay(row,thumbnail){
    const pipeline=await decodeCharacter(row.path);
    if (thumbnail)
      pipeline.resize({
        width: 256,
        height: 256,
        fit: "inside",
        withoutEnlargement: true,
      });
    const bytes = await pipeline.png().toBuffer();
    return 'data:image/png;base64,'+bytes.toString('base64');
  }
  removed() {
    try {
      return this.catalog()
        .removed.filter(
          (e) =>
            /^custom-[a-f0-9]{32}$/.test(e.id) &&
            e.file === e.id + ".png" &&
            validName(e.name),
        )
        .map((e) => ({
          ...e,
          path: inside(path.join(this.directory, "removed"), e.file),
        }))
        .filter((e) => fs.existsSync(e.path));
    } catch {
      return [];
    }
  }
  async import(source) {
    const pipeline = await decodeCharacter(source);
    const normalized = await pipeline
      .resize({
        width: 2048,
        height: 2048,
        fit: "inside",
        withoutEnlargement: true,
      })
      .ensureAlpha()
      .png()
      .toBuffer();
    const pixels = await sharp(normalized)
      .resize(32, 32, { fit: "fill" })
      .raw()
      .toBuffer();
    let visible = false;
    for (let n = 3; n < pixels.length; n += 4)
      if (pixels[n] > 10) {
        visible = true;
        break;
      }
    if (!visible) throw Error("图片没有可见像素，请换一张有内容的图片。");
    const catalog = this.catalog(),
      id = "custom-" + randomUUID().replaceAll("-", ""),
      file = id + ".png";
    let name =
      path
        .basename(source, path.extname(source))
        .replace(/[\x00-\x1f]/g, "")
        .trim()
        .slice(0, 80) || "我的角色";
    fs.mkdirSync(this.directory, { recursive: true });
    const target = inside(this.directory, file);
    try {
      fs.writeFileSync(target, normalized, { flag: "wx" });
      catalog.characters.push({ id, file, name });
      writeJson(this.file, catalog);
    } catch (error) {
      try {
        fs.unlinkSync(target);
      } catch {}
      throw error;
    }
    return this.selected(id);
  }
  remove(id) {
    if (!/^custom-[a-f0-9]{32}$/.test(id))
      throw Error("只能移除自己导入的角色。");
    const c = this.catalog(),
      matches = c.characters.filter(
        (e) => e.id === id && e.file === id + ".png",
      ),
      entry = matches[0];
    if (matches.length !== 1) throw Error("找不到可移除的导入角色。");
    this.move(
      entry,
      this.directory,
      path.join(this.directory, "removed"),
      () => {
        c.characters = c.characters.filter((e) => e !== entry);
        c.removed.push({ ...entry, removedAt: new Date().toISOString() });
        writeJson(this.file, c);
      },
    );
  }
  restore(id) {
    const c = this.catalog(),
      matches = c.removed.filter(
        (e) =>
          e.id === id &&
          /^custom-[a-f0-9]{32}$/.test(id) &&
          e.file === id + ".png",
      ),
      entry = matches[0];
    if (matches.length !== 1 || c.characters.some((e) => e.id === id))
      throw Error("找不到可恢复的角色。");
    this.move(
      entry,
      path.join(this.directory, "removed"),
      this.directory,
      () => {
        c.removed = c.removed.filter((e) => e !== entry);
        const { removedAt, ...row } = entry;
        c.characters.push(row);
        writeJson(this.file, c);
      },
    );
  }
  move(entry, from, to, commit) {
    const source = inside(from, entry.file),
      target = inside(to, entry.file);
    fs.mkdirSync(to, { recursive: true });
    if (fs.existsSync(target)) throw Error("目标角色文件已存在。");
    fs.renameSync(source, target);
    try {
      commit();
    } catch (error) {
      fs.renameSync(target, source);
      throw error;
    }
  }
}
async function decodeCharacter(source) {
  if (
    ![".png", ".jpg", ".jpeg", ".bmp", ".gif"].includes(
      path.extname(source).toLowerCase(),
    )
  )
    throw Error("支持 PNG、JPG、BMP 和 GIF 图片；GIF 使用第一帧。");
  const stat = fs.statSync(source);
  if (!stat.isFile() || !stat.size || stat.size > 20 * 1024 * 1024)
    throw Error("图片不能为空，且不能超过 20 MB。");
  const bytes = fs.readFileSync(source);
  if (bytes[0] === 0x42 && bytes[1] === 0x4d) {
    if(process.platform==='win32'){
      const executable=fileURLToPath(new URL('../../native/GPTNiang.Native.exe',import.meta.url));
      const png=await new Promise((resolve,reject)=>execFile(executable,['--decode-bmp',source],{windowsHide:true,encoding:'buffer',timeout:10000,maxBuffer:96*1024*1024},(error,stdout)=>error?reject(Error('图片无法读取，请选择完整的 BMP 文件。',{cause:error})):resolve(stdout)));
      return sharp(png,{limitInputPixels:16000000});
    }
    if (bytes.length < 54) throw Error("图片无法读取。");
    const w = bytes.readInt32LE(18),
      h = Math.abs(bytes.readInt32LE(22));
    checkDimensions(w, h);
    const decoded = bmp.decode(bytes),
      rgba = Buffer.alloc(decoded.width * decoded.height * 4);
    for (let n = 0; n < rgba.length; n += 4) {
      rgba[n] = decoded.data[n + 3];
      rgba[n + 1] = decoded.data[n + 2];
      rgba[n + 2] = decoded.data[n + 1];
      rgba[n + 3] = 255;
    }
    return sharp(rgba, { raw: { width: w, height: h, channels: 4 } });
  }
  const pipeline = sharp(bytes, {
      limitInputPixels: 16000000,
      animated: false,
    }),
    meta = await pipeline.metadata();
  if (!["png", "jpeg", "gif"].includes(meta.format))
    throw Error("图片格式不受支持。");
  checkDimensions(meta.width, meta.pageHeight ?? meta.height);
  return pipeline;
}
function checkDimensions(w, h) {
  if (
    !Number.isInteger(w) ||
    !Number.isInteger(h) ||
    w < 1 ||
    h < 1 ||
    w > 4096 ||
    h > 4096 ||
    w * h > 16000000
  )
    throw Error("图片尺寸不能超过 4096 × 4096，且不能超过 1600 万像素。");
}
