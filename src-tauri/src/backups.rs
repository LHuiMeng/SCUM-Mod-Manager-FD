//! 本地备份的枚举、恢复与删除。
//!
//! 备份分散在四处，全部位于 `AppPaths.backups_dir` 之下：
//! - `deleted/`：删除模组时整体搬走的文件或目录，文件名带 `时间戳-序号-` 前缀；
//! - `imports/`：导入覆盖前搬走的旧文件或目录，文件名带 uuid 前缀；
//! - 顶层 `*.bak`：云端下载覆盖同名 PAK 前的备份；
//! - `deploy/<批次 uuid>/`：部署时被覆盖的游戏文件与框架目录备份。

use crate::paths::{is_within, path_string, safe_disk_name, AppPaths};
use anyhow::{bail, Context, Result};
use chrono::{DateTime, SecondsFormat, Utc};
use std::fs;
use std::path::{Component, Path, PathBuf};
use std::time::SystemTime;

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BackupEntry {
    pub id: String,
    pub kind: String,
    pub name: String,
    pub path: String,
    pub size: u64,
    pub created_at: String,
    pub detail: String,
    /// 部署目录备份只能查看，前端据此禁用恢复按钮。
    pub restorable: bool,
}

const KIND_DELETED: &str = "deleted";
const KIND_IMPORT: &str = "import";
const KIND_REPLACED: &str = "replaced";
const KIND_DEPLOY: &str = "deploy";

/// 单次列表最多返回的条目数，避免备份堆积后把界面撑爆。
const MAX_BACKUPS: usize = 500;
/// deploy 备份最多扫描的层级（相对 `backups/deploy`，批次目录算第 1 层）。
const MAX_DEPLOY_DEPTH: usize = 6;
/// 扫描 deploy 时最多读取的目录条目数，防止异常目录拖死列表。
const MAX_DEPLOY_SCAN_ENTRIES: usize = 5000;
/// 目录体积统计上限：2 GiB。
const MAX_DIRECTORY_SIZE: u64 = 2 * 1024 * 1024 * 1024;
/// 目录体积统计最多遍历的条目数。
const MAX_DIRECTORY_SIZE_ENTRIES: usize = 5000;
/// 恢复目录时允许的最大嵌套层数。
const MAX_COPY_DEPTH: usize = 24;

/// 扫描阶段用的中间结构：保留修改时间用于排序，最终只返回 `BackupEntry`。
struct Found {
    modified: Option<SystemTime>,
    entry: BackupEntry,
}

/// 列出全部备份，按修改时间从新到旧排序，最多 500 条。
pub fn list_backups(paths: &AppPaths) -> Result<Vec<BackupEntry>> {
    let mut found = Vec::new();
    scan_flat_source(
        paths,
        KIND_DELETED,
        &paths.backups_dir.join("deleted"),
        strip_deleted_prefix,
        &mut found,
    );
    scan_flat_source(
        paths,
        KIND_IMPORT,
        &paths.backups_dir.join("imports"),
        strip_import_prefix,
        &mut found,
    );
    scan_replaced(paths, &mut found);
    scan_deploy(paths, &mut found);

    found.sort_by(|left, right| {
        right
            .modified
            .cmp(&left.modified)
            .then_with(|| left.entry.name.cmp(&right.entry.name))
            .then_with(|| left.entry.id.cmp(&right.entry.id))
    });
    found.truncate(MAX_BACKUPS);
    Ok(found.into_iter().map(|item| item.entry).collect())
}

/// 把一份备份复制回可用位置。备份本身保留，可以反复恢复。
///
/// `game_running` 只约束部署备份（它们属于游戏目录，运行中写回可能让游戏崩溃）。
pub fn restore_backup(paths: &AppPaths, id: &str, game_running: bool) -> Result<String> {
    let source = resolve_backup_path(paths, id)?;
    let metadata =
        fs::symlink_metadata(&source).with_context(|| format!("备份不存在：{}", id.trim()))?;
    if is_reparse_like(&metadata) {
        bail!("备份路径无效");
    }
    let Some((kind, name)) = classify_backup(paths, &source, &metadata) else {
        bail!("备份路径无效");
    };
    if kind == KIND_DEPLOY && game_running {
        bail!("游戏运行期间不能恢复部署备份，请先关闭游戏");
    }

    if metadata.is_dir() {
        // 部署备份的目录是旧框架整棵树的快照，放回游戏目录需要配合部署清单，
        // 这里只提供查看，避免用户误把半棵目录塞进 UE4SS。
        if kind == KIND_DEPLOY {
            bail!("「{name}」是部署目录备份，仅可查看，不能恢复");
        }
        let target = unique_directory_target(&paths.ue4ss_mods, &restore_name(&name));
        copy_directory(&source, &target)?;
        return Ok(format!(
            "已恢复目录备份「{name}」到 {}",
            path_string(&target)
        ));
    }

    // 部署备份属于游戏目录里的原文件（dwmapi.dll、旧框架配置等），必须按清单写回原位置，
    // 不能像普通模组一样丢进本地模组库。
    if kind == KIND_DEPLOY {
        let target = deploy_backup_target(paths, &source)?
            .with_context(|| format!("找不到部署备份「{name}」对应的游戏文件，无法恢复"))?;
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent)
                .with_context(|| format!("无法创建目录 {}", path_string(parent)))?;
        }
        fs::copy(&source, &target).with_context(|| {
            format!(
                "无法把部署备份 {} 还原到 {}",
                path_string(&source),
                path_string(&target)
            )
        })?;
        return Ok(format!(
            "已把部署备份「{name}」还原到 {}",
            path_string(&target)
        ));
    }

    let target = unique_file_target(&paths.local_mods, &restore_name(&name));
    fs::copy(&source, &target).with_context(|| {
        format!(
            "无法把备份 {} 复制到 {}",
            path_string(&source),
            path_string(&target)
        )
    })?;
    Ok(format!("已恢复备份「{name}」到 {}", path_string(&target)))
}

/// 部署备份在清单里记录的原目标；找不到或路径越界时返回错误。
fn deploy_backup_target(paths: &AppPaths, backup: &Path) -> Result<Option<PathBuf>> {
    let Some(manifest) = crate::mods::deploy::read_manifest(paths) else {
        return Ok(None);
    };
    let Some(item) = manifest
        .backups
        .iter()
        .find(|item| same_path(Path::new(&item.backup), backup))
    else {
        return Ok(None);
    };
    let target = PathBuf::from(&item.target);
    if !manifest
        .roots
        .iter()
        .any(|root| is_within(&target, Path::new(root)))
    {
        bail!("部署清单中的目标路径越界，已拒绝恢复");
    }
    Ok(Some(target))
}

fn same_path(left: &Path, right: &Path) -> bool {
    is_within(left, right) && is_within(right, left)
}

/// 删除一份备份：文件直接删，目录整棵删。
pub fn remove_backup(paths: &AppPaths, id: &str) -> Result<()> {
    let path = resolve_backup_path(paths, id)?;
    let metadata =
        fs::symlink_metadata(&path).with_context(|| format!("备份不存在：{}", id.trim()))?;
    if is_reparse_like(&metadata) {
        bail!("备份路径无效");
    }
    if metadata.is_dir() {
        fs::remove_dir_all(&path)
            .with_context(|| format!("无法删除备份目录 {}", path_string(&path)))?;
    } else {
        fs::remove_file(&path)
            .with_context(|| format!("无法删除备份文件 {}", path_string(&path)))?;
    }
    Ok(())
}

/// 校验 id 并解析成备份目录内的绝对路径。
///
/// 拒绝空串、带盘符/冒号、绝对路径、`..` 以及任何非普通路径组件；
/// 最后再用 `is_within` 兜一次，确保拼出来的路径没有跑出 `backups`。
fn resolve_backup_path(paths: &AppPaths, id: &str) -> Result<PathBuf> {
    let trimmed = id.trim();
    if trimmed.is_empty() || trimmed.contains(':') {
        bail!("备份路径无效");
    }
    if trimmed
        .split(['/', '\\'])
        .any(|segment| segment.is_empty() || segment == "..")
    {
        bail!("备份路径无效");
    }
    let candidate = Path::new(trimmed);
    if candidate.is_absolute()
        || !candidate
            .components()
            .all(|component| matches!(component, Component::Normal(_)))
    {
        bail!("备份路径无效");
    }
    let path = paths.backups_dir.join(candidate);
    if !is_within(&path, &paths.backups_dir) {
        bail!("备份路径无效");
    }
    Ok(path)
}

/// 判断路径属于哪一类备份，并给出展示名。
fn classify_backup(
    paths: &AppPaths,
    path: &Path,
    metadata: &fs::Metadata,
) -> Option<(String, String)> {
    let file_name = path.file_name()?.to_string_lossy().into_owned();
    let parent = path.parent()?;

    if same_directory(parent, &paths.backups_dir.join("deleted")) {
        return Some((KIND_DELETED.to_string(), strip_deleted_prefix(&file_name)));
    }
    if same_directory(parent, &paths.backups_dir.join("imports")) {
        return Some((KIND_IMPORT.to_string(), strip_import_prefix(&file_name)));
    }
    if same_directory(parent, &paths.backups_dir) {
        if metadata.is_file() && ends_with_bak(&file_name) {
            return Some((KIND_REPLACED.to_string(), strip_bak_suffix(&file_name)));
        }
        return None;
    }
    let display = deploy_display_name(&paths.backups_dir.join("deploy"), path)?;
    Some((KIND_DEPLOY.to_string(), display))
}

/// 展示名里只剩最后一段文件名，再按 Windows 规则净化后作为恢复目标名。
fn restore_name(display: &str) -> String {
    let last = display.rsplit(['/', '\\']).next().unwrap_or(display);
    safe_disk_name(last, "备份")
}

/// 文件恢复目标：同名已存在时改成 `主名-恢复-时间戳.扩展名`。
fn unique_file_target(directory: &Path, file_name: &str) -> PathBuf {
    let direct = directory.join(file_name);
    if !direct.exists() {
        return direct;
    }
    let path = Path::new(file_name);
    let stem = path
        .file_stem()
        .map(|value| value.to_string_lossy().into_owned())
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| "备份".to_string());
    let extension = path
        .extension()
        .map(|value| format!(".{}", value.to_string_lossy()))
        .unwrap_or_default();
    let stamp = Utc::now().format("%Y%m%d-%H%M%S");
    for attempt in 1..=100u32 {
        let suffix = if attempt == 1 {
            String::new()
        } else {
            format!("-{attempt}")
        };
        let candidate = directory.join(format!("{stem}-恢复-{stamp}{suffix}{extension}"));
        if !candidate.exists() {
            return candidate;
        }
    }
    directory.join(format!(
        "{stem}-恢复-{stamp}-{}{extension}",
        uuid::Uuid::new_v4()
    ))
}

/// 目录恢复目标：同名已存在时追加 `-恢复-时间戳`。
fn unique_directory_target(directory: &Path, name: &str) -> PathBuf {
    let direct = directory.join(name);
    if !direct.exists() {
        return direct;
    }
    let stamp = Utc::now().format("%Y%m%d-%H%M%S");
    for attempt in 1..=100u32 {
        let suffix = if attempt == 1 {
            String::new()
        } else {
            format!("-{attempt}")
        };
        let candidate = directory.join(format!("{name}-恢复-{stamp}{suffix}"));
        if !candidate.exists() {
            return candidate;
        }
    }
    directory.join(format!("{name}-恢复-{stamp}-{}", uuid::Uuid::new_v4()))
}

/// 递归复制目录；跳过符号链接/junction，限制层数，避免顺着链接写到备份目录之外。
fn copy_directory(source: &Path, destination: &Path) -> Result<()> {
    fs::create_dir_all(destination)
        .with_context(|| format!("无法创建恢复目录 {}", path_string(destination)))?;
    let mut stack = vec![(source.to_path_buf(), destination.to_path_buf(), 0usize)];
    while let Some((from, to, depth)) = stack.pop() {
        if depth > MAX_COPY_DEPTH {
            bail!("备份目录嵌套过深，已停止恢复");
        }
        let entries = fs::read_dir(&from)
            .with_context(|| format!("无法读取备份目录 {}", path_string(&from)))?;
        for item in entries {
            let item = item?;
            let path = item.path();
            let metadata = fs::symlink_metadata(&path)?;
            if is_reparse_like(&metadata) {
                continue;
            }
            let target = to.join(item.file_name());
            if metadata.is_dir() {
                fs::create_dir_all(&target)
                    .with_context(|| format!("无法创建恢复目录 {}", path_string(&target)))?;
                stack.push((path, target, depth + 1));
            } else if metadata.is_file() {
                fs::copy(&path, &target).with_context(|| {
                    format!(
                        "无法把备份 {} 复制到 {}",
                        path_string(&path),
                        path_string(&target)
                    )
                })?;
            }
        }
    }
    Ok(())
}

/// 扫描 `deleted/`、`imports/` 这类直接铺开的备份目录（条目本身可能是目录）。
fn scan_flat_source(
    paths: &AppPaths,
    kind: &str,
    directory: &Path,
    display_name: fn(&str) -> String,
    found: &mut Vec<Found>,
) {
    let Ok(entries) = fs::read_dir(directory) else {
        return;
    };
    for item in entries.flatten() {
        let path = item.path();
        let Ok(metadata) = fs::symlink_metadata(&path) else {
            continue;
        };
        if is_reparse_like(&metadata) || (!metadata.is_file() && !metadata.is_dir()) {
            continue;
        }
        let Some(file_name) = path
            .file_name()
            .map(|value| value.to_string_lossy().into_owned())
        else {
            continue;
        };
        let name = display_name(&file_name);
        if let Some(entry) = build_entry(paths, kind, name, &path, &metadata) {
            found.push(entry);
        }
    }
}

/// 扫描顶层 `*.bak`（云端下载覆盖前的 PAK 备份）。
fn scan_replaced(paths: &AppPaths, found: &mut Vec<Found>) {
    let Ok(entries) = fs::read_dir(&paths.backups_dir) else {
        return;
    };
    for item in entries.flatten() {
        let path = item.path();
        let Some(file_name) = path
            .file_name()
            .map(|value| value.to_string_lossy().into_owned())
        else {
            continue;
        };
        if !ends_with_bak(&file_name) {
            continue;
        }
        let Ok(metadata) = fs::symlink_metadata(&path) else {
            continue;
        };
        if is_reparse_like(&metadata) || !metadata.is_file() {
            continue;
        }
        let name = strip_bak_suffix(&file_name);
        if let Some(entry) = build_entry(paths, KIND_REPLACED, name, &path, &metadata) {
            found.push(entry);
        }
    }
}

/// 扫描 `deploy/`：批次目录本身不列，只列批次里的文件与目录。
fn scan_deploy(paths: &AppPaths, found: &mut Vec<Found>) {
    let deploy_root = paths.backups_dir.join("deploy");
    let Ok(batches) = fs::read_dir(&deploy_root) else {
        return;
    };
    let mut budget = MAX_DEPLOY_SCAN_ENTRIES;
    for batch in batches.flatten() {
        let path = batch.path();
        let Ok(metadata) = fs::symlink_metadata(&path) else {
            continue;
        };
        if is_reparse_like(&metadata) || !metadata.is_dir() {
            continue;
        }
        scan_deploy_directory(paths, &deploy_root, &path, 1, &mut budget, found);
    }
}

fn scan_deploy_directory(
    paths: &AppPaths,
    deploy_root: &Path,
    directory: &Path,
    depth: usize,
    budget: &mut usize,
    found: &mut Vec<Found>,
) {
    if depth > MAX_DEPLOY_DEPTH || *budget == 0 {
        return;
    }
    let Ok(entries) = fs::read_dir(directory) else {
        return;
    };
    for item in entries.flatten() {
        if *budget == 0 {
            return;
        }
        *budget -= 1;
        let path = item.path();
        let Ok(metadata) = fs::symlink_metadata(&path) else {
            continue;
        };
        if is_reparse_like(&metadata) {
            continue;
        }
        let Some(display) = deploy_display_name(deploy_root, &path) else {
            continue;
        };
        if metadata.is_dir() {
            // 以 `.bak` 结尾的目录是整棵目录快照（例如旧 UE4SS 框架），
            // 已经作为一条“目录备份”列出；再展开内部文件会用几千条记录淹没列表，
            // 其体积也已经由目录条目递归统计。
            let whole_tree = path
                .file_name()
                .map(|value| ends_with_bak(&value.to_string_lossy()))
                .unwrap_or(false);
            if let Some(entry) = build_entry(paths, KIND_DEPLOY, display, &path, &metadata) {
                found.push(entry);
            }
            if !whole_tree {
                scan_deploy_directory(paths, deploy_root, &path, depth + 1, budget, found);
            }
        } else if metadata.is_file() {
            if let Some(entry) = build_entry(paths, KIND_DEPLOY, display, &path, &metadata) {
                found.push(entry);
            }
        }
    }
}

/// 组装一条备份记录；路径不在备份根目录内或名字为空时返回 `None`。
fn build_entry(
    paths: &AppPaths,
    kind: &str,
    name: String,
    path: &Path,
    metadata: &fs::Metadata,
) -> Option<Found> {
    if name.trim().is_empty() {
        return None;
    }
    let id = backup_id(paths, path)?;
    let is_dir = metadata.is_dir();
    let modified = metadata.modified().ok();
    Some(Found {
        modified,
        entry: BackupEntry {
            id,
            kind: kind.to_string(),
            name,
            path: path_string(path),
            size: if is_dir {
                directory_size_bounded(path)
            } else {
                metadata.len()
            },
            created_at: modified.map(format_timestamp).unwrap_or_default(),
            detail: detail_for(kind, is_dir).to_string(),
            restorable: !(kind == KIND_DEPLOY && is_dir),
        },
    })
}

fn detail_for(kind: &str, is_dir: bool) -> &'static str {
    match kind {
        KIND_DELETED => "删除模组时的备份",
        KIND_IMPORT => "导入覆盖前的备份",
        KIND_REPLACED => "被同名下载覆盖的 PAK",
        _ if is_dir => "目录备份，仅可查看",
        _ => "部署覆盖前的游戏文件",
    }
}

/// id 就是相对 `backups` 的路径，统一用 `/` 分隔，前后端不必处理平台差异。
fn backup_id(paths: &AppPaths, path: &Path) -> Option<String> {
    let relative = path.strip_prefix(&paths.backups_dir).ok()?;
    let parts: Vec<String> = relative
        .components()
        .filter_map(|component| match component {
            Component::Normal(value) => Some(value.to_string_lossy().into_owned()),
            _ => None,
        })
        .collect();
    if parts.is_empty() {
        return None;
    }
    Some(parts.join("/"))
}

/// `deploy` 展示名：相对 `backups/deploy` 的路径，去掉批次 uuid 目录与 `.bak` 后缀。
///
/// 批次 uuid 是部署时的内部实现细节，留在名字里既难读，也会让恢复目标多出一层目录，
/// 因此展示名只保留批次内的相对路径。
fn deploy_display_name(deploy_root: &Path, path: &Path) -> Option<String> {
    let relative = path.strip_prefix(deploy_root).ok()?;
    let parts: Vec<String> = relative
        .components()
        .filter_map(|component| match component {
            Component::Normal(value) => Some(value.to_string_lossy().into_owned()),
            _ => None,
        })
        .collect();
    if parts.len() < 2 {
        return None;
    }
    // 只去掉最后一个路径段的 `.bak`，避免把中间目录里的字面量一起改掉。
    let mut display_parts = parts[1..].to_vec();
    if let Some(last) = display_parts.last_mut() {
        *last = strip_bak_suffix(last);
    }
    let display = display_parts.join("/");
    (!display.is_empty()).then_some(display)
}

/// 去掉删除备份的 `YYYYmmdd-HHMMSS-mmm-序号-` 前缀；格式不符就原样返回。
fn strip_deleted_prefix(file_name: &str) -> String {
    let mut rest = file_name;
    for expected in [8usize, 6, 3, 1] {
        let Some((head, tail)) = rest.split_once('-') else {
            return file_name.to_string();
        };
        // 序号可能超过一位，其余段长度固定为 8/6/3。
        let digits_ok = !head.is_empty()
            && head.chars().all(|ch| ch.is_ascii_digit())
            && (expected == 1 || head.len() == expected);
        if !digits_ok || tail.is_empty() {
            return file_name.to_string();
        }
        rest = tail;
    }
    rest.to_string()
}

/// 去掉导入备份的 uuid 前缀；不是合法 uuid 就原样返回。
fn strip_import_prefix(file_name: &str) -> String {
    if let (Some(prefix), Some(rest)) = (file_name.get(..36), file_name.get(36..)) {
        if uuid::Uuid::parse_str(prefix).is_ok() {
            if let Some(stripped) = rest.strip_prefix('-') {
                if !stripped.is_empty() {
                    return stripped.to_string();
                }
            }
        }
    }
    file_name.to_string()
}

fn ends_with_bak(value: &str) -> bool {
    value
        .get(value.len().saturating_sub(4)..)
        .is_some_and(|tail| tail.eq_ignore_ascii_case(".bak"))
}

fn strip_bak_suffix(value: &str) -> String {
    if ends_with_bak(value) {
        value[..value.len() - 4].to_string()
    } else {
        value.to_string()
    }
}

/// 体积统计：递归求文件大小之和，条目数与总量都有上限，遇到链接直接跳过。
fn directory_size_bounded(path: &Path) -> u64 {
    let mut total = 0u64;
    let mut visited = 0usize;
    let mut stack = vec![(path.to_path_buf(), 0usize)];
    while let Some((directory, depth)) = stack.pop() {
        if depth > MAX_COPY_DEPTH {
            continue;
        }
        let Ok(entries) = fs::read_dir(&directory) else {
            continue;
        };
        for item in entries.flatten() {
            visited += 1;
            if visited > MAX_DIRECTORY_SIZE_ENTRIES {
                return total.min(MAX_DIRECTORY_SIZE);
            }
            let Ok(metadata) = fs::symlink_metadata(item.path()) else {
                continue;
            };
            if is_reparse_like(&metadata) {
                continue;
            }
            if metadata.is_dir() {
                stack.push((item.path(), depth + 1));
            } else if metadata.is_file() {
                total = total.saturating_add(metadata.len());
                if total >= MAX_DIRECTORY_SIZE {
                    return MAX_DIRECTORY_SIZE;
                }
            }
        }
    }
    total.min(MAX_DIRECTORY_SIZE)
}

fn format_timestamp(time: SystemTime) -> String {
    // ISO8601（UTC，秒级）。取不到 mtime 时由调用方回退空串。
    DateTime::<Utc>::from(time).to_rfc3339_opts(SecondsFormat::Secs, true)
}

/// 符号链接、目录 junction 及其它 Windows 重解析点：既不能顺着遍历，也不能恢复/删除。
fn is_reparse_like(metadata: &fs::Metadata) -> bool {
    if metadata.file_type().is_symlink() {
        return true;
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x400;
        if metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
            return true;
        }
    }
    false
}

/// 两个目录是否指向同一位置（Windows 大小写与分隔符不敏感）。
fn same_directory(left: &Path, right: &Path) -> bool {
    is_within(left, right) && is_within(right, left)
}

#[cfg(test)]
mod tests {
    use super::{list_backups, path_string, remove_backup, restore_backup, BackupEntry};
    use crate::test_support::TempRoot;
    use std::fs;
    use std::path::Path;

    fn write_file(path: &Path, contents: &[u8]) {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).unwrap();
        }
        fs::write(path, contents).unwrap();
    }

    fn find<'a>(entries: &'a [BackupEntry], suffix: &str) -> &'a BackupEntry {
        entries
            .iter()
            .find(|entry| entry.id.ends_with(suffix))
            .unwrap_or_else(|| panic!("列表里没有 {suffix}：{entries:#?}"))
    }

    #[test]
    fn empty_backup_root_lists_nothing() {
        let temp = TempRoot::new("backups-empty");
        let paths = temp.paths();
        assert!(list_backups(&paths).unwrap().is_empty());
    }

    #[test]
    fn lists_deleted_imports_replaced_and_deploy_backups() {
        let temp = TempRoot::new("backups-list");
        let paths = temp.paths();
        write_file(
            &paths
                .backups_dir
                .join("deleted/20260102-030405-678-0-旧武器包.pak"),
            b"old-weapon",
        );
        let deleted_dir = paths
            .backups_dir
            .join("deleted/20260102-030406-100-1-旧界面模组");
        write_file(&deleted_dir.join("Scripts/main.lua"), b"lua");
        write_file(&deleted_dir.join("README.txt"), b"readme!");
        write_file(
            &paths
                .backups_dir
                .join("imports/550e8400-e29b-41d4-a716-446655440000-导入模组.pak"),
            b"import",
        );
        write_file(&paths.backups_dir.join("Demo.pak.bak"), b"replaced");
        let batch = paths
            .backups_dir
            .join("deploy/7f3d1c2e-0000-4000-8000-000000000000");
        write_file(&batch.join("0000-DeployMod.pak"), b"deploy");
        write_file(&batch.join("ue4ss-20260101000000.bak/mod.lua"), b"lua");

        let entries = list_backups(&paths).unwrap();
        assert_eq!(entries.len(), 6, "{entries:#?}");

        let weapon = find(&entries, "deleted/20260102-030405-678-0-旧武器包.pak");
        assert_eq!(weapon.kind, "deleted");
        assert_eq!(weapon.name, "旧武器包.pak");
        assert_eq!(weapon.detail, "删除模组时的备份");
        assert_eq!(weapon.size, 10);
        assert!(!weapon.created_at.is_empty(), "created_at 应为 ISO8601");
        assert!(weapon.created_at.contains('T'));
        assert!(weapon.path.ends_with("旧武器包.pak"));

        let ui = find(&entries, "deleted/20260102-030406-100-1-旧界面模组");
        assert_eq!(ui.kind, "deleted");
        assert_eq!(ui.name, "旧界面模组");
        assert_eq!(ui.size, 3 + 7, "目录体积应递归求和");

        let imported = find(&entries, "-导入模组.pak");
        assert_eq!(imported.kind, "import");
        assert_eq!(imported.name, "导入模组.pak");
        assert_eq!(imported.detail, "导入覆盖前的备份");

        let replaced = find(&entries, "Demo.pak.bak");
        assert_eq!(replaced.kind, "replaced");
        assert_eq!(replaced.name, "Demo.pak");
        assert_eq!(replaced.detail, "被同名下载覆盖的 PAK");

        let deployed = find(&entries, "0000-DeployMod.pak");
        assert_eq!(deployed.kind, "deploy");
        assert_eq!(deployed.name, "0000-DeployMod.pak");
        assert_eq!(deployed.detail, "部署覆盖前的游戏文件");
        assert!(deployed.restorable);

        let deploy_dir = find(&entries, "ue4ss-20260101000000.bak");
        assert_eq!(deploy_dir.kind, "deploy");
        assert_eq!(deploy_dir.name, "ue4ss-20260101000000");
        assert_eq!(deploy_dir.detail, "目录备份，仅可查看");
        assert_eq!(deploy_dir.size, 3);
        assert!(!deploy_dir.restorable);

        // 修改时间降序：ISO8601 字符串可直接按字典序比较。
        assert!(
            entries
                .windows(2)
                .all(|pair| pair[0].created_at >= pair[1].created_at),
            "列表应按修改时间降序：{entries:#?}"
        );
    }

    #[test]
    fn restores_a_deleted_pak_and_keeps_the_backup() {
        let temp = TempRoot::new("backups-restore-file");
        let paths = temp.paths();
        let original = paths
            .backups_dir
            .join("deleted/20260102-030405-678-0-旧武器包.pak");
        write_file(&original, b"pak-bytes");

        let entries = list_backups(&paths).unwrap();
        let entry = &entries[0];
        let message = restore_backup(&paths, &entry.id, false).unwrap();
        let restored = paths.local_mods.join("旧武器包.pak");
        assert!(message.contains(&path_string(&restored)), "{message}");
        assert_eq!(fs::read(&restored).unwrap(), b"pak-bytes");
        assert!(original.is_file(), "恢复后必须保留备份本身");

        // 再恢复一次：目标已存在，应改名为带恢复时间戳的文件。
        restore_backup(&paths, &entry.id, false).unwrap();
        let renamed = fs::read_dir(&paths.local_mods)
            .unwrap()
            .flatten()
            .map(|item| item.file_name().to_string_lossy().into_owned())
            .find(|name| name.starts_with("旧武器包-恢复-"))
            .expect("冲突时应生成改名文件");
        assert!(renamed.ends_with(".pak"), "{renamed}");
        assert_eq!(
            fs::read(paths.local_mods.join(&renamed)).unwrap(),
            b"pak-bytes"
        );
    }

    #[test]
    fn restores_deleted_directory_into_ue4ss_mods() {
        let temp = TempRoot::new("backups-restore-dir");
        let paths = temp.paths();
        let original = paths
            .backups_dir
            .join("deleted/20260102-030406-100-1-旧界面模组");
        write_file(&original.join("Scripts/main.lua"), b"lua");

        let entries = list_backups(&paths).unwrap();
        let message = restore_backup(&paths, &entries[0].id, false).unwrap();
        let restored = paths.ue4ss_mods.join("旧界面模组");
        assert!(message.contains(&path_string(&restored)), "{message}");
        assert_eq!(fs::read(restored.join("Scripts/main.lua")).unwrap(), b"lua");
        assert!(original.is_dir(), "目录备份同样要保留");

        // 同名目录已存在时要加恢复时间戳。
        restore_backup(&paths, &entries[0].id, false).unwrap();
        assert!(
            fs::read_dir(&paths.ue4ss_mods)
                .unwrap()
                .flatten()
                .any(|item| item
                    .file_name()
                    .to_string_lossy()
                    .starts_with("旧界面模组-恢复-")),
            "目录冲突时应改名恢复"
        );
    }

    #[test]
    fn deploy_files_restore_to_game_path_but_directories_are_view_only() {
        let temp = TempRoot::new("backups-deploy");
        let paths = temp.paths();
        let batch = paths
            .backups_dir
            .join("deploy/7f3d1c2e-0000-4000-8000-000000000000");
        let backup_file = batch.join("0000-DeployMod.pak");
        write_file(&backup_file, b"deploy");
        write_file(&batch.join("ue4ss-20260101000000.bak/mod.lua"), b"lua");

        let game_root = paths.root.join("game");
        let target = game_root.join("dwmapi.dll");
        std::fs::create_dir_all(&game_root).unwrap();
        std::fs::write(&target, b"current").unwrap();
        let manifest = crate::mods::deploy::DeployedManifest {
            deployed_at: "2026-01-01T00:00:00Z".to_string(),
            roots: vec![path_string(&game_root)],
            backups: vec![crate::mods::deploy::DeployedBackup {
                target: path_string(&target),
                backup: path_string(&backup_file),
            }],
            ..Default::default()
        };
        std::fs::write(
            &paths.deployment_manifest,
            serde_json::to_vec(&manifest).unwrap(),
        )
        .unwrap();

        let entries = list_backups(&paths).unwrap();
        let file_entry = find(&entries, "0000-DeployMod.pak");
        let running_error = restore_backup(&paths, &file_entry.id, true)
            .unwrap_err()
            .to_string();
        assert!(running_error.contains("运行期间"), "{running_error}");

        let message = restore_backup(&paths, &file_entry.id, false).unwrap();
        assert!(message.contains(&path_string(&target)), "{message}");
        assert_eq!(fs::read(&target).unwrap(), b"deploy");
        assert!(
            !paths.local_mods.join("0000-DeployMod.pak").exists(),
            "部署备份不能恢复进本地模组库"
        );

        let dir_entry = find(&entries, "ue4ss-20260101000000.bak");
        let error = restore_backup(&paths, &dir_entry.id, false)
            .unwrap_err()
            .to_string();
        assert!(error.contains("仅可查看"), "{error}");
        assert!(
            fs::read_dir(&paths.ue4ss_mods).unwrap().next().is_none(),
            "目录备份不能被恢复到 UE4SS"
        );
    }

    #[test]
    fn removes_backups_from_disk_and_listing() {
        let temp = TempRoot::new("backups-remove");
        let paths = temp.paths();
        let replaced = paths.backups_dir.join("Demo.pak.bak");
        write_file(&replaced, b"replaced");
        let deleted_dir = paths
            .backups_dir
            .join("deleted/20260102-030406-100-1-旧界面模组");
        write_file(&deleted_dir.join("main.lua"), b"lua");

        let entries = list_backups(&paths).unwrap();
        let replaced_id = find(&entries, "Demo.pak.bak").id.clone();
        remove_backup(&paths, &replaced_id).unwrap();
        assert!(!replaced.exists());
        let ids: Vec<_> = list_backups(&paths)
            .unwrap()
            .into_iter()
            .map(|entry| entry.id)
            .collect();
        assert!(!ids.contains(&replaced_id), "{ids:?}");

        let dir_id = find(&entries, "旧界面模组").id.clone();
        remove_backup(&paths, &dir_id).unwrap();
        assert!(!deleted_dir.exists(), "目录备份应整棵删除");
        assert!(list_backups(&paths).unwrap().is_empty());

        let error = remove_backup(&paths, &dir_id).unwrap_err().to_string();
        assert!(error.contains("备份不存在"), "{error}");
    }

    #[test]
    fn rejects_ids_outside_the_backup_root() {
        let temp = TempRoot::new("backups-invalid-id");
        let paths = temp.paths();
        write_file(&paths.backups_dir.join("Demo.pak.bak"), b"x");

        for id in [
            "",
            "   ",
            "../escape.pak",
            "deleted/../../config.json",
            "/etc/passwd",
            r"C:\Windows\win.ini",
            "deleted//Demo.pak.bak",
        ] {
            let restore_error = restore_backup(&paths, id, false).unwrap_err().to_string();
            assert!(
                restore_error.contains("备份路径无效"),
                "id={id:?} 应被拒绝，实际：{restore_error}"
            );
            let remove_error = remove_backup(&paths, id).unwrap_err().to_string();
            assert!(
                remove_error.contains("备份路径无效"),
                "id={id:?} 应被拒绝，实际：{remove_error}"
            );
        }
        assert!(paths.backups_dir.join("Demo.pak.bak").is_file());
    }
}
