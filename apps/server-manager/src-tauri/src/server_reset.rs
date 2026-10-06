//! A reset is a transaction, not deletion followed by signup. Uncommitted data
//! is restored after a failure/crash; committed old data is removed, not retained
//! as a user-visible backup. Only manager-owned workspace directories qualify.
use crate::{manager::ServerSettings, platform};
use serde::{Deserialize, Serialize};
use std::{fs, path::{Component, Path, PathBuf}};

const OWNER_FILE: &str = ".codmes-manager-workspace";
const OWNER_VALUE: &str = "codmes-server-manager-owned-workspace-v1\n";
const JOURNAL_FILE: &str = "server-manager-reset.json";

pub fn validate_workspace(root: &Path, default_root: &Path) -> Result<(), String> {
    reject_links(root)?;
    reject_links(&root.join(OWNER_FILE))?;
    if !root.is_dir() { return Err("서버 데이터 폴더를 찾을 수 없습니다.".into()); }
    if root != default_root && fs::read_to_string(root.join(OWNER_FILE)).ok().as_deref() != Some(OWNER_VALUE) {
        return Err("이 데이터 폴더는 Server Manager 전용 폴더로 확인되지 않아 초기화할 수 없습니다. 기존 계정으로 로그인해 저장소 설정을 확인하세요.".into());
    }
    Ok(())
}

pub fn mark_workspace(root: &Path, default_root: &Path) -> Result<(), String> {
    reject_links(root)?;
    let marker = root.join(OWNER_FILE);
    reject_links(&marker)?;
    if marker.exists() { return Ok(()); }
    // Do not adopt an existing external directory: it may contain unrelated files.
    if root == default_root || fs::read_dir(root).map_err(|e| e.to_string())?.next().is_none() {
        fs::write(&marker, OWNER_VALUE).map_err(|e| e.to_string())?;
        platform::restrict_settings_file(&marker)?;
    }
    Ok(())
}

fn reject_links(root: &Path) -> Result<(), String> {
    if !root.is_absolute() || root.parent().is_none() {
        return Err("안전한 절대 경로의 전용 데이터 폴더가 필요합니다.".into());
    }
    let mut current = PathBuf::new();
    for component in root.components() {
        if matches!(component, Component::ParentDir | Component::CurDir) {
            return Err("상위 경로나 상대 경로는 초기화할 수 없습니다.".into());
        }
        current.push(component);
        if fs::symlink_metadata(&current).is_ok_and(|m| m.file_type().is_symlink()) {
            return Err("심볼릭 링크를 포함한 데이터 저장소는 초기화할 수 없습니다.".into());
        }
    }
    Ok(())
}

#[derive(Clone, Serialize, Deserialize)]
struct Journal {
    previous_settings: ServerSettings,
    quarantine: PathBuf,
    committed: bool,
}

pub struct ResetTransaction {
    journal_path: PathBuf,
    journal: Journal,
}

impl ResetTransaction {
    pub fn begin(settings_path: &Path, settings: &ServerSettings, default_root: &Path) -> Result<Self, String> {
        let root = Path::new(&settings.workspace_root);
        validate_workspace(root, default_root)?;
        let journal_path = settings_path.with_file_name(JOURNAL_FILE);
        if journal_path.exists() { return Err("중단된 서버 초기화 정리가 필요합니다. 앱을 다시 실행하세요.".into()); }
        let quarantine = root.with_file_name(format!(".codmes-reset-{:016x}", rand::random::<u64>()));
        if quarantine.exists() { return Err("초기화 임시 경로가 이미 존재합니다.".into()); }
        let transaction = Self { journal_path, journal: Journal {
            previous_settings: settings.clone(), quarantine, committed: false,
        }};
        transaction.save()?;
        if let Err(error) = fs::rename(root, &transaction.journal.quarantine) {
            let _ = fs::remove_file(&transaction.journal_path);
            return Err(format!("기존 데이터를 분리하지 못했습니다: {error}"));
        }
        let prepared = fs::create_dir(root).map_err(|e| e.to_string())
            .and_then(|_| mark_workspace(root, default_root));
        if let Err(error) = prepared {
            transaction.rollback()?;
            return Err(error);
        }
        Ok(transaction)
    }

    pub fn pending(settings_path: &Path, default_root: &Path) -> Result<Option<Self>, String> {
        let journal_path = settings_path.with_file_name(JOURNAL_FILE);
        if !journal_path.exists() { return Ok(None); }
        reject_links(&journal_path)?;
        let bytes = fs::read(&journal_path).map_err(|e| e.to_string())?;
        if bytes.len() > 16_384 { return Err("초기화 기록의 크기가 올바르지 않습니다.".into()); }
        let journal: Journal = serde_json::from_slice(&bytes).map_err(|_| "초기화 기록을 읽을 수 없습니다.")?;
        let root = Path::new(&journal.previous_settings.workspace_root);
        reject_links(root)?;
        reject_links(&journal.quarantine)?;
        let leaf = journal.quarantine.file_name().and_then(|v| v.to_str()).unwrap_or("");
        let suffix = leaf.strip_prefix(".codmes-reset-").unwrap_or("");
        if root.parent() != journal.quarantine.parent() || suffix.len() != 16
            || !suffix.chars().all(|c| c.is_ascii_hexdigit()) {
            return Err("안전하지 않은 초기화 기록입니다. 데이터를 변경하지 않았습니다.".into());
        }
        if root != default_root {
            let ownership_root = if journal.quarantine.exists() { &journal.quarantine } else { root };
            reject_links(&ownership_root.join(OWNER_FILE))?;
            if fs::read_to_string(ownership_root.join(OWNER_FILE)).ok().as_deref() != Some(OWNER_VALUE) {
                return Err("초기화 대상의 소유권을 확인할 수 없습니다.".into());
            }
        }
        Ok(Some(Self { journal_path, journal }))
    }

    pub fn roots(&self) -> [&Path; 2] {
        [Path::new(&self.journal.previous_settings.workspace_root), &self.journal.quarantine]
    }
    pub fn previous_settings(&self) -> &ServerSettings { &self.journal.previous_settings }
    pub fn committed(&self) -> bool { self.journal.committed }

    pub fn commit(&mut self) -> Result<Option<String>, String> {
        self.journal.committed = true;
        if let Err(error) = self.save() { self.journal.committed = false; return Err(error); }
        Ok(self.cleanup().err())
    }

    pub fn cleanup(&self) -> Result<(), String> {
        if !self.committed() { return Err("완료되지 않은 초기화의 원본 데이터는 삭제할 수 없습니다.".into()); }
        if self.journal.quarantine.exists() {
            reject_links(&self.journal.quarantine)?;
            fs::remove_dir_all(&self.journal.quarantine).map_err(|e| format!("기존 서버 데이터 정리가 아직 완료되지 않았습니다: {e}"))?;
        }
        fs::remove_file(&self.journal_path).map_err(|e| e.to_string())
    }

    pub fn rollback(&self) -> Result<(), String> {
        if self.committed() { return Err("완료된 서버 초기화는 되돌릴 수 없습니다.".into()); }
        if self.journal.quarantine.exists() {
            let root = Path::new(&self.journal.previous_settings.workspace_root);
            reject_links(root)?;
            if root.exists() { fs::remove_dir_all(root).map_err(|e| e.to_string())?; }
            fs::rename(&self.journal.quarantine, root).map_err(|e| format!("기존 데이터 복원 실패: {e}"))?;
        }
        fs::remove_file(&self.journal_path).map_err(|e| e.to_string())
    }

    fn save(&self) -> Result<(), String> {
        reject_links(&self.journal_path)?;
        let temporary = self.journal_path.with_extension("json.next");
        reject_links(&temporary)?;
        let bytes = serde_json::to_vec_pretty(&self.journal).map_err(|e| e.to_string())?;
        fs::write(&temporary, bytes).map_err(|e| e.to_string())?;
        platform::restrict_settings_file(&temporary)?;
        fs::File::open(&temporary).and_then(|f| f.sync_all()).map_err(|e| e.to_string())?;
        fs::rename(temporary, &self.journal_path).map_err(|e| e.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    struct Fixture { base: PathBuf, root: PathBuf, settings: PathBuf, values: ServerSettings }
    impl Fixture {
        fn new() -> Self {
            let base = fs::canonicalize(std::env::temp_dir()).unwrap().join(format!("codmes-reset-test-{:016x}", rand::random::<u64>()));
            let root = base.join("workspace");
            fs::create_dir_all(&root).unwrap();
            fs::write(root.join("old-account"), b"old private data").unwrap();
            let mut values = ServerSettings::default();
            values.workspace_root = root.to_string_lossy().into_owned();
            Self { settings: base.join("server-manager.json"), base, root, values }
        }
        fn begin(&self) -> ResetTransaction { ResetTransaction::begin(&self.settings, &self.values, &self.root).unwrap() }
    }
    impl Drop for Fixture { fn drop(&mut self) { let _ = fs::remove_dir_all(&self.base); } }
    #[test] fn failed_signup_restores_original_data() {
        let f = Fixture::new(); let transaction = f.begin();
        fs::write(f.root.join("new-account"), b"partial").unwrap();
        transaction.rollback().unwrap();
        assert!(f.root.join("old-account").is_file());
        assert!(!f.root.join("new-account").exists());
        assert!(ResetTransaction::pending(&f.settings, &f.root).unwrap().is_none());
    }
    #[test] fn successful_signup_removes_old_data_and_journal() {
        let f = Fixture::new(); let mut transaction = f.begin();
        fs::write(f.root.join("new-account"), b"new").unwrap();
        assert!(transaction.commit().unwrap().is_none());
        assert!(!f.root.join("old-account").exists());
        assert!(f.root.join("new-account").is_file());
        assert!(!transaction.roots()[1].exists());
        assert!(transaction.rollback().is_err());
    }
    #[test] fn interrupted_reset_is_recoverable_before_commit() {
        let f = Fixture::new(); drop(f.begin());
        let pending = ResetTransaction::pending(&f.settings, &f.root).unwrap().unwrap();
        assert!(!pending.committed()); pending.rollback().unwrap();
        assert!(f.root.join("old-account").exists());
    }
    #[test] fn uncommitted_original_cannot_be_cleaned_up() {
        let f = Fixture::new(); let transaction = f.begin();
        assert!(transaction.cleanup().is_err());
        assert!(transaction.roots()[1].join("old-account").is_file());
        transaction.rollback().unwrap();
    }
    #[test] fn interrupted_committed_cleanup_keeps_new_server_only() {
        let f = Fixture::new(); let mut transaction = f.begin();
        fs::write(f.root.join("new-account"), b"new").unwrap();
        transaction.journal.committed = true; transaction.save().unwrap();
        let pending = ResetTransaction::pending(&f.settings, &f.root).unwrap().unwrap();
        assert!(pending.committed()); pending.cleanup().unwrap();
        assert!(f.root.join("new-account").is_file());
        assert!(!pending.roots()[1].exists());
    }
    #[test] fn external_unowned_directories_and_broad_roots_are_rejected() {
        let f = Fixture::new();
        assert!(validate_workspace(&f.base, &f.root).is_err());
        assert!(validate_workspace(Path::new("/"), &f.root).is_err());
        assert!(validate_workspace(&f.root.join("../workspace"), &f.root).is_err());
    }
    #[test] fn new_empty_custom_workspace_can_be_owned_but_existing_files_are_not_adopted() {
        let f = Fixture::new(); let custom = f.base.join("custom"); fs::create_dir(&custom).unwrap();
        mark_workspace(&custom, &f.root).unwrap(); assert!(validate_workspace(&custom, &f.root).is_ok());
        mark_workspace(&f.base, &f.root).unwrap(); assert!(!f.base.join(OWNER_FILE).exists());
    }
    #[test] fn forged_recovery_cannot_delete_other_paths() {
        let f = Fixture::new(); let transaction = f.begin();
        let mut journal = transaction.journal.clone(); journal.quarantine = f.base.clone();
        fs::write(f.base.join(JOURNAL_FILE), serde_json::to_vec(&journal).unwrap()).unwrap();
        assert!(ResetTransaction::pending(&f.settings, &f.root).is_err());
        assert!(f.base.exists());
    }
    #[cfg(unix)]
    #[test] fn linked_roots_are_rejected_and_linked_children_never_delete_external_files() {
        let f = Fixture::new(); let outside = f.base.join("outside"); fs::create_dir(&outside).unwrap();
        fs::write(outside.join("keep"), b"keep").unwrap();
        let linked = f.base.join("linked"); std::os::unix::fs::symlink(&f.root, &linked).unwrap();
        assert!(validate_workspace(&linked, &linked).is_err());
        std::os::unix::fs::symlink(&outside, f.root.join("linked-child")).unwrap();
        let mut transaction = f.begin(); transaction.commit().unwrap();
        assert!(outside.join("keep").is_file());
    }
}
