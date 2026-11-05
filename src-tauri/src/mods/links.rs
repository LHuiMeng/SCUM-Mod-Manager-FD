//! NTFS 目录 junction 封装。
//!
//! 用途：把游戏 `Content\Paks\~mods` 变成指向启动器部署目录的链接，让游戏直接读到
//! 启动器里的 PAK——部署时不再复制几百 MB，退出时也不用删除。
//!
//! junction（重解析点 IO_REPARSE_TAG_MOUNT_POINT）与符号链接的区别：
//! 创建不需要 SeCreateSymbolicLinkPrivilege，普通用户即可，但只能指向本地 NTFS 目录。

use std::io;
use std::path::{Path, PathBuf};

/// 硬链接/链接模式的部署结果，用来记录“这次到底是链接还是复制”。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FileLinkKind {
    /// 同卷硬链接：0 字节写入。
    HardLink,
    /// 跨卷等情况退回复制。
    Copied,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EnsureOutcome {
    Created,
    Unchanged,
    Replaced,
}

/// 路径是不是目录 junction（或指向目录的符号链接）。
pub fn is_junction(path: &Path) -> bool {
    match std::fs::symlink_metadata(path) {
        Ok(metadata) => metadata.file_type().is_symlink() && path.is_dir(),
        Err(_) => false,
    }
}

/// 读 junction 指向的目标；不是 junction 时返回 None。
pub fn junction_target(path: &Path) -> Option<PathBuf> {
    if !is_junction(path) {
        return None;
    }
    std::fs::read_link(path)
        .ok()
        .map(|target| strip_verbatim_prefix(&target))
}

fn strip_verbatim_prefix(path: &Path) -> PathBuf {
    let text = path.to_string_lossy();
    match text.strip_prefix(r"\\?\") {
        Some(rest) => PathBuf::from(rest),
        None => PathBuf::from(text.as_ref()),
    }
}

fn same_path(left: &Path, right: &Path) -> bool {
    let normalize = |path: &Path| {
        std::path::absolute(path)
            .unwrap_or_else(|_| path.to_path_buf())
            .to_string_lossy()
            .trim_end_matches(['\\', '/'])
            .to_ascii_lowercase()
    };
    normalize(left) == normalize(right)
}

/// 保证 `link` 是一个指向 `target` 的 junction。
///
/// - 不存在 → 创建（Created）
/// - 已是指向 target 的 junction → 不动（Unchanged）
/// - 是 junction 但指向别处 → 删掉重建（Replaced）
/// - 是真实目录 → 返回错误，交由调用方决定迁移策略（绝不静默删除用户目录）
pub fn ensure_junction(link: &Path, target: &Path) -> io::Result<EnsureOutcome> {
    std::fs::create_dir_all(target)?;
    if is_junction(link) {
        if junction_target(link).is_some_and(|current| same_path(&current, target)) {
            return Ok(EnsureOutcome::Unchanged);
        }
        remove_junction(link)?;
        create_junction(link, target)?;
        return Ok(EnsureOutcome::Replaced);
    }
    if link.exists() {
        return Err(io::Error::new(
            io::ErrorKind::AlreadyExists,
            format!(
                "{} 已存在且是真实目录，无法替换为链接",
                link.display()
            ),
        ));
    }
    create_junction(link, target)?;
    Ok(EnsureOutcome::Created)
}

/// 删除 junction 本身（保留目标目录内容）；对真实目录不做任何事。
pub fn remove_junction(path: &Path) -> io::Result<()> {
    if !is_junction(path) {
        return Ok(());
    }
    std::fs::remove_dir(path)
}

/// 同卷用硬链接（0 拷贝、无需权限），跨卷自动退回复制。
pub fn link_or_copy(source: &Path, target: &Path) -> io::Result<FileLinkKind> {
    if let Some(parent) = target.parent() {
        std::fs::create_dir_all(parent)?;
    }
    if target.exists() {
        let _ = std::fs::remove_file(target);
    }
    match std::fs::hard_link(source, target) {
        Ok(()) => Ok(FileLinkKind::HardLink),
        Err(_) => {
            std::fs::copy(source, target)?;
            Ok(FileLinkKind::Copied)
        }
    }
}

#[cfg(windows)]
pub fn create_junction(link: &Path, target: &Path) -> io::Result<()> {
    imp::create_junction(link, target)
}

#[cfg(not(windows))]
pub fn create_junction(_link: &Path, _target: &Path) -> io::Result<()> {
    Err(io::Error::new(
        io::ErrorKind::Unsupported,
        "目录 junction 只在 Windows 上可用",
    ))
}

#[cfg(windows)]
mod imp {
    use super::*;
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Foundation::{CloseHandle, GENERIC_WRITE, INVALID_HANDLE_VALUE};
    use windows_sys::Win32::Storage::FileSystem::{
        CreateFileW, FILE_FLAG_BACKUP_SEMANTICS, FILE_FLAG_OPEN_REPARSE_POINT, FILE_SHARE_READ,
        FILE_SHARE_WRITE, OPEN_EXISTING,
    };
    use windows_sys::Win32::System::IO::DeviceIoControl;

    const IO_REPARSE_TAG_MOUNT_POINT: u32 = 0xA000_0003;
    const FSCTL_SET_REPARSE_POINT: u32 = 0x0009_00A4;

    fn wide(path: &Path) -> Vec<u16> {
        path.as_os_str()
            .encode_wide()
            .chain(std::iter::once(0))
            .collect()
    }

    pub(super) fn create_junction(link: &Path, target: &Path) -> io::Result<()> {
        let target = std::path::absolute(target)?;
        let target_text = target.to_string_lossy();
        let target_text = target_text.trim_start_matches(r"\\?\");
        let target_wide: Vec<u16> = target_text.encode_utf16().collect();
        let nt_prefix = [b'\\' as u16, b'?' as u16, b'?' as u16, b'\\' as u16];

        let substitute_bytes = ((nt_prefix.len() + target_wide.len()) * 2) as u16;
        let print_bytes = (target_wide.len() * 2) as u16;
        // 头部 8 + 四个偏移/长度字段 8 + 两个名字各带一个 NUL
        let data_length = 8 + substitute_bytes + 2 + print_bytes + 2;
        let mut buffer = vec![0u8; 8 + data_length as usize];

        buffer[0..4].copy_from_slice(&IO_REPARSE_TAG_MOUNT_POINT.to_ne_bytes());
        buffer[4..6].copy_from_slice(&data_length.to_ne_bytes());
        // Reserved = 0
        buffer[8..10].copy_from_slice(&0u16.to_ne_bytes());
        buffer[10..12].copy_from_slice(&substitute_bytes.to_ne_bytes());
        buffer[12..14].copy_from_slice(&(substitute_bytes + 2).to_ne_bytes());
        buffer[14..16].copy_from_slice(&print_bytes.to_ne_bytes());

        let mut cursor = 16;
        for unit in nt_prefix.iter().chain(target_wide.iter()) {
            buffer[cursor..cursor + 2].copy_from_slice(&unit.to_ne_bytes());
            cursor += 2;
        }
        cursor += 2; // SubstituteName 的 NUL
        for unit in target_wide.iter() {
            buffer[cursor..cursor + 2].copy_from_slice(&unit.to_ne_bytes());
            cursor += 2;
        }
        // PrintName 的 NUL 由 vec 初始化时的 0 承担

        std::fs::create_dir_all(link)?;
        // junction 要求空目录；create_dir_all 对已存在目录不会报错，但这里由调用方保证
        let handle = unsafe {
            CreateFileW(
                wide(link).as_ptr(),
                GENERIC_WRITE,
                FILE_SHARE_READ | FILE_SHARE_WRITE,
                std::ptr::null(),
                OPEN_EXISTING,
                FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
                std::ptr::null_mut(),
            )
        };
        if handle == INVALID_HANDLE_VALUE {
            let error = io::Error::last_os_error();
            let _ = std::fs::remove_dir(link);
            return Err(error);
        }
        let mut returned = 0u32;
        let ok = unsafe {
            DeviceIoControl(
                handle,
                FSCTL_SET_REPARSE_POINT,
                buffer.as_ptr() as *const core::ffi::c_void,
                buffer.len() as u32,
                std::ptr::null_mut(),
                0,
                &mut returned,
                std::ptr::null_mut(),
            )
        };
        let error = io::Error::last_os_error();
        unsafe { CloseHandle(handle) };
        if ok == 0 {
            let _ = std::fs::remove_dir(link);
            return Err(error);
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    struct TempRoot(PathBuf);

    impl TempRoot {
        fn new(label: &str) -> Self {
            let path = std::env::temp_dir().join(format!(
                "scum-mod-links-{label}-{}",
                uuid::Uuid::new_v4()
            ));
            std::fs::create_dir_all(&path).unwrap();
            Self(path)
        }

        fn path(&self) -> &Path {
            &self.0
        }
    }

    impl Drop for TempRoot {
        fn drop(&mut self) {
            let link = self.0.join("link");
            let _ = remove_junction(&link);
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn creates_reads_and_removes_a_junction() {
        let temp = TempRoot::new("create");
        let target = temp.path().join("deployed");
        std::fs::create_dir_all(&target).unwrap();
        let mut file = std::fs::File::create(target.join("mod.pak")).unwrap();
        file.write_all(b"pak").unwrap();
        let link = temp.path().join("link");

        create_junction(&link, &target).unwrap();

        assert!(is_junction(&link), "junction 未被识别");
        assert!(link.join("mod.pak").is_file(), "透过 junction 读不到文件");
        let read_back = junction_target(&link).expect("读不到 junction 目标");
        assert!(same_path(&read_back, &target), "目标不符：{read_back:?}");

        remove_junction(&link).unwrap();
        assert!(!link.exists());
        assert!(target.join("mod.pak").is_file(), "删链接不应影响目标");
    }

    #[test]
    fn ensure_junction_is_idempotent_and_repoints() {
        let temp = TempRoot::new("ensure");
        let first = temp.path().join("first");
        let second = temp.path().join("second");
        std::fs::create_dir_all(&first).unwrap();
        std::fs::create_dir_all(&second).unwrap();
        let link = temp.path().join("link");

        assert_eq!(ensure_junction(&link, &first).unwrap(), EnsureOutcome::Created);
        assert_eq!(ensure_junction(&link, &first).unwrap(), EnsureOutcome::Unchanged);
        assert_eq!(ensure_junction(&link, &second).unwrap(), EnsureOutcome::Replaced);
        assert!(same_path(&junction_target(&link).unwrap(), &second));
    }

    #[test]
    fn refuses_to_replace_a_real_directory() {
        let temp = TempRoot::new("real");
        let target = temp.path().join("deployed");
        std::fs::create_dir_all(&target).unwrap();
        let real = temp.path().join("real-dir");
        std::fs::create_dir_all(real.join("keep")).unwrap();

        let error = ensure_junction(&real, &target).unwrap_err();

        assert_eq!(error.kind(), io::ErrorKind::AlreadyExists);
        assert!(real.join("keep").is_dir(), "真实目录必须原样保留");
    }

    #[test]
    fn hard_links_on_the_same_volume() {
        let temp = TempRoot::new("hardlink");
        let source = temp.path().join("source.pak");
        std::fs::write(&source, b"payload").unwrap();
        let deployed = temp.path().join("deployed").join("001_source.pak");

        let kind = link_or_copy(&source, &deployed).unwrap();

        assert_eq!(kind, FileLinkKind::HardLink);
        assert_eq!(std::fs::read(&deployed).unwrap(), b"payload");
        // 硬链接共享内容：改源文件，部署文件跟着变
        std::fs::write(&source, b"payload-v2").unwrap();
        assert_eq!(std::fs::read(&deployed).unwrap(), b"payload-v2");
    }
}
