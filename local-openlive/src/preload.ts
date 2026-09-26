import { contextBridge, ipcRenderer } from "electron";

contextBridge.exposeInMainWorld("herdrInference", {
  onJob(callback: (job: unknown) => void) {
    ipcRenderer.on("inference.job", (_event, job) => callback(job));
  },
  onCancel(callback: (ids: number[]) => void) {
    ipcRenderer.on("inference.cancel", (_event, ids) => callback(ids));
  },
  ready(value: unknown) { ipcRenderer.send("inference.ready", value); },
  result(value: unknown) { ipcRenderer.send("inference.result", value); },
});
