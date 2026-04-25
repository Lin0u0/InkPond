use std::collections::HashMap;
use std::ffi::{CStr, CString};
use std::io::Read;
use std::os::raw::c_char;
use std::path::{Component, Path, PathBuf};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::{Arc, Mutex, OnceLock};

use typst::diag::{FileError, FileResult, PackageError, SourceDiagnostic};
use typst::foundations::{Bytes, Datetime};
use typst::layout::{Frame, FrameItem, PagedDocument, Point, Transform};
use typst::syntax::package::PackageSpec;
use typst::syntax::{FileId, Source, Span, VirtualPath};
use typst::text::{Font, FontBook};
use typst::utils::LazyHash;
use typst::{Library, LibraryExt, World};
use typst_pdf::{PdfOptions, pdf};

const EXTRA_FONT_CACHE_LIMIT: usize = 16;

static BUNDLED_FONT_FACES: OnceLock<Arc<Vec<Font>>> = OnceLock::new();
static EXTRA_FONT_FACES_CACHE: OnceLock<Mutex<HashMap<String, Arc<Vec<Font>>>>> = OnceLock::new();
static PACKAGE_FETCH_LOCKS: OnceLock<Mutex<HashMap<String, Arc<Mutex<()>>>>> = OnceLock::new();

#[cfg(debug_assertions)]
macro_rules! debug_log {
    ($($arg:tt)*) => {
        eprintln!($($arg)*);
    };
}

#[cfg(not(debug_assertions))]
macro_rules! debug_log {
    ($($arg:tt)*) => {};
}

// ---------------------------------------------------------------------------
// C FFI — options struct
// ---------------------------------------------------------------------------

/// Compile options passed from Swift.
///
/// All pointer fields may be null to opt out of that feature.
#[repr(C)]
pub struct TypstOptions {
    /// Array of extra font file paths (e.g. system CJK fonts).
    pub font_paths: *const *const c_char,
    pub font_path_count: usize,
    /// Directory used to cache downloaded @preview packages.
    pub cache_dir: *const c_char,
    /// Root directory for resolving local file references (e.g. #image("images/photo.jpg")).
    pub root_dir: *const c_char,
    /// Root directory for local packages (e.g. @local/mypackage:1.0.0).
    /// Expected layout: {local_packages_dir}/{namespace}/{name}/{version}/
    pub local_packages_dir: *const c_char,
}

// ---------------------------------------------------------------------------
// In-memory Typst World
// ---------------------------------------------------------------------------

struct SimpleWorld {
    library: LazyHash<Library>,
    book: LazyHash<FontBook>,
    fonts: Vec<Font>,
    main_id: FileId,
    source: Source,
    /// Root directory for the package cache (if provided).
    pkg_cache_root: Option<PathBuf>,
    /// Root directory for resolving local file references (images, imports).
    root_dir: Option<PathBuf>,
    /// Root directory for local packages (checked before downloading).
    local_packages_root: Option<PathBuf>,
    /// Maps "ns/name/ver" → Ok(extracted dir) | Err(message).
    pkg_dirs: Mutex<HashMap<String, Result<PathBuf, PackageError>>>,
    /// Per-request source cache (avoids re-reading the same file).
    source_cache: Mutex<HashMap<FileId, Source>>,
    /// Per-request binary file cache.
    file_cache: Mutex<HashMap<FileId, Bytes>>,
}

impl SimpleWorld {
    /// Construct a world.
    ///
    /// # Safety
    /// `options` must be null or point to a valid `TypstOptions`.
    unsafe fn new(source_text: &str, options: *const TypstOptions) -> Self {
        let mut fonts: Vec<Font> = Vec::new();
        let mut book = FontBook::new();

        let mut pkg_cache_root: Option<PathBuf> = None;
        let mut root_dir: Option<PathBuf> = None;
        let mut local_packages_root: Option<PathBuf> = None;
        let mut font_paths: Vec<String> = Vec::new();

        if !options.is_null() {
            let opts = &*options;

            debug_log!("[typst-ffi] font_path_count from Swift: {}", opts.font_path_count);

            // Gather extra font paths from Swift.
            if !opts.font_paths.is_null() {
                for i in 0..opts.font_path_count {
                    let ptr = *opts.font_paths.add(i);
                    if ptr.is_null() {
                        continue;
                    }
                    let path = match CStr::from_ptr(ptr).to_str() {
                        Ok(s) => s.to_string(),
                        Err(_) => continue,
                    };
                    font_paths.push(path);
                }
            } else if opts.font_path_count > 0 {
                debug_log!(
                    "[typst-ffi] font_path_count was non-zero but font_paths pointer was null"
                );
            }

            // --- Package cache directory ---
            if !opts.cache_dir.is_null() {
                if let Ok(s) = CStr::from_ptr(opts.cache_dir).to_str() {
                    if !s.is_empty() {
                        pkg_cache_root = Some(PathBuf::from(s));
                    }
                }
            }

            // --- Root directory for local file resolution ---
            if !opts.root_dir.is_null() {
                if let Ok(s) = CStr::from_ptr(opts.root_dir).to_str() {
                    if !s.is_empty() {
                        root_dir = Some(PathBuf::from(s));
                        debug_log!("[typst-ffi] root_dir: {}", s);
                    }
                }
            }

            // --- Local packages directory ---
            if !opts.local_packages_dir.is_null() {
                if let Ok(s) = CStr::from_ptr(opts.local_packages_dir).to_str() {
                    if !s.is_empty() {
                        local_packages_root = Some(PathBuf::from(s));
                        debug_log!("[typst-ffi] local_packages_dir: {}", s);
                    }
                }
            }
        }

        // --- Extra font paths (system/user/project fonts from Swift/CoreText) ---
        //
        // Insert these before Typst's bundled fonts. If the user explicitly
        // selects an iOS family such as PingFang SC and one character needs
        // fallback (Latin cascade, emoji, etc.), Typst's fallback search should
        // prefer the platform fonts Swift resolved for this document before
        // falling back to Libertinus/New Computer Modern from typst-assets.
        if !font_paths.is_empty() {
            let extra_faces = extra_font_faces(&font_paths);
            for font in extra_faces.iter().cloned() {
                book.push(font.info().clone());
                fonts.push(font);
            }
            debug_log!(
                "[typst-ffi] loaded {} extra font faces (cache key paths: {})",
                extra_faces.len(),
                font_paths.len()
            );
        }

        let bundled_faces = bundled_font_faces();
        for font in bundled_faces.iter().cloned() {
            book.push(font.info().clone());
            fonts.push(font);
        }

        debug_log!("[typst-ffi] bundled fonts: {}", bundled_faces.len());

        let main_id = FileId::new(None, VirtualPath::new("main.typ"));
        let source = Source::new(main_id, source_text.to_string());

        Self {
            library: LazyHash::new(Library::default()),
            book: LazyHash::new(book),
            fonts,
            main_id,
            source,
            pkg_cache_root,
            root_dir,
            local_packages_root,
            pkg_dirs: Mutex::new(HashMap::new()),
            source_cache: Mutex::new(HashMap::new()),
            file_cache: Mutex::new(HashMap::new()),
        }
    }

    /// Return (and download if needed) the local directory for a package.
    fn package_dir(&self, spec: &PackageSpec) -> FileResult<PathBuf> {
        let key = format!("{}/{}/{}", spec.namespace, spec.name, spec.version);

        {
            let guard = self.pkg_dirs.lock().unwrap();
            if let Some(result) = guard.get(&key) {
                return result.clone().map_err(FileError::Package);
            }
        }

        // Check local packages directory first (supports @local and any custom namespace).
        if let Some(local_root) = &self.local_packages_root {
            let local_dir = local_root
                .join(spec.namespace.as_str())
                .join(spec.name.as_str())
                .join(spec.version.to_string());
            if local_dir.exists() {
                debug_log!("[typst-ffi] resolved local package: {}", key);
                let result = Ok(local_dir);
                self.pkg_dirs.lock().unwrap().insert(key, result.clone());
                return result.map_err(FileError::Package);
            }
        }

        let cache_root = self
            .pkg_cache_root
            .as_ref()
            .ok_or_else(|| {
                FileError::Package(PackageError::Other(Some(
                    "package cache directory is unavailable".into(),
                )))
            })?;

        let pkg_dir = cache_root
            .join(spec.namespace.as_str())
            .join(spec.name.as_str())
            .join(spec.version.to_string());

        let package_lock = package_fetch_lock(&key);
        let _guard = package_lock.lock().unwrap();

        let result = if pkg_dir.exists() {
            Ok(pkg_dir.clone())
        } else {
            let url = format!(
                "https://packages.typst.org/{}/{}-{}.tar.gz",
                spec.namespace, spec.name, spec.version
            );
            download_and_extract(&url, &pkg_dir)
        };

        self.pkg_dirs.lock().unwrap().insert(key, result.clone());
        result.map_err(FileError::Package)
    }

    fn format_span_location(&self, span: Span) -> Option<String> {
        let id = span.id()?;
        let source = self.source(id).ok()?;
        let range = source.range(span).or_else(|| span.range())?;
        let (line, column) = source.lines().byte_to_line_column(range.start)?;
        Some(format!(
            "{}:{}:{}",
            self.display_file_label(id),
            line + 1,
            column + 1
        ))
    }

    fn display_file_label(&self, id: FileId) -> String {
        if let Some(package) = id.package() {
            format!("{package}{}", id.vpath().as_rooted_path().display())
        } else {
            id.vpath().as_rootless_path().display().to_string()
        }
    }
}

fn bundled_font_faces() -> Arc<Vec<Font>> {
    BUNDLED_FONT_FACES
        .get_or_init(|| {
            let mut faces = Vec::new();
            for data in typst_assets::fonts() {
                for font in Font::iter(Bytes::new(data)) {
                    faces.push(font);
                }
            }
            Arc::new(faces)
        })
        .clone()
}

fn package_fetch_lock(key: &str) -> Arc<Mutex<()>> {
    let locks = PACKAGE_FETCH_LOCKS.get_or_init(|| Mutex::new(HashMap::new()));
    let mut guard = locks.lock().unwrap();
    guard
        .entry(key.to_string())
        .or_insert_with(|| Arc::new(Mutex::new(())))
        .clone()
}

fn extra_font_faces(paths: &[String]) -> Arc<Vec<Font>> {
    let key = paths.join("\u{1F}");
    let cache = EXTRA_FONT_FACES_CACHE.get_or_init(|| Mutex::new(HashMap::new()));

    {
        let guard = cache.lock().unwrap();
        if let Some(cached) = guard.get(&key) {
            return cached.clone();
        }
    }

    let mut faces: Vec<Font> = Vec::new();
    let mut failed = 0usize;
    for path in paths {
        match std::fs::read(path) {
            Ok(data) => {
                for font in Font::iter(Bytes::new(data)) {
                    faces.push(font);
                }
            }
            Err(e) => {
                let _ = &e;
                debug_log!("[typst-ffi] FAILED to read font: {} — {}", path, e);
                failed += 1;
            }
        }
    }
    let _ = failed;
    debug_log!(
        "[typst-ffi] extra font cache miss: {} faces, {} files failed",
        faces.len(),
        failed
    );

    let faces = Arc::new(faces);
    let mut guard = cache.lock().unwrap();
    if guard.len() >= EXTRA_FONT_CACHE_LIMIT {
        guard.clear();
    }
    guard.insert(key, faces.clone());
    faces
}

/// Download a `.tar.gz` from `url` and extract it into `dest`.
fn download_and_extract(url: &str, dest: &Path) -> Result<PathBuf, PackageError> {
    let response = ureq::get(url)
        .call()
        .map_err(|e| PackageError::NetworkFailed(Some(format!("{e}").into())))?;

    let mut buf = Vec::new();
    response
        .into_reader()
        .read_to_end(&mut buf)
        .map_err(|e| PackageError::NetworkFailed(Some(format!("{e}").into())))?;

    let staging_dir = make_staging_directory(dest)
        .map_err(|e| PackageError::Other(Some(e.into())))?;
    if let Err(error) = extract_tar_gz_bytes(&buf, &staging_dir) {
        let _ = std::fs::remove_dir_all(&staging_dir);
        return Err(PackageError::MalformedArchive(Some(error.into())));
    }

    match std::fs::rename(&staging_dir, dest) {
        Ok(()) => {}
        Err(_) if dest.exists() => {
            let _ = std::fs::remove_dir_all(&staging_dir);
        }
        Err(error) => {
            let _ = std::fs::remove_dir_all(&staging_dir);
            return Err(PackageError::Other(Some(
                format!("rename failed: {error}").into(),
            )));
        }
    }

    Ok(dest.to_owned())
}

fn make_staging_directory(dest: &Path) -> Result<PathBuf, String> {
    let parent = dest
        .parent()
        .ok_or_else(|| format!("invalid destination path: {}", dest.display()))?;
    std::fs::create_dir_all(parent).map_err(|e| format!("mkdir failed: {e}"))?;

    let suffix = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|e| format!("clock error: {e}"))?
        .as_nanos();
    let file_name = dest
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("package");
    let staging_dir = parent.join(format!(".{file_name}.extracting-{suffix}"));

    if staging_dir.exists() {
        std::fs::remove_dir_all(&staging_dir).map_err(|e| format!("cleanup failed: {e}"))?;
    }
    std::fs::create_dir_all(&staging_dir).map_err(|e| format!("mkdir failed: {e}"))?;
    Ok(staging_dir)
}

fn extract_tar_gz_bytes(bytes: &[u8], dest: &Path) -> Result<(), String> {
    let gz = flate2::read::GzDecoder::new(std::io::Cursor::new(bytes));
    let mut archive = tar::Archive::new(gz);

    let entries = archive
        .entries()
        .map_err(|e| format!("archive entries failed: {e}"))?;

    for entry in entries {
        let mut entry = entry.map_err(|e| format!("archive entry failed: {e}"))?;
        let entry_type = entry.header().entry_type();

        if entry_type.is_symlink() || entry_type.is_hard_link() {
            return Err("archive contains unsupported link entries".to_string());
        }

        let relative_path = sanitized_archive_path(
            &entry
                .path()
                .map_err(|e| format!("archive path failed: {e}"))?,
        )?;

        if relative_path.as_os_str().is_empty() {
            continue;
        }

        let target_path = dest.join(&relative_path);
        if entry_type.is_dir() {
            std::fs::create_dir_all(&target_path).map_err(|e| format!("mkdir failed: {e}"))?;
            continue;
        }

        if !entry_type.is_file() {
            return Err(format!("archive contains unsupported entry type: {entry_type:?}"));
        }

        if let Some(parent) = target_path.parent() {
            std::fs::create_dir_all(parent).map_err(|e| format!("mkdir failed: {e}"))?;
        }
        entry
            .unpack(&target_path)
            .map_err(|e| format!("extract failed: {e}"))?;
    }

    Ok(())
}

fn sanitized_archive_path(path: &Path) -> Result<PathBuf, String> {
    let mut sanitized = PathBuf::new();

    for component in path.components() {
        match component {
            Component::CurDir => continue,
            Component::Normal(part) => sanitized.push(part),
            Component::Prefix(_) | Component::RootDir | Component::ParentDir => {
                return Err(format!("unsafe archive path: {}", path.display()));
            }
        }
    }

    Ok(sanitized)
}

impl World for SimpleWorld {
    fn library(&self) -> &LazyHash<Library> {
        &self.library
    }

    fn book(&self) -> &LazyHash<FontBook> {
        &self.book
    }

    fn main(&self) -> FileId {
        self.main_id
    }

    fn source(&self, id: FileId) -> FileResult<Source> {
        if id == self.main_id {
            return Ok(self.source.clone());
        }

        // Check cache first
        if let Some(src) = self.source_cache.lock().unwrap().get(&id).cloned() {
            return Ok(src);
        }

        // Resolve the file path
        let path = if let Some(spec) = id.package() {
            let pkg_dir = self.package_dir(spec)?;
            pkg_dir.join(id.vpath().as_rootless_path())
        } else {
            // Local file — resolve against root_dir
            let root = self.root_dir.as_ref().ok_or_else(|| {
                FileError::NotFound(id.vpath().as_rootless_path().to_owned())
            })?;
            root.join(id.vpath().as_rootless_path())
        };

        let text = std::fs::read_to_string(&path)
            .map_err(|_| FileError::NotFound(path.clone()))?;
        let src = Source::new(id, text);
        self.source_cache.lock().unwrap().insert(id, src.clone());
        Ok(src)
    }

    fn file(&self, id: FileId) -> FileResult<Bytes> {
        // Check cache first
        if let Some(b) = self.file_cache.lock().unwrap().get(&id).cloned() {
            return Ok(b);
        }

        // Resolve the file path
        let path = if let Some(spec) = id.package() {
            let pkg_dir = self.package_dir(spec)?;
            pkg_dir.join(id.vpath().as_rootless_path())
        } else {
            // Local file (e.g. images) — resolve against root_dir
            let root = self.root_dir.as_ref().ok_or_else(|| {
                FileError::NotFound(id.vpath().as_rootless_path().to_owned())
            })?;
            root.join(id.vpath().as_rootless_path())
        };

        let data = std::fs::read(&path)
            .map_err(|_| FileError::NotFound(path.clone()))?;
        let bytes = Bytes::new(data);
        self.file_cache.lock().unwrap().insert(id, bytes.clone());
        Ok(bytes)
    }

    fn font(&self, index: usize) -> Option<Font> {
        self.fonts.get(index).cloned()
    }

    fn today(&self, offset: Option<i64>) -> Option<Datetime> {
        use std::time::{SystemTime, UNIX_EPOCH};
        let secs = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs() as i64;
        let total = secs + offset.unwrap_or(0) * 3600;
        let (y, m, d) = unix_days_to_ymd((total / 86400) as i32);
        Datetime::from_ymd(y, m, d)
    }
}

/// https://howardhinnant.github.io/date_algorithms.html
fn unix_days_to_ymd(mut days: i32) -> (i32, u8, u8) {
    days += 719468;
    let era = days.div_euclid(146097);
    let doe = days.rem_euclid(146097) as u32;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe as i32 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    (y, m as u8, d as u8)
}

// ---------------------------------------------------------------------------
// C FFI — result type and compile/free functions
// ---------------------------------------------------------------------------

/// Result returned across the FFI boundary. Free with `typst_free_result`.
#[repr(C)]
pub struct TypstResult {
    pub pdf_data: *mut u8,
    pub pdf_len: usize,
    pub error_message: *mut c_char,
    pub success: bool,
}

/// Compile Typst source to PDF.
///
/// # Safety
/// `source` must be a valid null-terminated UTF-8 C string.
/// `options` may be null (disables CJK fonts and package downloads).
/// Free the result with `typst_free_result`.
#[no_mangle]
pub unsafe extern "C" fn typst_compile(
    source: *const c_char,
    options: *const TypstOptions,
) -> TypstResult {
    match catch_unwind(AssertUnwindSafe(|| unsafe { typst_compile_impl(source, options) })) {
        Ok(result) => result,
        Err(_) => error_result("Typst compiler panicked"),
    }
}

unsafe fn typst_compile_impl(
    source: *const c_char,
    options: *const TypstOptions,
) -> TypstResult {
    if source.is_null() {
        return error_result("null source pointer");
    }
    let source_str = match CStr::from_ptr(source).to_str() {
        Ok(s) => s,
        Err(_) => return error_result("source is not valid UTF-8"),
    };

    let world = SimpleWorld::new(source_str, options);

    match typst::compile::<PagedDocument>(&world).output {
        Ok(document) => match pdf(&document, &PdfOptions::default()) {
            Ok(bytes) => {
                let len = bytes.len();
                let mut boxed = bytes.into_boxed_slice();
                let ptr = boxed.as_mut_ptr();
                std::mem::forget(boxed);
                TypstResult {
                    pdf_data: ptr,
                    pdf_len: len,
                    error_message: std::ptr::null_mut(),
                    success: true,
                }
            }
            Err(e) => error_result(&format_diagnostics(&world, &e)),
        },
        Err(e) => error_result(&format_diagnostics(&world, &e)),
    }
}

/// Free a `TypstResult` returned by `typst_compile`.
///
/// # Safety
/// Must have been returned by `typst_compile` and not yet freed.
#[no_mangle]
pub unsafe extern "C" fn typst_free_result(result: TypstResult) {
    if !result.pdf_data.is_null() {
        let slice_ptr = std::ptr::slice_from_raw_parts_mut(result.pdf_data, result.pdf_len);
        drop(Box::from_raw(slice_ptr));
    }
    if !result.error_message.is_null() {
        drop(CString::from_raw(result.error_message));
    }
}

// ---------------------------------------------------------------------------
// C FFI — source map types and compile-with-source-map
// ---------------------------------------------------------------------------

/// A single source-map entry mapping a PDF position to a source location.
#[derive(Clone, Copy)]
#[repr(C)]
pub struct SourceMapEntry {
    /// 0-based page index.
    pub page: u32,
    /// Y position in PDF points from the top of the page.
    pub y_pt: f32,
    /// X position in PDF points from the left of the page.
    pub x_pt: f32,
    /// Byte offset in the source file.
    pub source_offset: u32,
    /// Byte length of the mapped source range.
    pub source_length: u16,
    /// 1-based line number.
    pub line: u32,
    /// 1-based column number.
    pub column: u16,
}

/// Extended result that includes both PDF data and a source map.
/// Free with `typst_free_result_with_map`.
#[repr(C)]
pub struct TypstResultWithMap {
    pub pdf_data: *mut u8,
    pub pdf_len: usize,
    pub error_message: *mut c_char,
    pub success: bool,
    pub source_map: *mut SourceMapEntry,
    pub source_map_len: usize,
}

/// Walk a frame recursively, collecting source map entries for text items.
fn walk_frame(
    frame: &Frame,
    page_index: u32,
    transform: Transform,
    source: &Source,
    entries: &mut Vec<SourceMapEntry>,
) {
    for (pos, item) in frame.items() {
        let point = Point::new(pos.x, pos.y).transform(transform);

        match item {
            FrameItem::Text(text_item) => {
                // Use the first glyph's span for this text run.
                if let Some(glyph) = text_item.glyphs.first() {
                    let span = glyph.span.0;
                    if span.is_detached() {
                        continue;
                    }
                    // Only map spans from the main source file.
                    if let Some(id) = span.id() {
                        if id != source.id() {
                            continue;
                        }
                    } else {
                        continue;
                    }
                    if let Some(range) = source.range(span).or_else(|| span.range()) {
                        if let Some((line, col)) = source.lines().byte_to_line_column(range.start) {
                            entries.push(SourceMapEntry {
                                page: page_index,
                                y_pt: point.y.to_pt() as f32,
                                x_pt: point.x.to_pt() as f32,
                                source_offset: range.start as u32,
                                source_length: (range.end - range.start).min(u16::MAX as usize) as u16,
                                line: (line + 1) as u32,
                                column: (col + 1) as u16,
                            });
                        }
                    }
                }
            }
            FrameItem::Group(group) => {
                let group_transform = transform
                    .pre_concat(Transform::translate(pos.x, pos.y))
                    .pre_concat(group.transform);
                walk_frame(&group.frame, page_index, group_transform, source, entries);
            }
            _ => {}
        }
    }
}

/// Extract a source map from a compiled document.
/// Returns entries sorted by source offset, deduplicated so that each source
/// span maps to a single PDF position (the body occurrence, not TOC/header
/// duplicates).
fn extract_source_map(document: &PagedDocument, source: &Source) -> Vec<SourceMapEntry> {
    let mut entries = Vec::new();

    for (page_index, page) in document.pages.iter().enumerate() {
        walk_frame(
            &page.frame,
            page_index as u32,
            Transform::identity(),
            source,
            &mut entries,
        );
    }

    // Sort by source offset.
    entries.sort_by_key(|e| e.source_offset);

    // Deduplicate entries that share the same source_offset (same source span
    // rendered in multiple places, e.g. outline/TOC, body heading, page header).
    // For each group, pick the entry whose page best matches the surrounding
    // body content — the nearest entry on a different source offset tells us
    // which page the body flow is on.
    deduplicate_source_map(&mut entries);

    entries
}

/// For groups of entries sharing the same `source_offset` that span multiple
/// pages (e.g. heading text rendered in TOC, body, and page headers), keep
/// only the entries on the "body" page.  Groups that are all on the same page
/// (e.g. wrapped text) are left untouched.
fn deduplicate_source_map(entries: &mut Vec<SourceMapEntry>) {
    if entries.len() <= 1 {
        return;
    }

    // Phase 1 — identify offset groups and whether they span multiple pages.
    //   (start, end, multi_page)
    let mut groups: Vec<(usize, usize, bool)> = Vec::new();
    {
        let mut i = 0;
        while i < entries.len() {
            let offset = entries[i].source_offset;
            let mut j = i + 1;
            while j < entries.len() && entries[j].source_offset == offset {
                j += 1;
            }
            let multi = entries[i..j].windows(2).any(|w| w[0].page != w[1].page);
            groups.push((i, j, multi));
            i = j;
        }
    }

    // Phase 2 — for each multi-page group, find the body page by looking at
    // the nearest *single-page* (non-duplicate) group's page.
    let mut result: Vec<SourceMapEntry> = Vec::with_capacity(entries.len());

    for (gi, &(start, end, multi)) in groups.iter().enumerate() {
        if !multi {
            // All entries on the same page — keep every entry (line wrapping).
            result.extend_from_slice(&entries[start..end]);
            continue;
        }

        // Find reference page from the nearest single-page group.
        // Prefer FORWARD neighbours — body content after a heading is on
        // the same page as the heading itself, whereas backward neighbours
        // (e.g. document title / TOC preamble) may sit on the TOC page.
        let ref_page = {
            let mut found = None;
            // Forward search first.
            for d in 1..groups.len() {
                if gi + d < groups.len() {
                    let (gs, _, gm) = groups[gi + d];
                    if !gm {
                        found = Some(entries[gs].page);
                        break;
                    }
                }
            }
            // Backward search only if nothing found forwards.
            if found.is_none() {
                for d in 1..groups.len() {
                    if gi >= d {
                        let (gs, _, gm) = groups[gi - d];
                        if !gm {
                            found = Some(entries[gs].page);
                            break;
                        }
                    }
                }
            }
            // Fallback: highest page (body is after TOC).
            found.unwrap_or(entries[end - 1].page)
        };

        // Determine which page in this group is closest to ref_page.
        let mut best_page = entries[start].page;
        let mut best_dist = best_page.abs_diff(ref_page);
        for k in (start + 1)..end {
            let dist = entries[k].page.abs_diff(ref_page);
            if dist < best_dist {
                best_page = entries[k].page;
                best_dist = dist;
            }
        }

        // Keep all entries on the best page (preserves wrapped text on the body page).
        for k in start..end {
            if entries[k].page == best_page {
                result.push(entries[k]);
            }
        }
    }

    *entries = result;
}

/// Compile Typst source to PDF and extract a source map.
///
/// # Safety
/// Same requirements as `typst_compile`.
/// Free the result with `typst_free_result_with_map`.
#[no_mangle]
pub unsafe extern "C" fn typst_compile_with_source_map(
    source: *const c_char,
    options: *const TypstOptions,
) -> TypstResultWithMap {
    match catch_unwind(AssertUnwindSafe(|| unsafe {
        typst_compile_with_source_map_impl(source, options)
    })) {
        Ok(result) => result,
        Err(_) => error_result_with_map("Typst compiler panicked"),
    }
}

unsafe fn typst_compile_with_source_map_impl(
    source: *const c_char,
    options: *const TypstOptions,
) -> TypstResultWithMap {
    if source.is_null() {
        return error_result_with_map("null source pointer");
    }
    let source_str = match CStr::from_ptr(source).to_str() {
        Ok(s) => s,
        Err(_) => return error_result_with_map("source is not valid UTF-8"),
    };

    let world = SimpleWorld::new(source_str, options);

    match typst::compile::<PagedDocument>(&world).output {
        Ok(document) => {
            let map_entries = extract_source_map(&document, &world.source);

            match pdf(&document, &PdfOptions::default()) {
                Ok(bytes) => {
                    let pdf_len = bytes.len();
                    let mut pdf_boxed = bytes.into_boxed_slice();
                    let pdf_ptr = pdf_boxed.as_mut_ptr();
                    std::mem::forget(pdf_boxed);

                    let map_len = map_entries.len();
                    let (map_ptr, map_len) = if map_len > 0 {
                        let mut map_boxed = map_entries.into_boxed_slice();
                        let ptr = map_boxed.as_mut_ptr();
                        std::mem::forget(map_boxed);
                        (ptr, map_len)
                    } else {
                        (std::ptr::null_mut(), 0)
                    };

                    TypstResultWithMap {
                        pdf_data: pdf_ptr,
                        pdf_len,
                        error_message: std::ptr::null_mut(),
                        success: true,
                        source_map: map_ptr,
                        source_map_len: map_len,
                    }
                }
                Err(e) => error_result_with_map(&format_diagnostics(&world, &e)),
            }
        }
        Err(e) => error_result_with_map(&format_diagnostics(&world, &e)),
    }
}

/// Free a `TypstResultWithMap`.
///
/// # Safety
/// Must have been returned by `typst_compile_with_source_map` and not yet freed.
#[no_mangle]
pub unsafe extern "C" fn typst_free_result_with_map(result: TypstResultWithMap) {
    if !result.pdf_data.is_null() {
        let slice_ptr = std::ptr::slice_from_raw_parts_mut(result.pdf_data, result.pdf_len);
        drop(Box::from_raw(slice_ptr));
    }
    if !result.error_message.is_null() {
        drop(CString::from_raw(result.error_message));
    }
    if !result.source_map.is_null() {
        let slice_ptr =
            std::ptr::slice_from_raw_parts_mut(result.source_map, result.source_map_len);
        drop(Box::from_raw(slice_ptr));
    }
}

/// Get the embedded typst-ios crate version.
///
/// Returns a pointer to a static null-terminated UTF-8 string.
#[no_mangle]
pub extern "C" fn typst_version() -> *const c_char {
    static VERSION: &str = concat!(env!("CARGO_PKG_VERSION"), "\0");
    VERSION.as_ptr() as *const c_char
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn error_result(msg: &str) -> TypstResult {
    let c = CString::new(msg).unwrap_or_else(|_| CString::new("error").unwrap());
    TypstResult {
        pdf_data: std::ptr::null_mut(),
        pdf_len: 0,
        error_message: c.into_raw(),
        success: false,
    }
}

fn error_result_with_map(msg: &str) -> TypstResultWithMap {
    let c = CString::new(msg).unwrap_or_else(|_| CString::new("error").unwrap());
    TypstResultWithMap {
        pdf_data: std::ptr::null_mut(),
        pdf_len: 0,
        error_message: c.into_raw(),
        success: false,
        source_map: std::ptr::null_mut(),
        source_map_len: 0,
    }
}

fn format_diagnostics(world: &SimpleWorld, diags: &[SourceDiagnostic]) -> String {
    diags
        .iter()
        .map(|diag| format_diagnostic(world, diag))
        .collect::<Vec<_>>()
        .join("\n\n")
}

fn format_diagnostic(world: &SimpleWorld, diag: &SourceDiagnostic) -> String {
    let mut lines = vec![diag.message.to_string()];

    if let Some(location) = world.format_span_location(diag.span) {
        lines.push(format!("({location})"));
    }

    lines.extend(diag.hints.iter().map(|hint| format!("Hint: {hint}")));

    lines.join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;
    use flate2::Compression;
    use flate2::write::GzEncoder;
    use tar::{Builder, EntryType, Header};

    #[test]
    fn extract_tar_gz_bytes_extracts_regular_files() {
        let archive = build_tar_gz(vec![
            TarEntry::file("main.typ", b"hello"),
            TarEntry::file("nested/image.png", &[1, 2, 3]),
        ]);
        let dest = make_temp_dir();

        extract_tar_gz_bytes(&archive, &dest).unwrap();

        assert_eq!(std::fs::read_to_string(dest.join("main.typ")).unwrap(), "hello");
        assert_eq!(std::fs::read(dest.join("nested/image.png")).unwrap(), vec![1, 2, 3]);

        let _ = std::fs::remove_dir_all(dest);
    }

    #[test]
    fn extract_tar_gz_bytes_rejects_parent_traversal() {
        let error = sanitized_archive_path(Path::new("../escape.typ")).unwrap_err();

        assert!(error.contains("unsafe archive path"));
    }

    #[test]
    fn extract_tar_gz_bytes_rejects_symlink_entries() {
        let archive = build_tar_gz(vec![TarEntry::symlink("assets/link", "../outside")]);
        let dest = make_temp_dir();

        let error = extract_tar_gz_bytes(&archive, &dest).unwrap_err();

        assert!(error.contains("unsupported link entries"));
        let _ = std::fs::remove_dir_all(dest);
    }

    #[test]
    fn format_diagnostics_includes_source_location() {
        let world = unsafe { SimpleWorld::new("= broken", std::ptr::null()) };
        let span = Span::from_range(world.main(), 0..1);
        let rendered =
            format_diagnostics(&world, &[SourceDiagnostic::error(span, "unexpected token")]);

        assert!(rendered.contains("unexpected token"));
        assert!(rendered.contains("(main.typ:1:1)"));
    }

    #[test]
    fn extract_source_map_produces_entries() {
        let source_text = "= Hello World\n\nThis is a test paragraph.";
        let world = unsafe { SimpleWorld::new(source_text, std::ptr::null()) };
        let compiled = typst::compile::<PagedDocument>(&world);
        let document = compiled.output.expect("compilation should succeed");
        let entries = extract_source_map(&document, &world.source);

        assert!(!entries.is_empty(), "source map should have entries");
        // All entries should be on page 0 for a simple document.
        assert!(entries.iter().all(|e| e.page == 0));
        // Lines should be 1-based and > 0.
        assert!(entries.iter().all(|e| e.line >= 1));
        // Columns should be 1-based and > 0.
        assert!(entries.iter().all(|e| e.column >= 1));
    }

    #[test]
    fn extract_source_map_preserves_multiple_entries_for_same_source_line() {
        let source_text = concat!(
            "#set page(width: 120pt, height: 200pt, margin: 8pt)\n",
            "This is a deliberately long source line that should wrap into multiple rendered lines ",
            "so the source map keeps more than one entry for the same original line."
        );
        let world = unsafe { SimpleWorld::new(source_text, std::ptr::null()) };
        let compiled = typst::compile::<PagedDocument>(&world);
        let document = compiled.output.expect("compilation should succeed");
        let entries = extract_source_map(&document, &world.source);

        let wrapped_line_entries: Vec<_> = entries.iter().filter(|entry| entry.line == 2).collect();

        assert!(
            wrapped_line_entries.len() > 1,
            "expected multiple source-map entries for the wrapped source line, got {}",
            wrapped_line_entries.len()
        );
        assert!(
            wrapped_line_entries
                .windows(2)
                .any(|pair| pair[0].x_pt != pair[1].x_pt || pair[0].y_pt != pair[1].y_pt),
            "expected wrapped entries to preserve multiple rendered positions"
        );
    }

    #[test]
    fn simple_world_ignores_null_font_paths_array() {
        let options = TypstOptions {
            font_paths: std::ptr::null(),
            font_path_count: 1,
            cache_dir: std::ptr::null(),
            root_dir: std::ptr::null(),
            local_packages_dir: std::ptr::null(),
        };

        let world = unsafe { SimpleWorld::new("= Hello", &options) };
        let bundled_count = bundled_font_faces().len();

        assert_eq!(world.fonts.len(), bundled_count);
    }

    #[test]
    fn simple_world_ignores_empty_cache_dir() {
        let empty_cache = CString::new("").unwrap();
        let options = TypstOptions {
            font_paths: std::ptr::null(),
            font_path_count: 0,
            cache_dir: empty_cache.as_ptr(),
            root_dir: std::ptr::null(),
            local_packages_dir: std::ptr::null(),
        };

        let world = unsafe { SimpleWorld::new("= Hello", &options) };

        assert!(world.pkg_cache_root.is_none());
    }

    #[test]
    fn typst_pdf_embeds_sbix_emoji_as_image_xobject() {
        let emoji_font = Path::new("/System/Library/Fonts/Apple Color Emoji.ttc");
        if !emoji_font.exists() {
            return;
        }

        let source = CString::new(
            r#"#set page(width: 120pt, height: 120pt, margin: 12pt)
#set text(font: "Apple Color Emoji", size: 72pt)
😀"#,
        )
        .unwrap();
        let font_path = CString::new(emoji_font.to_string_lossy().as_bytes()).unwrap();
        let font_paths = [font_path.as_ptr()];
        let options = TypstOptions {
            font_paths: font_paths.as_ptr(),
            font_path_count: font_paths.len(),
            cache_dir: std::ptr::null(),
            root_dir: std::ptr::null(),
            local_packages_dir: std::ptr::null(),
        };

        let result = unsafe { typst_compile_impl(source.as_ptr(), &options) };
        assert!(
            result.success,
            "{}",
            if result.error_message.is_null() {
                "compile failed without an error message".to_string()
            } else {
                unsafe { CStr::from_ptr(result.error_message) }
                    .to_string_lossy()
                    .into_owned()
            }
        );

        let pdf = unsafe { std::slice::from_raw_parts(result.pdf_data, result.pdf_len) }.to_vec();
        unsafe { typst_free_result(result) };

        assert!(
            pdf.windows(b"/Subtype /Image".len())
                .any(|window| window == b"/Subtype /Image"),
            "sbix emoji should be emitted as a PDF image XObject"
        );
    }

    #[derive(Clone)]
    struct TarEntry<'a> {
        path: &'a str,
        entry_type: EntryType,
        data: &'a [u8],
        link_name: Option<&'a str>,
    }

    impl<'a> TarEntry<'a> {
        fn file(path: &'a str, data: &'a [u8]) -> Self {
            Self {
                path,
                entry_type: EntryType::Regular,
                data,
                link_name: None,
            }
        }
        fn symlink(path: &'a str, target: &'a str) -> Self {
            Self {
                path,
                entry_type: EntryType::Symlink,
                data: &[],
                link_name: Some(target),
            }
        }
    }

    fn build_tar_gz(entries: Vec<TarEntry<'_>>) -> Vec<u8> {
        let encoder = GzEncoder::new(Vec::new(), Compression::default());
        let mut builder = Builder::new(encoder);

        for entry in entries {
            let mut header = Header::new_gnu();
            header.set_entry_type(entry.entry_type);
            header.set_mode(if entry.entry_type.is_dir() { 0o755 } else { 0o644 });
            header.set_size(entry.data.len() as u64);
            if let Some(link_name) = entry.link_name {
                header.set_link_name(link_name).unwrap();
            }
            header.set_cksum();
            builder
                .append_data(&mut header, entry.path, entry.data)
                .unwrap();
        }

        builder.into_inner().unwrap().finish().unwrap()
    }

    fn make_temp_dir() -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "typst-ios-tests-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }
}
