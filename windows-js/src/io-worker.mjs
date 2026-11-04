import { parentPort, workerData } from "node:worker_threads";
import { Characters } from "./core/characters.mjs";
import { AudioStore } from "./core/audio.mjs";
try {
  let result;
  if (workerData.kind === "character")
    result = await new Characters(workerData.root, workerData.dataDir).import(
      workerData.source,
    );
  else if (workerData.kind === "audio") {
    new AudioStore(workerData.root, workerData.dataDir).import(
      workerData.slot,
      workerData.source,
    );
    result = true;
  } else throw Error("无效文件处理任务");
  parentPort.postMessage({ ok: true, result });
} catch (error) {
  parentPort.postMessage({ ok: false, error: error.message });
}
