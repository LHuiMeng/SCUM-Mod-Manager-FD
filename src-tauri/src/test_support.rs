use crate::paths::AppPaths;
use std::fs;
use std::path::{Path, PathBuf};
use uuid::Uuid;

pub struct TempRoot {
    path: PathBuf,
}

impl TempRoot {
    pub fn new(label: &str) -> Self {
        let path = std::env::temp_dir().join(format!("scum-mod-desk-{}-{}", label, Uuid::new_v4()));
        fs::create_dir_all(&path).unwrap();
        Self { path }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn paths(&self) -> AppPaths {
        let paths = AppPaths::for_test(self.path.clone());
        fs::create_dir_all(&paths.root).unwrap();
        fs::create_dir_all(&paths.secrets).unwrap();
        fs::create_dir_all(&paths.local_mods).unwrap();
        fs::create_dir_all(&paths.ue4ss_mods).unwrap();
        fs::create_dir_all(&paths.logs_dir).unwrap();
        paths
    }
}

impl Drop for TempRoot {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
    }
}
