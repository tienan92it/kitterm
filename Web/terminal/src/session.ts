import {
  decodeServerFrame,
  encodeInput,
  encodePause,
  encodeResize,
  encodeResume,
  type ServerFrame,
} from "./protocol";

export type SessionHandlers = {
  onFrame: (frame: ServerFrame) => void;
  onOpen?: () => void;
  onClose?: (event: CloseEvent) => void;
  onError?: (event: Event) => void;
};

/** One WebSocket = one PTY session. Closing the page ends the shell. */
export class KittermSession {
  private ws: WebSocket | null = null;
  private readonly handlers: SessionHandlers;

  constructor(handlers: SessionHandlers) {
    this.handlers = handlers;
  }

  connect(url = defaultWsUrl()): void {
    this.close();
    const ws = new WebSocket(url);
    ws.binaryType = "arraybuffer";
    this.ws = ws;

    ws.onopen = () => {
      this.handlers.onOpen?.();
    };
    ws.onmessage = (event) => {
      if (!(event.data instanceof ArrayBuffer)) {
        return;
      }
      try {
        this.handlers.onFrame(decodeServerFrame(event.data));
      } catch (err) {
        console.error("kitterm: bad frame", err);
      }
    };
    ws.onclose = (event) => {
      this.handlers.onClose?.(event);
    };
    ws.onerror = (event) => {
      this.handlers.onError?.(event);
    };
  }

  get ready(): boolean {
    return this.ws?.readyState === WebSocket.OPEN;
  }

  sendInput(data: string | Uint8Array): void {
    // Mirror daemon maxInputBytes (64KiB); chunk large pastes.
    const maxChunk = 64 * 1024;
    if (typeof data === "string") {
      if (data.length <= maxChunk) {
        this.send(encodeInput(data));
        return;
      }
      const encoded = new TextEncoder().encode(data);
      for (let offset = 0; offset < encoded.length; offset += maxChunk) {
        this.send(encodeInput(encoded.subarray(offset, offset + maxChunk)));
      }
      return;
    }
    for (let offset = 0; offset < data.length; offset += maxChunk) {
      this.send(encodeInput(data.subarray(offset, offset + maxChunk)));
    }
  }

  sendResize(cols: number, rows: number): void {
    this.send(encodeResize(cols, rows));
  }

  sendPause(): void {
    this.send(encodePause());
  }

  sendResume(): void {
    this.send(encodeResume());
  }

  close(): void {
    if (this.ws) {
      // Detach handlers first: an intentional close (dispose, reconnect)
      // must not fire onClose and trigger the reconnect path.
      this.ws.onopen = null;
      this.ws.onmessage = null;
      this.ws.onclose = null;
      this.ws.onerror = null;
      this.ws.close();
      this.ws = null;
    }
  }

  private send(buffer: ArrayBuffer): void {
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(buffer);
    }
  }
}

export function defaultWsUrl(): string {
  const proto = location.protocol === "https:" ? "wss:" : "ws:";
  return `${proto}//${location.host}/ws`;
}
