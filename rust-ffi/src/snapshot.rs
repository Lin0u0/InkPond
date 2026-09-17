//! Operation-local read closure. Sealed worlds hold only verified bytes, never live roots.
use super::*;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::os::fd::{AsRawFd, FromRawFd};
use std::time::{Instant, Duration as StdDuration};

const IDENTITY: &str = "typst-ios-0.15.0/seal-v1/bundled-typst-assets-0.15.0";
const MAX_JSON: usize = 16 * 1024 * 1024;
const HARD_BYTES: u64 = 1024 * 1024 * 1024;
const HARD_ENTRIES: u32 = 16384;
type Failure = (u32, String);
type Result<T> = std::result::Result<T, Failure>;
fn fail(code: u32, text: impl Into<String>) -> Failure { (code, text.into()) }
fn digest(b: &[u8]) -> String { format!("{:x}", Sha256::digest(b)) }

#[repr(C)]
pub struct TypstSnapshotPrepareOptionsV1 {
    pub struct_size: u32, pub schema_version: u32, pub inputs: *const TypstOptions,
    pub stage_dir: *const c_char, pub frozen_unix_seconds: i64,
    pub maximum_total_bytes: u64, pub maximum_file_bytes: u64,
    pub maximum_entries: u32, pub maximum_packages: u32, pub remaining_milliseconds: u64,
}
#[repr(C)]
pub struct TypstSnapshotPrepareResultV1 {
    pub status: u32, pub manifest_json: *mut u8, pub manifest_len: usize, pub error_message: *mut c_char,
}
#[repr(C)]
pub struct TypstSnapshotCompileResultV1 { pub status: u32, pub artifact: TypstPreviewResult }
// Only moves newly allocated owned result buffers from the worker back to the caller.
struct SendArtifact(TypstPreviewResult);
unsafe impl Send for SendArtifact {}

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Limits { total: u64, file: u64, entries: u32, packages: u32, milliseconds: u64 }
impl Limits {
    fn validate(&self) -> Result<()> {
        if self.total == 0 || self.total > HARD_BYTES || self.file == 0 || self.file > HARD_BYTES ||
            self.entries == 0 || self.entries > HARD_ENTRIES || self.packages == 0 || self.packages > self.entries ||
            self.milliseconds == 0 || self.milliseconds > 3_600_000 { return Err(fail(1,"invalid required limits")); }
        Ok(())
    }
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Blob { path: String, len: u64, sha256: String }
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Entry { package: Option<String>, relative: String, blob: Blob }
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Negative { package: Option<String>, relative: String }
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Package { spec: String, origin: String }
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Manifest {
    schema: u32, compiler: String, frozen_unix_seconds: i64, main_identity: String,
    source: Blob, fonts: Vec<Blob>, files: Vec<Entry>, negatives: Vec<Negative>, packages: Vec<Package>, limits: Limits,
}
struct Observation { path: PathBuf, bytes: Vec<u8> }
struct Recording {
    stage: PathBuf, root: PathBuf, limits: Limits, start: Instant, total: u64,
    entries: Vec<Entry>, negatives: Vec<(Negative, PathBuf)>, packages: HashMap<String,String>, observations: Vec<Observation>,
}
struct State { bytes: HashMap<FileId, Bytes>, negatives: HashSet<FileId>, recording: Option<Recording>, violation: Option<Failure> }
pub(super) struct Policy { state: Mutex<State>, clock: i64, pub output_kind: u32 }
impl Policy {
    fn latch(&self, e: Failure) { let mut s=self.state.lock().unwrap(); if s.violation.is_none() { s.violation=Some(e); } }
    fn check(&self) -> Result<()> {
        let s=self.state.lock().unwrap();
        if let Some(e)=&s.violation { return Err(e.clone()); }
        if let Some(r)=&s.recording { budget(r)?; }
        Ok(())
    }
    pub fn today(&self, offset: Option<Duration>) -> Option<Datetime> {
        let offset=offset.map(|v| v.seconds().round()).unwrap_or(0.0);
        if !offset.is_finite() || offset.abs() > 86400.0 { self.latch(fail(1,"invalid clock offset")); return None; }
        let days=self.clock.checked_add(offset as i64)?.div_euclid(86400);
        let days=i32::try_from(days).ok()?;
        let (y,m,d)=unix_days_to_ymd(days); Datetime::from_ymd(y,m,d)
    }
    pub fn read(&self, world: &SimpleWorld, id: FileId) -> FileResult<Bytes> {
        match self.read_inner(world,id) {
            Ok(v)=>Ok(v), Err((9, _))=>Err(vpath_not_found(id)), Err(e)=> { self.latch(e); Err(vpath_not_found(id)) }
        }
    }
    fn read_inner(&self, world: &SimpleWorld, id: FileId) -> Result<Bytes> {
        let mut s=self.state.lock().unwrap();
        if let Some(r)=&s.recording { budget(r)?; }
        if s.negatives.contains(&id) { return Err(fail(9,"recorded missing file")); }
        if let Some(b)=s.bytes.get(&id) { return Ok(b.clone()); }
        let r=s.recording.as_mut().ok_or_else(||fail(3,format!("unrecorded dependency: {}",world.display_file_label(id))))?;
        let (root,package)=match id.root() {
            VirtualRoot::Project=>(r.root.clone(),None),
            VirtualRoot::Package(spec)=> {
                let key=spec.to_string();
                if !r.packages.contains_key(&key) && r.packages.len() >= r.limits.packages as usize { return Err(fail(5,"package limit")); }
                // The legacy resolver canonicalizes local package paths. Check the
                // original spelling first so that cannot erase a symlink boundary.
                if let Some(local) = &world.local_packages_root {
                    if std::fs::symlink_metadata(local).is_ok() { open_checked(local, true)?; }
                    let candidate = local.join(spec.namespace.as_str()).join(spec.name.as_str()).join(spec.version.to_string());
                    if std::fs::symlink_metadata(&candidate).is_ok() { open_checked(&candidate, true)?; }
                }
                let path=world.package_dir(spec).map_err(|e|fail(7,e.to_string()))?;
                let origin=if world.local_packages_root.as_ref().is_some_and(|p| path.starts_with(p)) { "local" } else { "cache" };
                r.packages.insert(key.clone(),origin.into()); (path,Some(key))
            }
        };
        let relative=id.vpath().get_without_slash().to_string(); validate_relative(&relative)?;
        let path=root.join(&relative);
        let bytes=match read_checked(&path,r.limits.file) {
            Ok(bytes) => bytes,
            Err((9, message)) => {
                if r.observations.len()+r.negatives.len() >= r.limits.entries as usize { return Err(fail(5,"entry limit")); }
                r.negatives.push((Negative { package, relative }, path));
                s.negatives.insert(id);
                return Err(fail(9,message));
            }
            Err(e) => return Err(e),
        };
        let blob=stage_blob(r,&bytes)?;
        r.entries.push(Entry { package, relative, blob });
        r.observations.push(Observation { path, bytes: bytes.clone() });
        let bytes=Bytes::new(bytes); s.bytes.insert(id,bytes.clone()); Ok(bytes)
    }
}
fn budget(r: &Recording) -> Result<()> {
    if r.start.elapsed() > StdDuration::from_millis(r.limits.milliseconds) { Err(fail(5,"cooperative I/O deadline exceeded (CPU compilation is not interruptible)")) } else { Ok(()) }
}
fn validate_relative(p: &str) -> Result<()> {
    if p.is_empty() || p.contains('\\') || p.contains('\0') || p.split('/').any(|s|s.is_empty() || s=="." || s=="..") || Path::new(p).components().any(|c| !matches!(c,Component::Normal(_))) { return Err(fail(4,"invalid relative path")); } Ok(())
}
// Walk from / using opened directory handles and O_NOFOLLOW for *every* component.
// No canonicalize-then-reopen window; symlinks (even internal ones) are forbidden.
fn open_checked(path: &Path, directory: bool) -> Result<std::fs::File> {
    if !path.is_absolute() { return Err(fail(4,"absolute physical path required")); }
    let mut fd=std::fs::File::open("/").map_err(|e|fail(7,e.to_string()))?;
    let components: Vec<_>=path.components().collect();
    for (i,c) in components.iter().enumerate().skip(1) {
        let Component::Normal(name)=c else { return Err(fail(4,"non-normal physical path")); };
        use std::os::unix::ffi::OsStrExt;
        let name=CString::new(name.as_bytes()).map_err(|_|fail(4,"NUL in path"))?;
        let is_dir=i+1<components.len() || directory;
        let flags=libc::O_RDONLY | libc::O_CLOEXEC | libc::O_NOFOLLOW | libc::O_NONBLOCK | if is_dir {libc::O_DIRECTORY} else {0};
        let raw=unsafe { libc::openat(fd.as_raw_fd(),name.as_ptr(),flags) };
        if raw<0 { let e=std::io::Error::last_os_error(); return Err(fail(if e.raw_os_error()==Some(libc::ENOENT) {9} else {4},format!("no-follow open {}: {}",path.display(),e))); }
        fd=unsafe { std::fs::File::from_raw_fd(raw) };
    }
    Ok(fd)
}
fn read_checked(path: &Path, maximum: u64) -> Result<Vec<u8>> {
    use std::io::{Seek,SeekFrom};
    use std::os::unix::fs::MetadataExt;
    let mut file=open_checked(path,false)?;
    let before=file.metadata().map_err(|e|fail(7,e.to_string()))?;
    if !before.is_file() { return Err(fail(4,"not a regular file")); }
    if before.len()>maximum { return Err(fail(5,"file byte limit")); }
    let mut bytes=Vec::new(); (&mut file).take(maximum+1).read_to_end(&mut bytes).map_err(|e|fail(7,e.to_string()))?;
    if bytes.len() as u64>maximum { return Err(fail(5,"file byte limit")); }
    file.seek(SeekFrom::Start(0)).map_err(|e|fail(7,e.to_string()))?;
    let mut again=Vec::new(); (&mut file).take(maximum+1).read_to_end(&mut again).map_err(|e|fail(7,e.to_string()))?;
    let after=file.metadata().map_err(|e|fail(7,e.to_string()))?;
    let current=open_checked(path,false)?.metadata().map_err(|e|fail(7,e.to_string()))?;
    if bytes!=again || before.len()!=after.len() || before.mtime()!=after.mtime() || before.mtime_nsec()!=after.mtime_nsec() || before.ctime()!=after.ctime() || before.ctime_nsec()!=after.ctime_nsec() || before.ino()!=current.ino() || before.dev()!=current.dev() { return Err(fail(2,"input changed while reading")); }
    Ok(bytes)
}
fn stage_blob(r: &mut Recording, bytes: &[u8]) -> Result<Blob> {
    budget(r)?;
    if bytes.len() as u64>r.limits.file || r.total.checked_add(bytes.len() as u64).is_none_or(|n|n>r.limits.total) || (r.observations.len()+r.negatives.len()) >= r.limits.entries as usize { return Err(fail(5,"capture limits exceeded")); }
    let hash=digest(bytes); let relative=format!("sealed-v1/{hash}");
    let dir=open_checked(&r.stage.join("sealed-v1"),true)?;
    let name=CString::new(hash.clone()).unwrap();
    let raw=unsafe {libc::openat(dir.as_raw_fd(),name.as_ptr(),libc::O_WRONLY|libc::O_CREAT|libc::O_EXCL|libc::O_NOFOLLOW|libc::O_CLOEXEC,0o600)};
    if raw<0 {
        if std::io::Error::last_os_error().kind()!=std::io::ErrorKind::AlreadyExists || read_checked(&r.stage.join(&relative),r.limits.file)?!=bytes { return Err(fail(4,"blob publication failed")); }
    } else {
        use std::io::Write;
        let mut file=unsafe{std::fs::File::from_raw_fd(raw)};
        file.write_all(bytes).and_then(|_|file.sync_all()).map_err(|e|fail(7,e.to_string()))?;
    }
    r.total+=bytes.len() as u64;
    Ok(Blob { path: relative, len: bytes.len() as u64, sha256: hash })
}
fn verify_blob(stage: &Path, blob: &Blob, limits: &Limits) -> Result<Vec<u8>> {
    validate_relative(&blob.path)?;
    if blob.sha256.len()!=64 || !blob.sha256.bytes().all(|b|b.is_ascii_digit() || (b'a'..=b'f').contains(&b)) || blob.path!=format!("sealed-v1/{}",blob.sha256) || blob.len>limits.file { return Err(fail(4,"invalid blob descriptor")); }
    let bytes=read_checked(&stage.join(&blob.path),limits.file).map_err(|e|fail(4,e.1))?;
    if bytes.len() as u64!=blob.len || digest(&bytes)!=blob.sha256 { return Err(fail(4,"blob digest/length mismatch")); } Ok(bytes)
}
struct Inputs { stage: PathBuf, root: PathBuf, cache: Option<PathBuf>, local: Option<PathBuf>, fonts: Vec<PathBuf>, source: String, clock: i64, limits: Limits }
fn set_fonts(world: &mut SimpleWorld, bytes: Vec<Vec<u8>>) -> Result<()> {
    let mut fonts=Vec::new();
    for data in bytes {
        let faces: Vec<_>=Font::iter(Bytes::new(data)).collect();
        if faces.is_empty() { return Err(fail(4,"invalid selected font")); } fonts.extend(faces);
    }
    fonts.extend(bundled_font_faces().iter().cloned());
    let mut book=FontBook::new(); for f in &fonts {book.push(f.info().clone());}
    world.fonts=fonts; world.book=LazyHash::new(book); Ok(())
}
fn new_world(source: &str, clock: i64, state: State, fonts: Vec<Vec<u8>>, output_kind: u32) -> Result<SimpleWorld> {
    let mut world=unsafe{SimpleWorld::new(source,std::ptr::null())};
    set_fonts(&mut world,fonts)?;
    world.snapshot=Some(Policy { state: Mutex::new(state), clock, output_kind }); Ok(world)
}
// Threads provide stack capacity and panic containment, NOT cache isolation.
// comemo 0.5.1 caches are global. Its call-tree lookup validates tracked World
// calls against this world, so every returned dependency is pinned by Policy;
// accelerator reuse is restricted to a tracked input within that compilation.
// A failed cache probe can conservatively add a read or latch a violation.
// Never globally evict: concurrent legacy compilations also use these caches.
fn fresh<T: Send>(f: impl FnOnce()->Result<T> + Send) -> Result<T> {
    std::thread::scope(|scope| {
        std::thread::Builder::new().name("typst-sealed".into()).stack_size(PREVIEW_STACK_SIZE_BYTES).spawn_scoped(scope,move|| {
            catch_unwind(AssertUnwindSafe(f)).unwrap_or_else(|_|Err(fail(8,"native snapshot panic")))
        }).map_err(|e|fail(7,e.to_string()))?.join().unwrap_or_else(|_|Err(fail(8,"snapshot thread panic")))
    })
}
fn compile(world: &SimpleWorld) -> Result<PagedDocument> {
    let result=typst::compile::<PagedDocument>(world).output;
    world.snapshot.as_ref().unwrap().check()?;
    let result=result.map_err(|e|fail(6,format_diagnostics(world,&e)));
    world.snapshot.as_ref().unwrap().check()?; result
}
fn prepare(input: Inputs) -> Result<Vec<u8>> {
    let start=Instant::now();
    open_checked(&input.stage,true)?; open_checked(&input.root,true)?;
    if !input.root.starts_with(&input.stage) || input.fonts.iter().any(|p|!p.starts_with(&input.stage)) { return Err(fail(1,"project/fonts must be inside stage lease")); }
    // Reserve our own namespace once. Never reuse or erase another operation's blobs.
    let dir=open_checked(&input.stage,true)?; let name=c"sealed-v1";
    if unsafe{libc::mkdirat(dir.as_raw_fd(),name.as_ptr(),0o700)}!=0 { return Err(fail(4,"sealed-v1 already exists or cannot be created")); }
    let mut r=Recording { stage:input.stage.clone(),root:input.root.clone(),limits:input.limits.clone(),start,total:0,entries:Vec::new(),negatives:Vec::new(),packages:HashMap::new(),observations:Vec::new() };
    let source=stage_blob(&mut r,input.source.as_bytes())?;
    // Main source counts as an entry but has no live source-file observation.
    r.observations.push(Observation {path:input.stage.join(&source.path),bytes:input.source.as_bytes().to_vec()});
    let mut fonts=Vec::new(); let mut font_bytes=Vec::new();
    for path in input.fonts {
        let bytes=read_checked(&path,r.limits.file)?;
        fonts.push(stage_blob(&mut r,&bytes)?); r.observations.push(Observation {path,bytes:bytes.clone()}); font_bytes.push(bytes);
    }
    let mut world=new_world(&input.source,input.clock,State {bytes:HashMap::new(),negatives:HashSet::new(),recording:Some(r),violation:None},font_bytes,3)?;
    world.pkg_cache_root=input.cache; world.local_packages_root=input.local;
    fresh(|| { let document=compile(&world)?; let artifact=preview_result_from_document(&world,document,true); let ok=artifact.success; unsafe{typst_free_preview_result(artifact)}; world.snapshot.as_ref().unwrap().check()?; if !ok {return Err(fail(6,"discovery rendering failed"));} Ok(()) })?;
    let policy=world.snapshot.as_ref().unwrap(); let mut state=policy.state.lock().unwrap(); let r=state.recording.take().unwrap();
    for observation in &r.observations {
        budget(&r)?;
        if read_checked(&observation.path,r.limits.file).map_err(|e|fail(2,e.1))?!=observation.bytes { return Err(fail(2,"observed input changed before seal")); }
    }
    for (_, path) in &r.negatives {
        budget(&r)?;
        if !matches!(open_checked(path,false), Err((9,_))) { return Err(fail(2,"negative observation changed")); }
    }
    let mut packages:Vec<_>=r.packages.iter().map(|(spec,origin)|Package {spec:spec.clone(),origin:origin.clone()}).collect(); packages.sort_by(|a,b|a.spec.cmp(&b.spec));
    let manifest=Manifest {schema:1,compiler:IDENTITY.into(),frozen_unix_seconds:input.clock,main_identity:"main.typ".into(),source,fonts,files:r.entries.clone(),negatives:r.negatives.iter().map(|(n,_)|n.clone()).collect(),packages,limits:input.limits};
    let json=serde_json::to_vec(&manifest).map_err(|e|fail(4,e.to_string()))?;
    if json.len()>MAX_JSON { return Err(fail(5,"manifest size limit")); }
    budget(&r)?;
    // Verify all staged inputs, pin bytes, then validate without a resolver in a fresh thread.
    let sealed=load(&input.stage,&json,3)?;
    fresh(|| { let doc=compile(&sealed)?; let artifact=preview_result_from_document(&sealed,doc,true); let ok=artifact.success; unsafe{typst_free_preview_result(artifact)}; sealed.snapshot.as_ref().unwrap().check()?; if !ok {return Err(fail(6,"sealed validation rendering failed"));} Ok(()) })?;
    budget(&r)?; Ok(json)
}
fn load(stage: &Path, json: &[u8], output: u32) -> Result<SimpleWorld> {
    let start=Instant::now();
    if json.is_empty() || json.len()>MAX_JSON { return Err(fail(4,"manifest size")); }
    let m:Manifest=serde_json::from_slice(json).map_err(|e|fail(4,e.to_string()))?;
    m.limits.validate().map_err(|e|fail(4,e.1))?;
    if m.schema!=1 || m.compiler!=IDENTITY || m.main_identity!="main.typ" || !valid_clock(m.frozen_unix_seconds) { return Err(fail(4,"schema/compiler/clock identity mismatch")); }
    if m.files.len()+m.negatives.len()+m.fonts.len()+1>m.limits.entries as usize || m.packages.len()>m.limits.packages as usize {return Err(fail(4,"manifest count limit"));}
    let mut specs=HashSet::new();
    for package in &m.packages {
        let spec:PackageSpec=package.spec.parse().map_err(|_|fail(4,"invalid package spec"))?;
        if spec.to_string()!=package.spec || !["local","cache"].contains(&package.origin.as_str()) || !specs.insert(package.spec.clone()) {return Err(fail(4,"invalid/duplicate package"));}
    }
    let mut total=0u64;
    let mut verify=|b:&Blob|->Result<Vec<u8>> {
        total=total.checked_add(b.len).ok_or_else(||fail(4,"byte overflow"))?;
        if total>m.limits.total || start.elapsed()>StdDuration::from_millis(m.limits.milliseconds) {return Err(fail(5,"verification budget"));}
        verify_blob(stage,b,&m.limits)
    };
    let source=verify(&m.source)?; let source=std::str::from_utf8(&source).map_err(|_|fail(4,"source UTF-8"))?;
    let mut fonts=Vec::new(); for b in &m.fonts {fonts.push(verify(b)?);}
    let mut bytes=HashMap::new(); let mut used=HashSet::new();
    for entry in &m.files {
        validate_relative(&entry.relative)?;
        let root=if let Some(spec)=&entry.package {
            if !specs.contains(spec) {return Err(fail(4,"unlisted package"));} used.insert(spec.clone());
            VirtualRoot::Package(spec.parse().map_err(|_|fail(4,"package"))?)
        } else {VirtualRoot::Project};
        let path=VirtualPath::new(&entry.relative).map_err(|_|fail(4,"virtual path"))?;
        let id=RootedPath::new(root,path).intern();
        if bytes.insert(id,Bytes::new(verify(&entry.blob)?)).is_some() {return Err(fail(4,"duplicate file identity"));}
    }
    let mut negatives=HashSet::new();
    for entry in &m.negatives {
        validate_relative(&entry.relative)?;
        let root=if let Some(spec)=&entry.package {
            if !specs.contains(spec) {return Err(fail(4,"unlisted negative package"));}
            used.insert(spec.clone());
            VirtualRoot::Package(spec.parse().map_err(|_|fail(4,"package"))?)
        } else {VirtualRoot::Project};
        let path=VirtualPath::new(&entry.relative).map_err(|_|fail(4,"virtual path"))?;
        let id=RootedPath::new(root,path).intern();
        if bytes.contains_key(&id) || !negatives.insert(id) {return Err(fail(4,"duplicate negative identity"));}
    }
    if used!=specs {return Err(fail(4,"inconsistent package references"));}
    new_world(source,m.frozen_unix_seconds,State {bytes,negatives,recording:None,violation:None},fonts,output)
}
fn valid_clock(t:i64)->bool {(-62_135_596_800..=253_402_300_799).contains(&t)}
unsafe fn cpath(ptr:*const c_char, required:bool)->Result<Option<PathBuf>> {
    if ptr.is_null() { return if required {Err(fail(1,"missing path"))} else {Ok(None)}; }
    let s=CStr::from_ptr(ptr).to_str().map_err(|_|fail(1,"invalid path UTF-8"))?;
    if s.is_empty() || !Path::new(s).is_absolute() {return Err(fail(1,"absolute nonempty path required"));} Ok(Some(s.into()))
}
unsafe fn input(source:*const u8,len:usize,opts:*const TypstSnapshotPrepareOptionsV1)->Result<Inputs> {
    if opts.is_null() {return Err(fail(1,"null options"));}
    // Read size before accessing remaining versioned fields.
    if (*opts).struct_size as usize!=std::mem::size_of::<TypstSnapshotPrepareOptionsV1>() {return Err(fail(1,"options size mismatch"));}
    let o=&*opts;
    if o.schema_version!=1 || o.inputs.is_null() || !valid_clock(o.frozen_unix_seconds) {return Err(fail(1,"invalid schema/inputs/clock"));}
    let limits=Limits {total:o.maximum_total_bytes,file:o.maximum_file_bytes,entries:o.maximum_entries,packages:o.maximum_packages,milliseconds:o.remaining_milliseconds}; limits.validate()?;
    if len as u64>limits.file {return Err(fail(5,"source limit"));}
    if source.is_null() && len!=0 {return Err(fail(1,"null source"));}
    let source=if len==0 {&[]} else {std::slice::from_raw_parts(source,len)};
    let source=std::str::from_utf8(source).map_err(|_|fail(1,"invalid source UTF-8"))?.to_owned();
    let i=&*o.inputs;
    if i.font_path_count>limits.entries as usize || (i.font_path_count!=0 && i.font_paths.is_null()) {return Err(fail(1,"invalid font pointers/count"));}
    let mut fonts=Vec::new(); for n in 0..i.font_path_count {fonts.push(cpath(*i.font_paths.add(n),true)?.unwrap());}
    Ok(Inputs {stage:cpath(o.stage_dir,true)?.unwrap(),root:cpath(i.root_dir,true)?.unwrap(),cache:cpath(i.cache_dir,false)?,local:cpath(i.local_packages_dir,false)?,fonts,source,clock:o.frozen_unix_seconds,limits})
}
#[no_mangle]
pub unsafe extern "C" fn typst_prepare_snapshot_v1(source:*const u8,len:usize,options:*const TypstSnapshotPrepareOptionsV1)->TypstSnapshotPrepareResultV1 {
    match catch_unwind(AssertUnwindSafe(||input(source,len,options).and_then(prepare))).unwrap_or_else(|_|Err(fail(8,"native prepare panic"))) {
        Ok(bytes)=> {let mut bytes=bytes.into_boxed_slice();let len=bytes.len();let ptr=bytes.as_mut_ptr();std::mem::forget(bytes);TypstSnapshotPrepareResultV1 {status:0,manifest_json:ptr,manifest_len:len,error_message:std::ptr::null_mut()}},
        Err((status,message))=>TypstSnapshotPrepareResultV1 {status:if status==9 {4} else {status},manifest_json:std::ptr::null_mut(),manifest_len:0,error_message:string_into_raw(message)},
    }
}
#[no_mangle]
pub unsafe extern "C" fn typst_free_snapshot_prepare_result_v1(r:TypstSnapshotPrepareResultV1) {
    if !r.manifest_json.is_null() {drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(r.manifest_json,r.manifest_len)));}
    if !r.error_message.is_null() {drop(CString::from_raw(r.error_message));}
}
#[no_mangle]
pub unsafe extern "C" fn typst_compile_snapshot_v1(stage:*const c_char,json:*const u8,len:usize,output:u32)->TypstSnapshotCompileResultV1 {
    let result=catch_unwind(AssertUnwindSafe(||->Result<SendArtifact> {
        if !(1..=3).contains(&output) || json.is_null() || len==0 || len>MAX_JSON {return Err(fail(1,"invalid final arguments"));}
        let stage=cpath(stage,true)?.unwrap();let json=std::slice::from_raw_parts(json,len);
        fresh(|| {
            let world=load(&stage,json,output)?; let document=compile(&world)?;
            let artifact=preview_result_from_document(&world,document,output!=2);
            if let Err(e)=world.snapshot.as_ref().unwrap().check() {typst_free_preview_result(artifact);return Err(e);}
            if !artifact.success {typst_free_preview_result(artifact);return Err(fail(6,"sealed rendering failed"));}
            Ok(SendArtifact(artifact))
        })
    })).unwrap_or_else(|_|Err(fail(8,"native final panic")));
    match result {Ok(SendArtifact(artifact))=>TypstSnapshotCompileResultV1 {status:0,artifact},Err((status,message))=>TypstSnapshotCompileResultV1 {status,artifact:error_result_preview(&message)}}
}
#[no_mangle]
pub unsafe extern "C" fn typst_free_snapshot_compile_result_v1(r:TypstSnapshotCompileResultV1) {typst_free_preview_result(r.artifact);}

// Publication completeness records are local implementation metadata, never staged dependencies.
// Legacy cache trees without a marker remain usable if they have an ordinary manifest;
// competing publication winners must have the marker produced after successful extraction.
pub(super) fn valid_legacy_package(path: &Path) -> bool {
    open_checked(path, true).is_ok() && read_checked(&path.join("typst.toml"), MAX_PACKAGE_ENTRY_BYTES).is_ok()
}
pub(super) fn valid_published_package(path:&Path)->bool {
    open_checked(path,true).is_ok() && read_checked(&path.join("typst.toml"),MAX_PACKAGE_ENTRY_BYTES).is_ok()
        && read_checked(&path.join(".inkpond-complete-v1"),128).is_ok_and(|b|b==b"complete\n")
}
pub(super) fn mark_published_package(path:&Path)->std::result::Result<(),String> {
    read_checked(&path.join("typst.toml"),MAX_PACKAGE_ENTRY_BYTES).map_err(|e|e.1)?;
    std::fs::write(path.join(".inkpond-complete-v1"),b"complete\n").map_err(|e|e.to_string())
}
