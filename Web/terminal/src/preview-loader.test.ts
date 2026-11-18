import { describe, expect, it } from "vitest";

import { lazyModule } from "./preview-loader";

/** A loader over a fake `import()` and a fake idle queue. */
function harness() {
  const loads: Array<{ resolve: (value: string) => void; reject: (reason: Error) => void }> = [];
  const idle: Array<() => void> = [];
  const loader = lazyModule<string>(
    () =>
      new Promise<string>((resolve, reject) => {
        loads.push({ resolve, reject });
      }),
    (run) => idle.push(run),
  );
  return { loader, loads, idle };
}

describe("the preview chunk", () => {
  it("is not asked for before the first output", () => {
    const { loads, idle } = harness();
    expect(loads).toHaveLength(0);
    expect(idle).toHaveLength(0);
  });

  it("is not asked for at the first output, only when the page is idle after it", () => {
    const { loader, loads, idle } = harness();
    loader.afterFirstOutput();
    expect(idle).toHaveLength(1);
    expect(loads).toHaveLength(0);
    idle[0]();
    expect(loads).toHaveLength(1);
  });

  it("is asked for once, however much output arrives", () => {
    const { loader, loads, idle } = harness();
    loader.afterFirstOutput();
    loader.afterFirstOutput();
    loader.afterFirstOutput();
    expect(idle).toHaveLength(1);
    idle[0]();
    loader.afterFirstOutput();
    expect(idle).toHaveLength(1);
    expect(loads).toHaveLength(1);
  });

  it("is the module a later use gets, with no second load", async () => {
    const { loader, loads, idle } = harness();
    loader.afterFirstOutput();
    idle[0]();
    loads[0].resolve("the module");
    expect(await loader.use()).toBe("the module");
    expect(await loader.use()).toBe("the module");
    expect(loads).toHaveLength(1);
  });

  it("loads once when a use comes before the idle load", async () => {
    const { loader, loads, idle } = harness();
    loader.afterFirstOutput();
    const first = loader.use();
    expect(loads).toHaveLength(1);
    idle[0]();
    const second = loader.use();
    expect(loads).toHaveLength(1);
    loads[0].resolve("the module");
    expect(await first).toBe("the module");
    expect(await second).toBe("the module");
  });

  it("loads at once on a use before any output", () => {
    const { loader, loads, idle } = harness();
    void loader.use();
    expect(loads).toHaveLength(1);
    expect(idle).toHaveLength(0);
  });

  it("tries the import again on the next use after a rejection", async () => {
    const { loader, loads } = harness();
    const failed = loader.use();
    loads[0].reject(new Error("404"));
    await expect(failed).rejects.toThrow("404");
    expect(loads).toHaveLength(1);

    const again = loader.use();
    expect(loads).toHaveLength(2);
    loads[1].resolve("the module");
    expect(await again).toBe("the module");
    expect(await loader.use()).toBe("the module");
    expect(loads).toHaveLength(2);
  });

  it("tries again on a use after the idle load is rejected", async () => {
    const { loader, loads, idle } = harness();
    loader.afterFirstOutput();
    idle[0]();
    loads[0].reject(new Error("offline"));
    // Let the loader's own handler forget the failed load.
    await Promise.resolve();
    await Promise.resolve();
    const use = loader.use();
    expect(loads).toHaveLength(2);
    loads[1].resolve("the module");
    expect(await use).toBe("the module");
  });
});
