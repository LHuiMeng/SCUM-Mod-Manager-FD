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
    await clickText(label, ".rail-button");
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
    const resizeHandles = await evaluate(
      "document.querySelectorAll('.window-resize-handle').length",
    );
    if (info.horizontalOverflow) throw new Error("出现横向溢出");
    if (info.clipped.length) throw new Error(`控件越界：${JSON.stringify(info.clipped)}`);
    for (const [label, rect] of Object.entries(info.controls)) {
      if (!rect || rect.width < 20 || rect.height < 20 || rect.right > info.viewport.width + 1) {
        throw new Error(`${label} 不可见`);
      }
    }
    if (primary !== 1) throw new Error(`主操作数量应为 1，实际 ${primary}`);
    if (resizeHandles !== 8) throw new Error(`窗口缩放命中区数量异常：${resizeHandles}`);
    screenshots.push(await screenshot("1440-light-library-initial"));
    return { info, primary, resizeHandles };
  });

  await test("拖拽排序实时显示插入槽位与其他模组让位", async () => {
    const setup = await evaluate(`(() => {
      const rows = [...document.querySelectorAll(".mod-row")];
      if (rows.length < 3) return null;
      const names = rows.map(row => row.querySelector(".mod-row-main > b")?.innerText ?? "");
      const source = rows[0];
      const target = rows[2];
      const sourceRect = source.getBoundingClientRect();
      const targetRect = target.getBoundingClientRect();
      window.__dragPoint = {
        x: sourceRect.left + Math.min(280, sourceRect.width * 0.48),
        startY: sourceRect.top + sourceRect.height * 0.48,
        targetY: targetRect.top + targetRect.height * 0.35,
      };
      source.dispatchEvent(new PointerEvent("pointerdown", {
        bubbles: true,
        cancelable: true,
        pointerId: 41,
        pointerType: "mouse",
        isPrimary: true,
        button: 0,
        buttons: 1,
        clientX: window.__dragPoint.x,
        clientY: window.__dragPoint.startY,
      }));
      return { names, sourceRect: { top: sourceRect.top }, targetRect: { top: targetRect.top } };
    })()`);
    if (!setup) throw new Error("拖拽回归需要至少三个模组");

    await evaluate(`window.dispatchEvent(new PointerEvent("pointermove", {
      bubbles: true,
      cancelable: true,
      pointerId: 41,
      pointerType: "mouse",
      isPrimary: true,
      buttons: 1,
      clientX: window.__dragPoint.x,
      clientY: window.__dragPoint.targetY,
    }))`);
    await waitFor("document.querySelector('.mod-row.is-dragging') !== null");
    await waitFor("document.querySelector('.mod-drop-indicator') !== null");
    const preview = await evaluate(`(() => {
      const source = document.querySelector(".mod-row.is-dragging");
      const shifted = [...document.querySelectorAll(".mod-row.is-drag-shift-up, .mod-row.is-drag-shift-down")];
      const indicator = document.querySelector(".mod-drop-indicator");
      const foot = document.querySelector(".table-foot b");
      return {
        sourceTransform: getComputedStyle(source).transform,
        shifted: shifted.map(row => ({
          id: row.dataset.modId,
          transform: getComputedStyle(row).transform,
          transitionDuration: getComputedStyle(row).transitionDuration,
        })),
        indicatorText: indicator?.innerText ?? "",
        markerTop: indicator?.style.getPropertyValue("--drop-marker-top") ?? "",
        footText: foot?.innerText ?? "",
        live: document.querySelector(".table-foot > span")?.getAttribute("aria-live"),
      };
    })()`);
    if (preview.sourceTransform === "none") throw new Error(`拖动行未跟随指针：${JSON.stringify(preview)}`);
    if (preview.shifted.length < 2) throw new Error(`其他模组没有让位：${JSON.stringify(preview)}`);
    if (preview.shifted.some(item => item.transform === "none")) {
      throw new Error(`让位行缺少过渡位移：${JSON.stringify(preview)}`);
    }
    if (!preview.shifted.some(item => item.transitionDuration.includes("0.32s"))) {
      throw new Error(`让位过渡时长不足：${JSON.stringify(preview.shifted)}`);
    }
    if (!preview.markerTop || !preview.indicatorText.includes("释放到第")) {
      throw new Error(`插入槽位提示缺失：${JSON.stringify(preview)}`);
    }
    if (!preview.footText.includes("释放到第 03 位") || preview.live !== "polite") {
      throw new Error(`拖拽状态反馈异常：${JSON.stringify(preview)}`);
    }
    const transitionSamples = [];
    for (const delay of [0, 90, 320]) {
      if (delay > 0) await wait(delay);
      transitionSamples.push(
        await evaluate(`getComputedStyle(
          document.querySelector(".mod-row.is-drag-shift-up, .mod-row.is-drag-shift-down")
        ).transform`),
      );
    }
    if (new Set(transitionSamples).size < 2) {
      throw new Error(`让位过程没有连续过渡：${JSON.stringify(transitionSamples)}`);
    }
    screenshots.push(await screenshot("1440-light-drag-preview"));

    await evaluate(`window.dispatchEvent(new PointerEvent("pointerup", {
      bubbles: true,
      pointerId: 41,
      pointerType: "mouse",
      isPrimary: true,
      button: 0,
      buttons: 0,
      clientX: window.__dragPoint.x,
      clientY: window.__dragPoint.targetY,
    }))`);
    await waitFor("document.querySelector('.mod-row.is-dragging') === null");
    await waitFor(
      `document.querySelector(".mod-row .mod-row-main > b")?.innerText === ${JSON.stringify(setup.names[1])}`,
      10000,
    );
    const settled = await evaluate(
      "Boolean(document.querySelector('.mod-row.is-drop-settled'))",
    );
    if (!settled) throw new Error("拖放结束后缺少落位反馈");
    await wait(420);
    return {
      names: setup.names,
      preview,
      transitionSamples,
      finalFirst: await evaluate(
        "document.querySelector('.mod-row .mod-row-main > b')?.innerText",
      ),
    };
  });

  await test("搜索、清空与筛选", async () => {
    const before = await evaluate("document.querySelectorAll('.mod-row').length");
    await setInput("搜索模组、标签或备注", "WeaponPack");
    await waitFor("document.querySelectorAll('.mod-row').length === 1");
    await setInput("搜索模组、标签或备注", "");
    await waitFor(`document.querySelectorAll('.mod-row').length === ${before}`);
    await clickText("客户端 PAK");
    const clientRows = await evaluate("document.querySelectorAll('.mod-row').length");
    const reflowing = await evaluate(`[...document.querySelectorAll(".mod-row")]
      .some(row => row.getAnimations().some(animation => {
        const timing = animation.effect?.getTiming();
        return timing?.duration === 260;
      }))`);
    if (!reflowing) throw new Error("筛选后的列表重排动效未生效");
    await clickText("全部");
    const allRows = await evaluate("document.querySelectorAll('.mod-row').length");
    if (clientRows <= 0 || allRows !== before) throw new Error("筛选结果异常");
    return { before, clientRows, allRows, reflowing };
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
    const feedbackClass = before === "true" ? "is-toggle-off" : "is-toggle-on";
    await waitFor(
      `document.querySelector(${JSON.stringify(selector)})?.closest(".mod-row")?.classList.contains(${JSON.stringify(
        feedbackClass,
      )})`,
    );
    const toggleMotion = await evaluate(`(() => {
      const row = document.querySelector(${JSON.stringify(selector)})?.closest(".mod-row");
      return {
        rowClass: row?.className ?? "",
        stateAnimation: getComputedStyle(row?.querySelector(".mod-state-pill")).animationName,
      };
    })()`);
    if (!toggleMotion.rowClass.includes(feedbackClass) ||
        !toggleMotion.stateAnimation.includes("motion-state-change")) {
      throw new Error(`启停动效未生效：${JSON.stringify(toggleMotion)}`);
    }
    const after = await evaluate(
      `document.querySelector(${JSON.stringify(selector)})?.getAttribute("aria-checked")`,
    );
    await evaluate(`document.querySelector(${JSON.stringify(selector)})?.click()`);
    await waitFor(
      `document.querySelector(${JSON.stringify(selector)})?.getAttribute("aria-checked") === ${JSON.stringify(
        before,
      )}`,
    );
    return { before, after, toggleMotion };
  });

  await test("冲突覆盖链、胜者保存与响应式弹层", async () => {
    const selected = await evaluate(`(() => {
      const row = [...document.querySelectorAll(".mod-row")]
        .find(item => item.querySelector(".mod-row-main > b")?.innerText === "SCUM_WeaponPack_Elite");
      if (!row) return false;
      row.click();
      return true;
    })()`);
    if (!selected) throw new Error("找不到用于冲突验收的模组行");
    await waitFor(
      `document.querySelector(".mod-row.is-selected .mod-row-main > b")?.innerText === "SCUM_WeaponPack_Elite"`,
    );

    const before = await evaluate(`(() => {
      const row = document.querySelector(".mod-row.is-selected");
      return {
        conflictPill: row?.querySelector(".mod-conflict-pill")?.innerText ?? "",
        healthTrigger: Boolean(document.querySelector(".inspector .conflict-health-trigger")),
      };
    })()`);
    if (!before.conflictPill.includes("覆盖") || !before.conflictPill.includes("被覆盖")) {
      throw new Error(`覆盖统计未显示：${JSON.stringify(before)}`);
    }
    if (!before.healthTrigger) throw new Error("冲突详情入口不存在");

    await evaluate("document.querySelector('.conflict-health-trigger')?.click()");
    await waitFor("document.querySelector('.conflict-panel') !== null");
    const panel = await evaluate(`(() => {
      const dialog = document.querySelector(".modal-card");
      const choices = [...document.querySelectorAll(".conflict-choice")];
      const paths = [...document.querySelectorAll(".conflict-paths code")];
      const rect = dialog?.getBoundingClientRect();
      return {
        title: document.querySelector("#modal-title")?.innerText ?? "",
        groups: document.querySelectorAll(".conflict-group").length,
        choices: choices.map(choice => choice.innerText),
        paths: paths.map(path => path.innerText),
        selected: choices.find(choice => choice.getAttribute("aria-checked") === "true")?.innerText ?? "",
        dialogInsideViewport: Boolean(rect && rect.left >= 0 && rect.right <= innerWidth + 1),
        horizontalOverflow: document.documentElement.scrollWidth > innerWidth + 1,
      };
    })()`);
    if (panel.title !== "覆盖关系") throw new Error(`冲突弹层标题异常：${JSON.stringify(panel)}`);
    if (panel.groups < 1 || panel.choices.length < 2 || panel.paths.length < 2) {
      throw new Error(`冲突详情内容不完整：${JSON.stringify(panel)}`);
    }
    if (!panel.paths.some(path => path.endsWith(".uasset")) ||
        !panel.paths.some(path => path.endsWith(".uexp"))) {
      throw new Error(`UE 资源组未完整展示：${JSON.stringify(panel.paths)}`);
    }
    if (!panel.dialogInsideViewport || panel.horizontalOverflow) {
      throw new Error(`冲突弹层越界：${JSON.stringify(panel)}`);
    }
    screenshots.push(await screenshot("1440-light-conflict"));

    await send("Emulation.setDeviceMetricsOverride", {
      width: 1100,
      height: 720,
      deviceScaleFactor: 1,
      mobile: false,
    });
    await wait(200);
    const narrow = await evaluate(`(() => {
      const dialog = document.querySelector(".modal-card");
      const rect = dialog?.getBoundingClientRect();
      const clipped = [...document.querySelectorAll(".modal-card button, .modal-card code")]
        .filter(element => {
          const box = element.getBoundingClientRect();
          return box.width > 0 && (box.right > innerWidth + 1 || box.left < -1);
        })
        .slice(0, 8)
        .map(element => (element.innerText || "").slice(0, 50));
      return {
        dialogInsideViewport: Boolean(rect && rect.left >= 0 && rect.right <= innerWidth + 1),
        horizontalOverflow: document.documentElement.scrollWidth > innerWidth + 1,
        clipped,
      };
    })()`);
    if (narrow.dialogInsideViewport === false || narrow.horizontalOverflow || narrow.clipped.length) {
      throw new Error(`1100 宽冲突弹层越界：${JSON.stringify(narrow)}`);
    }
    screenshots.push(await screenshot("1100-light-conflict"));
    await send("Emulation.setDeviceMetricsOverride", {
      width: 1440,
      height: 900,
      deviceScaleFactor: 1,
      mobile: false,
    });
    await wait(150);

    const picked = await evaluate(`(() => {
      const choice = [...document.querySelectorAll(".conflict-choice")]
        .find(item => item.innerText.includes("SCUM_WeaponPack_Elite"));
      if (!choice) return false;
      choice.click();
      return true;
    })()`);
    if (!picked) throw new Error("找不到覆盖胜者选项");
    await waitFor(
      `[...document.querySelectorAll(".conflict-choice")]
        .find(item => item.innerText.includes("SCUM_WeaponPack_Elite"))
        ?.getAttribute("aria-checked") === "true"`,
    );
    await clickText("保存覆盖选择", ".modal-foot button");
    await waitFor("document.querySelector('.conflict-panel') === null");
    await waitFor("document.body.innerText.includes('覆盖选择已保存')");
    await waitFor(
      `document.querySelector(".mod-row.is-selected .mod-conflict-pill")?.innerText.includes("覆盖 2 / 被覆盖 0")`,
    );

    await evaluate("document.querySelector('.conflict-health-trigger')?.click()");
    await waitFor("document.querySelector('.conflict-panel') !== null");
    const currentWinner = await evaluate(
      "document.querySelector('.conflict-winner-summary > div:nth-child(2) dd')?.innerText ?? ''",
    );
    if (currentWinner !== "SCUM_WeaponPack_Elite") {
      throw new Error(`当前胜者未更新：${currentWinner}`);
    }
    await clickText("取消", ".modal-foot button");
    await waitFor("document.querySelector('.conflict-panel') === null");
    return { before, panel, narrow, currentWinner };
  });

  await test("模组类型配色与完全覆盖淡化", async () => {
    const appearance = await evaluate(`(() => {
      const types = ["clientPak", "serverPak", "ue4ssMod", "configFile", "script", "other"];
      const colors = {};
      for (const type of types) {
        const row = document.createElement("div");
        row.className = "mod-row";
        row.dataset.modType = type;
        const label = document.createElement("span");
        label.className = "mod-type";
        row.appendChild(label);
        document.body.appendChild(row);
        colors[type] = getComputedStyle(label).color;
        row.remove();
      }
      const faded = document.createElement("div");
      faded.className = "mod-row is-fully-overridden";
      document.body.appendChild(faded);
      const opacity = Number(getComputedStyle(faded).opacity);
      faded.remove();
      return {
        colors,
        uniqueColors: new Set(Object.values(colors)).size,
        opacity,
      };
    })()`);
    if (appearance.uniqueColors !== 6) {
      throw new Error(`模组类型颜色未全部区分：${JSON.stringify(appearance)}`);
    }
    if (!(appearance.opacity > 0 && appearance.opacity < 1)) {
      throw new Error(`完全被覆盖行未淡化：${appearance.opacity}`);
    }
    return appearance;
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
    await clickAria("切换到暗色主题");
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
      dark.selectedRowBackground !== "rgb(35, 35, 35)" ||
      dark.selectedRowTransition.includes("background")
    ) {
      throw new Error(`暗色选中行对比度过渡异常：${JSON.stringify(dark)}`);
    }
    screenshots.push(await screenshot("1440-dark-library"));
    const conflictRow = await evaluate(`(() => {
      const row = [...document.querySelectorAll(".mod-row")]
        .find(item => item.querySelector(".mod-conflict-pill.has-conflict, .mod-conflict-pill.is-full"));
      if (!row) return false;
      row.click();
      return true;
    })()`);
    if (!conflictRow) throw new Error("暗色主题下找不到冲突模组");
    await waitFor("document.querySelector('.conflict-health-trigger') !== null");
    await evaluate("document.querySelector('.conflict-health-trigger')?.click()");
    await waitFor("document.querySelector('.conflict-panel') !== null");
    screenshots.push(await screenshot("1440-dark-conflict"));
    await clickText("取消", ".modal-foot button");
    await waitFor("document.querySelector('.conflict-panel') === null");
    await clickAria("切换到亮色主题");
    await waitFor("document.documentElement.dataset.theme === 'light'");
    return dark;
  });

  await test("设置页路径检测、云源保存与保存反馈", async () => {
    await navigate("设置");
    await clickText("自动检测路径");
    await waitFor("document.body.innerText.includes('已填入检测到的路径')");
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
    const cardLayout = await evaluate(`(() => {
      const cards = [...document.querySelectorAll(".remote-card")];
      const card = cards[0];
      const name = card.querySelector(".remote-name");
      const author = card.querySelector(".remote-byline");
      const description = card.querySelector(".remote-description");
      name.textContent = "Very Long Mod Name ".repeat(24);
      author.textContent = "VeryLongAuthorName".repeat(24);
      description.textContent = "这是一段用于验证长内容截断的超长模组描述。".repeat(120);
      const clampOf = (el) => getComputedStyle(el).webkitLineClamp || getComputedStyle(el).lineClamp;
      return {
        heights: cards.map(item => Math.round(item.getBoundingClientRect().height)),
        nameClamp: clampOf(name),
        descriptionClamp: clampOf(description),
        cardScroll: card.scrollHeight > card.clientHeight + 1,
        bylineTruncated: author.scrollWidth > author.clientWidth + 1,
      };
    })()`);
    if (cardLayout.nameClamp !== "2") {
      throw new Error(`模组名未限制为两行：${JSON.stringify(cardLayout)}`);
    }
    if (cardLayout.descriptionClamp !== "3") {
      throw new Error(`描述未限制为三行：${JSON.stringify(cardLayout)}`);
    }
    if (cardLayout.cardScroll) {
      throw new Error(`云端卡片内出现滚动容器：${JSON.stringify(cardLayout)}`);
    }
    if (!cardLayout.bylineTruncated) {
      throw new Error(`作者行未做省略：${JSON.stringify(cardLayout)}`);
    }
    screenshots.push(await screenshot("1440-light-cloud-long-content"));
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
    await waitFor("document.querySelector('.remote-viewer-item') !== null", 10000);
    await clickText("检查冲突");
    await waitFor("document.body.innerText.includes('已分析 2 个远端 PAK')", 10000);
    await setInput(
      "记录用途、版本、测试结果或回滚说明...",
      "QA remote note",
      "textarea",
    );
    await clickText("保存备注");
    await waitFor("document.body.innerText.includes('备注已保存')", 10000);
    await clickText("重命名");
    await waitFor(
      "document.querySelector('#modal-title')?.innerText === '重命名远端模组'",
    );
    await clickText("取消", ".modal-foot button");
    await clickText("删除");
    await waitFor(
      "document.querySelector('#modal-title')?.innerText === '删除远端模组'",
    );
    await clickText("取消", ".modal-foot button");
    const viewerHeight = await evaluate(
      "document.querySelector('.panel-viewer')?.getBoundingClientRect().height ?? 0",
    );
    if (viewerHeight <= 0 || viewerHeight > 760) {
      throw new Error(`模组查看器高度异常：${viewerHeight}`);
    }
    screenshots.push(await screenshot("1440-light-server"));
    return { rows: await evaluate("document.querySelectorAll('.remote-file-row').length") };
  });

  await test("SFTP 路径导航、全类型文件与布局编辑", async () => {
    const initial = await evaluate(`(() => ({
      lockedPanels: document.querySelectorAll(".server-panel-drag.is-locked").length,
      resizers: document.querySelectorAll(".server-panel-resizer").length,
      path: document.querySelector(".remote-path-controls input")?.value ?? "",
      files: [...document.querySelectorAll(".remote-file-row")]
        .map(row => row.innerText)
        .slice(0, 6),
    }))()`);
    if (initial.lockedPanels !== 3 || initial.resizers !== 0) {
      throw new Error(`默认布局未锁定：${JSON.stringify(initial)}`);
    }
    if (!initial.path.includes("/~mods")) {
      throw new Error(`初始远端路径异常：${initial.path}`);
    }
    if (!initial.files.some(text => text.includes("PAK"))) {
      throw new Error(`文件树未展示 PAK 类型：${JSON.stringify(initial.files)}`);
    }
    await evaluate("document.querySelector('.remote-file-row:not(.is-browsable)')?.click()");
    await waitFor("document.querySelector('.remote-file-selection') !== null");
    const selectedFile = await evaluate(`(() => ({
      text: document.querySelector(".remote-file-selection")?.innerText ?? "",
      download: Boolean(document.querySelector(".remote-file-selection button")),
    }))()`);
    if (!selectedFile.download || !selectedFile.text.toLowerCase().includes(".pak")) {
      throw new Error(`文件详情或下载入口缺失：${JSON.stringify(selectedFile)}`);
    }

    await clickText("上级目录");
    await waitFor(
      "document.querySelector('.remote-path-controls input')?.value === '/srv/scum/SCUM/Content/Paks'",
    );
    await waitFor(
      "document.querySelector('.remote-root-switches button:not(:disabled)') !== null",
    );
    await clickText("PAK 根目录");
    await waitFor(
      "document.querySelector('.remote-path-controls input')?.value === '/srv/scum/SCUM/Content/Paks/~mods'",
    );
    await waitFor(
      "document.querySelector('.remote-root-switches button:not(:disabled)') !== null",
    );
    await clickText("主目录");
    await waitFor("document.body.innerText.includes('该目录位于模组根目录之外，仅可浏览')");
    await waitFor(
      "document.querySelector('.remote-root-switches button:not(:disabled)') !== null",
    );
    await clickText("PAK 根目录");
    await waitFor(
      "document.querySelector('.remote-path-controls input')?.value === '/srv/scum/SCUM/Content/Paks/~mods'",
    );

    await clickText("编辑布局");
    await waitFor(
      "document.querySelector('.server-panel-stage.is-editing') !== null && document.querySelectorAll('.server-panel-resizer').length === 3",
    );
    const beforeMove = await evaluate(`(() => {
      const panel = document.querySelector(".panel-account");
      const drag = panel.querySelector(".server-panel-drag");
      const rect = panel.getBoundingClientRect();
      const dragRect = drag.getBoundingClientRect();
      window.__serverDrag = {
        x: dragRect.left + dragRect.width / 2,
        y: dragRect.top + dragRect.height / 2,
      };
      drag.dispatchEvent(new PointerEvent("pointerdown", {
        bubbles: true,
        cancelable: true,
        pointerId: 71,
        pointerType: "mouse",
        isPrimary: true,
        button: 0,
        buttons: 1,
        clientX: window.__serverDrag.x,
        clientY: window.__serverDrag.y,
      }));
      return { left: rect.left, top: rect.top, width: rect.width, height: rect.height };
    })()`);
    await evaluate(`window.dispatchEvent(new PointerEvent("pointermove", {
      bubbles: true,
      cancelable: true,
      pointerId: 71,
      pointerType: "mouse",
      isPrimary: true,
      buttons: 1,
      clientX: window.__serverDrag.x + 36,
      clientY: window.__serverDrag.y + 24,
    }))`);
    await wait(90);
    await evaluate(`window.dispatchEvent(new PointerEvent("pointerup", {
      bubbles: true,
      pointerId: 71,
      pointerType: "mouse",
      isPrimary: true,
      button: 0,
      buttons: 0,
      clientX: window.__serverDrag.x + 36,
      clientY: window.__serverDrag.y + 24,
    }))`);
    const afterMove = await evaluate(`(() => {
      const rect = document.querySelector(".panel-account").getBoundingClientRect();
      return { left: rect.left, top: rect.top, width: rect.width, height: rect.height };
    })()`);
    if (afterMove.left <= beforeMove.left + 4 || afterMove.top <= beforeMove.top + 4) {
      throw new Error(`面板未跟随拖拽：${JSON.stringify({ beforeMove, afterMove })}`);
    }

    const resizeStart = await evaluate(`(() => {
      const panel = document.querySelector(".panel-account");
      const handle = panel.querySelector(".server-panel-resizer");
      const rect = panel.getBoundingClientRect();
      const handleRect = handle.getBoundingClientRect();
      window.__serverResize = {
        x: handleRect.left + handleRect.width / 2,
        y: handleRect.top + handleRect.height / 2,
      };
      handle.dispatchEvent(new PointerEvent("pointerdown", {
        bubbles: true,
        cancelable: true,
        pointerId: 72,
        pointerType: "mouse",
        isPrimary: true,
        button: 0,
        buttons: 1,
        clientX: window.__serverResize.x,
        clientY: window.__serverResize.y,
      }));
      return { width: rect.width, height: rect.height };
    })()`);
    await evaluate(`window.dispatchEvent(new PointerEvent("pointermove", {
      bubbles: true,
      cancelable: true,
      pointerId: 72,
      pointerType: "mouse",
      isPrimary: true,
      buttons: 1,
      clientX: window.__serverResize.x + 42,
      clientY: window.__serverResize.y + 28,
    }))`);
    await wait(90);
    await evaluate(`window.dispatchEvent(new PointerEvent("pointerup", {
      bubbles: true,
      pointerId: 72,
      pointerType: "mouse",
      isPrimary: true,
      button: 0,
      buttons: 0,
      clientX: window.__serverResize.x + 42,
      clientY: window.__serverResize.y + 28,
    }))`);
    const resizeEnd = await evaluate(`(() => {
      const rect = document.querySelector(".panel-account").getBoundingClientRect();
      return { width: rect.width, height: rect.height };
    })()`);
    if (resizeEnd.width <= resizeStart.width + 8 || resizeEnd.height <= resizeStart.height + 8) {
      throw new Error(`面板未跟随缩放：${JSON.stringify({ resizeStart, resizeEnd })}`);
    }
    screenshots.push(await screenshot("1440-light-server-layout-edit"));

    await clickText("完成编辑");
    await waitFor(
      "document.querySelectorAll('.server-panel-resizer').length === 0 && document.querySelectorAll('.server-panel-drag.is-locked').length === 3",
    );
    await clickText("恢复布局");
    await wait(120);
    return {
      initial,
      beforeMove,
      afterMove,
      resizeStart,
      resizeEnd,
      lockedAfterFinish: await evaluate(
        "document.querySelectorAll('.server-panel-drag.is-locked').length",
      ),
    };
  });

  await test("日志刷新、筛选与清空", async () => {
    await navigate("日志");
    await waitFor("document.querySelectorAll('.log-line').length > 0", 10000);
    await clickText("信息");
    const filtered = await evaluate("document.querySelectorAll('.log-line').length");
    await clickText("全部");
    await clickText("清空");
    await clickText("确认清空");
    await waitFor("document.body.innerText.includes('没有日志')");
    screenshots.push(await screenshot("1440-light-logs-empty"));
    return { filtered };
  });

  await test("删除模组入口、重复副本备份与列表移除", async () => {
    await navigate("模组库");
    await evaluate(`(() => {
      const row = [...document.querySelectorAll(".mod-row")]
        .find(item => item.querySelector(".mod-row-main > b")?.innerText === "SCUM_WeaponPack_Elite");
      row?.click();
      return true;
    })()`);
    await waitFor(
      `document.querySelector(".mod-row.is-selected .mod-row-main > b")?.innerText === "SCUM_WeaponPack_Elite"`,
    );
    const rowCount = await evaluate("document.querySelectorAll('.mod-row').length");
    await clickText("删除模组", ".inspector-footer button");
    await waitFor("document.querySelector('.modal-card') !== null");
    const copy = await evaluate("document.querySelector('.modal-card')?.innerText ?? ''");
    if (!copy.includes("backups/deleted") || !copy.includes("另外 1 份相同副本")) {
      throw new Error(`删除确认未说明备份或重复副本：${copy.slice(0, 220)}`);
    }
    screenshots.push(await screenshot("1440-light-delete-confirm"));
    await clickText("移入备份", ".modal-foot button");
    await waitFor("document.querySelector('.mod-row.is-removing') !== null");
    const deleteMotion = await evaluate(
      "getComputedStyle(document.querySelector('.mod-row.is-removing')).animationName",
    );
    if (!deleteMotion.includes("motion-row-out")) {
      throw new Error(`删除收起动画未生效：${deleteMotion}`);
    }
    await waitFor("document.querySelector('.modal-card') === null");
    await waitFor(`document.querySelectorAll('.mod-row').length === ${rowCount - 1}`);
    await waitFor("document.body.innerText.includes('模组已移入备份')");
    const removed = await evaluate(
      `![...document.querySelectorAll(".mod-row-main > b")].some(item => item.innerText === "SCUM_WeaponPack_Elite")`,
    );
    if (!removed) throw new Error("删除后模组仍留在列表中");
    return { copy: copy.slice(0, 220), rowCountAfter: rowCount - 1, deleteMotion };
  });

  await test("中英文切换、持久化与英文窄窗布局", async () => {
    await navigate("设置");
    await clickText("English", ".language-options button");
    await waitFor("document.documentElement.lang === 'en-US'");
    await waitFor("document.querySelector('h1')?.innerText === 'Settings'");
    const stored = await evaluate("localStorage.getItem('scum-language')");
    if (stored !== "en-US") throw new Error(`语言未持久化：${stored}`);

    await send("Emulation.setDeviceMetricsOverride", {
      width: 1100,
      height: 720,
      deviceScaleFactor: 1,
      mobile: false,
    });
    await wait(200);
    const englishSettingsLayout = await evaluate(`(() => {
      const clipped = [...document.querySelectorAll("h1, button, input, textarea")]
        .filter(element => {
          const box = element.getBoundingClientRect();
          return box.width > 0 && (box.right > innerWidth + 1 || box.left < -1);
        })
        .slice(0, 12)
        .map(element => ({
          tag: element.tagName,
          text: (element.innerText || element.value || "").slice(0, 40),
          className: element.className,
        }));
      return {
        horizontalOverflow: document.documentElement.scrollWidth > innerWidth + 1,
        clipped,
      };
    })()`);
    if (englishSettingsLayout.horizontalOverflow || englishSettingsLayout.clipped.length) {
      throw new Error(`英文设置页越界：${JSON.stringify(englishSettingsLayout)}`);
    }
    screenshots.push(await screenshot("1100-en-settings"));
    await clickText("Library", ".rail-button");
    await waitFor("document.querySelector('h1')?.innerText === 'Mod Library'");
    await wait(200);
    const englishLayout = await evaluate(`(() => {
      const clipped = [...document.querySelectorAll("h1, button, input, textarea")]
        .filter(element => {
          const box = element.getBoundingClientRect();
          return box.width > 0 && (box.right > innerWidth + 1 || box.left < -1);
        })
        .slice(0, 12)
        .map(element => ({
          tag: element.tagName,
          text: (element.innerText || element.value || "").slice(0, 40),
          className: element.className,
        }));
      return {
        horizontalOverflow: document.documentElement.scrollWidth > innerWidth + 1,
        clipped,
      };
    })()`);
    if (englishLayout.horizontalOverflow || englishLayout.clipped.length) {
      throw new Error(`英文布局越界：${JSON.stringify(englishLayout)}`);
    }
    screenshots.push(await screenshot("1100-en-library"));
    const selectedConflict = await evaluate(`(() => {
      const row = [...document.querySelectorAll(".mod-row")]
        .find(item => item.querySelector(".mod-conflict-pill.has-conflict, .mod-conflict-pill.is-full"));
      if (!row) return false;
      row.click();
      return true;
    })()`);
    if (!selectedConflict) throw new Error("英文界面找不到冲突详情入口");
    await waitFor("document.querySelector('.conflict-health-trigger') !== null");
    await evaluate("document.querySelector('.conflict-health-trigger')?.click()");
    await waitFor("document.querySelector('#modal-title')?.innerText === 'Override relationships'");
    const englishConflict = await evaluate(`(() => {
      const dialog = document.querySelector(".modal-card");
      const rect = dialog?.getBoundingClientRect();
      return {
        groups: document.querySelectorAll(".conflict-group").length,
        choices: document.querySelectorAll(".conflict-choice").length,
        dialogInsideViewport: Boolean(rect && rect.left >= 0 && rect.right <= innerWidth + 1),
        horizontalOverflow: document.documentElement.scrollWidth > innerWidth + 1,
      };
    })()`);
    if (
      englishConflict.groups < 1 ||
      englishConflict.choices < 2 ||
      !englishConflict.dialogInsideViewport ||
      englishConflict.horizontalOverflow
    ) {
      throw new Error(`英文冲突弹层异常：${JSON.stringify(englishConflict)}`);
    }
    screenshots.push(await screenshot("1100-en-conflict"));
    await clickText("Cancel", ".modal-foot button");
    await waitFor("document.querySelector('.conflict-panel') === null");

    await clickText("Settings", ".rail-button");
    await waitFor("document.querySelector('h1')?.innerText === 'Settings'");
    await clickText("简体中文", ".language-options button");
    await waitFor("document.documentElement.lang === 'zh-CN'");
    await waitFor("document.querySelector('h1')?.innerText === '设置'");
    await send("Emulation.setDeviceMetricsOverride", {
      width: 1440,
      height: 900,
      deviceScaleFactor: 1,
      mobile: false,
    });
    return { stored, englishLayout };
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

  await test("窄窗 980x640 启动条不溢出", async () => {
    await send("Emulation.setDeviceMetricsOverride", {
      width: 980,
      height: 640,
      deviceScaleFactor: 1,
      mobile: false,
    });
    await navigate("模组库");
    await waitFor("document.querySelector('.launch-strip') !== null");
    const strip = await evaluate(`(() => {
      const el = document.querySelector(".launch-strip");
      const primary = document.querySelector(".launch-primary");
      const state = document.querySelector(".strip-state b");
      const rect = primary.getBoundingClientRect();
      const stripRect = el.getBoundingClientRect();
      return {
        overflow: el.scrollWidth > el.clientWidth + 1,
        primaryInside: rect.right <= stripRect.right - 8,
        primaryText: primary.innerText.trim(),
        stateText: state.innerText.trim(),
      };
    })()`);
    if (strip.overflow) throw new Error(`启动条溢出：${JSON.stringify(strip)}`);
    if (!strip.primaryInside) throw new Error(`主按钮越界：${JSON.stringify(strip)}`);
    screenshots.push(await screenshot("980-library"));
    return strip;
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
