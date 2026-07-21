import {
  LOCAL_FONT_ID,
  TERMINAL_FONTS,
  escapeCssFontFamily,
  type TerminalFontId,
} from "./fonts";
import { isLocalFontAccessSupported, queryLocalFonts } from "./local-fonts";
import {
  FONT_SIZE_MAX,
  FONT_SIZE_MIN,
  type KittermSettings,
  type TabTitleSettings,
  clampFontSize,
} from "./settings-store";
import { TERMINAL_THEMES, type TerminalThemeId } from "./themes";

export type SettingsPanelCallbacks = {
  onThemeChange: (themeId: TerminalThemeId) => void;
  onFontChange: (fontId: TerminalFontId) => void;
  onLocalFontFamilyChange: (family: string) => void;
  onFontSizeChange: (fontSize: number) => void;
  onTabTitleChange: (title: string) => void;
  onTabTitleShowFolderChange: (showFolder: boolean) => void;
};

export class SettingsPanel {
  private readonly root: HTMLElement;
  private readonly callbacks: SettingsPanelCallbacks;
  private readonly dialog: HTMLElement;
  private readonly backdrop: HTMLElement;
  private themeSelect: HTMLSelectElement | null = null;
  private fontSelect: HTMLSelectElement | null = null;
  private sizeInput: HTMLInputElement | null = null;
  private localSection: HTMLElement | null = null;
  private localSearch: HTMLInputElement | null = null;
  private localList: HTMLElement | null = null;
  private localManual: HTMLInputElement | null = null;
  private localStatus: HTMLElement | null = null;
  private tabTitleInput: HTMLInputElement | null = null;
  private tabTitleFolder: HTMLInputElement | null = null;
  private tabTitleNote: HTMLElement | null = null;
  /** Editing stays closed until the daemon confirms this client controls the
   * session; observers never get it. */
  private tabTitleEditable = false;
  private localFamilies: readonly string[] = [];
  private localFontFamily: string | null;
  /** Applied font id, as last confirmed by settings sync. */
  private currentFontId: TerminalFontId;
  /** True while the user is picking a local font that is not applied yet. */
  private browsingLocalFonts = false;
  private open = false;
  private loadingLocal = false;

  constructor(root: HTMLElement, initial: KittermSettings, callbacks: SettingsPanelCallbacks) {
    this.root = root;
    this.callbacks = callbacks;
    this.localFontFamily = initial.localFontFamily;
    this.currentFontId = initial.fontId;
    this.root.innerHTML = "";
    this.root.className = "settings-host";

    const gear = document.createElement("button");
    gear.type = "button";
    gear.className = "settings-gear";
    gear.setAttribute("aria-label", "Terminal settings");
    gear.title = "Settings";
    gear.textContent = "⚙";
    gear.addEventListener("click", () => this.toggle());

    this.backdrop = document.createElement("div");
    this.backdrop.className = "settings-backdrop";
    this.backdrop.hidden = true;
    this.backdrop.addEventListener("click", () => this.close());

    this.dialog = document.createElement("div");
    this.dialog.className = "settings-dialog";
    this.dialog.hidden = true;
    this.dialog.setAttribute("role", "dialog");
    this.dialog.setAttribute("aria-label", "Terminal settings");
    this.dialog.innerHTML = `
      <div class="settings-header">
        <h2>Settings</h2>
        <button type="button" class="settings-close" aria-label="Close">✕</button>
      </div>
      <label class="settings-field">
        <span>Theme</span>
        <select id="settings-theme"></select>
      </label>
      <label class="settings-field">
        <span>Font</span>
        <select id="settings-font"></select>
      </label>
      <div id="settings-local-font" class="settings-local-font" hidden>
        <label class="settings-field">
          <span>System fonts</span>
          <input id="settings-local-search" type="search" placeholder="Search fonts…" autocomplete="off" />
        </label>
        <div id="settings-local-list" class="settings-local-list" role="listbox" aria-label="Installed fonts"></div>
        <label class="settings-field">
          <span>Or type a family name</span>
          <input id="settings-local-manual" type="text" placeholder="e.g. JetBrains Mono" autocomplete="off" />
        </label>
        <p id="settings-local-status" class="settings-local-status" hidden></p>
      </div>
      <label class="settings-field">
        <span>Font size</span>
        <div class="settings-stepper">
          <button type="button" id="settings-size-dec" aria-label="Decrease font size">−</button>
          <input id="settings-size" type="number" min="${FONT_SIZE_MIN}" max="${FONT_SIZE_MAX}" step="1" />
          <button type="button" id="settings-size-inc" aria-label="Increase font size">+</button>
        </div>
      </label>
      <div class="settings-field">
        <label for="settings-tab-title">Tab title</label>
        <input id="settings-tab-title" type="text" placeholder="kitterm" autocomplete="off" spellcheck="false" />
        <label class="settings-check">
          <input id="settings-tab-title-folder" type="checkbox" />
          <span>Folder name</span>
        </label>
        <p id="settings-tab-title-note" class="settings-note" hidden>Only the session owner can rename this tab.</p>
      </div>
    `;

    this.root.append(gear, this.backdrop, this.dialog);

    this.themeSelect = this.dialog.querySelector("#settings-theme");
    this.fontSelect = this.dialog.querySelector("#settings-font");
    this.sizeInput = this.dialog.querySelector("#settings-size");
    this.localSection = this.dialog.querySelector("#settings-local-font");
    this.localSearch = this.dialog.querySelector("#settings-local-search");
    this.localList = this.dialog.querySelector("#settings-local-list");
    this.localManual = this.dialog.querySelector("#settings-local-manual");
    this.localStatus = this.dialog.querySelector("#settings-local-status");
    this.tabTitleInput = this.dialog.querySelector("#settings-tab-title");
    this.tabTitleFolder = this.dialog.querySelector("#settings-tab-title-folder");
    this.tabTitleNote = this.dialog.querySelector("#settings-tab-title-note");

    if (this.tabTitleInput) {
      this.tabTitleInput.value = initial.tabTitle;
      // `input` (not `change`): the title tracks typing, like the live preview
      // the other settings give.
      this.tabTitleInput.addEventListener("input", () => {
        if (!this.tabTitleEditable) return;
        this.callbacks.onTabTitleChange(this.tabTitleInput!.value);
      });
    }

    if (this.tabTitleFolder) {
      this.tabTitleFolder.checked = initial.tabTitleShowFolder;
      this.tabTitleFolder.addEventListener("change", () => {
        if (!this.tabTitleEditable) return;
        this.callbacks.onTabTitleShowFolderChange(this.tabTitleFolder!.checked);
      });
    }

    this.setTabTitleEditable(false);

    if (this.themeSelect) {
      for (const theme of TERMINAL_THEMES) {
        const option = document.createElement("option");
        option.value = theme.id;
        option.textContent = theme.label;
        this.themeSelect.append(option);
      }
      this.themeSelect.value = initial.themeId;
      this.themeSelect.addEventListener("change", () => {
        this.callbacks.onThemeChange(this.themeSelect!.value as TerminalThemeId);
      });
    }

    if (this.fontSelect) {
      for (const font of TERMINAL_FONTS) {
        const option = document.createElement("option");
        option.value = font.id;
        option.textContent = font.label;
        this.fontSelect.append(option);
      }
      const localOption = document.createElement("option");
      localOption.value = LOCAL_FONT_ID;
      localOption.textContent = this.localFontLabel(initial.localFontFamily);
      this.fontSelect.append(localOption);

      this.fontSelect.value = initial.fontId;
      this.fontSelect.addEventListener("change", () => {
        const id = this.fontSelect!.value as TerminalFontId;
        if (id === LOCAL_FONT_ID) {
          this.showLocalSection(true);
          void this.ensureLocalFontsLoaded();
          if (this.localFontFamily) {
            this.callbacks.onFontChange(LOCAL_FONT_ID);
          } else {
            // Nothing applied yet — keep picker open across other setting changes.
            this.browsingLocalFonts = true;
          }
          return;
        }
        this.browsingLocalFonts = false;
        this.showLocalSection(false);
        this.callbacks.onFontChange(id);
      });
    }

    this.localSearch?.addEventListener("input", () => this.renderLocalList());
    this.localManual?.addEventListener("change", () => this.commitManualLocalFont());
    this.localManual?.addEventListener("keydown", (event) => {
      if (event.key === "Enter") {
        event.preventDefault();
        this.commitManualLocalFont();
      }
    });
    if (this.localManual && initial.localFontFamily) {
      this.localManual.value = initial.localFontFamily;
    }

    if (this.sizeInput) {
      this.sizeInput.value = String(initial.fontSize);
      this.sizeInput.addEventListener("change", () => this.commitFontSize());
      this.sizeInput.addEventListener("keydown", (event) => {
        if (event.key === "Enter") {
          event.preventDefault();
          this.commitFontSize();
        }
      });
    }

    this.dialog.querySelector("#settings-size-dec")?.addEventListener("click", () => {
      this.bumpFontSize(-1);
    });
    this.dialog.querySelector("#settings-size-inc")?.addEventListener("click", () => {
      this.bumpFontSize(1);
    });
    this.dialog.querySelector(".settings-close")?.addEventListener("click", () => this.close());

    this.showLocalSection(initial.fontId === LOCAL_FONT_ID);

    document.addEventListener("keydown", this.onDocumentKeydown);
  }

  dispose(): void {
    document.removeEventListener("keydown", this.onDocumentKeydown);
    this.root.innerHTML = "";
  }

  toggle(): void {
    if (this.open) this.close();
    else this.show();
  }

  show(): void {
    this.open = true;
    this.backdrop.hidden = false;
    this.dialog.hidden = false;
    this.themeSelect?.focus();
    if (this.fontSelect?.value === LOCAL_FONT_ID) {
      void this.ensureLocalFontsLoaded();
    }
  }

  close(): void {
    this.open = false;
    this.backdrop.hidden = true;
    this.dialog.hidden = true;
    if (this.browsingLocalFonts) {
      // Nothing was applied — revert the select to the applied font.
      this.browsingLocalFonts = false;
      if (this.fontSelect) this.fontSelect.value = this.currentFontId;
      this.showLocalSection(this.currentFontId === LOCAL_FONT_ID);
    }
  }

  sync(settings: KittermSettings): void {
    this.localFontFamily = settings.localFontFamily;
    this.currentFontId = settings.fontId;
    if (settings.fontId === LOCAL_FONT_ID) this.browsingLocalFonts = false;
    if (this.themeSelect) this.themeSelect.value = settings.themeId;
    if (this.fontSelect) {
      this.updateLocalOptionLabel(settings.localFontFamily);
      if (!this.browsingLocalFonts) this.fontSelect.value = settings.fontId;
    }
    if (this.sizeInput) this.sizeInput.value = String(settings.fontSize);
    this.syncTabTitle(settings);
    if (this.localManual && settings.localFontFamily) {
      this.localManual.value = settings.localFontFamily;
    }
    this.showLocalSection(
      this.browsingLocalFonts || settings.fontId === LOCAL_FONT_ID,
    );
    this.renderLocalList();
  }

  /** Update just the tab-title controls. Used when a title arrives from
   * another tab, so mirroring does not rebuild the whole panel (`sync` also
   * re-renders the installed-font list). */
  syncTabTitle(settings: TabTitleSettings): void {
    if (
      this.tabTitleInput &&
      document.activeElement !== this.tabTitleInput &&
      this.tabTitleInput.value !== settings.tabTitle
    ) {
      this.tabTitleInput.value = settings.tabTitle;
    }
    if (this.tabTitleFolder) this.tabTitleFolder.checked = settings.tabTitleShowFolder;
  }

  /** Controllers may rename the tab; observers see the owner's title only. */
  setTabTitleEditable(editable: boolean): void {
    this.tabTitleEditable = editable;
    if (this.tabTitleInput) this.tabTitleInput.disabled = !editable;
    if (this.tabTitleFolder) this.tabTitleFolder.disabled = !editable;
    if (this.tabTitleNote) this.tabTitleNote.hidden = editable;
  }

  private readonly onDocumentKeydown = (event: KeyboardEvent): void => {
    if (event.key === "Escape" && this.open) {
      event.preventDefault();
      this.close();
    }
    // ⌘, / Ctrl+,
    if (
      event.key === "," &&
      (event.metaKey || event.ctrlKey) &&
      !event.altKey &&
      !event.shiftKey
    ) {
      event.preventDefault();
      this.toggle();
    }
  };

  private localFontLabel(family: string | null): string {
    return family?.trim() ? `Local: ${family.trim()}` : "Local font…";
  }

  private updateLocalOptionLabel(family: string | null): void {
    if (!this.fontSelect) return;
    const option = [...this.fontSelect.options].find((entry) => entry.value === LOCAL_FONT_ID);
    if (option) option.textContent = this.localFontLabel(family);
  }

  private showLocalSection(visible: boolean): void {
    if (this.localSection) this.localSection.hidden = !visible;
  }

  private setLocalStatus(message: string | null): void {
    if (!this.localStatus) return;
    if (!message) {
      this.localStatus.hidden = true;
      this.localStatus.textContent = "";
      return;
    }
    this.localStatus.hidden = false;
    this.localStatus.textContent = message;
  }

  private async ensureLocalFontsLoaded(): Promise<void> {
    if (this.loadingLocal) return;
    if (!isLocalFontAccessSupported()) {
      this.setLocalStatus(
        "This browser cannot list system fonts. Type a family name below (Chrome/Edge recommended).",
      );
      this.localFamilies = [];
      this.renderLocalList();
      return;
    }

    this.loadingLocal = true;
    this.setLocalStatus("Requesting access to system fonts…");
    try {
      const families = await queryLocalFonts();
      this.localFamilies = families;
      if (families.length === 0) {
        this.setLocalStatus(
          "No fonts returned (permission denied or empty). Type a family name below.",
        );
      } else {
        this.setLocalStatus(`${families.length} font families`);
      }
      this.renderLocalList();
    } finally {
      this.loadingLocal = false;
    }
  }

  private renderLocalList(): void {
    if (!this.localList) return;
    const query = (this.localSearch?.value ?? "").trim().toLowerCase();
    const filtered = query
      ? this.localFamilies.filter((family) => family.toLowerCase().includes(query))
      : this.localFamilies;

    this.localList.innerHTML = "";
    const limit = 80;
    for (const family of filtered.slice(0, limit)) {
      const button = document.createElement("button");
      button.type = "button";
      button.className = "settings-local-item";
      button.setAttribute("role", "option");
      button.textContent = family;
      button.style.fontFamily = `"${escapeCssFontFamily(family)}", monospace`;
      if (family === this.localFontFamily) {
        button.classList.add("is-selected");
        button.setAttribute("aria-selected", "true");
      }
      button.addEventListener("click", () => {
        this.pickLocalFamily(family);
      });
      this.localList.append(button);
    }
    if (filtered.length > limit) {
      const more = document.createElement("p");
      more.className = "settings-local-more";
      more.textContent = `Showing ${limit} of ${filtered.length} — refine search`;
      this.localList.append(more);
    }
  }

  private pickLocalFamily(family: string): void {
    const trimmed = family.trim();
    if (!trimmed) return;
    this.localFontFamily = trimmed;
    this.browsingLocalFonts = false;
    if (this.localManual) this.localManual.value = trimmed;
    this.updateLocalOptionLabel(trimmed);
    if (this.fontSelect) this.fontSelect.value = LOCAL_FONT_ID;
    this.callbacks.onLocalFontFamilyChange(trimmed);
    this.renderLocalList();
  }

  private commitManualLocalFont(): void {
    const value = this.localManual?.value ?? "";
    if (!value.trim()) return;
    this.pickLocalFamily(value);
  }

  private bumpFontSize(delta: number): void {
    const current = Number(this.sizeInput?.value ?? FONT_SIZE_MIN);
    const next = clampFontSize(current + delta);
    if (this.sizeInput) this.sizeInput.value = String(next);
    this.callbacks.onFontSizeChange(next);
  }

  private commitFontSize(): void {
    const next = clampFontSize(Number(this.sizeInput?.value));
    if (this.sizeInput) this.sizeInput.value = String(next);
    this.callbacks.onFontSizeChange(next);
  }
}
