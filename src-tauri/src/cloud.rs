use crate::edition;
use crate::metadata::MetadataFile;
use crate::models::{
    AppSettings, CloudDownloadProgress, ModEntry, RemoteMod, MAX_CLOUD_DOWNLOAD_SEGMENTS,
    MIN_CLOUD_DOWNLOAD_SEGMENTS,
};
use crate::mods::install_ue4ss_zip;
use crate::paths::{free_space, safe_disk_name, AppPaths};
use crate::secrets::RuntimeSecrets;
use anyhow::{bail, Context, Result};
use chrono::{DateTime, Utc};
use futures_util::StreamExt;
use percent_encoding::percent_decode_str;
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};
use std::net::{Ipv4Addr, Ipv6Addr};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::Semaphore;
use tokio::task::JoinSet;
use url::Url;

static DOWNLOAD_SEQUENCE: AtomicU64 = AtomicU64::new(0);
static DOWNLOAD_CONNECTIONS: OnceLock<Semaphore> = OnceLock::new();

/// 全局下载连接上限。单模组上限（MAX_CLOUD_DOWNLOAD_SEGMENTS）必须小于它，
/// 否则一个模组就能占满全部槽位，其它模组的下载只能等它让出。
const MAX_CLOUD_CONNECTIONS: usize = 256;
/// 每 4MB 允许增加一路并发。小于 32MB 的文件会被 MIN_CLOUD_DOWNLOAD_SEGMENTS
/// 的下限顶回 8 路，ramp 只在更大的文件上真正起作用。
const CONNECTION_RAMP_BYTES: u64 = 4 * 1024 * 1024;
const PROGRESS_INTERVAL: Duration = Duration::from_millis(120);

pub(crate) type CloudDownloadProgressCallback = Arc<dyn Fn(CloudDownloadProgress) + Send + Sync>;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct SegmentPlan {
    workers: usize,
    chunk_size: u64,
    total_chunks: usize,
}

struct SegmentedDownloadState {
    client: reqwest::Client,
    source: Url,
    settings: AppSettings,
    secrets: RuntimeSecrets,
    access: CloudAccess,
    id: String,
    total: u64,
    plan: SegmentPlan,
    directory: PathBuf,
    downloaded: AtomicU64,
    next_chunk: AtomicUsize,
    cancelled: AtomicBool,
    progress_gate: Mutex<ProgressGate>,
    on_progress: CloudDownloadProgressCallback,
}

struct ProgressGate {
    last_emit: Instant,
    last_value: u64,
}

impl SegmentedDownloadState {
    fn report_downloading(&self, force: bool) {
        let current = self.downloaded.load(Ordering::Relaxed);
        let mut gate = self
            .progress_gate
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if !force && gate.last_emit.elapsed() < PROGRESS_INTERVAL {
            return;
        }
        if current < gate.last_value {
            return;
        }
        gate.last_emit = Instant::now();
        gate.last_value = current;
        notify_download_progress(
            &self.on_progress,
            &self.id,
            "downloading",
            current,
            Some(self.total),
            self.plan.workers,
            None,
        );
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CloudAccess {
    Public,
    Server,
}

impl CloudAccess {
    pub fn current() -> Self {
        match edition::current() {
            edition::Edition::Public => Self::Public,
            edition::Edition::Server => Self::Server,
        }
    }
}

pub async fn fetch_catalog(
    paths: &AppPaths,
    settings: &mut AppSettings,
    secrets: &RuntimeSecrets,
    access: CloudAccess,
) -> Result<Vec<RemoteMod>> {
    let urls = ordered_urls(settings);
    if urls.is_empty() {
        bail!("尚未配置云源地址");
    }
    let client = cloud_client(std::time::Duration::from_secs(25))?;
    let mut errors = Vec::new();
    for base in urls {
        let url = format!("{}/mods", base.trim_end_matches('/'));
        let parsed = match Url::parse(&url) {
            Ok(parsed) if allowed_cloud_transport(&parsed) => parsed,
            Ok(_) => {
                errors.push(format!("{url}: 仅允许 HTTPS 云源（本机回环除外）"));
                continue;
            }
            Err(error) => {
                errors.push(format!("{url}: {error}"));
                continue;
            }
        };
        let request = authorize_cloud_request(
            client.get(parsed.clone()),
            &parsed,
            settings,
            secrets,
            access,
        );
        match request.send().await {
            Ok(response) => {
                if !response.status().is_success() {
                    errors.push(format!("{url}: HTTP {}", response.status()));
                    continue;
                }
                match response.json::<Value>().await {
                    Ok(value) => {
                        settings.cloud.active_base_url = base.clone();
                        save_catalog_cache(paths, &base, &value);
                        return parse_catalog(paths, &base, value);
                    }
                    Err(error) => errors.push(format!("{url}: {error}")),
                }
            }
            Err(error) => errors.push(format!("{url}: {error}")),
        }
    }
    bail!("所有云源线路均不可用：{}", errors.join("；"))
}

pub async fn download_remote(
    paths: &AppPaths,
    settings: &mut AppSettings,
    secrets: &RuntimeSecrets,
    access: CloudAccess,
    id: &str,
    on_progress: CloudDownloadProgressCallback,
) -> Result<String> {
    let catalog = match fetch_catalog(paths, settings, secrets, access).await {
        Ok(catalog) => catalog,
        Err(error) => {
            // 目录接口抖动不该让已知的 download_url 和 SHA-256 一起失效。
            let cached = load_catalog_cache(paths).with_context(|| {
                format!("云端目录不可用（{error:#}），且没有可用的本地目录缓存")
            })?;
            eprintln!("云端目录不可用，改用上次成功的本地缓存：{error:#}");
            cached
        }
    };
    let remote = catalog
        .iter()
        .find(|item| item.id == id)
        .with_context(|| format!("云端目录中不存在模组 {id}"))?;
    let sequence = DOWNLOAD_SEQUENCE.fetch_add(1, Ordering::Relaxed);
    let work_dir = paths.root.join("downloads").join(format!(
        "{}.{}.{}.parts",
        safe_disk_name(id, "mod"),
        std::process::id(),
        sequence
    ));
    tokio::fs::create_dir_all(&work_dir).await?;
    let result = download_remote_into(
        paths,
        settings,
        secrets,
        access,
        remote,
        &work_dir,
        on_progress,
    )
    .await;
    let _ = tokio::fs::remove_dir_all(&work_dir).await;
    result
}

async fn download_remote_into(
    paths: &AppPaths,
    settings: &AppSettings,
    secrets: &RuntimeSecrets,
    access: CloudAccess,
    remote: &RemoteMod,
    work_dir: &Path,
    on_progress: CloudDownloadProgressCallback,
) -> Result<String> {
    let client = cloud_client(Duration::from_secs(600))?;
    let mut candidates = download_candidates(settings, remote);
    candidates.dedup();
    let mut errors = Vec::new();
    for (index, url) in candidates.into_iter().enumerate() {
        let parsed = match Url::parse(&url) {
            Ok(parsed) if allowed_cloud_transport(&parsed) => parsed,
            Ok(_) => {
                errors.push(format!(
                    "{}: 仅允许 HTTPS 下载地址（本机回环除外）",
                    download_endpoint_label(&url)
                ));
                continue;
            }
            Err(error) => {
                errors.push(format!("{}: {error}", download_endpoint_label(&url)));
                continue;
            }
        };
        let has_declared_hash = !remote.sha256.trim().is_empty();
        if !download_source_allowed(settings, &parsed, has_declared_hash) {
            errors.push(format!(
                "{}: 跨源下载缺少 SHA-256，已跳过",
                download_endpoint_label(&url)
            ));
            continue;
        }
        let candidate_dir = work_dir.join(format!("candidate-{index}"));
        tokio::fs::create_dir_all(&candidate_dir).await?;
        let result = download_candidate(
            paths,
            &client,
            &parsed,
            settings,
            secrets,
            access,
            remote,
            &candidate_dir,
            on_progress.clone(),
        )
        .await;
        let _ = tokio::fs::remove_dir_all(&candidate_dir).await;
        match result {
            Ok(message) => return Ok(message),
            Err(error) => errors.push(format!("{}: {error:#}", download_endpoint_label(&url))),
        }
    }
    bail!("下载失败：{}", errors.join("；"))
}

async fn download_candidate(
    paths: &AppPaths,
    client: &reqwest::Client,
    source: &Url,
    settings: &AppSettings,
    secrets: &RuntimeSecrets,
    access: CloudAccess,
    remote: &RemoteMod,
    directory: &Path,
    on_progress: CloudDownloadProgressCallback,
) -> Result<String> {
    notify_download_progress(
        &on_progress,
        &remote.id,
        "preparing",
        0,
        (remote.file_size > 0).then_some(remote.file_size),
        0,
        Some("正在探测 Range 支持并规划动态分片".to_string()),
    );
    let total = probe_range(client, source, settings, secrets, access).await?;
    let plan = segment_plan(total, settings.cloud.max_download_segments);
    if plan.workers == 0 || plan.total_chunks == 0 {
        bail!("服务器返回的文件大小为 0，无法分片下载");
    }
    if let Some(available) = free_space(directory) {
        // 分片全部落盘后还要合并出一份完整文件，峰值是两倍大小。
        let needed = total.saturating_mul(2).saturating_add(64 * 1024 * 1024);
        if available < needed {
            bail!(
                "磁盘空间不足：合并分片需要约 {}，当前可用 {}",
                human_bytes(needed),
                human_bytes(available)
            );
        }
    }
    notify_download_progress(
        &on_progress,
        &remote.id,
        "preparing",
        0,
        Some(total),
        0,
        Some(format!(
            "已规划 {} 个分片，启用 {} 路并发",
            plan.total_chunks, plan.workers
        )),
    );

    let state = Arc::new(SegmentedDownloadState {
        client: client.clone(),
        source: source.clone(),
        settings: settings.clone(),
        secrets: secrets.clone(),
        access,
        id: remote.id.clone(),
        total,
        plan,
        directory: directory.to_path_buf(),
        downloaded: AtomicU64::new(0),
        next_chunk: AtomicUsize::new(0),
        cancelled: AtomicBool::new(false),
        progress_gate: Mutex::new(ProgressGate {
            last_emit: Instant::now(),
            last_value: 0,
        }),
        on_progress: on_progress.clone(),
    });
    notify_download_progress(
        &on_progress,
        &remote.id,
        "downloading",
        0,
        Some(total),
        plan.workers,
        None,
    );

    let mut tasks = JoinSet::new();
    for _ in 0..plan.workers {
        let state = state.clone();
        tasks.spawn(async move { download_worker(state).await });
    }
    let mut first_error = None;
    while let Some(result) = tasks.join_next().await {
        match result {
            Ok(Ok(())) => {}
            Ok(Err(error)) => {
                first_error.get_or_insert(error);
                tasks.abort_all();
            }
            Err(error) => {
                first_error.get_or_insert_with(|| anyhow::anyhow!("下载任务异常：{error}"));
            }
        }
    }
    if let Some(error) = first_error {
        return Err(error);
    }

    notify_download_progress(
        &on_progress,
        &remote.id,
        "verifying",
        total,
        Some(total),
        0,
        Some("正在按分片顺序合并并校验 SHA-256".to_string()),
    );
    let payload = directory.join("payload.part");
    let digest = merge_parts(&state, &payload).await?;
    let has_declared_hash = !remote.sha256.trim().is_empty();
    if has_declared_hash && !digest.eq_ignore_ascii_case(remote.sha256.trim()) {
        bail!("SHA-256 校验失败");
    }

    notify_download_progress(
        &on_progress,
        &remote.id,
        "installing",
        total,
        Some(total),
        0,
        Some("正在写入本地模组库".to_string()),
    );
    install_downloaded(paths, &payload, remote).await?;
    notify_download_progress(
        &on_progress,
        &remote.id,
        "completed",
        total,
        Some(total),
        0,
        None,
    );
    Ok(download_message(remote, has_declared_hash))
}

fn segment_plan(size: u64, configured_max: usize) -> SegmentPlan {
    if size == 0 {
        return SegmentPlan {
            workers: 0,
            chunk_size: 0,
            total_chunks: 0,
        };
    }
    let configured = configured_max.clamp(MIN_CLOUD_DOWNLOAD_SEGMENTS, MAX_CLOUD_DOWNLOAD_SEGMENTS);
    let byte_ceiling = usize::try_from(size).unwrap_or(usize::MAX);
    let worker_ceiling = configured
        .min(byte_ceiling)
        .max(MIN_CLOUD_DOWNLOAD_SEGMENTS.min(byte_ceiling));
    let ramp_ceiling = usize::try_from(size.div_ceil(CONNECTION_RAMP_BYTES))
        .unwrap_or(usize::MAX)
        .max(1);
    let workers = worker_ceiling
        .min(ramp_ceiling)
        .max(MIN_CLOUD_DOWNLOAD_SEGMENTS.min(worker_ceiling));
    let target_chunks = (workers as u64).saturating_mul(2);
    let chunk_size = size.div_ceil(target_chunks).max(1);
    let total_chunks = usize::try_from(size.div_ceil(chunk_size)).unwrap_or(usize::MAX);
    SegmentPlan {
        workers: workers.min(total_chunks),
        chunk_size,
        total_chunks,
    }
}

async fn probe_range(
    client: &reqwest::Client,
    source: &Url,
    settings: &AppSettings,
    secrets: &RuntimeSecrets,
    access: CloudAccess,
) -> Result<u64> {
    let _permit = download_connections()
        .acquire()
        .await
        .context("等待下载连接槽位失败")?;
    let request = authorize_cloud_request(
        client
            .get(source.clone())
            .header(reqwest::header::RANGE, "bytes=0-0"),
        source,
        settings,
        secrets,
        access,
    );
    let response = request.send().await.context("Range 探测请求失败")?;
    if response.status() != reqwest::StatusCode::PARTIAL_CONTENT {
        bail!(
            "服务器不支持 HTTP Range（探测返回 HTTP {}），无法分片下载",
            response.status()
        );
    }
    let content_range = response
        .headers()
        .get(reqwest::header::CONTENT_RANGE)
        .and_then(|value| value.to_str().ok())
        .context("Range 探测响应缺少 Content-Range")?;
    let (start, end, total) = parse_content_range(content_range)?;
    if start != 0 || end != 0 {
        bail!("Range 探测返回了意外区间：{content_range}");
    }
    if total == 0 {
        bail!("服务器返回的文件大小为 0，无法分片下载");
    }
    let bytes = response.bytes().await.context("Range 探测响应读取失败")?;
    if bytes.len() != 1 {
        bail!("Range 探测响应应为 1 字节，实际为 {} 字节", bytes.len());
    }
    Ok(total)
}

async fn download_worker(state: Arc<SegmentedDownloadState>) -> Result<()> {
    loop {
        if state.cancelled.load(Ordering::Relaxed) {
            return Ok(());
        }
        let permit = download_connections()
            .acquire()
            .await
            .context("等待下载连接槽位失败")?;
        if state.cancelled.load(Ordering::Relaxed) {
            return Ok(());
        }
        let index = state.next_chunk.fetch_add(1, Ordering::Relaxed);
        if index >= state.plan.total_chunks {
            return Ok(());
        }
        let result = download_chunk(&state, index).await;
        drop(permit);
        if let Err(error) = result {
            state.cancelled.store(true, Ordering::Relaxed);
            return Err(error).with_context(|| format!("分片 {} 下载失败", index + 1));
        }
    }
}

const CHUNK_RETRIES: usize = 2;
const CHUNK_RETRY_DELAY: Duration = Duration::from_millis(300);

/// 分片级的临时失败：服务器 5xx/429、字节数不符。这类错误重试有意义，
/// 4xx 与协议不匹配则直接失败，重试只会浪费时间。
#[derive(Debug, thiserror::Error)]
#[error("{reason}")]
struct RetryableChunkError {
    reason: String,
}

fn is_retryable_chunk_error(error: &anyhow::Error) -> bool {
    if error.downcast_ref::<RetryableChunkError>().is_some() {
        return true;
    }
    if let Some(request_error) = error.downcast_ref::<reqwest::Error>() {
        return request_error.is_timeout()
            || request_error.is_connect()
            || request_error.is_request()
            || request_error.is_body();
    }
    error.downcast_ref::<std::io::Error>().is_some()
}

async fn download_chunk(state: &SegmentedDownloadState, index: usize) -> Result<()> {
    let mut attempt = 0;
    loop {
        match download_chunk_once(state, index).await {
            Ok(()) => return Ok(()),
            Err(error) if attempt < CHUNK_RETRIES && is_retryable_chunk_error(&error) => {
                attempt += 1;
                tokio::time::sleep(CHUNK_RETRY_DELAY * attempt as u32).await;
            }
            Err(error) => return Err(error),
        }
    }
}

async fn download_chunk_once(state: &SegmentedDownloadState, index: usize) -> Result<()> {
    let start = (index as u64)
        .checked_mul(state.plan.chunk_size)
        .context("分片起点溢出")?;
    let end_exclusive = ((index as u64) + 1)
        .checked_mul(state.plan.chunk_size)
        .context("分片终点溢出")?
        .min(state.total);
    let end = end_exclusive.checked_sub(1).context("分片终点无效")?;
    let expected = end_exclusive - start;
    let request = authorize_cloud_request(
        state
            .client
            .get(state.source.clone())
            .header(reqwest::header::RANGE, format!("bytes={start}-{end}")),
        &state.source,
        &state.settings,
        &state.secrets,
        state.access,
    );
    let response = request.send().await.context("分片请求失败")?;
    let status = response.status();
    if status != reqwest::StatusCode::PARTIAL_CONTENT {
        if status.is_server_error() || status == reqwest::StatusCode::TOO_MANY_REQUESTS {
            return Err(RetryableChunkError {
                reason: format!("分片请求返回 HTTP {status}"),
            }
            .into());
        }
        bail!("分片请求返回 HTTP {status}，服务器可能忽略了 Range");
    }
    let content_range = response
        .headers()
        .get(reqwest::header::CONTENT_RANGE)
        .and_then(|value| value.to_str().ok())
        .context("分片响应缺少 Content-Range")?;
    let (actual_start, actual_end, actual_total) = parse_content_range(content_range)?;
    if actual_start != start || actual_end != end || actual_total != state.total {
        bail!(
            "分片响应区间不匹配：请求 {start}-{end}/{}, 返回 {actual_start}-{actual_end}/{actual_total}",
            state.total
        );
    }
    if let Some(content_length) = response
        .headers()
        .get(reqwest::header::CONTENT_LENGTH)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.parse::<u64>().ok())
    {
        if content_length != expected {
            bail!("分片 Content-Length 不匹配：期望 {expected}，实际 {content_length}");
        }
    }

    let part_path = state.directory.join(format!("{index:08}.part"));
    let mut file = tokio::fs::File::create(&part_path)
        .await
        .with_context(|| format!("无法创建分片文件 {}", part_path.display()))?;
    let mut stream = response.bytes_stream();
    let mut received = 0_u64;
    // 中途失败时把已经计进总进度的字节扣回去，否则重试会让进度虚高。
    macro_rules! rollback {
        () => {
            state.downloaded.fetch_sub(received, Ordering::Relaxed);
        };
    }
    while let Some(chunk) = stream.next().await {
        let chunk = match chunk {
            Ok(chunk) => chunk,
            Err(error) => {
                rollback!();
                return Err(error).context("分片数据流中断");
            }
        };
        if let Err(error) = file.write_all(&chunk).await {
            rollback!();
            return Err(error).context("分片写入失败");
        }
        received += chunk.len() as u64;
        state
            .downloaded
            .fetch_add(chunk.len() as u64, Ordering::Relaxed);
        state.report_downloading(false);
    }
    if let Err(error) = file.flush().await {
        rollback!();
        return Err(error).context("分片写入失败");
    }
    if received != expected {
        rollback!();
        return Err(RetryableChunkError {
            reason: format!("分片字节数不匹配：期望 {expected}，实际 {received}"),
        }
        .into());
    }
    state.report_downloading(true);
    Ok(())
}

async fn merge_parts(state: &SegmentedDownloadState, payload: &Path) -> Result<String> {
    let mut output = tokio::fs::File::create(payload)
        .await
        .with_context(|| format!("无法创建合并文件 {}", payload.display()))?;
    let mut hasher = Sha256::new();
    let mut merged = 0_u64;
    let mut buffer = vec![0_u8; 256 * 1024];
    for index in 0..state.plan.total_chunks {
        let part_path = state.directory.join(format!("{index:08}.part"));
        let mut part = tokio::fs::File::open(&part_path)
            .await
            .with_context(|| format!("无法打开分片文件 {}", part_path.display()))?;
        loop {
            let read = part
                .read(&mut buffer)
                .await
                .with_context(|| format!("无法读取分片文件 {}", part_path.display()))?;
            if read == 0 {
                break;
            }
            hasher.update(&buffer[..read]);
            output.write_all(&buffer[..read]).await?;
            merged += read as u64;
        }
        let _ = tokio::fs::remove_file(&part_path).await;
    }
    output.flush().await?;
    if merged != state.total {
        bail!("合并后文件大小不匹配：期望 {}，实际 {merged}", state.total);
    }
    Ok(hex::encode(hasher.finalize()))
}

const ZIP_MAGIC: [u8; 4] = *b"PK\x03\x04";

fn normalize_mod_type(value: &str) -> String {
    value
        .chars()
        .filter(char::is_ascii_alphanumeric)
        .collect::<String>()
        .to_ascii_lowercase()
}

fn declared_ue4ss(mod_type: &str) -> bool {
    matches!(
        normalize_mod_type(mod_type).as_str(),
        "ue4ss" | "ue4ssmod" | "luamod"
    )
}

async fn read_payload_head(payload: &Path) -> Result<Vec<u8>> {
    let mut file = tokio::fs::File::open(payload)
        .await
        .with_context(|| format!("无法读取下载文件 {}", payload.display()))?;
    let mut buffer = vec![0_u8; ZIP_MAGIC.len()];
    let read = file.read(&mut buffer).await?;
    buffer.truncate(read);
    Ok(buffer)
}

async fn install_downloaded(paths: &AppPaths, payload: &Path, remote: &RemoteMod) -> Result<()> {
    let head = read_payload_head(payload).await?;
    if head.starts_with(&ZIP_MAGIC) {
        // 内容优先于云端声明：ZIP 一律走与本地拖入完全相同的安装路径，
        // 由它决定剥离 wrapper 后是 PAK 还是 UE4SS 模组。
        let paths = paths.clone();
        let payload = payload.to_path_buf();
        let preferred = remote.name.clone();
        let (imported, skipped) = tokio::task::spawn_blocking(move || {
            install_ue4ss_zip(&paths, &payload, Some(&preferred), true)
        })
        .await
        .context("解压任务异常")??;
        if imported == 0 {
            bail!("压缩包内没有可安装的内容（跳过 {skipped} 项）");
        }
        return Ok(());
    }
    if declared_ue4ss(&remote.mod_type) {
        bail!("云端把该模组标记为 UE4SS 模组，但下载到的文件不是 ZIP，已拒绝安装");
    }

    tokio::fs::create_dir_all(&paths.local_mods).await?;
    let destination = paths.local_mods.join(remote_filename(remote));
    if tokio::fs::try_exists(&destination).await.unwrap_or(false) {
        // 覆盖前留一份可回收的备份，避免用户改过的同名 PAK 被静默冲掉。
        tokio::fs::create_dir_all(&paths.backups_dir).await?;
        let file_name = destination
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_else(|| "mod.pak".to_string());
        let backup = paths.backups_dir.join(format!("{file_name}.bak"));
        let _ = tokio::fs::remove_file(&backup).await;
        tokio::fs::rename(&destination, &backup)
            .await
            .with_context(|| format!("无法备份已存在的模组文件 {}", destination.display()))?;
    }
    tokio::fs::rename(payload, &destination)
        .await
        .with_context(|| format!("无法写入模组文件 {}", destination.display()))?;
    Ok(())
}

fn parse_content_range(value: &str) -> Result<(u64, u64, u64)> {
    let rest = value
        .trim()
        .strip_prefix("bytes ")
        .context("Content-Range 格式无效")?;
    let (range, total) = rest.split_once('/').context("Content-Range 缺少总大小")?;
    let (start, end) = range.split_once('-').context("Content-Range 缺少区间")?;
    let start = start
        .trim()
        .parse::<u64>()
        .context("Content-Range 起点无效")?;
    let end = end
        .trim()
        .parse::<u64>()
        .context("Content-Range 终点无效")?;
    let total = total
        .trim()
        .parse::<u64>()
        .context("Content-Range 总大小无效")?;
    if start > end || end >= total {
        bail!("Content-Range 区间无效：{value}");
    }
    Ok((start, end, total))
}

fn download_connections() -> &'static Semaphore {
    DOWNLOAD_CONNECTIONS.get_or_init(|| Semaphore::new(MAX_CLOUD_CONNECTIONS))
}

fn notify_download_progress(
    callback: &CloudDownloadProgressCallback,
    id: &str,
    phase: &str,
    downloaded: u64,
    total: Option<u64>,
    segments: usize,
    message: Option<String>,
) {
    callback(CloudDownloadProgress {
        id: id.to_string(),
        phase: phase.to_string(),
        downloaded,
        total,
        segments,
        message,
    });
}

fn download_endpoint_label(value: &str) -> String {
    Url::parse(value)
        .map(|mut url| {
            url.set_query(None);
            url.set_fragment(None);
            url.to_string()
        })
        .unwrap_or_else(|_| value.split(['?', '#']).next().unwrap_or(value).to_string())
}

fn cloud_client(timeout: std::time::Duration) -> Result<reqwest::Client> {
    Ok(reqwest::Client::builder()
        .timeout(timeout)
        .redirect(reqwest::redirect::Policy::custom(|attempt| {
            let same_origin = attempt
                .previous()
                .last()
                .is_some_and(|previous| previous.origin() == attempt.url().origin());
            if same_origin {
                attempt.follow()
            } else {
                attempt.stop()
            }
        }))
        .user_agent(format!("SCUM-Mod-Desk/{}", env!("CARGO_PKG_VERSION")))
        .build()?)
}

fn allowed_cloud_transport(url: &Url) -> bool {
    url.scheme() == "https" || (url.scheme() == "http" && is_loopback_host(url))
}

fn is_loopback_host(url: &Url) -> bool {
    match url.host() {
        Some(url::Host::Ipv4(address)) => address == Ipv4Addr::LOCALHOST,
        Some(url::Host::Ipv6(address)) => address == Ipv6Addr::LOCALHOST,
        Some(url::Host::Domain(host)) => host.eq_ignore_ascii_case("localhost"),
        None => false,
    }
}

fn is_configured_cloud_origin(settings: &AppSettings, url: &Url) -> bool {
    ordered_urls(settings).iter().any(|base| {
        Url::parse(base)
            .ok()
            .is_some_and(|configured| configured.origin() == url.origin())
    })
}

fn download_source_allowed(settings: &AppSettings, url: &Url, has_declared_hash: bool) -> bool {
    has_declared_hash || is_configured_cloud_origin(settings, url)
}

fn catalog_cache_file(paths: &AppPaths) -> PathBuf {
    paths.root.join("cache").join("cloud_catalog.json")
}

/// 记住最后一次成功拉到的目录，供目录接口抖动时回退使用。
fn save_catalog_cache(paths: &AppPaths, base: &str, catalog: &Value) {
    let file = catalog_cache_file(paths);
    let Some(parent) = file.parent() else {
        return;
    };
    if std::fs::create_dir_all(parent).is_err() {
        return;
    }
    let payload = serde_json::json!({
        "base": base,
        "savedAt": Utc::now().to_rfc3339(),
        "catalog": catalog,
    });
    if let Ok(bytes) = serde_json::to_vec(&payload) {
        let _ = std::fs::write(&file, bytes);
    }
}

fn load_catalog_cache(paths: &AppPaths) -> Result<Vec<RemoteMod>> {
    let file = catalog_cache_file(paths);
    let bytes =
        std::fs::read(&file).with_context(|| format!("无法读取云端目录缓存 {}", file.display()))?;
    let payload: Value = serde_json::from_slice(&bytes).context("云端目录缓存格式无效")?;
    let base = payload
        .get("base")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let catalog = payload
        .get("catalog")
        .cloned()
        .context("云端目录缓存缺少目录内容")?;
    parse_catalog(paths, base, catalog)
}

/// 用云端目录缓存里的 sha256 → 名称映射补回显示名。
///
/// 旧版本下载时磁盘名被 ASCII 清洗过（`武器增强` 变成一串下划线），
/// 而显示名只取文件名时用户就只看到下划线。内容哈希是稳定的，
/// 可以据此把云端名找回来；匹配不上或已有名字的条目保持原样。
pub fn apply_catalog_names(
    paths: &AppPaths,
    metadata: &mut MetadataFile,
    mods: &mut [ModEntry],
) -> usize {
    let Ok(catalog) = load_catalog_cache(paths) else {
        return 0;
    };
    let mut by_hash: HashMap<String, String> = HashMap::new();
    for remote in catalog {
        let hash = remote.sha256.trim().to_ascii_lowercase();
        if hash.is_empty() {
            continue;
        }
        by_hash.entry(hash).or_insert(remote.name);
    }
    if by_hash.is_empty() {
        return 0;
    }

    let mut updated = 0;
    for entry in mods.iter_mut() {
        let known = metadata
            .entries
            .get(&entry.id)
            .and_then(|meta| meta.name.clone())
            .filter(|value| !value.trim().is_empty());
        if let Some(name) = known {
            entry.name = name;
            continue;
        }
        let hash = entry.sha256.trim().to_ascii_lowercase();
        if hash.is_empty() {
            continue;
        }
        let Some(name) = by_hash.get(&hash).cloned() else {
            continue;
        };
        entry.name = name.clone();
        metadata.entry_mut(&entry.id).name = Some(name);
        updated += 1;
    }
    updated
}

fn human_bytes(value: u64) -> String {
    const UNITS: [&str; 5] = ["B", "KB", "MB", "GB", "TB"];
    if value < 1024 {
        return format!("{value} B");
    }
    let mut size = value as f64;
    let mut unit = 0;
    while size >= 1024.0 && unit < UNITS.len() - 1 {
        size /= 1024.0;
        unit += 1;
    }
    format!("{size:.1} {}", UNITS[unit])
}

fn download_message(remote: &RemoteMod, verified: bool) -> String {
    if verified {
        format!("{} 已下载并通过 SHA-256 校验", remote.name)
    } else {
        format!(
            "{} 已下载，云目录未提供 SHA-256，未执行完整性校验",
            remote.name
        )
    }
}

fn authorize_cloud_request(
    mut request: reqwest::RequestBuilder,
    url: &Url,
    settings: &AppSettings,
    secrets: &RuntimeSecrets,
    access: CloudAccess,
) -> reqwest::RequestBuilder {
    if access != CloudAccess::Server {
        return request;
    }
    let token = secrets.cloud_auth_token.trim();
    if !token.is_empty() && should_attach_credentials(url, settings, access) {
        request = request.bearer_auth(token).header("X-Scum-Gate", token);
    }
    request
}

fn should_attach_credentials(url: &Url, settings: &AppSettings, access: CloudAccess) -> bool {
    access == CloudAccess::Server
        && allowed_cloud_transport(url)
        && is_configured_cloud_origin(settings, url)
}

fn ordered_urls(settings: &AppSettings) -> Vec<String> {
    let mut urls = Vec::new();
    if !settings.cloud.active_base_url.trim().is_empty() {
        urls.push(settings.cloud.active_base_url.trim().to_string());
    }
    urls.extend(settings.cloud.base_urls.iter().cloned());
    let mut seen = HashSet::new();
    urls.into_iter()
        .map(|url| url.trim_end_matches('/').to_string())
        .filter(|url| !url.is_empty() && seen.insert(url.clone()))
        .collect()
}

fn parse_catalog(paths: &AppPaths, base: &str, value: Value) -> Result<Vec<RemoteMod>> {
    let items = value
        .get("mods")
        .or_else(|| value.get("items"))
        .or_else(|| value.get("catalog"))
        .and_then(Value::as_array)
        .cloned()
        .or_else(|| value.as_array().cloned())
        .unwrap_or_default();
    let installed = installed_names(paths);
    let mut mods = Vec::new();
    for item in items {
        let Some(object) = item.as_object() else {
            continue;
        };
        let name = text(object.get("name")).unwrap_or_else(|| "未命名模组".to_string());
        let id = text(object.get("id"))
            .or_else(|| text(object.get("slug")))
            .unwrap_or_else(|| safe_disk_name(&name, "mod"));
        let mut download_url = text(object.get("download_url"))
            .or_else(|| text(object.get("downloadUrl")))
            .unwrap_or_default();
        if download_url.is_empty() {
            download_url = format!("{}/mods/{}/download", base.trim_end_matches('/'), id);
        }
        let tags = object
            .get("tags")
            .and_then(Value::as_array)
            .map(|items| {
                items
                    .iter()
                    .filter_map(Value::as_str)
                    .map(ToString::to_string)
                    .collect()
            })
            .unwrap_or_default();
        let file_size = number(object.get("file_size"))
            .or_else(|| number(object.get("fileSize")))
            .or_else(|| number(object.get("size_bytes")))
            .or_else(|| number(object.get("size")))
            .unwrap_or(0);
        let mod_type = text(object.get("type"))
            .or_else(|| text(object.get("mod_type")))
            .unwrap_or_else(|| "clientPak".to_string());
        mods.push(RemoteMod {
            installed: installed.contains(&id.to_ascii_lowercase())
                || installed.contains(&name.to_ascii_lowercase()),
            id,
            name,
            author: text(object.get("author")).unwrap_or_else(|| "未知作者".to_string()),
            version: text(object.get("version")).unwrap_or_else(|| "1.0.0".to_string()),
            description: text(object.get("description")).unwrap_or_default(),
            file_size,
            download_url,
            sha256: text(object.get("sha256")).unwrap_or_default(),
            tags,
            updated_at: text(object.get("updated_at"))
                .or_else(|| text(object.get("updatedAt")))
                .or_else(|| text(object.get("released_at")))
                .or_else(|| text(object.get("releasedAt")))
                .or_else(|| timestamp(object.get("uploaded_at")))
                .or_else(|| timestamp(object.get("uploadedAt")))
                .unwrap_or_else(|| Utc::now().to_rfc3339()),
            mod_type,
        });
    }
    Ok(mods)
}

fn installed_names(paths: &AppPaths) -> HashSet<String> {
    let mut names = HashSet::new();
    if let Ok(entries) = std::fs::read_dir(&paths.local_mods) {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            names.insert(name.to_ascii_lowercase());
            if let Some(stem) = Path::new(&name).file_stem() {
                names.insert(stem.to_string_lossy().to_ascii_lowercase());
            }
        }
    }
    if let Ok(entries) = std::fs::read_dir(&paths.ue4ss_mods) {
        for entry in entries.flatten() {
            names.insert(entry.file_name().to_string_lossy().to_ascii_lowercase());
        }
    }
    names
}

fn download_candidates(settings: &AppSettings, remote: &RemoteMod) -> Vec<String> {
    let mut candidates = Vec::new();
    if !remote.download_url.trim().is_empty() {
        candidates.push(remote.download_url.trim().to_string());
    }
    for base in ordered_urls(settings) {
        candidates.push(format!(
            "{}/mods/{}/download",
            base.trim_end_matches('/'),
            remote.id
        ));
    }
    candidates
}

fn remote_filename(remote: &RemoteMod) -> String {
    if let Ok(url) = Url::parse(&remote.download_url) {
        if let Some(encoded_name) = url
            .path_segments()
            .and_then(|mut segments| segments.next_back())
        {
            let decoded = percent_decode_str(encoded_name).decode_utf8_lossy();
            if decoded.contains('.') {
                if let Some(name) = safe_download_filename(&decoded) {
                    return name;
                }
            }
        }
    }
    let extension = if declared_ue4ss(&remote.mod_type) {
        "zip"
    } else {
        "pak"
    };
    format!("{}.{}", safe_disk_name(&remote.name, "mod"), extension)
}

fn safe_download_filename(value: &str) -> Option<String> {
    let file_name = Path::new(value).file_name()?.to_string_lossy();
    let path = Path::new(file_name.as_ref());
    let stem = path.file_stem()?.to_string_lossy();
    let safe_stem = safe_disk_name(&stem, "mod");
    match path.extension() {
        Some(extension) if !extension.is_empty() => Some(format!(
            "{safe_stem}.{}",
            safe_disk_name(&extension.to_string_lossy(), "bin").to_ascii_lowercase()
        )),
        _ => Some(safe_stem),
    }
}

fn text(value: Option<&Value>) -> Option<String> {
    value
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToString::to_string)
}

fn number(value: Option<&Value>) -> Option<u64> {
    value.and_then(|value| {
        value
            .as_u64()
            .or_else(|| value.as_str().and_then(|text| text.parse().ok()))
    })
}

fn timestamp(value: Option<&Value>) -> Option<String> {
    if let Some(text) = text(value) {
        return Some(text);
    }
    value
        .and_then(Value::as_i64)
        .and_then(|seconds| DateTime::<Utc>::from_timestamp(seconds, 0))
        .map(|timestamp| timestamp.to_rfc3339())
}

#[cfg(test)]
mod tests {
    use super::{
        allowed_cloud_transport, apply_catalog_names, declared_ue4ss, download_remote,
        download_source_allowed, fetch_catalog, human_bytes, install_downloaded,
        is_retryable_chunk_error, load_catalog_cache, ordered_urls, parse_catalog, remote_filename,
        save_catalog_cache, segment_plan, should_attach_credentials, AppSettings, CloudAccess,
        CloudDownloadProgressCallback, RetryableChunkError, RuntimeSecrets,
    };
    use crate::edition::Edition;
    use crate::models::{CloudDownloadProgress, ModEntry, RemoteMod};
    use crate::secrets::load_runtime_secrets;
    use crate::test_support::TempRoot;
    use serde_json::json;
    use sha2::{Digest, Sha256};
    use std::collections::HashMap;
    use std::fs;
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::path::Path;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
    use std::sync::{Arc, Mutex};
    use std::thread::{self, JoinHandle};
    use std::time::Duration;

    #[derive(Debug, Clone)]
    struct CapturedRequest {
        path: String,
        headers: HashMap<String, String>,
    }

    struct MockServer {
        base_url: String,
        stop: Arc<AtomicBool>,
        captured: Arc<Mutex<Vec<CapturedRequest>>>,
        handle: Option<JoinHandle<()>>,
    }

    impl MockServer {
        fn new(expected_sha256: String, download_status: u16) -> Self {
            Self::with_range(expected_sha256, download_status, true)
        }

        fn with_range(expected_sha256: String, download_status: u16, supports_range: bool) -> Self {
            Self::build(expected_sha256, download_status, supports_range, 0)
        }

        /// 前 `failures` 个分片请求返回 503，用来验证分片级重试。
        fn with_flaky(expected_sha256: String, failures: usize) -> Self {
            Self::build(expected_sha256, 200, true, failures)
        }

        fn build(
            expected_sha256: String,
            download_status: u16,
            supports_range: bool,
            failures: usize,
        ) -> Self {
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            listener.set_nonblocking(true).unwrap();
            let address = listener.local_addr().unwrap();
            let base_url = format!("http://{address}");
            let catalog = serde_json::to_vec(&json!({
                "mods": [{
                    "id": "demo",
                    "name": "Demo",
                    "type": "clientPak",
                    "sha256": expected_sha256
                }]
            }))
            .unwrap();
            let file_body = mock_file_body();
            let stop = Arc::new(AtomicBool::new(false));
            let captured = Arc::new(Mutex::new(Vec::new()));
            let thread_stop = stop.clone();
            let thread_captured = captured.clone();
            let flaky = Arc::new(AtomicUsize::new(failures));
            let thread_flaky = flaky.clone();
            let handle = thread::spawn(move || {
                while !thread_stop.load(Ordering::Relaxed) {
                    match listener.accept() {
                        Ok((stream, _)) => serve_connection(
                            stream,
                            &catalog,
                            &file_body,
                            download_status,
                            supports_range,
                            &thread_captured,
                            &thread_flaky,
                        ),
                        Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                            thread::sleep(Duration::from_millis(2));
                        }
                        Err(_) => break,
                    }
                }
            });
            Self {
                base_url,
                stop,
                captured,
                handle: Some(handle),
            }
        }

        fn finish(mut self) -> Vec<CapturedRequest> {
            self.stop.store(true, Ordering::Relaxed);
            self.handle.take().unwrap().join().unwrap();
            self.captured
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .clone()
        }
    }

    fn file_sha256() -> String {
        hex::encode(Sha256::digest(mock_file_body()))
    }

    fn mock_file_body() -> Vec<u8> {
        (0..64 * 1024)
            .map(|index| ((index * 31 + 17) % 251) as u8)
            .collect()
    }

    fn serve_connection(
        mut stream: std::net::TcpStream,
        catalog: &[u8],
        file_body: &[u8],
        download_status: u16,
        supports_range: bool,
        captured: &Mutex<Vec<CapturedRequest>>,
        flaky: &AtomicUsize,
    ) {
        stream.set_nonblocking(false).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        let mut request = Vec::new();
        let mut buffer = [0_u8; 4096];
        loop {
            match stream.read(&mut buffer) {
                Ok(0) => break,
                Ok(read) => {
                    request.extend_from_slice(&buffer[..read]);
                    if request.windows(4).any(|window| window == b"\r\n\r\n") {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
        let request_text = String::from_utf8_lossy(&request);
        let mut lines = request_text.lines();
        let path = lines
            .next()
            .and_then(|line| line.split_whitespace().nth(1))
            .unwrap_or_default()
            .to_string();
        let headers = lines
            .take_while(|line| !line.trim().is_empty())
            .filter_map(|line| line.split_once(':'))
            .map(|(name, value)| (name.trim().to_ascii_lowercase(), value.trim().to_string()))
            .collect::<HashMap<_, _>>();
        captured
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .push(CapturedRequest {
                path: path.clone(),
                headers: headers.clone(),
            });

        if path == "/mods" {
            write_response(&mut stream, 200, "application/json", catalog, &[]);
            return;
        }
        if download_status != 200 {
            write_response(
                &mut stream,
                download_status,
                "text/plain",
                b"forbidden",
                &[],
            );
            return;
        }
        if !supports_range {
            write_response(&mut stream, 200, "application/octet-stream", file_body, &[]);
            return;
        }
        let Some((start, end)) = headers
            .get("range")
            .and_then(|value| value.strip_prefix("bytes="))
            .and_then(|value| value.split_once('-'))
            .and_then(|(start, end)| {
                Some((start.parse::<usize>().ok()?, end.parse::<usize>().ok()?))
            })
        else {
            write_response(
                &mut stream,
                416,
                "text/plain",
                b"range required",
                &[("Content-Range", format!("bytes */{}", file_body.len()))],
            );
            return;
        };
        if start >= file_body.len() || start > end {
            write_response(
                &mut stream,
                416,
                "text/plain",
                b"range invalid",
                &[("Content-Range", format!("bytes */{}", file_body.len()))],
            );
            return;
        }
        if end > 0 && flaky.load(Ordering::Relaxed) > 0 {
            flaky.fetch_sub(1, Ordering::Relaxed);
            write_response(
                &mut stream,
                503,
                "text/plain",
                b"temporarily unavailable",
                &[],
            );
            return;
        }
        let end = end.min(file_body.len() - 1);
        let body = &file_body[start..=end];
        write_response(
            &mut stream,
            206,
            "application/octet-stream",
            body,
            &[(
                "Content-Range",
                format!("bytes {start}-{end}/{}", file_body.len()),
            )],
        );
    }

    fn write_response(
        stream: &mut std::net::TcpStream,
        status: u16,
        content_type: &str,
        body: &[u8],
        extra_headers: &[(&str, String)],
    ) {
        let reason = match status {
            200 => "OK",
            206 => "Partial Content",
            403 => "Forbidden",
            416 => "Range Not Satisfiable",
            _ => "Error",
        };
        let extras = extra_headers
            .iter()
            .map(|(name, value)| format!("{name}: {value}\r\n"))
            .collect::<String>();
        let header = format!(
            "HTTP/1.1 {status} {reason}\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\n{extras}Connection: close\r\n\r\n",
            body.len()
        );
        stream.write_all(header.as_bytes()).unwrap();
        stream.write_all(body).unwrap();
    }

    fn no_progress() -> CloudDownloadProgressCallback {
        Arc::new(|_| {})
    }

    fn collect_progress() -> (
        CloudDownloadProgressCallback,
        Arc<Mutex<Vec<CloudDownloadProgress>>>,
    ) {
        let events = Arc::new(Mutex::new(Vec::new()));
        let output = events.clone();
        let callback: CloudDownloadProgressCallback = Arc::new(move |progress| {
            output
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .push(progress);
        });
        (callback, events)
    }

    fn expected_segmented_requests(max_segments: usize) -> usize {
        2 + segment_plan(mock_file_body().len() as u64, max_segments).total_chunks
    }

    #[test]
    fn parses_catalog_aliases_defaults_and_installed_state() {
        let temp = TempRoot::new("cloud-catalog");
        let paths = temp.paths();
        fs::write(paths.local_mods.join("InstalledWeapon.pak"), b"pak").unwrap();
        fs::create_dir_all(paths.ue4ss_mods.join("ScriptPack")).unwrap();
        let value = json!({
            "items": [{
                "name": "InstalledWeapon",
                "slug": "installed-weapon",
                "author": "Tester",
                "version": "2.0.0",
                "size_bytes": "4096",
                "sha256": "ABC123",
                "tags": ["weapon", 7],
                "released_at": "2026-10-26T00:00:00Z",
                "type": "clientPak"
            }, {
                "id": "script-pack",
                "name": "ScriptPack",
                "mod_type": "ue4ssMod",
                "fileSize": 1024,
                "uploaded_at": 1788465403
            }]
        });

        let mods = parse_catalog(&paths, "https://mods.example.test/", value).unwrap();

        assert_eq!(mods.len(), 2);
        assert_eq!(mods[0].id, "installed-weapon");
        assert!(mods[0].installed);
        assert_eq!(mods[0].file_size, 4096);
        assert_eq!(mods[0].tags, vec!["weapon"]);
        assert_eq!(
            mods[0].download_url,
            "https://mods.example.test/mods/installed-weapon/download"
        );
        assert!(mods[1].installed);
        assert_eq!(mods[1].mod_type, "ue4ssMod");
        assert_eq!(mods[1].file_size, 1024);
        assert_eq!(mods[1].updated_at, "2026-09-03T19:56:43+00:00");
    }

    #[test]
    fn orders_active_cloud_source_first_and_removes_duplicates() {
        let settings = AppSettings {
            cloud: crate::models::CloudSettings {
                base_urls: vec![
                    "https://backup.example/".to_string(),
                    "https://primary.example/".to_string(),
                ],
                active_base_url: "https://primary.example".to_string(),
                max_download_segments: 16,
            },
            ..AppSettings::default()
        };

        assert_eq!(
            ordered_urls(&settings),
            vec!["https://primary.example", "https://backup.example"]
        );
    }

    #[test]
    fn derives_a_safe_filename_from_remote_metadata() {
        let remote = RemoteMod {
            id: "demo".to_string(),
            name: "../Unsafe Demo".to_string(),
            author: String::new(),
            version: String::new(),
            description: String::new(),
            file_size: 0,
            download_url: "https://mods.example.test/files/Unsafe%20Demo.pak?token=redacted"
                .to_string(),
            sha256: String::new(),
            tags: Vec::new(),
            updated_at: String::new(),
            mod_type: "clientPak".to_string(),
            installed: false,
        };

        assert_eq!(remote_filename(&remote), "Unsafe Demo.pak");
    }

    #[test]
    fn downloads_and_verifies_sha256_through_the_cloud_catalog() {
        let temp = TempRoot::new("cloud-download-success");
        let paths = temp.paths();
        let server = MockServer::new(file_sha256(), 200);
        let (progress, events) = collect_progress();
        let mut settings = AppSettings {
            cloud: crate::models::CloudSettings {
                base_urls: vec![server.base_url.clone()],
                active_base_url: String::new(),
                max_download_segments: 16,
            },
            ..AppSettings::default()
        };
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();

        let result = runtime
            .block_on(download_remote(
                &paths,
                &mut settings,
                &RuntimeSecrets::default(),
                CloudAccess::Server,
                "demo",
                progress,
            ))
            .unwrap();

        assert!(result.contains("SHA-256 校验"));
        assert_eq!(
            fs::read(paths.local_mods.join("Demo.pak")).unwrap(),
            mock_file_body()
        );
        assert_eq!(settings.cloud.active_base_url, server.base_url);
        let requests = server.finish();
        let plan = segment_plan(mock_file_body().len() as u64, 16);
        assert_eq!(requests.len(), 2 + plan.total_chunks);
        assert_eq!(requests[0].path, "/mods");
        assert_eq!(requests[1].path, "/mods/demo/download");
        assert_eq!(
            requests[1].headers.get("range").map(String::as_str),
            Some("bytes=0-0")
        );
        assert_eq!(
            requests[2..]
                .iter()
                .filter(|request| request.headers.contains_key("range"))
                .count(),
            plan.total_chunks
        );
        assert_eq!(
            fs::read_dir(paths.root.join("downloads")).unwrap().count(),
            0
        );

        let events = events
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clone();
        for phase in [
            "preparing",
            "downloading",
            "verifying",
            "installing",
            "completed",
        ] {
            assert!(
                events.iter().any(|event| event.phase == phase),
                "missing {phase} progress event"
            );
        }
        assert!(events
            .iter()
            .any(|event| { event.phase == "downloading" && event.segments == plan.workers }));
        assert_eq!(
            events.last().map(|event| event.phase.as_str()),
            Some("completed")
        );
    }

    #[test]
    fn does_not_claim_verification_when_the_catalog_has_no_sha256() {
        let temp = TempRoot::new("cloud-download-unverified");
        let paths = temp.paths();
        let server = MockServer::new(String::new(), 200);
        let mut settings = AppSettings {
            cloud: crate::models::CloudSettings {
                base_urls: vec![server.base_url.clone()],
                active_base_url: String::new(),
                max_download_segments: 16,
            },
            ..AppSettings::default()
        };
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();

        let result = runtime
            .block_on(download_remote(
                &paths,
                &mut settings,
                &RuntimeSecrets::default(),
                CloudAccess::Server,
                "demo",
                no_progress(),
            ))
            .unwrap();

        assert!(result.contains("未执行完整性校验"));
        assert!(!result.contains("通过 SHA-256 校验"));
        assert_eq!(server.finish().len(), expected_segmented_requests(16));
    }

    #[test]
    fn rejects_a_remote_file_with_the_wrong_sha256() {
        let temp = TempRoot::new("cloud-download-sha-mismatch");
        let paths = temp.paths();
        let server = MockServer::new("00".to_string(), 200);
        let mut settings = AppSettings {
            cloud: crate::models::CloudSettings {
                base_urls: vec![server.base_url.clone()],
                active_base_url: String::new(),
                max_download_segments: 16,
            },
            ..AppSettings::default()
        };
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();

        let error = runtime
            .block_on(download_remote(
                &paths,
                &mut settings,
                &RuntimeSecrets::default(),
                CloudAccess::Server,
                "demo",
                no_progress(),
            ))
            .unwrap_err();

        assert!(
            error.to_string().contains("SHA-256"),
            "unexpected download error: {error:#}"
        );
        assert!(!paths.local_mods.join("Demo.pak").exists());
        assert_eq!(server.finish().len(), expected_segmented_requests(16));
        assert_eq!(
            fs::read_dir(paths.root.join("downloads")).unwrap().count(),
            0
        );
    }

    #[test]
    fn server_edition_sends_the_same_shared_key_in_both_headers() {
        let temp = TempRoot::new("cloud-server-auth");
        let paths = temp.paths();
        let server = MockServer::new(file_sha256(), 200);
        let mut settings = AppSettings {
            cloud: crate::models::CloudSettings {
                base_urls: vec![server.base_url.clone()],
                active_base_url: String::new(),
                max_download_segments: 16,
            },
            ..AppSettings::default()
        };
        let secrets = RuntimeSecrets {
            cloud_auth_token: "unit-test-shared-key".to_string(),
            ..RuntimeSecrets::default()
        };
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();

        runtime
            .block_on(download_remote(
                &paths,
                &mut settings,
                &secrets,
                CloudAccess::Server,
                "demo",
                no_progress(),
            ))
            .unwrap();

        let requests = server.finish();
        assert_eq!(requests.len(), expected_segmented_requests(16));
        assert_eq!(requests[0].path, "/mods");
        assert!(requests[1].path.ends_with("/mods/demo/download"));
        for request in requests {
            assert_eq!(
                request.headers.get("authorization").map(String::as_str),
                Some("Bearer unit-test-shared-key")
            );
            assert_eq!(
                request.headers.get("x-scum-gate").map(String::as_str),
                Some("unit-test-shared-key")
            );
        }
    }

    #[test]
    fn public_edition_never_sends_cloud_credentials() {
        let temp = TempRoot::new("cloud-public-auth");
        let paths = temp.paths();
        let server = MockServer::new(file_sha256(), 200);
        let mut settings = AppSettings {
            cloud: crate::models::CloudSettings {
                base_urls: vec![server.base_url.clone()],
                active_base_url: String::new(),
                max_download_segments: 16,
            },
            ..AppSettings::default()
        };
        let secrets = RuntimeSecrets {
            cloud_auth_token: "must-not-leak".to_string(),
            ..RuntimeSecrets::default()
        };
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();

        runtime
            .block_on(download_remote(
                &paths,
                &mut settings,
                &secrets,
                CloudAccess::Public,
                "demo",
                no_progress(),
            ))
            .unwrap();

        for request in server.finish() {
            assert!(!request.headers.contains_key("authorization"));
            assert!(!request.headers.contains_key("x-scum-gate"));
        }
    }

    #[test]
    fn limits_cloud_credentials_to_secure_configured_origins() {
        let settings = AppSettings {
            cloud: crate::models::CloudSettings {
                base_urls: vec!["https://mods.example.test".to_string()],
                active_base_url: String::new(),
                max_download_segments: 16,
            },
            ..AppSettings::default()
        };

        assert!(should_attach_credentials(
            &url::Url::parse("https://mods.example.test/mods").unwrap(),
            &settings,
            CloudAccess::Server
        ));
        assert!(!should_attach_credentials(
            &url::Url::parse("https://cdn.example.test/file.pak").unwrap(),
            &settings,
            CloudAccess::Server
        ));
        assert!(!should_attach_credentials(
            &url::Url::parse("http://mods.example.test/mods").unwrap(),
            &settings,
            CloudAccess::Server
        ));
        assert!(!should_attach_credentials(
            &url::Url::parse("https://mods.example.test/mods").unwrap(),
            &settings,
            CloudAccess::Public
        ));
    }

    #[test]
    fn accepts_https_and_loopback_http_only() {
        for allowed in [
            "https://mods.example.test/mods",
            "http://localhost:1420/mods",
            "http://127.0.0.1:8080/mods",
            "http://[::1]:8080/mods",
        ] {
            assert!(
                allowed_cloud_transport(&url::Url::parse(allowed).unwrap()),
                "{allowed} should be accepted"
            );
        }
        for rejected in [
            "http://mods.example.test/mods",
            "ftp://mods.example.test/file.pak",
        ] {
            assert!(
                !allowed_cloud_transport(&url::Url::parse(rejected).unwrap()),
                "{rejected} should be rejected"
            );
        }
    }

    #[test]
    fn segment_plan_uses_at_least_eight_workers_and_two_chunks_per_worker() {
        let plan = segment_plan(128 * 1024 * 1024, 16);

        assert_eq!(plan.workers, 16);
        assert!(plan.total_chunks >= 32);
        assert_eq!(plan.chunk_size, 4 * 1024 * 1024);
    }

    #[test]
    fn segment_plan_honors_the_manual_ceiling_up_to_128() {
        let raised = segment_plan(128 * 1024 * 1024, 128);
        assert_eq!(raised.workers, 32);
        assert!(raised.total_chunks >= 64);
        assert_eq!(raised.chunk_size, 2 * 1024 * 1024);

        let clamped = segment_plan(1024 * 1024 * 1024, 999);
        assert_eq!(clamped.workers, 128);
        assert!(clamped.total_chunks >= 256);
    }

    #[test]
    fn segment_plan_never_exceeds_the_available_bytes() {
        let plan = segment_plan(4, 256);

        assert_eq!(plan.workers, 4);
        assert_eq!(plan.total_chunks, 4);
        assert_eq!(plan.chunk_size, 1);
    }

    #[test]
    fn requires_sha256_for_cross_origin_downloads() {
        let settings = AppSettings {
            cloud: crate::models::CloudSettings {
                base_urls: vec!["https://mods.example.test".to_string()],
                active_base_url: String::new(),
                max_download_segments: 16,
            },
            ..AppSettings::default()
        };
        let configured = url::Url::parse("https://mods.example.test/files/demo.pak").unwrap();
        let cross_origin = url::Url::parse("https://cdn.example.test/files/demo.pak").unwrap();

        assert!(download_source_allowed(&settings, &configured, false));
        assert!(!download_source_allowed(&settings, &cross_origin, false));
        assert!(download_source_allowed(&settings, &cross_origin, true));
    }

    #[test]
    fn reports_a_private_download_http_error_without_overwriting_it() {
        let temp = TempRoot::new("cloud-download-forbidden");
        let paths = temp.paths();
        let server = MockServer::new(file_sha256(), 403);
        let mut settings = AppSettings {
            cloud: crate::models::CloudSettings {
                base_urls: vec![server.base_url.clone()],
                active_base_url: String::new(),
                max_download_segments: 16,
            },
            ..AppSettings::default()
        };
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();

        let error = runtime
            .block_on(download_remote(
                &paths,
                &mut settings,
                &RuntimeSecrets {
                    cloud_auth_token: "wrong-key".to_string(),
                    ..RuntimeSecrets::default()
                },
                CloudAccess::Server,
                "demo",
                no_progress(),
            ))
            .unwrap_err()
            .to_string();

        assert!(error.contains("HTTP 403"), "unexpected error: {error}");
        assert!(!error.contains("SHA-256"), "unexpected error: {error}");
        assert!(!paths.local_mods.join("Demo.pak").exists());
        assert_eq!(server.finish().len(), 2);
    }

    #[test]
    fn rejects_a_server_that_ignores_range_instead_of_falling_back() {
        let temp = TempRoot::new("cloud-download-no-range");
        let paths = temp.paths();
        let server = MockServer::with_range(file_sha256(), 200, false);
        let mut settings = AppSettings {
            cloud: crate::models::CloudSettings {
                base_urls: vec![server.base_url.clone()],
                active_base_url: String::new(),
                max_download_segments: 16,
            },
            ..AppSettings::default()
        };
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();

        let error = runtime
            .block_on(download_remote(
                &paths,
                &mut settings,
                &RuntimeSecrets::default(),
                CloudAccess::Server,
                "demo",
                no_progress(),
            ))
            .unwrap_err()
            .to_string();

        assert!(
            error.contains("HTTP Range") && error.contains("HTTP 200"),
            "unexpected error: {error}"
        );
        assert!(!paths.local_mods.join("Demo.pak").exists());
        assert_eq!(server.finish().len(), 2);
        assert_eq!(
            fs::read_dir(paths.root.join("downloads")).unwrap().count(),
            0
        );
    }

    #[test]
    #[ignore = "requires packaged cloud sources and network access"]
    fn live_packaged_cloud_catalog_is_reachable() {
        let temp = TempRoot::new("cloud-live-catalog");
        let paths = temp.paths();
        let secrets = load_runtime_secrets(&paths, Edition::Public);
        assert!(
            !secrets.cloud_base_urls.is_empty(),
            "packaged cloud sources are empty"
        );
        let mut settings = AppSettings::default();
        crate::config::apply_default_cloud_sources(&mut settings, &secrets.cloud_base_urls);
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();

        let mods = runtime
            .block_on(fetch_catalog(
                &paths,
                &mut settings,
                &secrets,
                CloudAccess::Public,
            ))
            .unwrap();

        assert!(!mods.is_empty(), "live catalog returned no mods");
        assert!(mods.iter().any(|item| item.file_size > 0));
    }

    fn write_payload_zip(archive: &Path, entries: &[(&str, &[u8])]) {
        let file = std::fs::File::create(archive).unwrap();
        let mut writer = zip::ZipWriter::new(file);
        let options = zip::write::SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Stored);
        for (name, body) in entries {
            writer.start_file(*name, options).unwrap();
            writer.write_all(body).unwrap();
        }
        writer.finish().unwrap();
    }

    fn demo_remote(name: &str, mod_type: &str) -> RemoteMod {
        RemoteMod {
            id: "demo".to_string(),
            name: name.to_string(),
            author: String::new(),
            version: String::new(),
            description: String::new(),
            file_size: 0,
            download_url: "https://mods.example.test/files/Demo.pak".to_string(),
            sha256: String::new(),
            tags: Vec::new(),
            updated_at: String::new(),
            mod_type: mod_type.to_string(),
            installed: false,
        }
    }

    fn test_runtime() -> tokio::runtime::Runtime {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap()
    }

    #[test]
    fn recognizes_ue4ss_declarations_case_insensitively() {
        for declared in ["ue4ssMod", "UE4SS", "ue4ss_mod", "LuaMod"] {
            assert!(
                declared_ue4ss(declared),
                "{declared} should be treated as UE4SS"
            );
        }
        for declared in ["clientPak", "pak", "", "unknown"] {
            assert!(
                !declared_ue4ss(declared),
                "{declared} should not be treated as UE4SS"
            );
        }
    }

    #[test]
    fn installs_a_downloaded_zip_through_the_shared_ue4ss_path() {
        let temp = TempRoot::new("cloud-install-ue4ss");
        let paths = temp.paths();
        let payload = temp.path().join("payload.part");
        write_payload_zip(&payload, &[("武器增强/Scripts/main.lua", b"print('ok')")]);
        let remote = demo_remote("武器增强", "ue4ssMod");

        test_runtime()
            .block_on(install_downloaded(&paths, &payload, &remote))
            .unwrap();

        assert_eq!(
            fs::read(
                paths
                    .ue4ss_mods
                    .join("武器增强")
                    .join("Scripts")
                    .join("main.lua")
            )
            .unwrap(),
            b"print('ok')"
        );
        assert!(!paths.ue4ss_mods.join("武器增强").join("武器增强").exists());
    }

    #[test]
    fn installs_a_downloaded_pak_pack_into_the_local_library() {
        let temp = TempRoot::new("cloud-install-pak-zip");
        let paths = temp.paths();
        let payload = temp.path().join("payload.part");
        write_payload_zip(&payload, &[("nested/Weapon.pak", b"pak-bytes")]);
        let remote = demo_remote("武器增强", "clientPak");

        test_runtime()
            .block_on(install_downloaded(&paths, &payload, &remote))
            .unwrap();

        assert_eq!(
            fs::read(paths.local_mods.join("Weapon.pak")).unwrap(),
            b"pak-bytes"
        );
    }

    #[test]
    fn backs_up_an_existing_pak_before_replacing_it() {
        let temp = TempRoot::new("cloud-install-pak-backup");
        let paths = temp.paths();
        let existing = paths.local_mods.join("Demo.pak");
        fs::write(&existing, b"old").unwrap();
        let payload = temp.path().join("payload.part");
        fs::write(&payload, b"new").unwrap();
        let remote = demo_remote("Demo", "clientPak");

        test_runtime()
            .block_on(install_downloaded(&paths, &payload, &remote))
            .unwrap();

        assert_eq!(fs::read(&existing).unwrap(), b"new");
        assert_eq!(
            fs::read(paths.backups_dir.join("Demo.pak.bak")).unwrap(),
            b"old"
        );
    }

    #[test]
    fn rejects_a_ue4ss_declaration_whose_payload_is_not_a_zip() {
        let temp = TempRoot::new("cloud-install-bad-ue4ss");
        let paths = temp.paths();
        let payload = temp.path().join("payload.part");
        fs::write(&payload, b"not-a-zip").unwrap();
        let remote = demo_remote("武器增强", "ue4ssMod");

        let error = test_runtime()
            .block_on(install_downloaded(&paths, &payload, &remote))
            .unwrap_err();

        assert!(error.to_string().contains("不是 ZIP"));
    }

    #[test]
    fn retries_a_flaky_chunk_instead_of_failing_the_download() {
        let temp = TempRoot::new("cloud-download-retry");
        let paths = temp.paths();
        let server = MockServer::with_flaky(file_sha256(), 1);
        let mut settings = AppSettings {
            cloud: crate::models::CloudSettings {
                base_urls: vec![server.base_url.clone()],
                active_base_url: String::new(),
                max_download_segments: 16,
            },
            ..AppSettings::default()
        };
        let secrets = load_runtime_secrets(&paths, Edition::Public);

        let result = test_runtime()
            .block_on(download_remote(
                &paths,
                &mut settings,
                &secrets,
                CloudAccess::Public,
                "demo",
                no_progress(),
            ))
            .unwrap();

        assert!(result.contains("SHA-256 校验"));
        assert!(paths.local_mods.join("Demo.pak").exists());
        assert_eq!(server.finish().len(), expected_segmented_requests(16) + 1);
    }

    #[test]
    fn gives_up_after_the_retry_budget_is_spent() {
        let temp = TempRoot::new("cloud-download-retry-exhausted");
        let paths = temp.paths();
        let server = MockServer::with_flaky(file_sha256(), 500);
        let mut settings = AppSettings {
            cloud: crate::models::CloudSettings {
                base_urls: vec![server.base_url.clone()],
                active_base_url: String::new(),
                max_download_segments: 16,
            },
            ..AppSettings::default()
        };
        let secrets = load_runtime_secrets(&paths, Edition::Public);

        let error = test_runtime()
            .block_on(download_remote(
                &paths,
                &mut settings,
                &secrets,
                CloudAccess::Public,
                "demo",
                no_progress(),
            ))
            .unwrap_err();

        assert!(format!("{error:#}").contains("HTTP 503"));
        assert!(!paths.local_mods.join("Demo.pak").exists());
        let _ = server.finish();
    }

    #[test]
    fn round_trips_the_catalog_cache() {
        let temp = TempRoot::new("cloud-catalog-cache");
        let paths = temp.paths();
        let catalog = json!({
            "mods": [{
                "id": "demo",
                "name": "Demo",
                "sha256": "abc123",
                "type": "clientPak"
            }]
        });

        save_catalog_cache(&paths, "https://mods.example.test", &catalog);
        let mods = load_catalog_cache(&paths).unwrap();

        assert_eq!(mods.len(), 1);
        assert_eq!(mods[0].id, "demo");
        assert_eq!(mods[0].sha256, "abc123");
        assert_eq!(
            mods[0].download_url,
            "https://mods.example.test/mods/demo/download"
        );
    }

    #[test]
    fn backfills_display_names_from_the_catalog_cache() {
        let temp = TempRoot::new("cloud-name-backfill");
        let paths = temp.paths();
        let catalog = json!({
            "mods": [{
                "id": "demo",
                "name": "衣物容器嵌套",
                "sha256": "abcdef0123456789",
                "type": "clientPak"
            }]
        });
        save_catalog_cache(&paths, "https://mods.example.test", &catalog);

        let mut metadata = crate::metadata::MetadataFile::default();
        let mut mods = vec![ModEntry {
            id: "legacy".to_string(),
            name: "______".to_string(),
            file_name: "______.pak".to_string(),
            file_path: String::new(),
            file_size: 1,
            last_modified: String::new(),
            enabled: true,
            mod_type: "clientPak".to_string(),
            load_order: 0,
            tags: Vec::new(),
            notes: String::new(),
            sha256: "ABCDEF0123456789".to_string(),
            origin_source: "local".to_string(),
            deployed: false,
            description: String::new(),
            conflict_count: 0,
            update_version: None,
        }];

        assert_eq!(apply_catalog_names(&paths, &mut metadata, &mut mods), 1);
        assert_eq!(mods[0].name, "衣物容器嵌套");
        assert_eq!(
            metadata.entries["legacy"].name.as_deref(),
            Some("衣物容器嵌套")
        );

        // 名字已经记下来了，第二次不该重复计数，也不该被缓存覆盖
        metadata.entries.get_mut("legacy").unwrap().name = Some("用户自己改的名".to_string());
        assert_eq!(apply_catalog_names(&paths, &mut metadata, &mut mods), 0);
        assert_eq!(mods[0].name, "用户自己改的名");
    }

    #[test]
    fn formats_human_readable_sizes() {
        assert_eq!(human_bytes(512), "512 B");
        assert_eq!(human_bytes(1024), "1.0 KB");
        assert_eq!(human_bytes(64 * 1024 * 1024), "64.0 MB");
    }

    #[test]
    fn retries_only_transient_chunk_errors() {
        let transient: anyhow::Error = RetryableChunkError {
            reason: "分片请求返回 HTTP 503".to_string(),
        }
        .into();
        assert!(is_retryable_chunk_error(&transient));

        let fatal = anyhow::anyhow!("分片响应区间不匹配");
        assert!(!is_retryable_chunk_error(&fatal));
    }
}
