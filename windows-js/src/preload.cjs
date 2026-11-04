const { contextBridge, ipcRenderer } = require("electron");
contextBridge.exposeInMainWorld(
  "gpt",
  Object.freeze({
    command: (name, value) => ipcRenderer.invoke("command", name, value),
    hit: (inside) => ipcRenderer.send("hit", inside === true),
    drag: (value) => ipcRenderer.send("drag", value),
    shape: (value) => ipcRenderer.send("shape", value),
    pointer: () => ipcRenderer.invoke("pointer"),
    music: (value) => ipcRenderer.send("music-position", value),
    performance: (value) => ipcRenderer.send("frame-timing", value),
    ready: () => ipcRenderer.invoke("initial"),
    onState: (callback) => {
      ipcRenderer.on("state", (_event, value) => callback(value));
    },
    onBusy:callback=>ipcRenderer.on('busy',(_event,value)=>callback(value===true)),
    onPointer:callback=>ipcRenderer.on('pointer-position',(_event,value)=>callback(value)),
    onGeometry: (callback) => {
      ipcRenderer.on("geometry", (_event, value) => callback(value));
    },
    onAudio: (callback) => {
      ipcRenderer.on("audio", (_event, value) => callback(value));
    },
    onLamp: (callback) => {
      ipcRenderer.on("lamp", (_event, value) => callback(value));
    },
  }),
);
