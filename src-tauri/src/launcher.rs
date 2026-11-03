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
    monitor_process(app, state, token, pid);
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
    let reclaimed = state.reclaim_deployments_after_exit();
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
        return matches!(process.child.try_wait(), Ok(None));
    }
    false
}

fn monitor_process(app: AppHandle, state: &AppState, token: u64, pid: u32) {
    let app = app.clone();
    let _ = state;
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
        let exited = {
            let mut guard = state.process.lock().unwrap();
            match guard.as_mut() {
                Some(process) => match process.child.try_wait() {
                    Ok(Some(_)) => true,
                    Ok(None) => false,
                    Err(error) => {
                        state.log("error", "launcher", &format!("检测游戏进程失败：{error}"));
                        true
                    }
                },
                None => return,
            }
        };
        if exited {
            let _ = state.process.lock().unwrap().take();
            let reclaimed = state.reclaim_deployments_after_exit();
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
            let _ = app.emit("game-status-changed", &status);
            return;
        }
    });
}
