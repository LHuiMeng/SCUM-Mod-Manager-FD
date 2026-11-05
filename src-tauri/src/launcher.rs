use crate::models::GameStatus;
use crate::mods::deploy::{
    deploy_local_mods, find_executable, read_manifest, reclaim_mods, DeployedManifest,
};
use crate::state::AppState;
use anyhow::{bail, Context, Result};
use chrono::Utc;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};
use tauri::{AppHandle, Emitter, Manager};

pub struct ManagedProcess {
    pub child: Child,
    pub token: u64,
    pub pid: u32,
}

pub fn launch(app: AppHandle, state: &AppState, mode: &str) -> Result<GameStatus> {
    let started = Instant::now();
    if is_running(state) {
        bail!("游戏进程已经在运行");
    }
    let is_server = mode == "server";
    let settings = state.settings.lock().unwrap().clone();
    let mods = state.mods.read().unwrap().clone();
    let install = if is_server {
        settings.server_install_path.trim()
    } else {
        settings.scum_install_path.trim()
    };
    if install.is_empty() {
        bail!(
            "尚未设置 SCUM {}安装路径",
            if is_server { "服务端" } else { "客户端" }
        );
    }
    let executable_name = if is_server {
        "SCUMServer.exe"
    } else {
        "SCUM.exe"
    };
    let previous_manifest = read_manifest(&state.paths);
    let executable = find_executable(std::path::Path::new(install), executable_name)
        .with_context(|| format!("在 {install} 中找不到 {executable_name}"))?;
    let found_after = started.elapsed();
    let deployed_at = deploy_local_mods(&state.paths, &settings, &mods, is_server)?;
    let deploy_after = started.elapsed();
    if let Some(time) = deployed_at {
        *state.last_deployed_at.lock().unwrap() = Some(time);
    }

    let has_pak_mods = mods
        .iter()
        .any(|item| item.enabled && item.mod_type == "clientPak");
    let args = settings.launch_options.build_args(is_server, has_pak_mods);
    let mut command = Command::new(&executable);
    command
        .args(&args)
        .current_dir(executable.parent().context("无法确定游戏可执行文件目录")?)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x0000_0200);
    }
    state.log(
        "info",
        "launcher",
        &format!(
            "启动 {}：{} {}",
            executable_name,
            executable.display(),
            args.join(" ")
        ),
    );
    let log_baselines = crate::crash::capture_baselines(&settings);
    let child = match command.spawn() {
        Ok(child) => child,
        Err(error) => {
            let _ = reclaim_mods(&state.paths);
            return Err(error).context("无法创建游戏进程");
        }
    };
    let spawn_after = started.elapsed();
    let deployment_note = describe_deployment(&previous_manifest, &read_manifest(&state.paths));
    state.log(
        "info",
        "launcher",
        &format!(
            "启动耗时：定位exe {}ms / 部署 {}ms（{deployment_note}）/ spawn {}ms",
            found_after.as_millis(),
            deploy_after.as_millis() - found_after.as_millis(),
            spawn_after.as_millis() - deploy_after.as_millis(),
        ),
    );
    let pid = child.id();
    let token = {
        let mut next = state.next_launch_token.lock().unwrap();
        *next += 1;
        *next
    };
    let status = GameStatus {
        running: true,
        mode: Some(mode.to_string()),
        pid: Some(pid),
        started_at: Some(Utc::now().to_rfc3339()),
    };
    *state.game.lock().unwrap() = status.clone();
    *state.process.lock().unwrap() = Some(ManagedProcess { child, token, pid });
    let _ = app.emit("game-status-changed", &status);
    monitor_process(app, state, token, pid, log_baselines);
    Ok(status)
}

fn describe_deployment(
    previous: &Option<DeployedManifest>,
    current: &Option<DeployedManifest>,
) -> String {
    match (previous, current) {
        (Some(previous), Some(current)) if previous.deployed_at == current.deployed_at => {
            "复用既有部署".to_string()
        }
        (_, Some(current)) => format!(
            "全量拷贝 {} 个文件（{:.1} MB）",
            current.files.len(),
            current.file_sizes.values().sum::<u64>() as f64 / 1_048_576.0
        ),
        _ => "无启用模组，未部署".to_string(),
    }
}

pub fn stop(state: &AppState) -> Result<GameStatus> {
    stop_with_notice(state, |_| {})
}

pub fn stop_with_notice(
    state: &AppState,
    notify: impl FnMut(&crate::mods::deploy::ReclaimWait),
) -> Result<GameStatus> {
    let status_before = state.game.lock().unwrap().clone();
    let managed = state.process.lock().unwrap().take();
    if let Some(mut managed) = managed {
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            let _ = Command::new("taskkill.exe")
                .args(["/PID", &managed.pid.to_string(), "/T", "/F"])
                .creation_flags(0x0800_0000)
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status();
        }
        let _ = managed.child.kill();
        let _ = managed.child.wait();
    }
    #[cfg(windows)]
    if status_before.running {
        // 被 spawn 的可能只是引导进程：它退出后游戏本体还在跑。按镜像名再确认一次，
        // 否则回收会一直等被游戏加载的 dwmapi.dll。
        if let Some(mode) = status_before.mode.as_deref() {
            let image = image_name(mode);
            if game_process_running(image) {
                use std::os::windows::process::CommandExt;
                let _ = Command::new("taskkill.exe")
                    .args(["/IM", image, "/T", "/F"])
                    .creation_flags(0x0800_0000)
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .status();
                std::thread::sleep(Duration::from_millis(800));
            }
        }
    }
    let reclaimed = state.reclaim_deployments_after_exit_notified(notify);
    let status = GameStatus::default();
    *state.game.lock().unwrap() = status.clone();
    match reclaimed {
        Ok(Some(reclaimed)) => state.log(
            "info",
            "launcher",
            &format!("游戏已关闭，回收 {reclaimed} 个部署文件"),
        ),
        Ok(None) => state.log("info", "launcher", "游戏已关闭，按设置保留部署文件"),
        Err(error) => state.log(
            "error",
            "launcher",
            &format!("游戏已关闭，但部署文件回收失败：{error:#}"),
        ),
    }
    Ok(status)
}

pub fn is_running(state: &AppState) -> bool {
    if let Some(process) = state.process.lock().unwrap().as_mut() {
        if matches!(process.child.try_wait(), Ok(None)) {
            return true;
        }
    }
    // 直接启动的 exe 有时只是引导进程：它退出后真正的游戏进程仍在跑。
    // 这时如果报告“未运行”，回收会立刻撞上被占用的 dwmapi.dll。
    let status = state.game.lock().unwrap().clone();
    if status.running {
        if let Some(mode) = status.mode.as_deref() {
            return game_process_running(image_name(mode));
        }
    }
    false
}

fn image_name(mode: &str) -> &'static str {
    if mode == "server" {
        "SCUMServer.exe"
    } else {
        "SCUM.exe"
    }
}

/// 用 tasklist 检查同名游戏进程是否仍存在。用于识别“引导进程已退出、游戏还在跑”的情况。
#[cfg(windows)]
fn game_process_running(name: &str) -> bool {
    use std::os::windows::process::CommandExt;
    let filter = format!("IMAGENAME eq {name}");
    let output = Command::new("tasklist.exe")
        .args(["/FI", &filter, "/NH", "/FO", "CSV"])
        .creation_flags(0x0800_0000)
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output();
    match output {
        Ok(output) => {
            let text = String::from_utf8_lossy(&output.stdout).to_ascii_lowercase();
            text.contains(&name.to_ascii_lowercase())
        }
        Err(_) => false,
    }
}

#[cfg(not(windows))]
fn game_process_running(_name: &str) -> bool {
    false
}

fn monitor_process(
    app: AppHandle,
    state: &AppState,
    token: u64,
    pid: u32,
    log_baselines: crate::crash::LogBaselines,
) {
    let app = app.clone();
    let _ = state;
    let started_at = std::time::SystemTime::now();
    std::thread::spawn(move || loop {
        std::thread::sleep(Duration::from_secs(1));
        let state = app.state::<AppState>();
        let current_token = state
            .process
            .lock()
            .unwrap()
            .as_ref()
            .map(|process| process.token);
        if current_token != Some(token) {
            return;
        }
        let (exited, _exit_status) = {
            let mut guard = state.process.lock().unwrap();
            match guard.as_mut() {
                Some(process) => match process.child.try_wait() {
                    Ok(Some(status)) => (true, Some(status)),
                    Ok(None) => (false, None),
                    Err(error) => {
                        state.log("error", "launcher", &format!("检测游戏进程失败：{error}"));
                        (true, None)
                    }
                },
                None => return,
            }
        };
        if exited {
            let _ = state.process.lock().unwrap().take();
            // 某些启动方式下，被 spawn 的只是引导进程：它退出不代表游戏结束。
            // 此时回收会撞上仍被游戏加载的 dwmapi.dll，所以等真正的游戏进程退出。
            let mode = state
                .game
                .lock()
                .unwrap()
                .mode
                .clone()
                .unwrap_or_else(|| "client".to_string());
            let image = image_name(&mode);
            if game_process_running(image) {
                state.log(
                    "info",
                    "launcher",
                    &format!("引导进程已退出，但 {image} 仍在运行，等游戏结束后再回收部署文件"),
                );
                while game_process_running(image) && state.game.lock().unwrap().running {
                    std::thread::sleep(Duration::from_secs(2));
                }
            }
            // 用户在等待期间点了“停止游戏”：收尾交给 stop_with_notice，避免两处同时回收。
            if !state.game.lock().unwrap().running {
                return;
            }
            let progress_app = app.clone();
            let reclaimed = state.reclaim_deployments_after_exit_notified(|wait| {
                let file_name = std::path::Path::new(&wait.path)
                    .file_name()
                    .map(|name| name.to_string_lossy().into_owned())
                    .unwrap_or_else(|| wait.path.clone());
                let _ = progress_app.emit(
                    "reclaim-progress",
                    serde_json::json!({
                        "phase": if wait.waited_ms == 0 { "waiting" } else { "still-waiting" },
                        "file": file_name,
                        "waitedMs": wait.waited_ms,
                        "message": format!(
                            "{file_name} 正被占用，正在等待文件释放（已等待 {} 秒）",
                            wait.waited_ms / 1000
                        ),
                    }),
                );
            });
            let status = GameStatus::default();
            *state.game.lock().unwrap() = status.clone();
            match reclaimed {
                Ok(Some(reclaimed)) => state.log(
                    "info",
                    "launcher",
                    &format!("检测到游戏退出（PID {pid}），回收 {reclaimed} 个部署文件"),
                ),
                Ok(None) => state.log(
                    "info",
                    "launcher",
                    &format!("检测到游戏退出（PID {pid}），按设置保留部署文件"),
                ),
                Err(error) => state.log(
                    "error",
                    "launcher",
                    &format!("检测到游戏退出，但部署文件回收失败：{error:#}"),
                ),
            }
            // 每次退出都检查日志：引导进程可能以 0 退出，而真正崩溃的是它拉起的游戏进程。
            // analyze_logs 只在日志里出现致命错误/UE4SS 报错时才判定为异常退出。
            {
                let settings = state.settings.lock().unwrap().clone();
                let mods = state.mods.read().unwrap().clone();
                let report = crate::crash::analyze_logs(
                    &settings,
                    &mods,
                    Some(started_at - Duration::from_secs(5)),
                    &log_baselines,
                );
                if report.abnormal {
                    state.log("error", "crash", &report.summary);
                    *state.last_crash.lock().unwrap() = Some(report.clone());
                    let _ = app.emit("game-crash-report", &report);
                }
            }
            let _ = app.emit("game-status-changed", &status);
            return;
        }
    });
}
