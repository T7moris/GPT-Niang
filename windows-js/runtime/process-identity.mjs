import {createRequire} from 'node:module';
const require=createRequire(import.meta.url);
let api;
export function processIdentity(pid){
  if(!Number.isSafeInteger(pid)||pid<=0)return null;
  if(process.platform!=='win32')return null;
  try{
    if(!api){
      const koffi=require('koffi'),kernel=koffi.load('kernel32.dll');
      api={open:kernel.func('intptr_t __stdcall OpenProcess(uint32_t access,bool inherit,uint32_t pid)'),close:kernel.func('bool __stdcall CloseHandle(intptr_t h)'),times:kernel.func('bool __stdcall GetProcessTimes(intptr_t h,_Out_ uint64_t *created,_Out_ uint64_t *exited,_Out_ uint64_t *kernel,_Out_ uint64_t *user)'),image:kernel.func('bool __stdcall QueryFullProcessImageNameW(intptr_t h,uint32_t flags,_Out_ uint16_t *text,_Inout_ uint32_t *size)')};
    }
    const handle=api.open(0x1000,false,pid);if(!handle)return null;
    try{
      const created=[0n],exited=[0n],kernel=[0n],user=[0n],buffer=Buffer.alloc(65536),size=[32768];
      if(!api.times(handle,created,exited,kernel,user)||!api.image(handle,0,buffer,size))return null;
      const fileTime=BigInt(created[0]);
      return {pid,path:buffer.subarray(0,size[0]*2).toString('utf16le'),startedTicks:(fileTime+504911232000000000n).toString(),startedAt:Number((fileTime-116444736000000000n)/10000n)};
    }finally{api.close(handle);}
  }catch{return null;}
}
export function sameProcess(marker,identity){
  if(!identity||marker?.pid!==identity.pid)return false;
  const ticks=marker.processStartedTicks??marker.startedTicks;
  if(ticks!=null)return String(ticks)===identity.startedTicks;
  if(marker.startedAt){const time=typeof marker.startedAt==='number'?marker.startedAt:Date.parse(marker.startedAt);return Number.isFinite(time)&&time===identity.startedAt;}
  return false;
}
