/**
 * The paste route for origins that cannot read the clipboard.
 *
 * No API reads the clipboard without a secure context — that is the whole
 * point of the restriction, and `--lan` is plain HTTP. What still works
 * everywhere is the user's *own* paste gesture into a real field, so this puts
 * one on screen, waits for the paste, and hands the text back.
 *
 * The field is focused on open so the platform's paste affordance is one
 * long-press away, and a `paste` event resolves immediately — no second tap to
 * confirm, which would be the step that made this feel like a workaround.
 */

export interface PastePromptHandle {
  /** Resolves with the pasted text, or null if the user backed out. */
  readonly result: Promise<string | null>;
  /** Tear down early — e.g. the pane it belongs to went away. */
  close(): void;
}

/**
 * Show the prompt inside `host` and resolve once there is text or the user
 * cancels. Only one is useful at a time; a caller that opens a second should
 * close the first.
 */
export const promptForPaste = (host: HTMLElement): PastePromptHandle => {
  const overlay = document.createElement("div");
  overlay.className = "paste-prompt";
  overlay.setAttribute("role", "dialog");
  overlay.setAttribute("aria-label", "Paste text");

  const label = document.createElement("p");
  label.className = "paste-prompt-hint";
  label.textContent = "Paste here to send it to the terminal";

  const field = document.createElement("textarea");
  field.className = "paste-prompt-field";
  field.rows = 2;
  field.autocapitalize = "off";
  field.autocomplete = "off";
  field.spellcheck = false;
  field.setAttribute("aria-label", "Paste target");

  const actions = document.createElement("div");
  actions.className = "paste-prompt-actions";

  const cancel = document.createElement("button");
  cancel.type = "button";
  cancel.className = "paste-prompt-button";
  cancel.textContent = "Cancel";

  const send = document.createElement("button");
  send.type = "button";
  send.className = "paste-prompt-button is-primary";
  send.textContent = "Send";

  actions.append(cancel, send);
  overlay.append(label, field, actions);
  host.append(overlay);

  let settle: ((value: string | null) => void) | null = null;
  const result = new Promise<string | null>((resolve) => {
    settle = resolve;
  });

  let closed = false;
  const finish = (value: string | null): void => {
    if (closed) return;
    closed = true;
    overlay.remove();
    settle?.(value);
  };

  // The paste event carries the text before it lands in the field, so read the
  // field on the next turn rather than the (still empty) value now.
  field.addEventListener("paste", () => {
    window.setTimeout(() => finish(field.value || null), 0);
  });
  field.addEventListener("keydown", (event) => {
    // A hardware keyboard is reachable here too; Enter sends, Escape backs out.
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault();
      finish(field.value || null);
    } else if (event.key === "Escape") {
      event.preventDefault();
      finish(null);
    }
  });
  send.addEventListener("click", () => finish(field.value || null));
  cancel.addEventListener("click", () => finish(null));

  field.focus();

  return { result, close: () => finish(null) };
};
