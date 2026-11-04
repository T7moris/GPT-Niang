// Shared with the browser renderer: keep this module free of file-system APIs.
export function normalizeQuotes(value) {
  if(value&&typeof value==='object'&&!Array.isArray(value)&&Object.hasOwn(value,'quotes'))value=value.quotes;
  const rows=[],byText=new Map();
  for(const entry of Array.isArray(value)?value:[value]) {
    const raw=typeof entry==='string'?entry:entry?.text;
    if(typeof raw!=='string')continue;
    const text=raw.trim(),weight=typeof entry==='string'||!Object.hasOwn(entry||{},'weight')?1:Number(entry.weight);
    if(!text||text.length>200||/[\x00-\x08\x0b\x0c\x0e-\x1f]/.test(text)||!Number.isFinite(weight)||weight<=0||weight>1000)continue;
    if(byText.has(text))byText.get(text).weight=Math.min(1000,byText.get(text).weight+weight);
    else {const row={text,weight};rows.push(row);byText.set(text,row);}
  }
  return rows;
}
export function parseQuoteLines(text) {
  return normalizeQuotes(text.split(/\r?\n/).map(line=>{
    const match=line.match(/^\s*(\d+(?:\.\d+)?)\s*\|\s*(.+)$/);
    return match?{text:match[2].trim(),weight:Number(match[1])}:line.trim();
  }));
}
