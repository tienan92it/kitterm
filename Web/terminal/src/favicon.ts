/** Tab favicon: glyph color = connection state; top-right dot = unread output. */

export type FaviconState = "connected" | "reconnecting" | "exited";

const GLYPH_COLORS: Record<FaviconState, string> = {
  connected: "#3fb950",
  reconnecting: "#d29922",
  exited: "#f85149",
};

const UNREAD_DOT_COLOR = "#f85149";

export function setFavicon(state: FaviconState, unread = false): void {
  const canvas = document.createElement("canvas");
  canvas.width = 32;
  canvas.height = 32;
  const ctx = canvas.getContext("2d");
  if (!ctx) return;

  ctx.fillStyle = "#161b22";
  ctx.beginPath();
  ctx.roundRect(0, 0, 32, 32, 7);
  ctx.fill();
  ctx.strokeStyle = "#30363d";
  ctx.lineWidth = 2;
  ctx.stroke();

  const stroke = 2.6;
  ctx.strokeStyle = GLYPH_COLORS[state];
  ctx.lineWidth = stroke;
  ctx.lineCap = "round";
  ctx.lineJoin = "round";

  ctx.beginPath();
  ctx.moveTo(8, 9);
  ctx.lineTo(14, 16);
  ctx.lineTo(8, 23);
  ctx.stroke();

  ctx.beginPath();
  ctx.moveTo(19, 9.5);
  ctx.lineTo(19, 22.5);
  ctx.stroke();

  if (unread) {
    ctx.fillStyle = UNREAD_DOT_COLOR;
    ctx.beginPath();
    ctx.arc(28, 4, 4, 0, Math.PI * 2);
    ctx.fill();
  }

  let link = document.querySelector<HTMLLinkElement>("link[rel='icon']");
  if (!link) {
    link = document.createElement("link");
    link.rel = "icon";
    document.head.append(link);
  }
  link.href = canvas.toDataURL("image/png");
}
