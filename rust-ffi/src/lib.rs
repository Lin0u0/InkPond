use std::collections::{HashMap, HashSet};
use std::ffi::{CStr, CString};
use std::io::Read;
use std::os::raw::c_char;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::{Component, Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};

use syntect::easy::ScopeRangeIterator;
use syntect::parsing::{ParseState, Scope, ScopeStack};
use typst::diag::{FileError, FileResult, PackageError, SourceDiagnostic};
use typst::foundations::{Bytes, CastInfo, Datetime, Repr, Value};
use typst::layout::{Frame, FrameItem, PagedDocument, Point, Transform};
use typst::syntax::ast::AstNode;
use typst::syntax::package::PackageSpec;
use typst::syntax::{
    ast, highlight, parse, FileId, LinkedNode, Side, Source, Span, SyntaxKind, Tag, VirtualPath,
};
use typst::text::{Font, FontBook};
use typst::utils::LazyHash;
use typst::{Library, LibraryExt, World};
use typst_library::text::RAW_SYNTAXES;
use typst_pdf::{pdf, PdfOptions};

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

            debug_log!(
                "[typst-ffi] font_path_count from Swift: {}",
                opts.font_path_count
            );

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

        let cache_root = self.pkg_cache_root.as_ref().ok_or_else(|| {
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

    let staging_dir =
        make_staging_directory(dest).map_err(|e| PackageError::Other(Some(e.into())))?;
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
            return Err(format!(
                "archive contains unsupported entry type: {entry_type:?}"
            ));
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
            let root = self
                .root_dir
                .as_ref()
                .ok_or_else(|| FileError::NotFound(id.vpath().as_rootless_path().to_owned()))?;
            root.join(id.vpath().as_rootless_path())
        };

        let text = std::fs::read_to_string(&path).map_err(|_| FileError::NotFound(path.clone()))?;
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
            let root = self
                .root_dir
                .as_ref()
                .ok_or_else(|| FileError::NotFound(id.vpath().as_rootless_path().to_owned()))?;
            root.join(id.vpath().as_rootless_path())
        };

        let data = std::fs::read(&path).map_err(|_| FileError::NotFound(path.clone()))?;
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
    match catch_unwind(AssertUnwindSafe(|| unsafe {
        typst_compile_impl(source, options)
    })) {
        Ok(result) => result,
        Err(_) => error_result("Typst compiler panicked"),
    }
}

unsafe fn typst_compile_impl(source: *const c_char, options: *const TypstOptions) -> TypstResult {
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
                                source_length: (range.end - range.start).min(u16::MAX as usize)
                                    as u16,
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

// ---------------------------------------------------------------------------
// C FFI — syntax highlighting
// ---------------------------------------------------------------------------

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(C)]
pub struct TypstHighlightToken {
    /// UTF-16 code-unit offset for NSTextStorage/NSRange.
    pub utf16_location: u32,
    /// UTF-16 code-unit length for NSTextStorage/NSRange.
    pub utf16_length: u32,
    /// Numeric value matching typst_syntax::Tag order.
    pub tag: u32,
}

/// Result returned by `typst_highlight`.
#[repr(C)]
pub struct TypstHighlightResult {
    pub tokens: *mut TypstHighlightToken,
    pub token_len: usize,
    pub error_message: *mut c_char,
    pub success: bool,
}

/// Parse Typst source and return syntax-highlight tokens.
///
/// # Safety
/// `source` must be a valid null-terminated UTF-8 C string.
/// Free the result with `typst_free_highlight_result`.
#[no_mangle]
pub unsafe extern "C" fn typst_highlight(source: *const c_char) -> TypstHighlightResult {
    match catch_unwind(AssertUnwindSafe(|| unsafe { typst_highlight_impl(source) })) {
        Ok(result) => result,
        Err(_) => error_highlight_result("Typst highlighter panicked"),
    }
}

unsafe fn typst_highlight_impl(source: *const c_char) -> TypstHighlightResult {
    if source.is_null() {
        return error_highlight_result("null source pointer");
    }
    let source_str = match CStr::from_ptr(source).to_str() {
        Ok(s) => s,
        Err(_) => return error_highlight_result("source is not valid UTF-8"),
    };

    let tokens = highlight_tokens_for_source(source_str);
    let token_len = tokens.len();
    let (tokens, token_len) = if token_len > 0 {
        let mut boxed = tokens.into_boxed_slice();
        let ptr = boxed.as_mut_ptr();
        std::mem::forget(boxed);
        (ptr, token_len)
    } else {
        (std::ptr::null_mut(), 0)
    };

    TypstHighlightResult {
        tokens,
        token_len,
        error_message: std::ptr::null_mut(),
        success: true,
    }
}

fn highlight_tokens_for_source(source: &str) -> Vec<TypstHighlightToken> {
    let root = parse(source);
    let byte_to_utf16 = byte_to_utf16_offsets(source);
    let mut tokens = Vec::new();
    collect_highlight_tokens(&mut tokens, &LinkedNode::new(&root), &byte_to_utf16);
    tokens
}

fn collect_highlight_tokens(
    tokens: &mut Vec<TypstHighlightToken>,
    node: &LinkedNode,
    byte_to_utf16: &[usize],
) {
    if let Some(tag) = highlight(node) {
        let range = node.range();
        if let Some(token) = highlight_token(range.start, range.end, tag, byte_to_utf16) {
            tokens.push(token);
        }

        if tag == Tag::Raw {
            collect_embedded_raw_tokens(tokens, node, byte_to_utf16);
        }
    }

    for child in node.children() {
        collect_highlight_tokens(tokens, &child, byte_to_utf16);
    }
}

fn collect_embedded_raw_tokens(
    tokens: &mut Vec<TypstHighlightToken>,
    raw_node: &LinkedNode,
    byte_to_utf16: &[usize],
) {
    let Some(language) = raw_node.children().find_map(|child| {
        (child.kind() == SyntaxKind::RawLang).then(|| child.text().as_str().to_ascii_lowercase())
    }) else {
        return;
    };

    let syntax_set = &*RAW_SYNTAXES;
    let Some(syntax) = syntax_set.find_syntax_by_token(&language) else {
        return;
    };

    let mut parse_state = ParseState::new(syntax);
    let mut scope_stack = ScopeStack::new();

    for child in raw_node.children() {
        if child.kind() != SyntaxKind::Text {
            continue;
        }

        let line = child.text();
        let Ok(ops) = parse_state.parse_line(line.as_str(), syntax_set) else {
            return;
        };

        for (range, op) in ScopeRangeIterator::new(&ops, line.as_str()) {
            if scope_stack.apply(op).is_err() {
                return;
            }
            if range.is_empty() {
                continue;
            }

            let Some(tag) = embedded_raw_tag(&scope_stack) else {
                continue;
            };
            push_highlight_token(
                tokens,
                child.range().start + range.start,
                child.range().start + range.end,
                tag,
                byte_to_utf16,
            );
        }
    }
}

fn embedded_raw_tag(scope_stack: &ScopeStack) -> Option<Tag> {
    for (scope, tag) in embedded_raw_scope_tags() {
        if scope_stack
            .as_slice()
            .iter()
            .any(|active| scope.is_prefix_of(*active))
        {
            return Some(*tag);
        }
    }

    None
}

fn embedded_raw_scope_tags() -> &'static [(Scope, Tag)] {
    static TAGS: OnceLock<Vec<(Scope, Tag)>> = OnceLock::new();

    TAGS.get_or_init(|| {
        [
            ("invalid", Tag::Error),
            ("comment", Tag::Comment),
            ("string", Tag::String),
            ("constant.character.escape", Tag::Escape),
            ("constant.numeric", Tag::Number),
            ("keyword.operator", Tag::Operator),
            ("punctuation.definition.string", Tag::String),
            ("punctuation.definition.comment", Tag::Comment),
            ("storage", Tag::Keyword),
            ("keyword", Tag::Keyword),
            ("constant.language", Tag::Keyword),
            ("variable.language", Tag::Keyword),
            ("entity.name.function", Tag::Function),
            ("variable.function", Tag::Function),
            ("support.function", Tag::Function),
            ("support.macro", Tag::Function),
            ("entity.name.type", Tag::Function),
            ("support.type", Tag::Function),
            ("support.class", Tag::Function),
            ("constant", Tag::Number),
            ("entity.name.label", Tag::Label),
            ("markup.heading", Tag::Heading),
            ("markup.bold", Tag::Strong),
            ("markup.italic", Tag::Emph),
            ("markup.underline", Tag::Link),
            ("punctuation", Tag::Punctuation),
        ]
        .into_iter()
        .map(|(scope, tag)| {
            (
                Scope::new(scope).expect("embedded raw highlight scope should be valid"),
                tag,
            )
        })
        .collect()
    })
}

fn push_highlight_token(
    tokens: &mut Vec<TypstHighlightToken>,
    byte_start: usize,
    byte_end: usize,
    tag: Tag,
    byte_to_utf16: &[usize],
) {
    let Some(token) = highlight_token(byte_start, byte_end, tag, byte_to_utf16) else {
        return;
    };

    if let Some(last) = tokens.last_mut() {
        if last.tag == token.tag && last.utf16_location + last.utf16_length == token.utf16_location
        {
            last.utf16_length += token.utf16_length;
            return;
        }
    }

    tokens.push(token);
}

fn highlight_token(
    byte_start: usize,
    byte_end: usize,
    tag: Tag,
    byte_to_utf16: &[usize],
) -> Option<TypstHighlightToken> {
    if byte_start >= byte_end || byte_end >= byte_to_utf16.len() {
        return None;
    }

    let utf16_start = *byte_to_utf16.get(byte_start)?;
    let utf16_end = *byte_to_utf16.get(byte_end)?;
    if utf16_start >= utf16_end {
        return None;
    }

    Some(TypstHighlightToken {
        utf16_location: u32::try_from(utf16_start).ok()?,
        utf16_length: u32::try_from(utf16_end - utf16_start).ok()?,
        tag: highlight_tag_id(tag),
    })
}

fn byte_to_utf16_offsets(source: &str) -> Vec<usize> {
    let mut offsets = vec![0; source.len() + 1];
    let mut utf16_offset = 0;
    offsets[0] = 0;

    for (byte_offset, ch) in source.char_indices() {
        offsets[byte_offset] = utf16_offset;
        utf16_offset += ch.len_utf16();
        offsets[byte_offset + ch.len_utf8()] = utf16_offset;
    }

    offsets
}

fn highlight_tag_id(tag: Tag) -> u32 {
    match tag {
        Tag::Comment => 0,
        Tag::Punctuation => 1,
        Tag::Escape => 2,
        Tag::Strong => 3,
        Tag::Emph => 4,
        Tag::Link => 5,
        Tag::Raw => 6,
        Tag::Label => 7,
        Tag::Ref => 8,
        Tag::Heading => 9,
        Tag::ListMarker => 10,
        Tag::ListTerm => 11,
        Tag::MathDelimiter => 12,
        Tag::MathOperator => 13,
        Tag::Keyword => 14,
        Tag::Operator => 15,
        Tag::Number => 16,
        Tag::String => 17,
        Tag::Function => 18,
        Tag::Interpolated => 19,
        Tag::Error => 20,
    }
}

/// Free a `TypstHighlightResult`.
///
/// # Safety
/// Must have been returned by `typst_highlight` and not yet freed.
#[no_mangle]
pub unsafe extern "C" fn typst_free_highlight_result(result: TypstHighlightResult) {
    if !result.tokens.is_null() {
        let slice_ptr = std::ptr::slice_from_raw_parts_mut(result.tokens, result.token_len);
        drop(Box::from_raw(slice_ptr));
    }
    if !result.error_message.is_null() {
        drop(CString::from_raw(result.error_message));
    }
}

// ---------------------------------------------------------------------------
// C FFI — outline extraction
// ---------------------------------------------------------------------------

#[repr(C)]
pub struct TypstOutlineItem {
    /// UTF-16 code-unit offset for NSTextStorage/NSRange.
    pub utf16_location: u32,
    /// Heading depth, where `= Title` is 1.
    pub level: u32,
    /// Null-terminated UTF-8 title.
    pub title: *mut c_char,
}

/// Result returned by `typst_outline`.
#[repr(C)]
pub struct TypstOutlineResult {
    pub items: *mut TypstOutlineItem,
    pub item_len: usize,
    pub error_message: *mut c_char,
    pub success: bool,
}

/// Parse Typst source and return heading outline entries.
///
/// # Safety
/// `source` must be a valid null-terminated UTF-8 C string.
/// Free the result with `typst_free_outline_result`.
#[no_mangle]
pub unsafe extern "C" fn typst_outline(source: *const c_char) -> TypstOutlineResult {
    match catch_unwind(AssertUnwindSafe(|| unsafe { typst_outline_impl(source) })) {
        Ok(result) => result,
        Err(_) => error_outline_result("Typst outline parser panicked"),
    }
}

unsafe fn typst_outline_impl(source: *const c_char) -> TypstOutlineResult {
    if source.is_null() {
        return error_outline_result("null source pointer");
    }
    let source_str = match CStr::from_ptr(source).to_str() {
        Ok(s) => s,
        Err(_) => return error_outline_result("source is not valid UTF-8"),
    };

    let items = outline_items_for_source(source_str);
    let item_len = items.len();
    let (items, item_len) = if item_len > 0 {
        let mut boxed = items.into_boxed_slice();
        let ptr = boxed.as_mut_ptr();
        std::mem::forget(boxed);
        (ptr, item_len)
    } else {
        (std::ptr::null_mut(), 0)
    };

    TypstOutlineResult {
        items,
        item_len,
        error_message: std::ptr::null_mut(),
        success: true,
    }
}

fn outline_items_for_source(source: &str) -> Vec<TypstOutlineItem> {
    let root = parse(source);
    let byte_to_utf16 = byte_to_utf16_offsets(source);
    let mut items = Vec::new();
    collect_outline_items(&mut items, &LinkedNode::new(&root), &byte_to_utf16);
    items
}

fn collect_outline_items(
    items: &mut Vec<TypstOutlineItem>,
    node: &LinkedNode,
    byte_to_utf16: &[usize],
) {
    if let Some(heading) = node.get().cast::<ast::Heading>() {
        if let Some(item) = outline_item(node, heading, byte_to_utf16) {
            items.push(item);
        }
    }

    for child in node.children() {
        collect_outline_items(items, &child, byte_to_utf16);
    }
}

fn outline_item(
    node: &LinkedNode,
    heading: ast::Heading,
    byte_to_utf16: &[usize],
) -> Option<TypstOutlineItem> {
    let range = node.range();
    let utf16_location = *byte_to_utf16.get(range.start)?;
    let title = heading_title(heading);
    if title.is_empty() {
        return None;
    }

    Some(TypstOutlineItem {
        utf16_location: u32::try_from(utf16_location).ok()?,
        level: u32::try_from(heading.depth().get()).ok()?,
        title: CString::new(title).ok()?.into_raw(),
    })
}

fn heading_title(heading: ast::Heading) -> String {
    let mut title = String::new();
    collect_heading_title_text(heading.body().to_untyped(), &mut title);
    title.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn collect_heading_title_text(node: &typst::syntax::SyntaxNode, title: &mut String) {
    match node.kind() {
        SyntaxKind::Label
        | SyntaxKind::HeadingMarker
        | SyntaxKind::LineComment
        | SyntaxKind::BlockComment => return,
        SyntaxKind::Space | SyntaxKind::Parbreak | SyntaxKind::Linebreak => {
            title.push(' ');
            return;
        }
        SyntaxKind::Text
        | SyntaxKind::Escape
        | SyntaxKind::Shorthand
        | SyntaxKind::SmartQuote
        | SyntaxKind::Link => {
            title.push_str(node.text());
            return;
        }
        _ => {}
    }

    for child in node.children() {
        collect_heading_title_text(child, title);
    }
}

/// Free a `TypstOutlineResult`.
///
/// # Safety
/// Must have been returned by `typst_outline` and not yet freed.
#[no_mangle]
pub unsafe extern "C" fn typst_free_outline_result(result: TypstOutlineResult) {
    if !result.items.is_null() {
        let slice = std::slice::from_raw_parts_mut(result.items, result.item_len);
        for item in slice {
            if !item.title.is_null() {
                drop(CString::from_raw(item.title));
            }
        }

        let slice_ptr = std::ptr::slice_from_raw_parts_mut(result.items, result.item_len);
        drop(Box::from_raw(slice_ptr));
    }
    if !result.error_message.is_null() {
        drop(CString::from_raw(result.error_message));
    }
}

// ---------------------------------------------------------------------------
// C FFI — label extraction
// ---------------------------------------------------------------------------

#[repr(C)]
pub struct TypstLabelItem {
    /// Null-terminated UTF-8 label name without angle brackets.
    pub name: *mut c_char,
    /// Null-terminated UTF-8 kind derived from the labelled syntax node.
    pub kind: *mut c_char,
}

/// Result returned by `typst_labels`.
#[repr(C)]
pub struct TypstLabelResult {
    pub items: *mut TypstLabelItem,
    pub item_len: usize,
    pub error_message: *mut c_char,
    pub success: bool,
}

/// Parse Typst source and return label definitions from the syntax tree.
///
/// # Safety
/// `source` must be a valid null-terminated UTF-8 C string.
/// Free the result with `typst_free_label_result`.
#[no_mangle]
pub unsafe extern "C" fn typst_labels(source: *const c_char) -> TypstLabelResult {
    match catch_unwind(AssertUnwindSafe(|| unsafe { typst_labels_impl(source) })) {
        Ok(result) => result,
        Err(_) => error_label_result("Typst label parser panicked"),
    }
}

unsafe fn typst_labels_impl(source: *const c_char) -> TypstLabelResult {
    if source.is_null() {
        return error_label_result("null source pointer");
    }
    let source_str = match CStr::from_ptr(source).to_str() {
        Ok(s) => s,
        Err(_) => return error_label_result("source is not valid UTF-8"),
    };

    let items = label_items_for_source(source_str);
    let item_len = items.len();
    let (items, item_len) = if item_len > 0 {
        let mut boxed = items.into_boxed_slice();
        let ptr = boxed.as_mut_ptr();
        std::mem::forget(boxed);
        (ptr, item_len)
    } else {
        (std::ptr::null_mut(), 0)
    };

    TypstLabelResult {
        items,
        item_len,
        error_message: std::ptr::null_mut(),
        success: true,
    }
}

fn label_items_for_source(source: &str) -> Vec<TypstLabelItem> {
    let root = parse(source);
    let mut items = Vec::new();
    collect_label_items(&mut items, &LinkedNode::new(&root));
    items
}

fn collect_label_items(items: &mut Vec<TypstLabelItem>, node: &LinkedNode) {
    if let Some(label) = node.get().cast::<ast::Label>() {
        if let Some(item) = label_item(node, label) {
            items.push(item);
        }
    }

    for child in node.children() {
        collect_label_items(items, &child);
    }
}

fn label_item(node: &LinkedNode, label: ast::Label) -> Option<TypstLabelItem> {
    let parent = node.parent()?;
    if parent.kind() != SyntaxKind::Markup {
        return None;
    }

    let labelled = node.prev_sibling()?;
    let name = label.get();
    if name.is_empty() {
        return None;
    }

    Some(TypstLabelItem {
        name: string_into_raw(name.to_string()),
        kind: string_into_raw(label_kind_for_target(&labelled)),
    })
}

fn label_kind_for_target(node: &LinkedNode) -> String {
    if let Some(call) = node.get().cast::<ast::FuncCall>() {
        if let Some(name) = function_name_for_expr(call.callee()) {
            return name.to_ascii_lowercase();
        }
    }

    match node.kind() {
        SyntaxKind::Heading => "heading",
        SyntaxKind::Equation => "equation",
        SyntaxKind::ListItem => "list",
        SyntaxKind::EnumItem => "enum",
        SyntaxKind::TermItem => "term",
        SyntaxKind::Raw => "raw",
        SyntaxKind::Strong => "strong",
        SyntaxKind::Emph => "emph",
        SyntaxKind::Link => "link",
        SyntaxKind::ContentBlock => "content",
        _ => "label",
    }
    .to_string()
}

fn function_name_for_expr(expr: ast::Expr) -> Option<String> {
    match expr {
        ast::Expr::Ident(ident) => Some(ident.as_str().to_string()),
        ast::Expr::FieldAccess(access) => Some(access.field().as_str().to_string()),
        ast::Expr::FuncCall(call) => function_name_for_expr(call.callee()),
        _ => None,
    }
}

/// Free a `TypstLabelResult`.
///
/// # Safety
/// Must have been returned by `typst_labels` and not yet freed.
#[no_mangle]
pub unsafe extern "C" fn typst_free_label_result(result: TypstLabelResult) {
    if !result.items.is_null() {
        let slice = std::slice::from_raw_parts_mut(result.items, result.item_len);
        for item in slice {
            if !item.name.is_null() {
                drop(CString::from_raw(item.name));
            }
            if !item.kind.is_null() {
                drop(CString::from_raw(item.kind));
            }
        }

        let slice_ptr = std::ptr::slice_from_raw_parts_mut(result.items, result.item_len);
        drop(Box::from_raw(slice_ptr));
    }
    if !result.error_message.is_null() {
        drop(CString::from_raw(result.error_message));
    }
}

// ---------------------------------------------------------------------------
// C FFI — bibliography extraction
// ---------------------------------------------------------------------------

#[repr(C)]
pub struct TypstBibliographyItem {
    /// Null-terminated UTF-8 cite key.
    pub key: *mut c_char,
    /// Null-terminated UTF-8 Hayagriva entry type.
    pub entry_type: *mut c_char,
    /// Optional null-terminated UTF-8 title.
    pub title: *mut c_char,
}

/// Result returned by `typst_bibliography_entries`.
#[repr(C)]
pub struct TypstBibliographyResult {
    pub entries: *mut TypstBibliographyItem,
    pub entry_len: usize,
    pub error_message: *mut c_char,
    pub success: bool,
}

/// Parse BibLaTeX or Hayagriva YAML content and return cite entries.
///
/// # Safety
/// `source` must be a valid null-terminated UTF-8 C string. `file_name` may be
/// null; when present, its extension selects the same parser Typst uses.
/// Free the result with `typst_free_bibliography_result`.
#[no_mangle]
pub unsafe extern "C" fn typst_bibliography_entries(
    source: *const c_char,
    file_name: *const c_char,
) -> TypstBibliographyResult {
    match catch_unwind(AssertUnwindSafe(|| unsafe {
        typst_bibliography_entries_impl(source, file_name)
    })) {
        Ok(result) => result,
        Err(_) => error_bibliography_result("Typst bibliography parser panicked"),
    }
}

unsafe fn typst_bibliography_entries_impl(
    source: *const c_char,
    file_name: *const c_char,
) -> TypstBibliographyResult {
    if source.is_null() {
        return error_bibliography_result("null source pointer");
    }
    let source_str = match CStr::from_ptr(source).to_str() {
        Ok(s) => s,
        Err(_) => return error_bibliography_result("source is not valid UTF-8"),
    };
    let file_name = if file_name.is_null() {
        None
    } else {
        match CStr::from_ptr(file_name).to_str() {
            Ok(s) => Some(s),
            Err(_) => return error_bibliography_result("file name is not valid UTF-8"),
        }
    };

    let entries = match bibliography_items_for_source(source_str, file_name) {
        Ok(entries) => entries,
        Err(message) => return error_bibliography_result(&message),
    };
    let entry_len = entries.len();
    let (entries, entry_len) = if entry_len > 0 {
        let mut boxed = entries.into_boxed_slice();
        let ptr = boxed.as_mut_ptr();
        std::mem::forget(boxed);
        (ptr, entry_len)
    } else {
        (std::ptr::null_mut(), 0)
    };

    TypstBibliographyResult {
        entries,
        entry_len,
        error_message: std::ptr::null_mut(),
        success: true,
    }
}

fn bibliography_items_for_source(
    source: &str,
    file_name: Option<&str>,
) -> Result<Vec<TypstBibliographyItem>, String> {
    let library = parse_bibliography_library(source, file_name)?;
    Ok(library
        .iter()
        .map(|entry| TypstBibliographyItem {
            key: string_into_raw(entry.key().to_string()),
            entry_type: string_into_raw(format!("{:?}", entry.entry_type()).to_ascii_lowercase()),
            title: string_option_into_raw(entry.title().map(|title| title.to_string())),
        })
        .collect())
}

fn parse_bibliography_library(
    source: &str,
    file_name: Option<&str>,
) -> Result<hayagriva::Library, String> {
    let extension = file_name
        .and_then(|name| Path::new(name).extension())
        .and_then(|extension| extension.to_str())
        .map(str::to_ascii_lowercase);

    match extension.as_deref() {
        Some("yml" | "yaml") => hayagriva::io::from_yaml_str(source).map_err(|err| err.to_string()),
        Some("bib") => hayagriva::io::from_biblatex_str(source).map_err(format_biblatex_errors),
        _ => infer_bibliography_library(source),
    }
}

fn infer_bibliography_library(source: &str) -> Result<hayagriva::Library, String> {
    let yaml_error = match hayagriva::io::from_yaml_str(source) {
        Ok(library) => return Ok(library),
        Err(err) => err.to_string(),
    };

    match hayagriva::io::from_biblatex_str(source) {
        Ok(library) if !library.is_empty() => Ok(library),
        Ok(_) => Err(yaml_error),
        Err(biblatex_errors) => {
            let yaml_markers = source.chars().filter(|&ch| ch == ':').count();
            let biblatex_markers = source.chars().filter(|&ch| ch == '{').count();
            if biblatex_markers >= yaml_markers {
                Err(format_biblatex_errors(biblatex_errors))
            } else {
                Err(yaml_error)
            }
        }
    }
}

fn format_biblatex_errors(errors: Vec<hayagriva::io::BibLaTeXError>) -> String {
    errors
        .into_iter()
        .map(|error| error.to_string())
        .collect::<Vec<_>>()
        .join("\n")
}

/// Free a `TypstBibliographyResult`.
///
/// # Safety
/// Must have been returned by `typst_bibliography_entries` and not yet freed.
#[no_mangle]
pub unsafe extern "C" fn typst_free_bibliography_result(result: TypstBibliographyResult) {
    if !result.entries.is_null() {
        let slice = std::slice::from_raw_parts_mut(result.entries, result.entry_len);
        for entry in slice {
            if !entry.key.is_null() {
                drop(CString::from_raw(entry.key));
            }
            if !entry.entry_type.is_null() {
                drop(CString::from_raw(entry.entry_type));
            }
            if !entry.title.is_null() {
                drop(CString::from_raw(entry.title));
            }
        }

        let slice_ptr = std::ptr::slice_from_raw_parts_mut(result.entries, result.entry_len);
        drop(Box::from_raw(slice_ptr));
    }
    if !result.error_message.is_null() {
        drop(CString::from_raw(result.error_message));
    }
}

// ---------------------------------------------------------------------------
// C FFI — semantic completion symbols and cursor context
// ---------------------------------------------------------------------------

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(C)]
pub struct TypstCompletionValue {
    /// Display label for this accepted literal value.
    pub label: *mut c_char,
    /// Text to insert. May include quotes for string literals.
    pub insert_text: *mut c_char,
    /// Short detail, usually Typst's value documentation.
    pub detail: *mut c_char,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(C)]
pub struct TypstCompletionParam {
    pub name: *mut c_char,
    pub docs: *mut c_char,
    pub input: *mut c_char,
    pub default_value: *mut c_char,
    pub values: *mut TypstCompletionValue,
    pub value_len: usize,
    pub positional: bool,
    pub named: bool,
    pub variadic: bool,
    pub required: bool,
    pub settable: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(C)]
pub struct TypstCompletionSymbol {
    /// Symbol name exactly as Typst exposes it.
    pub name: *mut c_char,
    /// 0 keyword, 1 function, 2 value, 3 type, 4 module, 5 source-local.
    pub kind: u32,
    /// Short display detail.
    pub detail: *mut c_char,
    /// UTF-16 source location for source-local symbols, or u32::MAX otherwise.
    pub utf16_location: u32,
    /// UTF-16 end of the source-local scope, or u32::MAX for global symbols.
    pub utf16_scope_end: u32,
    pub params: *mut TypstCompletionParam,
    pub param_len: usize,
}

/// Result returned by `typst_completion_symbols`.
#[repr(C)]
pub struct TypstCompletionSymbolResult {
    pub symbols: *mut TypstCompletionSymbol,
    pub symbol_len: usize,
    pub error_message: *mut c_char,
    pub success: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(C)]
pub struct TypstContextItem {
    pub kind: *mut c_char,
    pub utf16_location: u32,
    pub utf16_length: u32,
}

/// Result returned by `typst_context_at`.
#[repr(C)]
pub struct TypstContextResult {
    pub items: *mut TypstContextItem,
    pub item_len: usize,
    /// Innermost enclosing function call's callee name, if any.
    pub function_name: *mut c_char,
    pub error_message: *mut c_char,
    pub success: bool,
}

#[derive(Clone, Debug)]
struct OwnedCompletionValue {
    label: String,
    insert_text: String,
    detail: String,
}

#[derive(Clone, Debug)]
struct OwnedCompletionParam {
    name: String,
    docs: String,
    input: String,
    default_value: String,
    values: Vec<OwnedCompletionValue>,
    positional: bool,
    named: bool,
    variadic: bool,
    required: bool,
    settable: bool,
}

#[derive(Clone, Debug)]
struct OwnedCompletionSymbol {
    name: String,
    kind: u32,
    detail: String,
    utf16_location: u32,
    utf16_scope_end: u32,
    params: Vec<OwnedCompletionParam>,
}

static LIBRARY_COMPLETION_SYMBOLS: OnceLock<Vec<OwnedCompletionSymbol>> = OnceLock::new();

/// Return Typst-library symbols plus `#let` / named `#import` symbols from
/// `source`. The Swift side should treat this as authoritative.
///
/// # Safety
/// `source` may be null or a valid null-terminated UTF-8 C string.
/// Free the result with `typst_free_completion_symbol_result`.
#[no_mangle]
pub unsafe extern "C" fn typst_completion_symbols(
    source: *const c_char,
) -> TypstCompletionSymbolResult {
    match catch_unwind(AssertUnwindSafe(|| unsafe {
        typst_completion_symbols_impl(source)
    })) {
        Ok(result) => result,
        Err(_) => error_completion_symbol_result("Typst completion symbol parser panicked"),
    }
}

unsafe fn typst_completion_symbols_impl(source: *const c_char) -> TypstCompletionSymbolResult {
    let source_str = if source.is_null() {
        ""
    } else {
        match CStr::from_ptr(source).to_str() {
            Ok(s) => s,
            Err(_) => return error_completion_symbol_result("source is not valid UTF-8"),
        }
    };

    let mut symbols = library_completion_symbols();
    if !source_str.is_empty() {
        symbols.extend(local_completion_symbols(source_str));
    }

    symbols.sort_by(|a, b| {
        a.name
            .cmp(&b.name)
            .then(a.kind.cmp(&b.kind))
            .then(a.utf16_location.cmp(&b.utf16_location))
    });
    symbols.dedup_by(|a, b| {
        a.name == b.name && a.kind == b.kind && a.utf16_location == b.utf16_location
    });

    let symbol_len = symbols.len();
    let (symbols, symbol_len) = if symbol_len > 0 {
        let ffi_symbols: Vec<_> = symbols
            .into_iter()
            .map(completion_symbol_into_ffi)
            .collect();
        let mut boxed = ffi_symbols.into_boxed_slice();
        let ptr = boxed.as_mut_ptr();
        std::mem::forget(boxed);
        (ptr, symbol_len)
    } else {
        (std::ptr::null_mut(), 0)
    };

    TypstCompletionSymbolResult {
        symbols,
        symbol_len,
        error_message: std::ptr::null_mut(),
        success: true,
    }
}

fn library_completion_symbols() -> Vec<OwnedCompletionSymbol> {
    LIBRARY_COMPLETION_SYMBOLS
        .get_or_init(build_library_completion_symbols)
        .clone()
}

fn build_library_completion_symbols() -> Vec<OwnedCompletionSymbol> {
    let library = Library::default();
    let mut symbols = keyword_completion_symbols();
    let mut visited = HashSet::new();

    for (name, binding) in library.global.scope().iter() {
        let name = name.to_string();
        let value = binding.read();
        push_symbol_for_value(
            &mut symbols,
            &mut visited,
            name,
            value,
            u32::MAX,
            u32::MAX,
            0,
        );
    }

    symbols
}

fn push_symbol_for_value(
    symbols: &mut Vec<OwnedCompletionSymbol>,
    visited: &mut HashSet<String>,
    name: String,
    value: &Value,
    utf16_location: u32,
    utf16_scope_end: u32,
    depth: usize,
) {
    if !visited.insert(name.clone()) {
        return;
    }

    symbols.push(completion_symbol_for_value(
        name.clone(),
        value,
        utf16_location,
        utf16_scope_end,
    ));

    // Modules, types, and element functions expose scoped fields such as
    // `calc.sin`, `table.cell`, and `outline.entry`. Keep the walk finite:
    // two levels covers standard-library fields without chasing cycles in `std`.
    if depth >= 2 || name == "std" {
        return;
    }

    if let Some(scope) = value.scope() {
        for (field, binding) in scope.iter() {
            let child_name = format!("{name}.{field}");
            push_symbol_for_value(
                symbols,
                visited,
                child_name,
                binding.read(),
                utf16_location,
                utf16_scope_end,
                depth + 1,
            );
        }
    }
}

fn completion_symbol_for_value(
    name: String,
    value: &Value,
    utf16_location: u32,
    utf16_scope_end: u32,
) -> OwnedCompletionSymbol {
    match value {
        Value::Func(func) => {
            let params = func
                .params()
                .unwrap_or(&[])
                .iter()
                .map(|param| OwnedCompletionParam {
                    name: param.name.to_string(),
                    docs: trim_docs(param.docs),
                    input: cast_info_summary(&param.input),
                    default_value: param
                        .default
                        .map(|default| default().repr().to_string())
                        .unwrap_or_default(),
                    values: cast_info_values(&param.input),
                    positional: param.positional,
                    named: param.named,
                    variadic: param.variadic,
                    required: param.required,
                    settable: param.settable,
                })
                .collect();

            OwnedCompletionSymbol {
                name,
                kind: 1,
                detail: func.title().unwrap_or("function").to_string(),
                utf16_location,
                utf16_scope_end,
                params,
            }
        }
        Value::Type(ty) => OwnedCompletionSymbol {
            name,
            kind: 3,
            detail: ty.title().to_string(),
            utf16_location,
            utf16_scope_end,
            params: vec![],
        },
        Value::Module(_) => OwnedCompletionSymbol {
            name,
            kind: 4,
            detail: "module".to_string(),
            utf16_location,
            utf16_scope_end,
            params: vec![],
        },
        _ => OwnedCompletionSymbol {
            name,
            kind: 2,
            detail: value.ty().long_name().to_string(),
            utf16_location,
            utf16_scope_end,
            params: vec![],
        },
    }
}

fn keyword_completion_symbols() -> Vec<OwnedCompletionSymbol> {
    const KEYWORDS: &[&str] = &[
        "let", "set", "show", "import", "include", "if", "else", "for", "in", "while", "return",
        "break", "continue", "context",
    ];

    KEYWORDS
        .iter()
        .map(|keyword| OwnedCompletionSymbol {
            name: (*keyword).to_string(),
            kind: 0,
            detail: "keyword".to_string(),
            utf16_location: u32::MAX,
            utf16_scope_end: u32::MAX,
            params: vec![],
        })
        .collect()
}

fn local_completion_symbols(source: &str) -> Vec<OwnedCompletionSymbol> {
    let root = parse(source);
    let byte_to_utf16 = byte_to_utf16_offsets(source);
    let mut symbols = Vec::new();
    let root = LinkedNode::new(&root);
    let root_scope_end = root.range().end;
    collect_local_completion_symbols(&mut symbols, &root, &byte_to_utf16, root_scope_end);
    symbols
}

fn collect_local_completion_symbols(
    symbols: &mut Vec<OwnedCompletionSymbol>,
    node: &LinkedNode,
    byte_to_utf16: &[usize],
    scope_end_byte: usize,
) {
    let current_scope_end_byte = local_scope_end_for_node(node).unwrap_or(scope_end_byte);
    let current_scope_end = utf16_location_for_byte(current_scope_end_byte, byte_to_utf16);

    if let Some(binding) = node.get().cast::<ast::LetBinding>() {
        let location = utf16_location_for_byte(node.range().end, byte_to_utf16);
        for ident in binding.kind().bindings() {
            push_local_symbol(symbols, ident, "local binding", location, current_scope_end);
        }
    } else if let Some(import) = node.get().cast::<ast::ModuleImport>() {
        let location = utf16_location_for_byte(node.range().end, byte_to_utf16);
        if let Some(rename) = import.new_name() {
            push_local_symbol(
                symbols,
                rename,
                "module import",
                location,
                current_scope_end,
            );
        } else if let Some(ast::Imports::Items(items)) = import.imports() {
            for item in items.iter() {
                push_local_symbol(
                    symbols,
                    item.bound_name(),
                    "imported symbol",
                    location,
                    current_scope_end,
                );
            }
        } else if import.imports().is_none() {
            if let Ok(name) = import.bare_name() {
                symbols.push(OwnedCompletionSymbol {
                    name: name.to_string(),
                    kind: 5,
                    detail: "module import".to_string(),
                    utf16_location: location,
                    utf16_scope_end: current_scope_end,
                    params: vec![],
                });
            }
        }
    } else if let Some(for_loop) = node.get().cast::<ast::ForLoop>() {
        let body = for_loop.body().to_untyped();
        let visible_from = utf16_location_for_byte(
            body.span()
                .range()
                .map(|range| range.start)
                .unwrap_or(node.range().start),
            byte_to_utf16,
        );
        let visible_until = utf16_location_for_byte(
            body.span()
                .range()
                .map(|range| range.end)
                .unwrap_or(node.range().end),
            byte_to_utf16,
        );
        for ident in for_loop.pattern().bindings() {
            push_local_symbol(symbols, ident, "loop binding", visible_from, visible_until);
        }
    } else if let Some(closure) = node.get().cast::<ast::Closure>() {
        let body = closure.body().to_untyped();
        let visible_from = utf16_location_for_byte(
            body.span()
                .range()
                .map(|range| range.start)
                .unwrap_or(node.range().start),
            byte_to_utf16,
        );
        let visible_until = utf16_location_for_byte(
            body.span()
                .range()
                .map(|range| range.end)
                .unwrap_or(node.range().end),
            byte_to_utf16,
        );
        for param in closure.params().children() {
            for ident in param_bindings(param) {
                push_local_symbol(symbols, ident, "parameter", visible_from, visible_until);
            }
        }
    }

    for child in node.children() {
        collect_local_completion_symbols(symbols, &child, byte_to_utf16, current_scope_end_byte);
    }
}

fn local_scope_end_for_node(node: &LinkedNode) -> Option<usize> {
    match node.kind() {
        SyntaxKind::Markup
        | SyntaxKind::Code
        | SyntaxKind::CodeBlock
        | SyntaxKind::ContentBlock => Some(node.range().end),
        _ => None,
    }
}

fn param_bindings(param: ast::Param) -> Vec<ast::Ident> {
    match param {
        ast::Param::Pos(pattern) => pattern.bindings(),
        ast::Param::Named(named) => vec![named.name()],
        ast::Param::Spread(spread) => spread.sink_ident().into_iter().collect(),
    }
}

fn push_local_symbol(
    symbols: &mut Vec<OwnedCompletionSymbol>,
    ident: ast::Ident,
    detail: &str,
    utf16_location: u32,
    utf16_scope_end: u32,
) {
    symbols.push(OwnedCompletionSymbol {
        name: ident.get().to_string(),
        kind: 5,
        detail: detail.to_string(),
        utf16_location,
        utf16_scope_end,
        params: vec![],
    });
}

fn utf16_location_for_byte(byte: usize, byte_to_utf16: &[usize]) -> u32 {
    byte_to_utf16
        .get(byte)
        .and_then(|offset| u32::try_from(*offset).ok())
        .unwrap_or(u32::MAX)
}

fn cast_info_summary(info: &CastInfo) -> String {
    let mut parts = Vec::new();
    info.walk(|part| match part {
        CastInfo::Any => parts.push("anything".to_string()),
        CastInfo::Value(value, _) => parts.push(value.repr().to_string()),
        CastInfo::Type(ty) => parts.push(ty.long_name().to_string()),
        CastInfo::Union(_) => {}
    });
    parts.dedup();
    parts.join(" | ")
}

fn cast_info_values(info: &CastInfo) -> Vec<OwnedCompletionValue> {
    let mut values = Vec::new();
    info.walk(|part| {
        if let CastInfo::Value(value, docs) = part {
            let insert_text = value.repr().to_string();
            values.push(OwnedCompletionValue {
                label: insert_text.trim_matches('"').to_string(),
                insert_text,
                detail: trim_docs(docs),
            });
        }
    });
    values
}

fn trim_docs(docs: &str) -> String {
    docs.lines()
        .map(str::trim)
        .find(|line| !line.is_empty())
        .unwrap_or("")
        .trim_start_matches("- ")
        .to_string()
}

fn completion_symbol_into_ffi(symbol: OwnedCompletionSymbol) -> TypstCompletionSymbol {
    let param_len = symbol.params.len();
    let (params, param_len) = if param_len > 0 {
        let ffi_params: Vec<_> = symbol
            .params
            .into_iter()
            .map(completion_param_into_ffi)
            .collect();
        let mut boxed = ffi_params.into_boxed_slice();
        let ptr = boxed.as_mut_ptr();
        std::mem::forget(boxed);
        (ptr, param_len)
    } else {
        (std::ptr::null_mut(), 0)
    };

    TypstCompletionSymbol {
        name: string_into_raw(symbol.name),
        kind: symbol.kind,
        detail: string_into_raw(symbol.detail),
        utf16_location: symbol.utf16_location,
        utf16_scope_end: symbol.utf16_scope_end,
        params,
        param_len,
    }
}

fn completion_param_into_ffi(param: OwnedCompletionParam) -> TypstCompletionParam {
    let value_len = param.values.len();
    let (values, value_len) = if value_len > 0 {
        let ffi_values: Vec<_> = param
            .values
            .into_iter()
            .map(completion_value_into_ffi)
            .collect();
        let mut boxed = ffi_values.into_boxed_slice();
        let ptr = boxed.as_mut_ptr();
        std::mem::forget(boxed);
        (ptr, value_len)
    } else {
        (std::ptr::null_mut(), 0)
    };

    TypstCompletionParam {
        name: string_into_raw(param.name),
        docs: string_into_raw(param.docs),
        input: string_into_raw(param.input),
        default_value: string_into_raw(param.default_value),
        values,
        value_len,
        positional: param.positional,
        named: param.named,
        variadic: param.variadic,
        required: param.required,
        settable: param.settable,
    }
}

fn completion_value_into_ffi(value: OwnedCompletionValue) -> TypstCompletionValue {
    TypstCompletionValue {
        label: string_into_raw(value.label),
        insert_text: string_into_raw(value.insert_text),
        detail: string_into_raw(value.detail),
    }
}

/// Free a `TypstCompletionSymbolResult`.
///
/// # Safety
/// Must have been returned by `typst_completion_symbols` and not yet freed.
#[no_mangle]
pub unsafe extern "C" fn typst_free_completion_symbol_result(result: TypstCompletionSymbolResult) {
    if !result.symbols.is_null() {
        let symbols = std::slice::from_raw_parts_mut(result.symbols, result.symbol_len);
        for symbol in symbols {
            free_raw_string(symbol.name);
            free_raw_string(symbol.detail);

            if !symbol.params.is_null() {
                let params = std::slice::from_raw_parts_mut(symbol.params, symbol.param_len);
                for param in params {
                    free_raw_string(param.name);
                    free_raw_string(param.docs);
                    free_raw_string(param.input);
                    free_raw_string(param.default_value);

                    if !param.values.is_null() {
                        let values = std::slice::from_raw_parts_mut(param.values, param.value_len);
                        for value in values {
                            free_raw_string(value.label);
                            free_raw_string(value.insert_text);
                            free_raw_string(value.detail);
                        }
                        let slice_ptr =
                            std::ptr::slice_from_raw_parts_mut(param.values, param.value_len);
                        drop(Box::from_raw(slice_ptr));
                    }
                }

                let slice_ptr = std::ptr::slice_from_raw_parts_mut(symbol.params, symbol.param_len);
                drop(Box::from_raw(slice_ptr));
            }
        }

        let slice_ptr = std::ptr::slice_from_raw_parts_mut(result.symbols, result.symbol_len);
        drop(Box::from_raw(slice_ptr));
    }
    free_raw_string(result.error_message);
}

/// Return the syntax kind chain at a UTF-16 cursor offset and the enclosing
/// function call name when the cursor is inside arguments.
///
/// # Safety
/// `source` must be a valid null-terminated UTF-8 C string.
/// Free the result with `typst_free_context_result`.
#[no_mangle]
pub unsafe extern "C" fn typst_context_at(
    source: *const c_char,
    utf16_offset: u32,
) -> TypstContextResult {
    match catch_unwind(AssertUnwindSafe(|| unsafe {
        typst_context_at_impl(source, utf16_offset)
    })) {
        Ok(result) => result,
        Err(_) => error_context_result("Typst cursor context parser panicked"),
    }
}

unsafe fn typst_context_at_impl(source: *const c_char, utf16_offset: u32) -> TypstContextResult {
    if source.is_null() {
        return error_context_result("null source pointer");
    }
    let source_str = match CStr::from_ptr(source).to_str() {
        Ok(s) => s,
        Err(_) => return error_context_result("source is not valid UTF-8"),
    };

    let byte_offset = utf16_to_byte_offset(source_str, utf16_offset as usize);
    let root = parse(source_str);
    let linked_root = LinkedNode::new(&root);
    let leaf = linked_root
        .leaf_at(byte_offset, Side::Before)
        .or_else(|| linked_root.leaf_at(byte_offset, Side::After))
        .unwrap_or_else(|| linked_root.clone());

    let byte_to_utf16 = byte_to_utf16_offsets(source_str);
    let function_name = enclosing_function_name(&leaf);
    let mut path = Vec::new();
    let mut current = Some(leaf);
    while let Some(node) = current {
        path.push(node.clone());
        current = node.parent().cloned();
    }
    path.reverse();

    let item_len = path.len();
    let items: Vec<_> = path
        .into_iter()
        .map(|node| context_item_for_node(&node, &byte_to_utf16))
        .collect();
    let (items, item_len) = if item_len > 0 {
        let mut boxed = items.into_boxed_slice();
        let ptr = boxed.as_mut_ptr();
        std::mem::forget(boxed);
        (ptr, item_len)
    } else {
        (std::ptr::null_mut(), 0)
    };

    TypstContextResult {
        items,
        item_len,
        function_name: string_option_into_raw(function_name),
        error_message: std::ptr::null_mut(),
        success: true,
    }
}

fn utf16_to_byte_offset(source: &str, utf16_offset: usize) -> usize {
    let mut current_utf16 = 0;
    for (byte_offset, ch) in source.char_indices() {
        if current_utf16 >= utf16_offset {
            return byte_offset;
        }
        current_utf16 += ch.len_utf16();
        if current_utf16 >= utf16_offset {
            return byte_offset + ch.len_utf8();
        }
    }
    source.len()
}

fn context_item_for_node(node: &LinkedNode, byte_to_utf16: &[usize]) -> TypstContextItem {
    let range = node.range();
    let utf16_start = byte_to_utf16.get(range.start).copied().unwrap_or(0);
    let utf16_end = byte_to_utf16.get(range.end).copied().unwrap_or(utf16_start);

    TypstContextItem {
        kind: string_into_raw(format!("{:?}", node.kind())),
        utf16_location: u32::try_from(utf16_start).unwrap_or(u32::MAX),
        utf16_length: u32::try_from(utf16_end.saturating_sub(utf16_start)).unwrap_or(0),
    }
}

fn enclosing_function_name(leaf: &LinkedNode) -> Option<String> {
    let mut current = Some(leaf.clone());
    while let Some(node) = current {
        if let Some(call) = node.get().cast::<ast::FuncCall>() {
            if let Some(name) = expr_callee_name(call.callee()) {
                return Some(name);
            }
        }
        current = node.parent().cloned();
    }
    None
}

fn expr_callee_name(expr: ast::Expr) -> Option<String> {
    match expr {
        ast::Expr::Ident(ident) => Some(ident.get().to_string()),
        ast::Expr::FieldAccess(access) => {
            let target = expr_callee_name(access.target())?;
            Some(format!("{}.{}", target, access.field().get()))
        }
        ast::Expr::FuncCall(call) => expr_callee_name(call.callee()),
        ast::Expr::Parenthesized(group) => expr_callee_name(group.expr()),
        _ => None,
    }
}

/// Free a `TypstContextResult`.
///
/// # Safety
/// Must have been returned by `typst_context_at` and not yet freed.
#[no_mangle]
pub unsafe extern "C" fn typst_free_context_result(result: TypstContextResult) {
    if !result.items.is_null() {
        let items = std::slice::from_raw_parts_mut(result.items, result.item_len);
        for item in items {
            free_raw_string(item.kind);
        }
        let slice_ptr = std::ptr::slice_from_raw_parts_mut(result.items, result.item_len);
        drop(Box::from_raw(slice_ptr));
    }
    free_raw_string(result.function_name);
    free_raw_string(result.error_message);
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

fn error_highlight_result(msg: &str) -> TypstHighlightResult {
    let c = CString::new(msg).unwrap_or_else(|_| CString::new("error").unwrap());
    TypstHighlightResult {
        tokens: std::ptr::null_mut(),
        token_len: 0,
        error_message: c.into_raw(),
        success: false,
    }
}

fn error_outline_result(msg: &str) -> TypstOutlineResult {
    let c = CString::new(msg).unwrap_or_else(|_| CString::new("error").unwrap());
    TypstOutlineResult {
        items: std::ptr::null_mut(),
        item_len: 0,
        error_message: c.into_raw(),
        success: false,
    }
}

fn error_label_result(msg: &str) -> TypstLabelResult {
    let c = CString::new(msg).unwrap_or_else(|_| CString::new("error").unwrap());
    TypstLabelResult {
        items: std::ptr::null_mut(),
        item_len: 0,
        error_message: c.into_raw(),
        success: false,
    }
}

fn error_bibliography_result(msg: &str) -> TypstBibliographyResult {
    let c = CString::new(msg).unwrap_or_else(|_| CString::new("error").unwrap());
    TypstBibliographyResult {
        entries: std::ptr::null_mut(),
        entry_len: 0,
        error_message: c.into_raw(),
        success: false,
    }
}

fn error_completion_symbol_result(msg: &str) -> TypstCompletionSymbolResult {
    let c = CString::new(msg).unwrap_or_else(|_| CString::new("error").unwrap());
    TypstCompletionSymbolResult {
        symbols: std::ptr::null_mut(),
        symbol_len: 0,
        error_message: c.into_raw(),
        success: false,
    }
}

fn error_context_result(msg: &str) -> TypstContextResult {
    let c = CString::new(msg).unwrap_or_else(|_| CString::new("error").unwrap());
    TypstContextResult {
        items: std::ptr::null_mut(),
        item_len: 0,
        function_name: std::ptr::null_mut(),
        error_message: c.into_raw(),
        success: false,
    }
}

fn string_into_raw(value: String) -> *mut c_char {
    CString::new(value)
        .unwrap_or_else(|_| CString::new("").unwrap())
        .into_raw()
}

fn string_option_into_raw(value: Option<String>) -> *mut c_char {
    value.map(string_into_raw).unwrap_or(std::ptr::null_mut())
}

unsafe fn free_raw_string(ptr: *mut c_char) {
    if !ptr.is_null() {
        drop(CString::from_raw(ptr));
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
    use flate2::write::GzEncoder;
    use flate2::Compression;
    use tar::{Builder, EntryType, Header};

    fn outline_item_title(item: &TypstOutlineItem) -> String {
        if item.title.is_null() {
            return String::new();
        }

        unsafe { CStr::from_ptr(item.title).to_string_lossy().into_owned() }
    }

    fn free_outline_test_items(items: Vec<TypstOutlineItem>) {
        for item in items {
            if !item.title.is_null() {
                unsafe {
                    drop(CString::from_raw(item.title));
                }
            }
        }
    }

    fn label_item_pair(item: &TypstLabelItem) -> (String, String) {
        let name = if item.name.is_null() {
            String::new()
        } else {
            unsafe { CStr::from_ptr(item.name).to_string_lossy().into_owned() }
        };
        let kind = if item.kind.is_null() {
            String::new()
        } else {
            unsafe { CStr::from_ptr(item.kind).to_string_lossy().into_owned() }
        };
        (name, kind)
    }

    fn free_label_test_items(items: Vec<TypstLabelItem>) {
        for item in items {
            if !item.name.is_null() {
                unsafe {
                    drop(CString::from_raw(item.name));
                }
            }
            if !item.kind.is_null() {
                unsafe {
                    drop(CString::from_raw(item.kind));
                }
            }
        }
    }

    fn bibliography_item_info(item: &TypstBibliographyItem) -> (String, String, Option<String>) {
        let key = if item.key.is_null() {
            String::new()
        } else {
            unsafe { CStr::from_ptr(item.key).to_string_lossy().into_owned() }
        };
        let entry_type = if item.entry_type.is_null() {
            String::new()
        } else {
            unsafe {
                CStr::from_ptr(item.entry_type)
                    .to_string_lossy()
                    .into_owned()
            }
        };
        let title = if item.title.is_null() {
            None
        } else {
            Some(unsafe { CStr::from_ptr(item.title).to_string_lossy().into_owned() })
        };
        (key, entry_type, title)
    }

    fn free_bibliography_test_items(items: Vec<TypstBibliographyItem>) {
        for item in items {
            if !item.key.is_null() {
                unsafe {
                    drop(CString::from_raw(item.key));
                }
            }
            if !item.entry_type.is_null() {
                unsafe {
                    drop(CString::from_raw(item.entry_type));
                }
            }
            if !item.title.is_null() {
                unsafe {
                    drop(CString::from_raw(item.title));
                }
            }
        }
    }

    #[test]
    fn extract_tar_gz_bytes_extracts_regular_files() {
        let archive = build_tar_gz(vec![
            TarEntry::file("main.typ", b"hello"),
            TarEntry::file("nested/image.png", &[1, 2, 3]),
        ]);
        let dest = make_temp_dir();

        extract_tar_gz_bytes(&archive, &dest).unwrap();

        assert_eq!(
            std::fs::read_to_string(dest.join("main.typ")).unwrap(),
            "hello"
        );
        assert_eq!(
            std::fs::read(dest.join("nested/image.png")).unwrap(),
            vec![1, 2, 3]
        );

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
    fn highlight_tokens_use_typst_parser_context() {
        let tokens = highlight_tokens_for_source("bread and butter\n#let value = 42");

        assert!(
            tokens.iter().all(|token| token.utf16_location != 6),
            "plain markup word 'and' should not be highlighted as a keyword"
        );
        assert!(
            tokens.iter().any(|token| token.utf16_location == 17
                && token.utf16_length == 1
                && token.tag == highlight_tag_id(Tag::Keyword)),
            "hash before let should receive Typst's keyword tag"
        );
        assert!(
            tokens.iter().any(|token| token.utf16_location == 18
                && token.utf16_length == 3
                && token.tag == highlight_tag_id(Tag::Keyword)),
            "let should receive Typst's keyword tag"
        );
    }

    #[test]
    fn highlight_tokens_return_utf16_offsets() {
        let tokens = highlight_tokens_for_source("你好 #let x = 1");

        assert!(
            tokens.iter().any(|token| token.utf16_location == 3
                && token.utf16_length == 1
                && token.tag == highlight_tag_id(Tag::Keyword)),
            "highlight locations should be UTF-16 offsets, not UTF-8 byte offsets"
        );
    }

    #[test]
    fn highlight_tokens_embed_syntect_for_raw_block_language() {
        let source = "```rust\nlet answer = 42\n// hi\n```";
        let tokens = highlight_tokens_for_source(source);

        assert!(
            tokens.iter().any(|token| token.utf16_location == 8
                && token.utf16_length == 3
                && token.tag == highlight_tag_id(Tag::Keyword)),
            "Rust keyword inside raw block should be highlighted"
        );
        assert!(
            tokens.iter().any(|token| token.utf16_location == 21
                && token.utf16_length == 2
                && token.tag == highlight_tag_id(Tag::Number)),
            "Rust numeric literal inside raw block should be highlighted"
        );
        assert!(
            tokens.iter().any(|token| token.utf16_location == 24
                && token.utf16_length == 5
                && token.tag == highlight_tag_id(Tag::Comment)),
            "Rust comment inside raw block should be highlighted"
        );
    }

    #[test]
    fn highlight_tokens_keep_unknown_raw_language_plain() {
        let source = "```notalang\nlet answer = 42\n```";
        let tokens = highlight_tokens_for_source(source);
        let let_start = source.find("let").unwrap() as u32;

        assert!(
            tokens.iter().any(|token| token.utf16_location == 0
                && token.utf16_length == source.len() as u32
                && token.tag == highlight_tag_id(Tag::Raw)),
            "raw block itself should still receive the raw token"
        );
        assert!(
            tokens.iter().all(|token| {
                !(token.utf16_location == let_start
                    && token.utf16_length == 3
                    && token.tag == highlight_tag_id(Tag::Keyword))
            }),
            "unknown raw languages should not receive embedded syntect tokens"
        );
    }

    #[test]
    fn completion_symbols_include_nested_typst_library_scopes() {
        let symbols = library_completion_symbols();

        for expected in ["calc.sin", "table.cell", "outline.entry"] {
            assert!(
                symbols
                    .iter()
                    .any(|symbol| symbol.name == expected && symbol.kind == 1),
                "expected library completion for {expected}"
            );
        }
    }

    #[test]
    fn local_completion_symbols_carry_declaration_scope() {
        let source = "#let outer = 1\n#let content = [\n  #let inner = 2\n  #inner\n]\n#outer\n";
        let symbols = local_completion_symbols(source);
        let outer = symbols
            .iter()
            .find(|symbol| symbol.name == "outer")
            .expect("outer binding should be discovered");
        let inner = symbols
            .iter()
            .find(|symbol| symbol.name == "inner")
            .expect("inner binding should be discovered");
        let source_len = source.encode_utf16().count() as u32;

        assert!(
            outer.utf16_scope_end >= source_len,
            "top-level binding should remain visible through end of file"
        );
        assert!(
            inner.utf16_scope_end < source_len,
            "content-block binding should not leak to the rest of the document"
        );
        assert!(
            inner.utf16_location < inner.utf16_scope_end,
            "local binding should become visible before its scope ends"
        );
    }

    #[test]
    fn context_at_empty_source_returns_root_context() {
        let source = CString::new("").unwrap();
        let result = unsafe { typst_context_at_impl(source.as_ptr(), 0) };

        assert!(result.success);
        assert!(
            result.item_len > 0,
            "empty source should still return the root syntax context"
        );

        unsafe { typst_free_context_result(result) };
    }

    #[test]
    fn utf16_to_byte_offset_clamps_to_character_boundaries() {
        let source = "a😀b";

        assert_eq!(utf16_to_byte_offset(source, 0), 0);
        assert_eq!(utf16_to_byte_offset(source, 1), "a".len());
        assert_eq!(utf16_to_byte_offset(source, 2), "a😀".len());
        assert_eq!(utf16_to_byte_offset(source, 3), "a😀".len());
        assert_eq!(utf16_to_byte_offset(source, 4), source.len());
    }

    #[test]
    fn outline_items_use_typst_parser_context() {
        let items = outline_items_for_source(
            r#"
= Real <intro>

```typ
= Not outline
```

== Next
"#,
        );

        let titles: Vec<_> = items.iter().map(outline_item_title).collect();
        let levels: Vec<_> = items.iter().map(|item| item.level).collect();

        assert_eq!(titles, vec!["Real", "Next"]);
        assert_eq!(levels, vec![1, 2]);

        free_outline_test_items(items);
    }

    #[test]
    fn outline_items_return_utf16_offsets() {
        let items = outline_items_for_source("你好\n= 标题");

        assert_eq!(items.len(), 1);
        assert_eq!(items[0].utf16_location, 3);
        assert_eq!(outline_item_title(&items[0]), "标题");

        free_outline_test_items(items);
    }

    #[test]
    fn label_items_use_typst_syntax_tree() {
        let items = label_items_for_source(
            r#"= Real <intro>

```typ
= Not a heading <fake-heading>
#figure("not real") <fake-figure>
```

#let literal = <not-a-definition>

#figure(table(columns: 1, [Nested])) <fig>
#table(columns: 1, [Cell]) <tbl>
$x + y$ <eq>
"#,
        );

        let pairs: Vec<_> = items.iter().map(label_item_pair).collect();

        assert_eq!(
            pairs,
            vec![
                ("intro".to_string(), "heading".to_string()),
                ("fig".to_string(), "figure".to_string()),
                ("tbl".to_string(), "table".to_string()),
                ("eq".to_string(), "equation".to_string()),
            ]
        );

        free_label_test_items(items);
    }

    #[test]
    fn bibliography_items_use_hayagriva_for_biblatex_and_yaml() {
        let biblatex = r#"
@string{journal_name = {Journal of Tests}}
@article{smith2020,
  title = {Nested {Brace} Title},
  journaltitle = journal_name
}
"#;
        let bib_items = bibliography_items_for_source(biblatex, Some("refs.bib")).unwrap();
        let bib_info: Vec<_> = bib_items.iter().map(bibliography_item_info).collect();

        assert_eq!(
            bib_info,
            vec![(
                "smith2020".to_string(),
                "article".to_string(),
                Some("Nested Brace Title".to_string())
            )]
        );

        free_bibliography_test_items(bib_items);

        let yaml = r#"
yaml-key:
  type: Book
  title: Hayagriva YAML Works
"#;
        let yaml_items = bibliography_items_for_source(yaml, Some("refs.yaml")).unwrap();
        let yaml_info: Vec<_> = yaml_items.iter().map(bibliography_item_info).collect();

        assert_eq!(
            yaml_info,
            vec![(
                "yaml-key".to_string(),
                "book".to_string(),
                Some("Hayagriva YAML Works".to_string())
            )]
        );

        free_bibliography_test_items(yaml_items);
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
            header.set_mode(if entry.entry_type.is_dir() {
                0o755
            } else {
                0o644
            });
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
