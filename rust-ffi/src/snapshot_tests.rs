//! Black-box native sealing and persistent publication regression tests.
use super::*;
use crate::snapshot::*;

struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let root = std::env::temp_dir().canonicalize().unwrap().join(format!("inkpond-seal-test-{}-{}", std::process::id(), NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)));
        std::fs::create_dir_all(root.join("project")).unwrap();
        Self(root)
    }
    fn write(&self, name: &str, bytes: impl AsRef<[u8]>) {
        let path = self.0.join(name);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, bytes).unwrap();
    }
    fn prepare(&self, source: &str, stage: &str) -> (u32, Vec<u8>, String) {
        let stage = self.0.join(stage);
        std::fs::create_dir_all(stage.join("project")).unwrap();
        // These inputs emulate the private project capture, not a live project fallback.
        for entry in std::fs::read_dir(self.0.join("project")).unwrap() {
            let entry = entry.unwrap();
            if entry.file_type().unwrap().is_file() { std::fs::copy(entry.path(), stage.join("project").join(entry.file_name())).unwrap(); }
        }
        let cstage = CString::new(stage.to_str().unwrap()).unwrap();
        let root = CString::new(stage.join("project").to_str().unwrap()).unwrap();
        let local = CString::new(self.0.join("local").to_str().unwrap()).unwrap();
        let cache = CString::new(self.0.join("cache").to_str().unwrap()).unwrap();
        let inputs = TypstOptions { font_paths: std::ptr::null(), font_path_count: 0, cache_dir: cache.as_ptr(), root_dir: root.as_ptr(), local_packages_dir: local.as_ptr() };
        let options = TypstSnapshotPrepareOptionsV1 { struct_size: std::mem::size_of::<TypstSnapshotPrepareOptionsV1>() as u32, schema_version: 1, inputs: &inputs, stage_dir: cstage.as_ptr(), frozen_unix_seconds: 1_700_000_000, maximum_total_bytes: 8*1024*1024, maximum_file_bytes: 4*1024*1024, maximum_entries: 100, maximum_packages: 20, remaining_milliseconds: 120_000 };
        unsafe {
            let result = typst_prepare_snapshot_v1(source.as_ptr(), source.len(), &options);
            let status = result.status;
            let manifest = if result.manifest_json.is_null() { Vec::new() } else { std::slice::from_raw_parts(result.manifest_json, result.manifest_len).to_vec() };
            let error = if result.error_message.is_null() { String::new() } else { CStr::from_ptr(result.error_message).to_string_lossy().into_owned() };
            typst_free_snapshot_prepare_result_v1(result);
            (status, manifest, error)
        }
    }
    fn final_pdf(&self, stage: &str, manifest: &[u8]) -> (u32, Vec<u8>) {
        let stage = CString::new(self.0.join(stage).to_str().unwrap()).unwrap();
        unsafe {
            let result = typst_compile_snapshot_v1(stage.as_ptr(), manifest.as_ptr(), manifest.len(), 1);
            let status = result.status;
            let bytes = if result.artifact.pdf_data.is_null() { Vec::new() } else { std::slice::from_raw_parts(result.artifact.pdf_data, result.artifact.pdf_len).to_vec() };
            typst_free_snapshot_compile_result_v1(result);
            (status, bytes)
        }
    }
}
impl Drop for Fixture { fn drop(&mut self) { let _ = std::fs::remove_dir_all(&self.0); } }

#[test]
fn dynamic_transitive_closure_is_sealed_and_tampering_fails_closed() {
    let f = Fixture::new();
    f.write("project/value.txt", "Frozen marker");
    f.write("local/local/outer/1.0.0/typst.toml", "[package]\nname = \"outer\"\nversion = \"1.0.0\"\nentrypoint = \"lib.typ\"\n");
    f.write("local/local/outer/1.0.0/lib.typ", "#import \"@local/inner:1.0.0\": marker\n#let result = marker");
    f.write("local/local/inner/1.0.0/typst.toml", "[package]\nname = \"inner\"\nversion = \"1.0.0\"\nentrypoint = \"lib.typ\"\n");
    f.write("local/local/inner/1.0.0/lib.typ", "#let marker = [Transitive frozen]");
    f.write("cache/unrelated/large.bin", vec![0u8; 9*1024*1024]);
    let source = "#let package = \"@local/outer:\" + \"1.0.0\"\n#import package: result\n#result\n#let name = \"value\" + \".txt\"\n#read(name)\n#datetime.today().display()";
    let (status, manifest, error) = f.prepare(source, "stage");
    assert_eq!(status, 0, "{error}");
    let json: serde_json::Value = serde_json::from_slice(&manifest).unwrap();
    assert_eq!(json["packages"].as_array().unwrap().len(), 2);
    assert!(json["files"].as_array().unwrap().iter().any(|v| v["relative"] == "value.txt"));
    let baseline = f.final_pdf("stage", &manifest);
    assert_eq!(baseline.0, 0); assert!(!baseline.1.is_empty());
    std::fs::remove_dir_all(f.0.join("local")).unwrap();
    std::fs::remove_dir_all(f.0.join("project")).unwrap();
    std::fs::remove_dir_all(f.0.join("stage/project")).unwrap();
    assert_eq!(f.final_pdf("stage", &manifest), baseline);
    let blob = json["files"][0]["blob"]["path"].as_str().unwrap();
    f.write(&format!("stage/{blob}"), "tampered");
    let corrupted = f.final_pdf("stage", &manifest);
    assert_ne!(corrupted.0, 0); assert!(corrupted.1.is_empty());
}

#[test]
fn missing_dependency_prevents_acceptance() {
    let f = Fixture::new();
    let (status, manifest, _) = f.prepare("#read(\"missing.txt\")", "stage");
    assert_ne!(status, 0); assert!(manifest.is_empty());
}

#[test]
fn downloaded_package_survives_stage_cleanup_and_reuses_offline() {
    use flate2::{write::GzEncoder, Compression};
    let f = Fixture::new();
    let encoder = GzEncoder::new(Vec::new(), Compression::default());
    let mut archive = tar::Builder::new(encoder);
    for (name, contents) in [("typst.toml", "[package]\nname = \"reuse\"\nversion = \"1.0.0\"\nentrypoint = \"lib.typ\"\n"), ("lib.typ", "#let marker = [Offline package]")] {
        let mut header = tar::Header::new_gnu(); header.set_size(contents.len() as u64); header.set_mode(0o644); header.set_cksum();
        archive.append_data(&mut header, name, contents.as_bytes()).unwrap();
    }
    let payload = archive.into_inner().unwrap().finish().unwrap();
    let url = "https://packages.typst.org/preview/reuse-1.0.0.tar.gz";
    TEST_DOWNLOADS.lock().unwrap().insert(url.into(), (payload.clone(), 0, true));
    let package = f.0.join("cache/preview/reuse/1.0.0");
    let source = "#import \"@preview/reuse:1.0.0\": marker\n#marker";
    let (status, manifest, error) = f.prepare(source, "first"); assert_eq!(status, 0, "{error}");
    assert_eq!(f.final_pdf("first", &manifest).0, 0);
    assert!(snapshot::valid_published_package(&package));
    { let mut downloads = TEST_DOWNLOADS.lock().unwrap(); let state = downloads.get_mut(url).unwrap(); assert_eq!(state.1, 1); state.2 = false; }
    std::fs::remove_dir_all(f.0.join("first")).unwrap();
    assert!(package.join("lib.typ").is_file());
    let (status, manifest, error) = f.prepare(source, "offline"); assert_eq!(status, 0, "{error}");
    assert_eq!(f.final_pdf("offline", &manifest).0, 0);
    assert_eq!(TEST_DOWNLOADS.lock().unwrap().remove(url).unwrap().1, 1);

    // Exercise the same extraction/publication routine without the resolver lock:
    // concurrent writers must use separate staging directories and accept a complete winner.
    let race_url = "fixture://concurrent-publication";
    TEST_DOWNLOADS.lock().unwrap().insert(race_url.into(), (payload, 0, true));
    let destination = f.0.join("concurrent/reuse");
    std::thread::scope(|scope| {
        let a = scope.spawn(|| download_and_extract(race_url, &destination));
        let b = scope.spawn(|| download_and_extract(race_url, &destination));
        assert_eq!(a.join().unwrap().unwrap(), destination);
        assert_eq!(b.join().unwrap().unwrap(), destination);
    });
    assert!(snapshot::valid_published_package(&destination));
    assert_eq!(std::fs::read_dir(destination.parent().unwrap()).unwrap().count(), 1);
    assert_eq!(TEST_DOWNLOADS.lock().unwrap().remove(race_url).unwrap().1, 2);
}

#[test]
fn local_package_symlink_is_rejected_before_legacy_canonicalization() {
    let f = Fixture::new();
    f.write("local/real/typst.toml", "[package]\nname = \"linked\"\nversion = \"1.0.0\"\nentrypoint = \"lib.typ\"\n");
    f.write("local/real/lib.typ", "#let value = [Linked]");
    std::fs::create_dir_all(f.0.join("local/local/linked")).unwrap();
    std::os::unix::fs::symlink(f.0.join("local/real"), f.0.join("local/local/linked/1.0.0")).unwrap();
    let (status, manifest, _) = f.prepare("#import \"@local/linked:1.0.0\": value\n#value", "stage");
    assert_ne!(status, 0); assert!(manifest.is_empty());
}

#[test]
fn global_cache_warming_does_not_change_dynamic_sealed_closure() {
    let f = Fixture::new();
    f.write("project/a.txt", "Branch A");
    f.write("project/b.txt", "Branch B");
    f.write("project/selector.txt", "a.txt");
    let source = "#let selected = read(\"selector.txt\")\n#read(selected)";
    let legacy = || {
        let source = CString::new(source).unwrap();
        let root = CString::new(f.0.join("project").to_str().unwrap()).unwrap();
        let options = TypstOptions { font_paths: std::ptr::null(), font_path_count: 0, cache_dir: std::ptr::null(), root_dir: root.as_ptr(), local_packages_dir: std::ptr::null() };
        unsafe { let result = typst_compile(source.as_ptr(), &options); let ok = result.success; typst_free_result(result); assert!(ok); }
    };
    legacy();
    f.write("project/selector.txt", "b.txt");
    let (status, manifest, error) = f.prepare(source, "branch-b"); assert_eq!(status, 0, "{error}");
    let json: serde_json::Value = serde_json::from_slice(&manifest).unwrap();
    let files = json["files"].as_array().unwrap();
    assert!(files.iter().any(|v| v["relative"] == "b.txt"));
    assert!(!files.iter().any(|v| v["relative"] == "a.txt"), "Rejected cache candidates must not pollute the actual closure");
    let baseline = f.final_pdf("branch-b", &manifest); assert_eq!(baseline.0, 0);
    f.write("project/selector.txt", "a.txt");
    legacy();
    assert_eq!(f.final_pdf("branch-b", &manifest), baseline);
    std::thread::scope(|scope| {
        let warmed = scope.spawn(legacy);
        for _ in 0..3 { assert_eq!(f.final_pdf("branch-b", &manifest), baseline); }
        warmed.join().unwrap();
    });
}
