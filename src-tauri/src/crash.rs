use std::path::{Path, PathBuf};
use std::time::SystemTime;

use crate::models::{AppSettings, ModEntry};

/// evidence 最多保留的日志行数。
const MAX_EVIDENCE: usize = 12;
/// suspects 最多返回的数量。
const MAX_SUSPECTS: usize = 8;
/// 单个可疑模组最多附带的日志行数。
const MAX_LINES_PER_SUSPECT: usize = 6;
/// 尾部上下文的行数。
const TAIL_LINES: usize = 200;

/// 一次游戏运行结束后的崩溃取证结果。字段全部用于前端展示与日志。
#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CrashSuspect {
    pub mod_id: String,
    pub name: String,
    pub reason: String,
    pub lines: Vec<String>,
}

#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CrashReport {
    pub abnormal: bool,
    pub cause: String,
    pub summary: String,
    pub log_path: Option<String>,
    pub ue4ss_log_path: Option<String>,
    pub evidence: Vec<String>,
    pub suspects: Vec<CrashSuspect>,
    pub suggestions: Vec<String>,
}

/// 崩溃类型；`code()` 直接写入 `CrashReport::cause`。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum CauseKind {
    PakIntegrity,
    Ue4ss,
    Crash,
    RequestExit,
    Unknown,
}

impl CauseKind {
    fn code(self) -> &'static str {
        match self {
            CauseKind::PakIntegrity => "pak-integrity",
            CauseKind::Ue4ss => "ue4ss",
            CauseKind::Crash => "crash",
            CauseKind::RequestExit => "request-exit",
            CauseKind::Unknown => "unknown",
        }
    }

    /// 证据优先级：签名问题最具体，其次脚本报错，再到致命错误，最后才是退出请求。
    fn rank(self) -> u8 {
        match self {
            CauseKind::PakIntegrity => 4,
            CauseKind::Ue4ss => 3,
            CauseKind::Crash => 2,
            CauseKind::RequestExit => 1,
            CauseKind::Unknown => 0,
        }
    }

    /// 命中该模组时写给用户的原因说明。
    fn reason(self) -> &'static str {
        match self {
            CauseKind::PakIntegrity => "该模组的 PAK 触发签名或完整性校验错误",
            CauseKind::Ue4ss => "UE4SS / Lua 脚本报错指向该模组",
            CauseKind::Crash => "致命错误上下文里出现该模组的 PAK 文件",
            CauseKind::RequestExit => "退出请求前的日志涉及该模组的 PAK 文件",
            CauseKind::Unknown => "日志中的 PAK 警告或错误涉及该模组的文件",
        }
    }
}

/// 单条崩溃证据。
struct Marker {
    kind: CauseKind,
    text: String,
}

fn has_error_word(lower: &str) -> bool {
    lower.contains("error")
        || lower.contains("crash")
        || lower.contains("exception")
        || lower.contains("traceback")
}

/// 判断一行日志属于哪类崩溃证据，全部按小写匹配。
fn classify_line(line: &str) -> Option<CauseKind> {
    let lower = line.to_ascii_lowercase();

    // PAK 签名 / 完整性：最具体的证据，优先级最高。
    if lower.contains("pak signature file")
        || lower.contains("integrity compromised")
        || lower.contains("pak file is corrupted")
    {
        return Some(CauseKind::PakIntegrity);
    }

    // UE4SS 本体或 Lua 脚本报错。
    if lower.contains("lua error")
        || lower.contains("lua exception")
        || lower.contains("lua traceback")
        || (lower.contains("[lua]") && has_error_word(&lower))
        || (lower.contains("ue4ss") && has_error_word(&lower))
    {
        return Some(CauseKind::Ue4ss);
    }

    // 通用致命错误。
    if lower.contains("fatal error")
        || lower.contains("unhandled exception")
        || lower.contains("access violation")
        || lower.contains("assertion failed")
        || lower.contains("logwindows: error")
        || lower.contains("failed to load")
    {
        return Some(CauseKind::Crash);
    }

    if lower.contains("requestexit") {
        return Some(CauseKind::RequestExit);
    }

    None
}

fn is_lua_error_line(lower: &str) -> bool {
    matches!(classify_line(lower), Some(CauseKind::Ue4ss))
}

/// 扫描整段文本，按出现顺序收集崩溃证据。
fn collect_markers(text: &str, skip_lines: usize) -> Vec<Marker> {
    let mut markers = Vec::new();
    for line in text.lines().skip(skip_lines) {
        if let Some(kind) = classify_line(line) {
            let trimmed = line.trim();
            if trimmed.is_empty() {
                continue;
            }
            markers.push(Marker {
                kind,
                text: trimmed.to_string(),
            });
        }
    }
    markers
}

fn push_unique_line(target: &mut Vec<String>, line: &str) {
    let trimmed = line.trim();
    if trimmed.is_empty() {
        return;
    }
    if target.iter().any(|existing| existing == trimmed) {
        return;
    }
    target.push(trimmed.to_string());
}

/// 文本最后 `TAIL_LINES` 行，保持原始顺序。
fn tail_of(text: &str) -> Vec<String> {
    let mut tail: Vec<String> = text
        .lines()
        .rev()
        .take(TAIL_LINES)
        .map(|line| line.trim().to_string())
        .collect();
    tail.reverse();
    tail
}

/// 去掉 `NNN_` 形式的数字前缀；没有前缀时原样返回。
fn strip_numeric_prefix(raw: &str) -> &str {
    let trimmed = raw.trim();
    let digits = trimmed
        .chars()
        .take_while(|value| value.is_ascii_digit())
        .count();
    if digits == 0 || digits >= trimmed.len() {
        return trimmed;
    }
    let rest = &trimmed[digits..];
    if let Some(stripped) = rest.strip_prefix('_').or_else(|| rest.strip_prefix('-')) {
        let stripped = stripped.trim_start();
        if !stripped.is_empty() {
            return stripped;
        }
    }
    trimmed
}

fn push_keyword(keywords: &mut Vec<String>, raw: &str) {
    let value = raw.trim().to_ascii_lowercase();
    // 少于 3 个字符的关键词几乎必然误报（例如 "a"、"mod"），直接忽略。
    if value.len() < 3 {
        return;
    }
    if keywords.iter().any(|existing| existing == &value) {
        return;
    }
    keywords.push(value);
}

/// 模组关键词：完整文件名、去扩展名的 stem、去掉数字前缀后的名字。
fn mod_keywords(entry: &ModEntry) -> Vec<String> {
    let mut keywords: Vec<String> = Vec::new();

    push_keyword(&mut keywords, &entry.file_name);

    let stem = Path::new(&entry.file_name)
        .file_stem()
        .and_then(|value| value.to_str())
        .unwrap_or("");
    push_keyword(&mut keywords, stem);
    push_keyword(&mut keywords, strip_numeric_prefix(stem));

    push_keyword(&mut keywords, &entry.name);
    push_keyword(&mut keywords, strip_numeric_prefix(&entry.name));

    keywords
}

/// 抽取一行日志里出现的 `.pak` 文件名（小写、去掉路径）。
fn pak_names_in_line(lower_line: &str) -> Vec<String> {
    let mut names: Vec<String> = Vec::new();
    for token in lower_line.split(|value: char| {
        value.is_whitespace()
            || matches!(
                value,
                '"' | '\'' | '`' | ',' | ';' | '(' | ')' | '[' | ']' | '{' | '}' | '<' | '>' | '|'
            )
    }) {
        let token = token.trim_matches(|value: char| value == '.' || value == ':' || value == ';');
        let Some(index) = token.rfind(".pak") else {
            continue;
        };
        let name = &token[..index + 4];
        let base = name
            .rsplit(|value: char| value == '\\' || value == '/')
            .next()
            .unwrap_or(name)
            .trim_start_matches('*');
        if base.len() <= 4 || names.iter().any(|existing| existing == base) {
            continue;
        }
        names.push(base.to_string());
    }
    names
}

fn pak_matches(pak: &str, keyword: &str) -> bool {
    if keyword.ends_with(".pak") {
        pak == keyword
    } else {
        pak.contains(keyword)
    }
}

fn display_name(entry: &ModEntry) -> String {
    if entry.name.trim().is_empty() {
        entry.file_name.clone()
    } else {
        entry.name.clone()
    }
}

/// 在证据行与尾部上下文里匹配 enabled 模组的 PAK 文件名。
fn find_suspects(context: &[String], mods: &[ModEntry]) -> Vec<CrashSuspect> {
    let mut ranked: Vec<(usize, CrashSuspect)> = Vec::new();

    for entry in mods.iter().filter(|entry| entry.enabled) {
        let keywords = mod_keywords(entry);
        if keywords.is_empty() {
            continue;
        }

        let mut hits = 0usize;
        let mut lines: Vec<String> = Vec::new();
        let mut strongest: Option<CauseKind> = None;

        for line in context {
            let lower = line.to_ascii_lowercase();
            let pak_names = pak_names_in_line(&lower);

            let matched = if pak_names.is_empty() {
                // 没有 .pak 名时只接受 UE4SS / Lua 报错行（脚本模组目录通常不带扩展名）。
                is_lua_error_line(&lower)
                    && keywords
                        .iter()
                        .any(|keyword| lower.contains(keyword.as_str()))
            } else {
                pak_names
                    .iter()
                    .any(|pak| keywords.iter().any(|keyword| pak_matches(pak, keyword)))
            };
            if !matched {
                continue;
            }

            hits += 1;
            if lines.len() < MAX_LINES_PER_SUSPECT && !lines.iter().any(|existing| existing == line)
            {
                lines.push(line.clone());
            }
            if let Some(kind) = classify_line(line) {
                strongest = Some(match strongest {
                    Some(current) if current.rank() > kind.rank() => current,
                    _ => kind,
                });
            }
        }

        if lines.is_empty() {
            continue;
        }

        let suspect = CrashSuspect {
            mod_id: entry.id.clone(),
            name: display_name(entry),
            reason: strongest.unwrap_or(CauseKind::Unknown).reason().to_string(),
            lines,
        };
        ranked.push((hits, suspect));
    }

    // 命中次数多的排前面；次数相同则保持启用模组的原有顺序。
    ranked.sort_by(|left, right| right.0.cmp(&left.0));
    ranked
        .into_iter()
        .take(MAX_SUSPECTS)
        .map(|(_, suspect)| suspect)
        .collect()
}

fn suspect_names(suspects: &[CrashSuspect]) -> String {
    let names: Vec<&str> = suspects
        .iter()
        .take(3)
        .map(|suspect| suspect.name.as_str())
        .collect();
    let joined = names.join("、");
    if suspects.len() > 3 {
        format!("{joined} 等")
    } else {
        joined
    }
}

fn build_summary(cause: CauseKind, suspects: &[CrashSuspect]) -> String {
    if !suspects.is_empty() {
        return format!("检测到异常退出，疑似由{}引发", suspect_names(suspects));
    }

    match cause {
        CauseKind::PakIntegrity => "检测到 PAK 签名或完整性校验失败，游戏异常退出".to_string(),
        CauseKind::Ue4ss => "检测到 UE4SS / Lua 脚本报错，游戏异常退出".to_string(),
        CauseKind::Crash => {
            "检测到致命错误（Fatal error / Access violation），游戏异常退出".to_string()
        }
        CauseKind::RequestExit => {
            "日志显示游戏收到退出请求后结束，未捕获明确的致命错误".to_string()
        }
        CauseKind::Unknown => "未检测到崩溃标记，本次运行可能正常结束".to_string(),
    }
}

fn build_suggestions(
    cause: CauseKind,
    suspects: &[CrashSuspect],
    log_path: Option<&Path>,
    ue4ss_path: Option<&Path>,
) -> Vec<String> {
    if !suspects.is_empty() {
        let mut out = vec![format!(
            "先禁用{}后重试，确认崩溃是否消失",
            suspect_names(suspects)
        )];
        out.push(match ue4ss_path {
            Some(path) => format!(
                "查看 UE4SS.log（{}）末尾的 Lua 或脚本报错，确认报错出自哪个模组",
                path.display()
            ),
            None => "查看 UE4SS.log 末尾的 Lua 或脚本报错，确认报错出自哪个模组".to_string(),
        });
        out.push("若仍崩溃，按一半一半的方式分批禁用模组，逐步缩小到具体文件".to_string());
        out.push("核对 ~mods 里是否有重名 PAK，并确认模组与当前游戏版本匹配".to_string());
        return out;
    }

    let mut out = Vec::new();
    out.push(match log_path {
        Some(path) => format!("查看日志定位崩溃点：{}", path.display()),
        None => "查看游戏日志（SCUM\\Saved\\Logs\\SCUM.log）定位崩溃点".to_string(),
    });
    out.push("禁用最近安装或最近更新的模组，再启动一次确认是否恢复".to_string());
    out.push("检查 PAK 是否缺失签名文件，并在启动参数中加入 -fileopenlog 核对挂载顺序".to_string());
    if matches!(cause, CauseKind::Ue4ss) {
        out.push("查看 UE4SS.log 中的 Lua 报错堆栈，确认报错来自哪个脚本模组".to_string());
    }
    out
}

/// 纯函数入口：只解析传入的文本，便于单元测试。
///
/// `since_line` 用于跳过上一次运行残留的日志行，`0` 表示全量分析。
pub fn analyze_texts(
    log_text: &str,
    ue4ss_text: &str,
    log_path: Option<&Path>,
    ue4ss_path: Option<&Path>,
    mods: &[ModEntry],
    since_line: usize,
) -> CrashReport {
    let mut markers = collect_markers(log_text, since_line);
    markers.extend(collect_markers(ue4ss_text, 0));

    // 只有“退出请求”而没有致命错误的日志通常就是玩家正常退出；
    // 它保留在上下文里帮助定位，但不能单独把这次运行判成崩溃。
    let fatal_markers: Vec<&Marker> = markers
        .iter()
        .filter(|marker| marker.kind != CauseKind::RequestExit)
        .collect();
    let abnormal = !fatal_markers.is_empty();
    let cause = fatal_markers
        .iter()
        .map(|marker| marker.kind)
        .max_by_key(|kind| kind.rank())
        .unwrap_or(CauseKind::Unknown);

    // 证据按出现顺序去重，最多 12 条。
    let mut evidence: Vec<String> = Vec::new();
    for marker in &markers {
        if evidence.len() >= MAX_EVIDENCE {
            break;
        }
        if evidence.iter().any(|existing| existing == &marker.text) {
            continue;
        }
        evidence.push(marker.text.clone());
    }

    // 匹配范围：命中行 + 两个日志各自的最后 200 行。
    let mut context: Vec<String> = Vec::new();
    for marker in &markers {
        push_unique_line(&mut context, &marker.text);
    }
    for line in tail_of(log_text) {
        push_unique_line(&mut context, &line);
    }
    for line in tail_of(ue4ss_text) {
        push_unique_line(&mut context, &line);
    }

    // 没有任何崩溃标记时不猜疑模组，保持 abnormal 与 suspects 语义一致。
    let suspects = if abnormal {
        find_suspects(&context, mods)
    } else {
        Vec::new()
    };

    let summary = build_summary(cause, &suspects);
    let suggestions = build_suggestions(cause, &suspects, log_path, ue4ss_path);

    CrashReport {
        abnormal,
        cause: cause.code().to_string(),
        summary,
        log_path: log_path.map(|path| path.to_string_lossy().into_owned()),
        ue4ss_log_path: ue4ss_path.map(|path| path.to_string_lossy().into_owned()),
        evidence,
        suspects,
        suggestions,
    }
}

/// 启动前记录的日志文件长度；退出后只分析这些文件新追加的内容，
/// 避免把上一次运行残留的 UE4SS 报错当成这一次的崩溃。
pub type LogBaselines = Vec<(PathBuf, u64)>;

pub fn capture_baselines(settings: &AppSettings) -> LogBaselines {
    let local_app = local_app_data();
    let mut baselines = LogBaselines::new();
    for path in game_log_candidates(settings, local_app.as_deref())
        .into_iter()
        .chain(ue4ss_log_candidates(settings, local_app.as_deref()))
    {
        if let Ok(meta) = std::fs::metadata(&path) {
            if meta.is_file() {
                baselines.push((path, meta.len()));
            }
        }
    }
    baselines
}

fn baseline_for(baselines: &[(PathBuf, u64)], path: &Path) -> u64 {
    baselines
        .iter()
        .find(|(candidate, _)| candidate == path)
        .map(|(_, offset)| *offset)
        .unwrap_or(0)
}

fn read_text_from(path: &Path, offset: u64) -> Option<String> {
    let bytes = std::fs::read(path).ok()?;
    let mut start = if (bytes.len() as u64) < offset {
        0 // 日志被游戏轮转/截断，从头读
    } else if bytes.len() as u64 == offset {
        return Some(String::new());
    } else {
        offset as usize
    };
    // 追加写入可能落在多字节字符中间，向前退到 UTF-8 边界。
    while start > 0 && start < bytes.len() && (bytes[start] & 0xC0) == 0x80 {
        start -= 1;
    }
    Some(String::from_utf8_lossy(&bytes[start..]).into_owned())
}

/// 对外入口：解析日志路径、读取文本，再交给 `analyze_texts` 分析。
pub fn analyze_logs(
    settings: &AppSettings,
    mods: &[ModEntry],
    since: Option<SystemTime>,
    baselines: &[(PathBuf, u64)],
) -> CrashReport {
    analyze_logs_with_local_app_data(
        settings,
        mods,
        since,
        baselines,
        local_app_data().as_deref(),
    )
}

/// 与 `analyze_logs` 等价，但把 `%LOCALAPPDATA%` 作为参数传入，测试可注入临时目录。
fn analyze_logs_with_local_app_data(
    settings: &AppSettings,
    mods: &[ModEntry],
    since: Option<SystemTime>,
    baselines: &[(PathBuf, u64)],
    local_app: Option<&Path>,
) -> CrashReport {
    let game_log = pick_existing(&game_log_candidates(settings, local_app), since);
    let ue4ss_log = pick_existing(&ue4ss_log_candidates(settings, local_app), since);

    if game_log.is_none() && ue4ss_log.is_none() {
        return missing_report();
    }

    let log_text = game_log
        .as_deref()
        .and_then(|path| read_text_from(path, baseline_for(baselines, path)))
        .unwrap_or_default();
    let ue4ss_text = ue4ss_log
        .as_deref()
        .and_then(|path| read_text_from(path, baseline_for(baselines, path)))
        .unwrap_or_default();

    let mut report = analyze_texts(
        &log_text,
        &ue4ss_text,
        game_log.as_deref(),
        ue4ss_log.as_deref(),
        mods,
        0,
    );

    // 主日志缺失、只剩 UE4SS.log 时仍然分析脚本错误；没有证据才判定为“未找到日志”。
    if game_log.is_none() && !report.abnormal {
        report.summary = "未找到本次运行的游戏日志".to_string();
    }
    report
}

fn local_app_data() -> Option<PathBuf> {
    std::env::var_os("LOCALAPPDATA").map(PathBuf::from)
}

fn push_candidate(candidates: &mut Vec<PathBuf>, path: PathBuf) {
    if candidates.iter().any(|existing| existing == &path) {
        return;
    }
    candidates.push(path);
}

/// 客户端与服务器日志候选，按“先客户端后服务端”的顺序排列。
fn game_log_candidates(settings: &AppSettings, local_app: Option<&Path>) -> Vec<PathBuf> {
    let mut candidates: Vec<PathBuf> = Vec::new();

    if let Some(base) = local_app {
        push_candidate(
            &mut candidates,
            base.join("SCUM")
                .join("Saved")
                .join("Logs")
                .join("SCUM.log"),
        );
    }

    let client_root = settings.scum_install_path.trim();
    if !client_root.is_empty() {
        let root = Path::new(client_root);
        push_candidate(
            &mut candidates,
            root.join("SCUM")
                .join("Saved")
                .join("Logs")
                .join("SCUM.log"),
        );
        // 兼容安装路径已指向内层 SCUM 目录的写法。
        push_candidate(
            &mut candidates,
            root.join("Saved").join("Logs").join("SCUM.log"),
        );
    }

    if let Some(base) = local_app {
        push_candidate(
            &mut candidates,
            base.join("SCUM")
                .join("Saved")
                .join("Logs")
                .join("SCUMServer.log"),
        );
    }

    let server_root = settings.server_install_path.trim();
    if !server_root.is_empty() {
        let root = Path::new(server_root);
        push_candidate(
            &mut candidates,
            root.join("SCUM")
                .join("Saved")
                .join("Logs")
                .join("SCUMServer.log"),
        );
        push_candidate(
            &mut candidates,
            root.join("Saved").join("Logs").join("SCUMServer.log"),
        );
    }

    candidates
}

fn ue4ss_log_candidates(settings: &AppSettings, local_app: Option<&Path>) -> Vec<PathBuf> {
    let mut candidates: Vec<PathBuf> = Vec::new();

    let client_root = settings.scum_install_path.trim();
    if !client_root.is_empty() {
        let root = Path::new(client_root);
        push_candidate(
            &mut candidates,
            root.join("SCUM")
                .join("Binaries")
                .join("Win64")
                .join("ue4ss")
                .join("UE4SS.log"),
        );
        push_candidate(
            &mut candidates,
            root.join("SCUM")
                .join("Binaries")
                .join("Win64")
                .join("UE4SS.log"),
        );
        // 兼容安装路径已指向内层 SCUM 目录的写法。
        push_candidate(
            &mut candidates,
            root.join("Binaries")
                .join("Win64")
                .join("ue4ss")
                .join("UE4SS.log"),
        );
        push_candidate(
            &mut candidates,
            root.join("Binaries").join("Win64").join("UE4SS.log"),
        );
    }

    if let Some(base) = local_app {
        push_candidate(
            &mut candidates,
            base.join("SCUM")
                .join("Saved")
                .join("Logs")
                .join("UE4SS.log"),
        );
    }

    candidates
}

/// 选第一个存在、且修改时间不早于 `since` 的日志。
fn pick_existing(candidates: &[PathBuf], since: Option<SystemTime>) -> Option<PathBuf> {
    candidates
        .iter()
        .find(|path| path.is_file() && fresh_enough(path, since))
        .cloned()
}

fn fresh_enough(path: &Path, since: Option<SystemTime>) -> bool {
    match since {
        None => true,
        Some(threshold) => std::fs::metadata(path)
            .and_then(|meta| meta.modified())
            .map(|modified| modified >= threshold)
            .unwrap_or(false),
    }
}

fn missing_report() -> CrashReport {
    CrashReport {
        abnormal: false,
        cause: "unknown".to_string(),
        summary: "未找到本次运行的游戏日志".to_string(),
        log_path: None,
        ue4ss_log_path: None,
        evidence: Vec::new(),
        suspects: Vec::new(),
        suggestions: vec![
            "确认游戏由本启动器启动，并已勾选 -log 参数".to_string(),
            "检查设置中的游戏安装路径是否指向 SCUM 目录".to_string(),
            "启动一次游戏并退出后，再重新运行崩溃分析".to_string(),
        ],
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::ModEntry;
    use std::fs;
    use std::path::PathBuf;

    fn temp_dir() -> PathBuf {
        let dir = std::env::temp_dir().join(format!("scum-crash-test-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&dir).expect("创建临时目录");
        dir
    }

    fn test_mod(id: &str, name: &str, file_name: &str, enabled: bool) -> ModEntry {
        ModEntry {
            id: id.to_string(),
            name: name.to_string(),
            file_name: file_name.to_string(),
            enabled,
            mod_type: "clientPak".to_string(),
            ..Default::default()
        }
    }

    #[test]
    fn pak_integrity_error_points_at_enabled_mod() {
        let dir = temp_dir();
        let log_path = dir.join("SCUM.log");
        let log_text = "\
LogInit: Display: Starting SCUM
LogPakFile: Warning: Pak file \"../../../SCUM/Content/Paks/~mods/AlphaOverhaul.pak\" has no signature
LogPakFile: Warning: Pak file \"../../../SCUM/Content/Paks/~mods/BetaTweaks.pak\" has no signature
LogPakFile: Error: Couldn't find pak signature file for AlphaOverhaul.pak
Fatal error: [File:Unknown] [Line: 42] Failed to load package
";
        fs::write(&log_path, log_text).expect("写入假日志");

        let mods = vec![
            test_mod("alpha", "Alpha Overhaul", "AlphaOverhaul.pak", true),
            test_mod("beta", "Beta Tweaks", "BetaTweaks.pak", false),
        ];

        let report = analyze_texts(log_text, "", Some(log_path.as_path()), None, &mods, 0);

        assert!(report.abnormal);
        assert_eq!(report.cause, "pak-integrity");
        assert!(report.evidence.len() <= MAX_EVIDENCE);
        assert!(report
            .evidence
            .iter()
            .any(|line| line.contains("Couldn't find pak signature file")));

        assert_eq!(report.suspects.len(), 1, "禁用模组不应被列为可疑");
        assert_eq!(report.suspects[0].mod_id, "alpha");
        assert!(report.suspects[0].lines.len() <= MAX_LINES_PER_SUSPECT);
        assert!(report.suspects[0]
            .lines
            .iter()
            .any(|line| line.contains("AlphaOverhaul.pak")));
        assert!(
            report.suspects[0].reason.contains("签名")
                || report.suspects[0].reason.contains("完整性")
        );

        assert!(report.summary.starts_with("检测到异常退出"));
        assert!(report.summary.contains("Alpha Overhaul"));
        assert!(report
            .suggestions
            .iter()
            .any(|line| line.contains("先禁用")));
        assert!(report
            .suggestions
            .iter()
            .any(|line| line.contains("UE4SS.log")));
        assert!(report
            .suggestions
            .iter()
            .any(|line| line.contains("一半一半")));

        assert_eq!(
            report.log_path,
            Some(log_path.to_string_lossy().into_owned())
        );

        fs::remove_dir_all(&dir).expect("清理临时目录");
    }

    #[test]
    fn ue4ss_lua_error_points_at_script_mod() {
        let dir = temp_dir();
        let log_path = dir.join("SCUM.log");
        let ue4ss_path = dir.join("UE4SS.log");
        let log_text = "LogInit: Display: Starting SCUM\nLogNet: Display: Join succeeded\n";
        let ue4ss_text = "\
[2026-05-01 10:00:00] Starting UE4SS
[Lua] Error: 890_LuaTweaks/scripts/main.lua: attempt to index a nil value
";
        fs::write(&log_path, log_text).expect("写入假日志");
        fs::write(&ue4ss_path, ue4ss_text).expect("写入假 UE4SS 日志");

        let mods = vec![test_mod("lua", "Lua Tweaks", "890_LuaTweaks.zip", true)];
        let report = analyze_texts(
            log_text,
            ue4ss_text,
            Some(log_path.as_path()),
            Some(ue4ss_path.as_path()),
            &mods,
            0,
        );

        assert!(report.abnormal);
        assert_eq!(report.cause, "ue4ss");
        assert!(report
            .evidence
            .iter()
            .any(|line| line.contains("[Lua] Error")));
        assert_eq!(report.suspects.len(), 1);
        assert_eq!(report.suspects[0].mod_id, "lua");
        assert!(report.suspects[0].reason.contains("Lua"));
        assert!(report.summary.contains("Lua Tweaks"));
        assert_eq!(
            report.ue4ss_log_path,
            Some(ue4ss_path.to_string_lossy().into_owned())
        );

        fs::remove_dir_all(&dir).expect("清理临时目录");
    }

    #[test]
    fn clean_log_is_not_abnormal() {
        let dir = temp_dir();
        let log_path = dir.join("SCUM.log");
        let log_text = "\
LogInit: Display: Starting SCUM
LogNet: Display: Login request accepted
LogExit: Display: Shutdown complete
";
        fs::write(&log_path, log_text).expect("写入假日志");

        let mods = vec![test_mod(
            "alpha",
            "Alpha Overhaul",
            "AlphaOverhaul.pak",
            true,
        )];
        let report = analyze_texts(log_text, "", Some(log_path.as_path()), None, &mods, 0);

        assert!(!report.abnormal);
        assert_eq!(report.cause, "unknown");
        assert!(report.evidence.is_empty());
        assert!(report.suspects.is_empty());
        assert!(report.summary.contains("未检测到崩溃标记"));
        assert!(report
            .suggestions
            .iter()
            .any(|line| line.contains("最近安装")));
        assert!(report
            .suggestions
            .iter()
            .any(|line| line.contains("-fileopenlog")));

        fs::remove_dir_all(&dir).expect("清理临时目录");
    }

    #[test]
    fn only_content_appended_after_baseline_is_analyzed() {
        let dir = temp_dir();
        let local_app = dir.join("localapp");
        let log_dir = local_app.join("SCUM").join("Saved").join("Logs");
        fs::create_dir_all(&log_dir).expect("创建日志目录");
        let ue4ss_path = log_dir.join("UE4SS.log");
        fs::write(&ue4ss_path, "[Lua] Error: old run failed\n").expect("写入旧日志");
        let offset = fs::metadata(&ue4ss_path).unwrap().len();
        let baselines = vec![(ue4ss_path.clone(), offset)];

        let settings = AppSettings {
            scum_install_path: dir.join("scum-install").to_string_lossy().into_owned(),
            ..AppSettings::default()
        };

        fs::write(
            &ue4ss_path,
            "[Lua] Error: old run failed\n[Lua] Info: clean run\n",
        )
        .expect("追加干净日志");
        let clean =
            analyze_logs_with_local_app_data(&settings, &[], None, &baselines, Some(&local_app));
        assert!(!clean.abnormal, "上一次运行的报错不应算到这一次头上");

        fs::write(
            &ue4ss_path,
            "[Lua] Error: old run failed\n[Lua] Error: new run failed\n",
        )
        .expect("追加崩溃日志");
        let crashed =
            analyze_logs_with_local_app_data(&settings, &[], None, &baselines, Some(&local_app));
        assert!(crashed.abnormal);
        assert!(crashed
            .evidence
            .iter()
            .all(|line| !line.contains("old run failed")));

        fs::remove_dir_all(&dir).expect("清理临时目录");
    }

    #[test]
    fn request_exit_without_fatal_error_is_a_normal_quit() {
        let log_text = "\
LogInit: Display: Starting SCUM
LogExit: Display: RequestExit was called by the player
";
        let report = analyze_texts(log_text, "", None, None, &[], 0);
        assert!(!report.abnormal);
        assert_eq!(report.cause, "unknown");
        assert!(report.summary.contains("未检测到崩溃标记"));
    }

    #[test]
    fn missing_log_reports_no_log() {
        let dir = temp_dir();
        let settings = AppSettings {
            scum_install_path: dir.join("scum-install").to_string_lossy().into_owned(),
            server_install_path: dir.join("server-install").to_string_lossy().into_owned(),
            ..AppSettings::default()
        };

        let report =
            analyze_logs_with_local_app_data(&settings, &[], None, &[], Some(dir.as_path()));

        assert!(!report.abnormal);
        assert_eq!(report.cause, "unknown");
        assert_eq!(report.summary, "未找到本次运行的游戏日志");
        assert!(report.log_path.is_none());
        assert!(report.ue4ss_log_path.is_none());
        assert!(report.evidence.is_empty());
        assert!(report.suspects.is_empty());
        assert!(!report.suggestions.is_empty());

        fs::remove_dir_all(&dir).expect("清理临时目录");
    }

    #[test]
    fn logs_older_than_since_are_ignored() {
        let dir = temp_dir();
        let local_app = dir.join("localapp");
        let log_dir = local_app.join("SCUM").join("Saved").join("Logs");
        fs::create_dir_all(&log_dir).expect("创建日志目录");
        let log_path = log_dir.join("SCUM.log");
        fs::write(&log_path, "LogInit: Display: Start\nFatal error: boom\n").expect("写入假日志");

        let settings = AppSettings {
            scum_install_path: dir.join("scum-install").to_string_lossy().into_owned(),
            ..AppSettings::default()
        };

        let fresh =
            analyze_logs_with_local_app_data(&settings, &[], None, &[], Some(local_app.as_path()));
        assert!(fresh.abnormal);
        assert_eq!(fresh.cause, "crash");

        let future = SystemTime::now() + std::time::Duration::from_secs(120);
        let stale = analyze_logs_with_local_app_data(
            &settings,
            &[],
            Some(future),
            &[],
            Some(local_app.as_path()),
        );
        assert!(!stale.abnormal);
        assert_eq!(stale.summary, "未找到本次运行的游戏日志");

        fs::remove_dir_all(&dir).expect("清理临时目录");
    }
}
