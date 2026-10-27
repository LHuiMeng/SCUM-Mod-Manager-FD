import { spawn, spawnSync } from "node:child_process";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import WebSocket from "ws";

const root = path.resolve(import.meta.dirname, "..");
const outDir = path.join(root, "test-artifacts", "native-regression");
const buildDir = path.join(outDir, "cargo-target");
const runRoot = path.join(outDir, "app-data");
const webviewRoot = path.join(outDir, "webview-data");
const inputsRoot = path.join(outDir, "inputs");
const testConfig = path.join(outDir, "tauri.e2e.conf.json");
const executable = path.join(buildDir, "release", "scum-mod-manager.exe");
const defaultBrowserArgs =
  "--disable-features=msWebOOUI,msPdfOOUI,msSmartScreenProtection";
const debugPort = Number(process.env.SCUM_MM_NATIVE_DEBUG_PORT ?? 19222);
const results = [];
const consoleErrors = [];
const runtimeErrors = [];
let child = null;
let socket = null;

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function cleanDirectory(target) {
  const normalized = path.resolve(target);
  assert(normalized.startsWith(path.resolve(outDir) + path.sep), `unsafe cleanup: ${normalized}`);
  fs.rmSync(normalized, { recursive: true, force: true });
  fs.mkdirSync(normalized, { recursive: true });
}

function wait(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

function ensurePortAvailable(port) {
  assert(Number.isInteger(port) && port > 1024 && port < 65536, `invalid debug port: ${port}`);
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.once("error", () =>
      reject(new Error(`native debug port ${port} is already in use`)),
    );
    server.listen(port, "127.0.0.1", () => {
      server.close(error => (error ? reject(error) : resolve()));
    });
  });
}

function buildTestExecutable(debugPort) {
  const sourceConfig = path.join(root, "src-tauri", "tauri.conf.json");
  const config = JSON.parse(fs.readFileSync(sourceConfig, "utf8"));
  const mainWindow = config.app?.windows?.find(window => window.label === "main");
  assert(mainWindow, "tauri.conf.json is missing the main window");
  mainWindow.additionalBrowserArgs = `${defaultBrowserArgs} --remote-debugging-port=${debugPort}`;
  const serialized = JSON.stringify(config, null, 2);
  if (!fs.existsSync(testConfig) || fs.readFileSync(testConfig, "utf8") !== serialized) {
    fs.writeFileSync(testConfig, serialized);
  }

  const tauriCli = path.join(root, "node_modules", "@tauri-apps", "cli", "tauri.js");
  const result = spawnSync(
    process.execPath,
    [tauriCli, "build", "--no-bundle", "--config", testConfig],
    {
      cwd: root,
      stdio: "inherit",
      windowsHide: true,
      env: {
        ...process.env,
        CARGO_TARGET_DIR: buildDir,
      },
    },
  );
  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error(`native test build failed with exit code ${result.status}`);
  }
}

async function waitForHttp(url, timeout = 45000) {
  const deadline = Date.now() + timeout;
  let lastError = null;
  while (Date.now() < deadline) {
    try {
      const response = await fetch(url);
      if (response.ok) return await response.json();
    } catch (error) {
      lastError = error;
    }
    await wait(250);
  }
  throw new Error(`等待 ${url} 超时：${lastError ?? "无响应"}`);
}

function killTree(process) {
  if (!process?.pid) return;
  spawnSync("taskkill", ["/PID", String(process.pid), "/T", "/F"], {
    stdio: "ignore",
    windowsHide: true,
  });
}

function resizeWindow(pid, width, height) {
  const script = `
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class NativeWindow {
  [DllImport("user32.dll", SetLastError = true)]
  public static extern bool SetWindowPos(
    IntPtr hWnd,
    IntPtr hWndInsertAfter,
    int x,
    int y,
    int width,
    int height,
    uint flags
  );
}
'@
$process = Get-Process -Id ${pid} -ErrorAction Stop
if ($process.MainWindowHandle -eq 0) { throw "main window handle is unavailable" }
if (-not [NativeWindow]::SetWindowPos(
  $process.MainWindowHandle,
  [IntPtr]::Zero,
  0,
  0,
  ${width},
  ${height},
  0x0002 -bor 0x0004
)) { throw "SetWindowPos failed" }
`;
  const result = spawnSync(
    "powershell.exe",
    ["-NoProfile", "-NonInteractive", "-Command", script],
    { stdio: "inherit", windowsHide: true },
  );
  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error(`failed to resize native window to ${width}x${height}`);
  }
}

async function connect(url) {
  const ws = new WebSocket(url);
  await new Promise((resolve, reject) => {
    ws.once("open", resolve);
    ws.once("error", reject);
  });
  socket = ws;
  let sequence = 0;
  const pending = new Map();

  ws.on("message", raw => {
    const message = JSON.parse(raw.toString());
    if (message.id && pending.has(message.id)) {
      const { resolve, reject } = pending.get(message.id);
      pending.delete(message.id);
      if (message.error) reject(new Error(JSON.stringify(message.error)));
      else resolve(message.result);
      return;
    }
    if (message.method === "Runtime.consoleAPICalled" && message.params.type === "error") {
      consoleErrors.push(
        message.params.args.map(item => item.value ?? item.description ?? "").join(" "),
      );
    }
    if (message.method === "Runtime.exceptionThrown") {
      runtimeErrors.push(
        `${message.params.exceptionDetails.text}: ${
          message.params.exceptionDetails.exception?.description ?? ""
        }`,
      );
    }
  });

  const send = (method, params = {}) =>
    new Promise((resolve, reject) => {
      const id = ++sequence;
      pending.set(id, { resolve, reject });
      ws.send(JSON.stringify({ id, method, params }));
    });

  async function evaluate(expression) {
    const response = await send("Runtime.evaluate", {
      expression,
      awaitPromise: true,
      returnByValue: true,
      userGesture: true,
    });
    if (response.exceptionDetails) {
      throw new Error(
        response.exceptionDetails.exception?.description ?? response.exceptionDetails.text,
      );
    }
    return response.result?.value;
  }

  async function waitFor(expression, timeout = 12000) {
    const deadline = Date.now() + timeout;
    while (Date.now() < deadline) {
      if (await evaluate(`Boolean(${expression})`)) return;
      await wait(100);
    }
    throw new Error(`等待超时：${expression}`);
  }

  async function invoke(command, args = {}) {
    return evaluate(
      `window.__TAURI_INTERNALS__.invoke(${JSON.stringify(command)}, ${JSON.stringify(args)})`,
    );
  }

  async function screenshot(name) {
    const image = await send("Page.captureScreenshot", {
      format: "png",
      fromSurface: true,
      captureBeyondViewport: false,
    });
    const target = path.join(outDir, `${name}.png`);
    fs.writeFileSync(target, Buffer.from(image.data, "base64"));
    return target;
  }

  async function test(name, action) {
    try {
      const detail = await action();
      results.push({ name, status: "PASS", detail: detail ?? null });
    } catch (error) {
      results.push({ name, status: "FAIL", detail: String(error?.stack ?? error) });
    }
  }

  await send("Page.enable");
  await send("Runtime.enable");
  await waitFor("document.querySelector('h1')?.innerText === '模组库'");
  await wait(600);

  await test("发布版本原生启动并加载隔离数据目录", async () => {
    const appInfo = await invoke("get_app_info");
    const actualRoot = path.resolve(appInfo.dataRoot);
    assert(
      actualRoot.toLowerCase() === path.resolve(runRoot).toLowerCase(),
      `dataRoot mismatch: ${actualRoot}`,
    );
    assert(appInfo.platform === "windows", `unexpected platform: ${appInfo.platform}`);
    assert(
      appInfo.edition === "public" || appInfo.edition === "server",
      `unexpected edition: ${appInfo.edition}`,
    );
    assert(
      (await invoke("get_library_snapshot")).mods.length === 0,
      "isolated app data should start empty",
    );
    return { appInfo };
  });

  await test("原生 Rust 导入 PAK 与 UE4SS 文件夹", async () => {
    const result = await invoke("import_mods", {
      paths: [
        path.join(inputsRoot, "NativeWeapon.pak"),
        path.join(inputsRoot, "NativeAI"),
      ],
    });
    assert(result.imported === 2, `unexpected import result: ${JSON.stringify(result)}`);
    const snapshot = await invoke("get_library_snapshot");
    const types = new Map(snapshot.mods.map(mod => [mod.name, mod.type]));
    assert(types.get("NativeWeapon") === "clientPak", "PAK was not imported");
    assert(types.get("NativeAI") === "ue4ssMod", "UE4SS directory was not imported");
    return result;
  });

  await test("原生拖放事件显示目标并导入文件", async () => {
    const dragPath = path.join(inputsRoot, "NativeDrop.pak");
    await invoke("plugin:event|emit", {
      event: "tauri://drag-enter",
      payload: { paths: [dragPath], position: { x: 600, y: 300 } },
    });
    await waitFor("document.querySelector('.library-drop-overlay') !== null");
    await invoke("plugin:event|emit", {
      event: "tauri://drag-leave",
      payload: {},
    });
    await waitFor("document.querySelector('.library-drop-overlay') === null");
    await invoke("plugin:event|emit", {
      event: "tauri://drag-drop",
      payload: { paths: [dragPath], position: { x: 600, y: 300 } },
    });
    await waitFor("document.querySelectorAll('.mod-row').length === 3");
    await waitFor("document.body.innerText.includes('导入完成')");
    return { rows: await evaluate("document.querySelectorAll('.mod-row').length") };
  });

  await test("原生标题栏、窗口尺寸与截图", async () => {
    const info = await evaluate(`(() => {
      const labels = ["最小化", "最大化", "关闭"];
      return {
        viewport: { width: innerWidth, height: innerHeight },
        dragRegion:
          document.querySelector(".title-status")?.hasAttribute("data-tauri-drag-region") ??
          false,
        themeSwitchDrag:
          getComputedStyle(document.querySelector(".theme-switch"))
            .getPropertyValue("-webkit-app-region")
            .trim(),
        controls: Object.fromEntries(labels.map(label => {
          const box = document.querySelector('button[aria-label="' + label + '"]')
            ?.getBoundingClientRect();
          return [label, box ? { width: box.width, height: box.height, right: box.right } : null];
        })),
        overflow: document.documentElement.scrollWidth > innerWidth + 1,
      };
    })()`);
    for (const [label, rect] of Object.entries(info.controls)) {
      assert(rect && rect.width >= 20 && rect.height >= 20, `${label} is not visible`);
      assert(rect.right <= info.viewport.width + 1, `${label} is clipped`);
    }
    assert(info.dragRegion, "title status drag region is missing");
    assert(info.themeSwitchDrag === "no-drag", "title bar button lost its no-drag region");
    assert(!info.overflow, "native page has horizontal overflow");
    return { info, screenshot: await screenshot("native-library-after-drop") };
  });

  await test("原生窄窗标题栏不丢失", async () => {
    resizeWindow(child.pid, 1000, 700);
    await waitFor("innerWidth <= 1100 && innerHeight <= 760");
    await wait(450);
    const info = await evaluate(`(() => {
      const labels = ["最小化", "最大化", "关闭"];
      return {
        viewport: { width: innerWidth, height: innerHeight },
        controls: Object.fromEntries(labels.map(label => {
          const box = document.querySelector('button[aria-label="' + label + '"]')
            ?.getBoundingClientRect();
          return [label, box ? { width: box.width, height: box.height, right: box.right } : null];
        })),
        overflow: document.documentElement.scrollWidth > innerWidth + 1,
      };
    })()`);
    for (const [label, rect] of Object.entries(info.controls)) {
      assert(rect && rect.width >= 20 && rect.height >= 20, `${label} disappeared in narrow window`);
      assert(rect.right <= info.viewport.width + 1, `${label} is clipped in narrow window`);
    }
    assert(!info.overflow, "narrow native page has horizontal overflow");
    return { info, screenshot: await screenshot("native-narrow-window") };
  });

  await test("原生最大化切换命令", async () => {
    await invoke("window_toggle_maximize");
    await wait(500);
    const maximized = await invoke("plugin:window|is_maximized", { label: "main" });
    await invoke("window_toggle_maximize");
    await wait(400);
    const restored = await invoke("plugin:window|is_maximized", { label: "main" });
    assert(maximized === true, "window did not maximize");
    assert(restored === false, "window did not restore");
    return { maximized, restored };
  });

  await test("原生关闭清理并退出进程", async () => {
    const pid = child.pid;
    // Closing the WebView destroys the IPC channel before invoke() can resolve.
    await evaluate(
      `setTimeout(() => window.__TAURI_INTERNALS__.invoke("window_close"), 100); true`,
    );
    const deadline = Date.now() + 12000;
    while (Date.now() < deadline) {
      const alive = spawnSync(
        "powershell",
        ["-NoProfile", "-Command", `if (Get-Process -Id ${pid} -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }`],
        { stdio: "ignore", windowsHide: true },
      );
      if (alive.status === 1) return { pid };
      await wait(250);
    }
    throw new Error(`process ${pid} did not exit after window_close`);
  });

  return {
    generatedAt: new Date().toISOString(),
    executable,
    dataRoot: runRoot,
    results,
    consoleErrors,
    runtimeErrors,
    passed: results.filter(item => item.status === "PASS").length,
    failed: results.filter(item => item.status === "FAIL").length,
  };
}

let report = null;
try {
  fs.mkdirSync(outDir, { recursive: true });
  cleanDirectory(runRoot);
  cleanDirectory(webviewRoot);
  cleanDirectory(inputsRoot);
  fs.writeFileSync(path.join(inputsRoot, "NativeWeapon.pak"), "native pak");
  fs.writeFileSync(path.join(inputsRoot, "NativeDrop.pak"), "native drop pak");
  fs.mkdirSync(path.join(inputsRoot, "NativeAI", "Scripts"), { recursive: true });
  fs.writeFileSync(
    path.join(inputsRoot, "NativeAI", "Scripts", "main.lua"),
    "print('native')",
  );

  await ensurePortAvailable(debugPort);
  buildTestExecutable(debugPort);
  assert(fs.existsSync(executable), `native test executable not found: ${executable}`);
  child = spawn(executable, [], {
    cwd: root,
    stdio: "ignore",
    windowsHide: true,
    env: {
      ...process.env,
      SCUM_MM_ROOT: runRoot,
      WEBVIEW2_USER_DATA_FOLDER: webviewRoot,
    },
  });
  const targets = await waitForHttp(`http://127.0.0.1:${debugPort}/json/list`);
  const target = targets.find(item => item.type === "page");
  assert(target, "native WebView2 page target not found");
  report = await connect(target.webSocketDebuggerUrl);
  fs.writeFileSync(
    path.join(outDir, "functional-report.json"),
    JSON.stringify(report, null, 2),
  );
  console.log(
    JSON.stringify(
      {
        outDir,
        passed: report.passed,
        failed: report.failed,
        consoleErrors: report.consoleErrors,
        runtimeErrors: report.runtimeErrors,
        failures: report.results.filter(item => item.status === "FAIL"),
      },
      null,
      2,
    ),
  );
  if (report.failed > 0 || report.consoleErrors.length || report.runtimeErrors.length) {
    process.exitCode = 1;
  }
} finally {
  socket?.close();
  if (child && child.exitCode === null) killTree(child);
}
