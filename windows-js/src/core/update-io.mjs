import { Worker } from 'node:worker_threads';

export function runUpdateIO(task) {
  return new Promise((resolve, reject) => {
    const transferList = [];
    for (const key of ['bytes', 'sums']) {
      const value = task[key];
      if (value && value.byteOffset === 0 &&
          value.byteLength === value.buffer.byteLength && value.byteLength > 8192)
        transferList.push(value.buffer);
    }
    const worker = new Worker(new URL('../update-io-worker.mjs',import.meta.url), {
      workerData: task,
      transferList,
    });
    let settled = false;
    const finish = (callback, value) => {
      if (settled) return;
      settled = true;
      callback(value);
    };
    worker.once('message', value => {
      if (value?.ok === true && value.result && typeof value.result === 'object')
        finish(resolve, value.result);
      else
        finish(reject, Error(typeof value?.error === 'string'
          ? value.error : '更新文件处理未返回有效结果。'));
    });
    worker.once('error', error => finish(reject, error));
    worker.once('exit', code =>
      finish(reject, Error('更新文件处理进程退出：' + code)));
  });
}
