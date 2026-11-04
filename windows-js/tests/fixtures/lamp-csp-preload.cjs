const {contextBridge}=require('electron');contextBridge.exposeInMainWorld('gpt',{onLamp(){}});
