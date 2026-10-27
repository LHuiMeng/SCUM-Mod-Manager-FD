import { spawn, spawnSync } from "node:child_process";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import WebSocket from "ws";

const root = path.resolve(import.meta.dirname, "..");
const outDir = path.join(root, "test-artifacts", "ui-regression");
const children = [];
let activeSocket = null;
let browserProfile = null;

fs.mkdirSync(outDir, { recursive: true });

function wait(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

function freePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      const port = typeof address === "object" && address ? address.port : 0;
      server.close(error => (error ? reject(error) : resolve(port)));
    });
  });
}

async function waitForHttp(url, timeout = 30000) {
  const deadline = Date.now() + timeout;
  let lastError = null;
  while (Date.now() < deadline) {
    try {
      const response = await fetch(url);
      if (response.ok) return;
    } catch (error) {
      lastError = error;
    }
    await wait(150);
  }
  throw new Error(`等待 ${url} 超时：${lastError ?? "无响应"}`);
}

function browserExecutable() {
  const candidates = [
    process.env.EDGE_PATH,
    process.env["ProgramFiles(x86)"]
      ? path.join(process.env["ProgramFiles(x86)"], "Microsoft", "Edge", "Application", "msedge.exe")
      : null,
    process.env.ProgramFiles
      ? path.join(process.env.ProgramFiles, "Microsoft", "Edge", "Application", "msedge.exe")
      : null,
    process.env.LOCALAPPDATA
      ? path.join(process.env.LOCALAPPDATA, "Microsoft", "Edge", "Application", "msedge.exe")
      : null,
    process.env.ProgramFiles
      ? path.join(process.env.ProgramFiles, "Google", "Chrome", "Application", "chrome.exe")
      : null,
  ].filter(Boolean);
  const found = candidates.find(candidate => fs.existsSync(candidate));
  if (!found) {
    throw new Error("未找到 Microsoft Edge 或 Google Chrome，无法运行浏览器回归测试。");
  }
  return found;
}

function killTree(child) {
  if (!child?.pid) return;
  if (process.platform === "win32") {
    spawnSync("taskkill", ["/PID", String(child.pid), "/T", "/F"], {
      stdio: "ignore",
      windowsHide: true,
    });
  } else {
    child.kill("SIGTERM");
  }
}

async function connect(url, appUrl) {
  const socket = new WebSocket(url);
  await new Promise((resolve, reject) => {
    socket.once("open", resolve);
    socket.once("error", reject);
  });
  activeSocket = socket;
  let sequence = 0;
  const pending = new Map();
  const consoleErrors = [];
  const runtimeErrors = [];
  const pageErrors = [];

  socket.on("message", raw => {
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
    if (message.method === "Log.entryAdded" && message.params.entry.level === "error") {
      const url = message.params.entry.url ?? "";
      if (!url.endsWith("/favicon.ico")) {
        pageErrors.push({ text: message.params.entry.text, url });
      }
    }
  });

  const send = (method, params = {}) =>
    new Promise((resolve, reject) => {
      const id = ++sequence;
      pending.set(id, { resolve, reject });
      socket.send(JSON.stringify({ id, method, params }));
    });

  async function evaluate(expression) {
    const result = await send("Runtime.evaluate", {
      expression,
      awaitPromise: true,
      returnByValue: true,
      userGesture: true,
    });
    if (result.exceptionDetails) {
      throw new Error(
        result.exceptionDetails.exception?.description ?? result.exceptionDetails.text,
      );
    }
    return result.result?.value;
  }

  async function waitFor(expression, timeout = 7000) {
    const deadline = Date.now() + timeout;
    while (Date.now() < deadline) {
      if (await evaluate(`Boolean(${expression})`)) return;
      await wait(80);
    }
    throw new Error(`等待超时：${expression}`);
  }

  async function clickAria(label) {
    const clicked = await evaluate(`(() => {
      const button = document.querySelector(${JSON.stringify(`button[aria-label="${label}"]`)});
      if (!button) return false;
      button.click();
      return true;
    })()`);
    if (!clicked) throw new Error(`找不到按钮 aria-label=${label}`);
  }

  async function clickText(text, selector = "button") {
    const clicked = await evaluate(`(() => {
      const element = [...document.querySelectorAll(${JSON.stringify(selector)})]
        .find(item => item.innerText.trim().includes(${JSON.stringify(text)}));
      if (!element) return false;
      element.click();
      return true;
    })()`);
    if (!clicked) throw new Error(`找不到文本按钮：${text}`);
  }

  async function setInput(placeholder, value, selector = "input") {
    const changed = await evaluate(`(() => {
      const input = document.querySelector(${JSON.stringify(`${selector}[placeholder="${placeholder}"]`)});
      if (!input) return false;
      const proto = input instanceof HTMLTextAreaElement
        ? HTMLTextAreaElement.prototype
        : HTMLInputElement.prototype;
      Object.getOwnPropertyDescriptor(proto, "value").set.call(input, ${JSON.stringify(value)});
      input.dispatchEvent(new Event("input", { bubbles: true }));
      input.dispatchEvent(new Event("change", { bubbles: true }));
      return true;
    })()`);
    if (!changed) throw new Error(`找不到输入框：${placeholder}`);
  }

  async function setInputByLabel(labelText, value) {
    const changed = await evaluate(`(() => {
      const label = [...document.querySelectorAll("label")]
        .find(item => item.innerText.includes(${JSON.stringify(labelText)}));
      const input = label?.querySelector("input, textarea");
      if (!input) return false;
      const proto = input instanceof HTMLTextAreaElement
        ? HTMLTextAreaElement.prototype
        : HTMLInputElement.prototype;
      Object.getOwnPropertyDescriptor(proto, "value").set.call(input, ${JSON.stringify(value)});
      input.dispatchEvent(new Event("input", { bubbles: true }));
      input.dispatchEvent(new Event("change", { bubbles: true }));
      return true;
    })()`);
    if (!changed) throw new Error(`找不到字段：${labelText}`);
  }

  async function navigate(label) {
    await clickAria(label);
    const heading = {
      模组库: "模组库",
      云端: "云端目录",
      服务器: "远程服务器",
      日志: "运行日志",
      设置: "设置",
    }[label];
    await waitFor(`document.querySelector("h1")?.innerText === ${JSON.stringify(heading)}`);
    await wait(150);
  }

  async function layout() {
    return evaluate(`(() => {
      const rect = element => {
        const box = element?.getBoundingClientRect();
        return box
          ? {
              left: box.left,
              top: box.top,
              right: box.right,
              bottom: box.bottom,
              width: box.width,
              height: box.height,
            }
          : null;
      };
      const labels = ["最小化", "最大化", "关闭"];
      return {
        viewport: { width: innerWidth, height: innerHeight },
        documentWidth: document.documentElement.scrollWidth,
        bodyWidth: document.body.scrollWidth,
        bodyHeight: document.body.scrollHeight,
        title: rect(document.querySelector(".titlebar")),
        content: rect(document.querySelector(".app-content")),
        controls: Object.fromEntries(
          labels.map(label => [
            label,
            rect(document.querySelector('button[aria-label="' + label + '"]')),
          ]),
        ),
        horizontalOverflow: document.documentElement.scrollWidth > innerWidth + 1,
        clipped: [...document.querySelectorAll("h1, button, input, textarea")]
          .filter(element => {
            const box = element.getBoundingClientRect();
            return box.width > 0 && (box.right > innerWidth + 1 || box.left < -1);
          })
          .slice(0, 12)
          .map(element => ({
            tag: element.tagName,
            text: (element.innerText || element.value || "").slice(0, 40),
            className: element.className,
          })),
      };
    })()`);
  }

  async function screenshot(name) {
    const result = await send("Page.captureScreenshot", {
      format: "png",
      fromSurface: true,
      captureBeyondViewport: false,
    });
    const file = path.join(outDir, `${name}.png`);
    fs.writeFileSync(file, Buffer.from(result.data, "base64"));
    return file;
  }

  const results = [];
  const screenshots = [];
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
  await send("Log.enable");
  await send("Emulation.setDeviceMetricsOverride", {
    width: 1440,
    height: 900,
    deviceScaleFactor: 1,
    mobile: false,
  });
  await send("Page.navigate", { url: appUrl });
  await waitFor(
    `location.href.startsWith(${JSON.stringify(appUrl)}) &&
      document.readyState === "complete" &&
      document.querySelector("h1") !== null`,
    10000,
  );
  await evaluate("localStorage.clear(); sessionStorage.clear(); true");
  await send("Page.reload", { ignoreCache: true });
  await waitFor("document.querySelector('h1') !== null", 10000);
  await waitFor("document.querySelectorAll('.mod-row').length > 0", 10000);
  await wait(500);

  await test("1440x900 模组库布局、窗口控件与单一主操作", async () => {
    const info = await layout();
    const primary = await evaluate(
      "document.querySelectorAll('.page-transition .button-primary').length",
    );
    if (info.horizontalOverflow) throw new Error("出现横向溢出");
    if (info.clipped.length) throw new Error(`控件越界：${JSON.stringify(info.clipped)}`);
    for (const [label, rect] of Object.entries(info.controls)) {
      if (!rect || rect.width < 20 || rect.height < 20 || rect.right > info.viewport.width + 1) {
        throw new Error(`${label} 不可见`);
      }
    }
    if (primary !== 1) throw new Error(`主操作数量应为 1，实际 ${primary}`);
    screenshots.push(await screenshot("1440-light-library-initial"));
    return { info, primary };
  });

  await test("搜索、清空与筛选", async () => {
    const before = await evaluate("document.querySelectorAll('.mod-row').length");
    await setInput("搜索模组、标签或备注", "WeaponPack");
    await waitFor("document.querySelectorAll('.mod-row').length === 1");
    await setInput("搜索模组、标签或备注", "");
    await waitFor(`document.querySelectorAll('.mod-row').length === ${before}`);
    await clickText("客户端 PAK");
    const clientRows = await evaluate("document.querySelectorAll('.mod-row').length");
    await clickText("全部");
    const allRows = await evaluate("document.querySelectorAll('.mod-row').length");
    if (clientRows <= 0 || allRows !== before) throw new Error("筛选结果异常");
    return { before, clientRows, allRows };
  });

  await test("三种排序循环", async () => {
    const label = () => evaluate("document.querySelector('.table-toolbar-right span')?.innerText");
    const seen = [await label()];
    for (let index = 0; index < 3; index += 1) {
      await clickAria("切换排序方式");
      await wait(100);
      seen.push(await label());
    }
    if (
      !seen.includes("按名称") ||
      !seen.includes("按文件大小") ||
      seen.at(-1) !== "按加载顺序"
    ) {
      throw new Error(`排序循环异常：${seen}`);
    }
    return seen;
  });

  await test("选择行与启停状态恢复", async () => {
    await evaluate("document.querySelector('.mod-row')?.click()");
    await waitFor("document.querySelector('.mod-row.is-selected') !== null");
    const selector = '.mod-row.is-selected button[role="switch"]';
    const before = await evaluate(
      `document.querySelector(${JSON.stringify(selector)})?.getAttribute("aria-checked")`,
    );
    await evaluate(`document.querySelector(${JSON.stringify(selector)})?.click()`);
    await waitFor(
      `document.querySelector(${JSON.stringify(selector)})?.getAttribute("aria-checked") !== ${JSON.stringify(
        before,
      )}`,
    );
    const after = await evaluate(
      `document.querySelector(${JSON.stringify(selector)})?.getAttribute("aria-checked")`,
    );
    await evaluate(`document.querySelector(${JSON.stringify(selector)})?.click()`);
    await waitFor(
      `document.querySelector(${JSON.stringify(selector)})?.getAttribute("aria-checked") === ${JSON.stringify(
        before,
      )}`,
    );
    return { before, after };
  });

  await test("启动选项弹层与参数切换", async () => {
    await clickText("启动选项");
    await waitFor("document.querySelector('[role=\"dialog\"][aria-label=\"启动选项\"]') !== null");
    const selector = 'button[role="switch"][aria-label="启用日志"]';
    const before = await evaluate(
      `document.querySelector(${JSON.stringify(selector)})?.getAttribute("aria-checked")`,
    );
    await evaluate(`document.querySelector(${JSON.stringify(selector)})?.click()`);
    await waitFor(
      `document.querySelector(${JSON.stringify(selector)})?.getAttribute("aria-checked") !== ${JSON.stringify(
        before,
      )}`,
    );
    await evaluate(
      "document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true })); true",
    );
    await waitFor("document.querySelector('[role=\"dialog\"][aria-label=\"启动选项\"]') === null");
    return { before };
  });

  await test("编辑标签与备注", async () => {
    await clickText("编辑标签与备注");
    await waitFor("document.querySelector('#notes-input') !== null");
    await setInput("记录兼容性、服务器用途或测试结果...", "QA regression note", "textarea");
    await setInput("输入后回车添加", "QA", "input");
    await evaluate(
      "document.querySelector('#tag-input')?.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true })); true",
    );
    await clickText("保存修改");
    await waitFor("document.querySelector('#notes-input') === null");
    await waitFor("document.body.innerText.includes('QA regression note')");
    return null;
  });

  await test("扫描、启动与停止游戏反馈", async () => {
    await clickText("扫描");
    await waitFor("document.body.innerText.includes('扫描完成')");
    await clickText("启动客户端");
    await waitFor("document.body.innerText.includes('停止游戏')", 10000);
    await clickText("停止游戏");
    await waitFor("document.body.innerText.includes('启动客户端')", 10000);
    return null;
  });

  await test("更新通知、下载安装流程与弹窗", async () => {
    await waitFor("document.body.innerText.includes('3.0.1 可用')", 10000);
    await clickText("3.0.1 可用");
    await waitFor("document.body.innerText.includes('发现新版本 3.0.1')");
    screenshots.push(await screenshot("1440-light-update-dialog"));
    await clickText("下载并安装");
    await waitFor(
      "document.body.innerText.includes('正在校验') || document.body.innerText.includes('正在安装')",
      10000,
    );
    screenshots.push(await screenshot("1440-light-update-progress"));
    return null;
  });

  await send("Page.reload", { ignoreCache: true });
  await waitFor("document.querySelector('h1') !== null", 10000);
  await waitFor("document.querySelectorAll('.mod-row').length > 0", 10000);
  await wait(350);

  await test("亮暗主题切换、持久化与中性石墨色", async () => {
    await clickAria("切换至暗色主题");
    await waitFor("document.documentElement.dataset.theme === 'dark'");
    const dark = await evaluate(`(() => {
      const style = getComputedStyle(document.documentElement);
      const selectedRow = getComputedStyle(document.querySelector(".mod-row.is-selected"));
      return {
        theme: document.documentElement.dataset.theme,
        stored: localStorage.getItem("scum-theme"),
        paper: style.getPropertyValue("--paper").trim(),
        paperHi: style.getPropertyValue("--paper-hi").trim(),
        accent: style.getPropertyValue("--accent").trim(),
        selectedRowBackground: selectedRow.backgroundColor,
        selectedRowTransition: selectedRow.transitionProperty,
      };
    })()`);
    if (
      dark.paper !== "#151515" ||
      dark.paperHi !== "#1c1c1c" ||
      dark.accent !== "#e1724b"
    ) {
      throw new Error(`暗色 token 异常：${JSON.stringify(dark)}`);
    }
    if (
      dark.selectedRowBackground !== "rgb(28, 28, 28)" ||
      dark.selectedRowTransition.includes("background")
    ) {
      throw new Error(`暗色选中行对比度过渡异常：${JSON.stringify(dark)}`);
    }
    screenshots.push(await screenshot("1440-dark-library"));
    await clickAria("切换至亮色主题");
    await waitFor("document.documentElement.dataset.theme === 'light'");
    return dark;
  });

  await test("设置页路径检测、云源保存与保存反馈", async () => {
    await navigate("设置");
    await clickText("自动检测路径");
    await waitFor("document.body.innerText.includes('路径检测完成')");
    await wait(400);
    await setInput("https://your-catalog.example", "https://catalog.example.test", "textarea");
    await waitFor(
      "document.querySelector('textarea[placeholder=\"https://your-catalog.example\"]')?.value === 'https://catalog.example.test'",
    );
    await clickText("保存设置");
    await waitFor("document.body.innerText.includes('设置已保存')");
    const info = await layout();
    if (info.horizontalOverflow) throw new Error("设置页横向溢出");
    screenshots.push(await screenshot("1440-light-settings"));
    return info;
  });

  await test("云端目录加载、搜索与下载反馈", async () => {
    await navigate("云端");
    await waitFor("document.querySelectorAll('.remote-card').length === 3", 10000);
    const cloudCopy = await evaluate(
      "document.querySelector('.page-cloud')?.innerText ?? ''",
    );
    if (!cloudCopy.includes("服务器版目录")) {
      throw new Error(`服务器版目录说明缺失：${cloudCopy.slice(0, 160)}`);
    }
    if (/连接 Steam|Steam 白名单/.test(cloudCopy)) {
      throw new Error("云端页仍包含已移除的 Steam 登录入口");
    }
    await setInput("搜索云端模组", "Vehicle");
    await waitFor("document.querySelectorAll('.remote-card').length === 1");
    await clickText("下载");
    await waitFor("document.body.innerText.includes('下载完成')", 10000);
    await setInput("搜索云端模组", "");
    await waitFor("document.querySelectorAll('.remote-card').length === 3");
    screenshots.push(await screenshot("1440-light-cloud"));
    return null;
  });

  await test("SFTP 账户保存、连接与目录加载", async () => {
    await navigate("服务器");
    await setInputByLabel("服务器地址", "sftp.example.com");
    await setInputByLabel("用户名", "modder");
    await setInputByLabel("密码", "not-a-real-secret");
    await setInputByLabel("远端 ~mods 路径", "/srv/scum/SCUM/Content/Paks/~mods");
    await clickText("安全保存账户");
    await waitFor("document.body.innerText.includes('SFTP 账户已安全保存')", 10000);
    await clickText("测试连接");
    await waitFor("document.querySelectorAll('.remote-file-row').length > 0", 10000);
    screenshots.push(await screenshot("1440-light-server"));
    return { rows: await evaluate("document.querySelectorAll('.remote-file-row').length") };
  });

  await test("日志刷新、筛选与清空", async () => {
    await navigate("日志");
    await waitFor("document.querySelectorAll('.log-line').length > 0", 10000);
    await clickText("INFO");
    const filtered = await evaluate("document.querySelectorAll('.log-line').length");
    await clickText("全部");
    await clickText("清空");
    await waitFor("document.body.innerText.includes('没有日志')");
    screenshots.push(await screenshot("1440-light-logs-empty"));
    return { filtered };
  });

  await test("1100x720 所有页面无横向溢出", async () => {
    await send("Emulation.setDeviceMetricsOverride", {
      width: 1100,
      height: 720,
      deviceScaleFactor: 1,
      mobile: false,
    });
    await wait(250);
    const report = {};
    for (const [label, page] of [
      ["模组库", "library"],
      ["云端", "cloud"],
      ["服务器", "server"],
      ["日志", "logs"],
      ["设置", "settings"],
    ]) {
      await navigate(label);
      const info = await layout();
      if (info.horizontalOverflow || info.clipped.length) {
        throw new Error(`${page} 越界：${JSON.stringify(info)}`);
      }
      report[page] = info;
    }
    screenshots.push(await screenshot("1100-light-settings"));
    return report;
  });

  await test("窄窗 980x640 与 800x640 标题栏三控件始终可见", async () => {
    const report = {};
    for (const [width, height] of [
      [980, 640],
      [800, 640],
    ]) {
      await send("Emulation.setDeviceMetricsOverride", {
        width,
        height,
        deviceScaleFactor: 1,
        mobile: false,
      });
      await wait(250);
      const info = await layout();
      for (const label of ["最小化", "最大化", "关闭"]) {
        const rect = info.controls[label];
        if (!rect || rect.width < 20 || rect.height < 20 || rect.right > width + 1) {
          throw new Error(`${width}x${height} ${label}：${JSON.stringify(rect)}`);
        }
      }
      if (info.horizontalOverflow) throw new Error(`${width}x${height} 横向溢出`);
      report[`${width}x${height}`] = info;
      screenshots.push(await screenshot(`${width}-title-controls`));
    }
    return report;
  });

  await test("窄窗 980x640 模组库容量信息不折行", async () => {
    await send("Emulation.setDeviceMetricsOverride", {
      width: 980,
      height: 640,
      deviceScaleFactor: 1,
      mobile: false,
    });
    await navigate("模组库");
    await waitFor("document.querySelector('.usage-top') !== null");
    const usage = await evaluate(`(() => {
      const value = document.querySelector(".usage-top > span:last-child");
      const label = document.querySelector(".usage-top > span:first-child");
      const range = document.createRange();
      range.selectNodeContents(value);
      const lines = new Set(
        [...range.getClientRects()]
          .filter(rect => rect.width > 0 && rect.height > 0)
          .map(rect => Math.round(rect.top))
      ).size;
      return {
        lines,
        labelVisible: getComputedStyle(label).display !== "none",
        text: value.innerText,
      };
    })()`);
    if (usage.lines !== 1) throw new Error(`容量信息折行：${JSON.stringify(usage)}`);
    if (usage.labelVisible) throw new Error("窄窗仍显示重复的容量标签");
    screenshots.push(await screenshot("980-library"));
    return usage;
  });

  await test("减弱动效偏好生效", async () => {
    await send("Emulation.setEmulatedMedia", {
      features: [{ name: "prefers-reduced-motion", value: "reduce" }],
    });
    await wait(100);
    const durations = await evaluate(`(() => {
      const page = getComputedStyle(document.querySelector(".page-transition"));
      const button = getComputedStyle(document.querySelector("button"));
      return {
        pageAnimation: page.animationDuration,
        pageTransition: page.transitionDuration,
        buttonTransition: button.transitionDuration,
      };
    })()`);
    if (
      ![
        durations.pageAnimation,
        durations.pageTransition,
        durations.buttonTransition,
      ].every(value => value === "0s" || parseFloat(value) <= 0.00002)
    ) {
      throw new Error(`减弱动效未生效：${JSON.stringify(durations)}`);
    }
    await send("Emulation.setEmulatedMedia", { features: [] });
    return durations;
  });

  await send("Emulation.setDeviceMetricsOverride", {
    width: 1440,
    height: 900,
    deviceScaleFactor: 1,
    mobile: false,
  });
  await wait(150);
  const report = {
    generatedAt: new Date().toISOString(),
    viewport: "1440x900 / 1100x720 / 980x640 / 800x640",
    results,
    runtimeErrors,
    consoleErrors,
    pageErrors,
    screenshots,
    passed: results.filter(item => item.status === "PASS").length,
    failed: results.filter(item => item.status === "FAIL").length,
  };
  fs.writeFileSync(
    path.join(outDir, "functional-report.json"),
    JSON.stringify(report, null, 2),
  );
  return report;
}

let report = null;
try {
  const previewPort = await freePort();
  const debugPort = await freePort();
  const appUrl = `http://127.0.0.1:${previewPort}/`;
  const preview = spawn(
    process.execPath,
    [
      path.join(root, "node_modules", "vite", "bin", "vite.js"),
      "preview",
      "--host",
      "127.0.0.1",
      "--port",
      String(previewPort),
      "--strictPort",
    ],
    {
      cwd: root,
      stdio: ["ignore", "pipe", "pipe"],
      windowsHide: true,
    },
  );
  children.push(preview);
  let previewError = "";
  preview.stderr.on("data", chunk => {
    previewError += chunk.toString();
  });
  await waitForHttp(appUrl);

  browserProfile = fs.mkdtempSync(path.join(os.tmpdir(), "scum-ui-regression-"));
  const browser = spawn(
    browserExecutable(),
    [
      "--headless=new",
      `--remote-debugging-port=${debugPort}`,
      `--user-data-dir=${browserProfile}`,
      "--no-first-run",
      "--disable-gpu",
      "--disable-extensions",
      "--disable-background-networking",
      appUrl,
    ],
    {
      stdio: "ignore",
      windowsHide: true,
    },
  );
  children.push(browser);
  await waitForHttp(`http://127.0.0.1:${debugPort}/json/version`);
  const targets = await (
    await fetch(`http://127.0.0.1:${debugPort}/json/list`)
  ).json();
  const target = targets.find(
    item => item.type === "page" && item.url.startsWith(appUrl),
  );
  if (!target) throw new Error(`未找到应用页面。${previewError}`);
  report = await connect(target.webSocketDebuggerUrl, appUrl);
  console.log(
    JSON.stringify(
      {
        outDir,
        passed: report.passed,
        failed: report.failed,
        runtimeErrors: report.runtimeErrors,
        consoleErrors: report.consoleErrors,
        pageErrors: report.pageErrors,
        failures: report.results.filter(item => item.status === "FAIL"),
      },
      null,
      2,
    ),
  );
  if (
    report.failed > 0 ||
    report.runtimeErrors.length ||
    report.consoleErrors.length ||
    report.pageErrors.length
  ) {
    process.exitCode = 1;
  }
} finally {
  activeSocket?.close();
  for (const child of children.reverse()) killTree(child);
  if (browserProfile) {
    await wait(500);
    try {
      fs.rmSync(browserProfile, {
        recursive: true,
        force: true,
        maxRetries: 10,
        retryDelay: 200,
      });
    } catch (error) {
      console.warn(`浏览器临时目录暂未释放：${error.message}`);
    }
  }
}
