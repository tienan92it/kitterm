import { TerminalApp } from "./terminal-app";
import "./styles.css";

const container = document.getElementById("terminal");
if (!container) {
  throw new Error("#terminal missing");
}

const statusEl = document.getElementById("status");
const searchRoot = document.getElementById("search");
const settingsRoot = document.getElementById("settings-root");
const app = new TerminalApp({ container, statusEl, searchRoot, settingsRoot });

window.addEventListener("beforeunload", () => {
  app.dispose();
});

if ("serviceWorker" in navigator) {
  window.addEventListener("load", () => {
    void navigator.serviceWorker.register("/sw.js").catch(() => {
      // Optional; ignore registration failures (file://, etc.).
    });
  });
}
