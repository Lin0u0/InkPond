#pragma once
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

/// Options for typst_compile. All pointer fields may be NULL.
typedef struct {
    /// Extra font file paths (e.g. system CJK fonts from CoreText).
    const char * const *font_paths;
    size_t              font_path_count;
    /// Directory for caching downloaded @preview packages.
    const char         *cache_dir;
    /// Root directory for resolving local file references (e.g. images).
    const char         *root_dir;
    /// Root directory for local packages (@local and custom namespaces).
    const char         *local_packages_dir;
} TypstOptions;

/// Result returned by typst_compile. Free with typst_free_result.
typedef struct {
    uint8_t *pdf_data;       ///< Non-null on success.
    size_t   pdf_len;
    char    *error_message;  ///< Null-terminated string on failure.
    bool     success;
} TypstResult;

/// Compile a null-terminated UTF-8 Typst source string to PDF.
/// options may be NULL to use bundled fonts only and skip package support.
TypstResult typst_compile(const char *source, const TypstOptions *options);

/// Download one @preview package into cache_dir before compilation.
/// spec is formatted as "@preview/name:version".
TypstResult typst_prefetch_package(const char *spec, const char *cache_dir);

/// Free a TypstResult returned by typst_compile.
void typst_free_result(TypstResult result);

/// A single source-map entry mapping a PDF position to a source location.
typedef struct {
    uint32_t page;            ///< 0-based page index.
    float    y_pt;            ///< Y in PDF points from page top.
    float    x_pt;            ///< X in PDF points from page left.
    uint32_t source_offset;   ///< Byte offset in source.
    uint16_t source_length;   ///< Byte length of mapped range.
    uint32_t line;            ///< 1-based line number.
    uint16_t column;          ///< 1-based column number.
} SourceMapEntry;

/// Extended result with PDF data and source map.
/// Free with typst_free_result_with_map.
typedef struct {
    uint8_t        *pdf_data;
    size_t          pdf_len;
    char           *error_message;
    bool            success;
    SourceMapEntry *source_map;
    size_t          source_map_len;
} TypstResultWithMap;

/// Compile Typst source to PDF and extract a source map.
/// options may be NULL. Free with typst_free_result_with_map.
TypstResultWithMap typst_compile_with_source_map(const char *source,
                                                  const TypstOptions *options);

/// Free a TypstResultWithMap.
void typst_free_result_with_map(TypstResultWithMap result);

/// Syntax-highlight tag IDs returned by typst_highlight.
enum {
    TypstHighlightTagComment = 0,
    TypstHighlightTagPunctuation = 1,
    TypstHighlightTagEscape = 2,
    TypstHighlightTagStrong = 3,
    TypstHighlightTagEmph = 4,
    TypstHighlightTagLink = 5,
    TypstHighlightTagRaw = 6,
    TypstHighlightTagLabel = 7,
    TypstHighlightTagRef = 8,
    TypstHighlightTagHeading = 9,
    TypstHighlightTagListMarker = 10,
    TypstHighlightTagListTerm = 11,
    TypstHighlightTagMathDelimiter = 12,
    TypstHighlightTagMathOperator = 13,
    TypstHighlightTagKeyword = 14,
    TypstHighlightTagOperator = 15,
    TypstHighlightTagNumber = 16,
    TypstHighlightTagString = 17,
    TypstHighlightTagFunction = 18,
    TypstHighlightTagInterpolated = 19,
    TypstHighlightTagError = 20,
};

/// A Typst syntax-highlight token in UTF-16 offsets for NSTextStorage.
typedef struct {
    uint32_t utf16_location;
    uint32_t utf16_length;
    uint32_t tag;
} TypstHighlightToken;

/// Result returned by typst_highlight. Free with typst_free_highlight_result.
typedef struct {
    TypstHighlightToken *tokens;
    size_t               token_len;
    char                *error_message;
    bool                 success;
} TypstHighlightResult;

/// Parse Typst source and return syntax-highlight tokens.
TypstHighlightResult typst_highlight(const char *source);

/// Free a TypstHighlightResult.
void typst_free_highlight_result(TypstHighlightResult result);

/// A single outline heading in UTF-16 offsets for NSTextStorage.
typedef struct {
    uint32_t utf16_location;
    uint32_t level;
    char    *title;
} TypstOutlineItem;

/// Result returned by typst_outline. Free with typst_free_outline_result.
typedef struct {
    TypstOutlineItem *items;
    size_t            item_len;
    char             *error_message;
    bool              success;
} TypstOutlineResult;

/// Parse Typst source and return heading outline entries.
TypstOutlineResult typst_outline(const char *source);

/// Free a TypstOutlineResult.
void typst_free_outline_result(TypstOutlineResult result);

/// A single Typst label definition.
typedef struct {
    char *name;
    char *kind;
} TypstLabelItem;

/// Result returned by typst_labels. Free with typst_free_label_result.
typedef struct {
    TypstLabelItem *items;
    size_t          item_len;
    char           *error_message;
    bool            success;
} TypstLabelResult;

/// Parse Typst source and return label definitions.
TypstLabelResult typst_labels(const char *source);

/// Free a TypstLabelResult.
void typst_free_label_result(TypstLabelResult result);

/// A single bibliography entry parsed by Hayagriva.
typedef struct {
    char *key;
    char *entry_type;
    char *title;
} TypstBibliographyItem;

/// Result returned by typst_bibliography_entries. Free with typst_free_bibliography_result.
typedef struct {
    TypstBibliographyItem *entries;
    size_t                 entry_len;
    char                  *error_message;
    bool                   success;
} TypstBibliographyResult;

/// Parse BibLaTeX or Hayagriva YAML content and return cite entries.
TypstBibliographyResult typst_bibliography_entries(const char *source, const char *file_name);

/// Free a TypstBibliographyResult.
void typst_free_bibliography_result(TypstBibliographyResult result);

/// A literal value accepted by a Typst function parameter.
typedef struct {
    char *label;
    char *insert_text;
    char *detail;
} TypstCompletionValue;

/// A Typst function parameter as exposed by Func::params().
typedef struct {
    char                 *name;
    char                 *docs;
    char                 *input;
    char                 *default_value;
    TypstCompletionValue *values;
    size_t                value_len;
    bool                  positional;
    bool                  named;
    bool                  variadic;
    bool                  required;
    bool                  settable;
} TypstCompletionParam;

/// Symbol kinds returned by typst_completion_symbols.
enum {
    TypstCompletionKindKeyword = 0,
    TypstCompletionKindFunction = 1,
    TypstCompletionKindValue = 2,
    TypstCompletionKindType = 3,
    TypstCompletionKindModule = 4,
    TypstCompletionKindLocal = 5,
};

/// A Typst completion symbol from Library::default().global or source-local syntax.
typedef struct {
    char                 *name;
    uint32_t              kind;
    char                 *detail;
    uint32_t              utf16_location;
    uint32_t              utf16_scope_end;
    TypstCompletionParam *params;
    size_t                param_len;
} TypstCompletionSymbol;

/// Result returned by typst_completion_symbols. Free with typst_free_completion_symbol_result.
typedef struct {
    TypstCompletionSymbol *symbols;
    size_t                 symbol_len;
    char                  *error_message;
    bool                   success;
} TypstCompletionSymbolResult;

/// Return Typst-library symbols plus #let / named #import symbols from source.
TypstCompletionSymbolResult typst_completion_symbols(const char *source);

/// Free a TypstCompletionSymbolResult.
void typst_free_completion_symbol_result(TypstCompletionSymbolResult result);

/// One syntax node in the cursor context chain.
typedef struct {
    char     *kind;
    uint32_t  utf16_location;
    uint32_t  utf16_length;
} TypstContextItem;

/// Result returned by typst_context_at. Free with typst_free_context_result.
typedef struct {
    TypstContextItem *items;
    size_t            item_len;
    char             *function_name;
    char             *error_message;
    bool              success;
} TypstContextResult;

/// Return the syntax kind chain and innermost function call at a UTF-16 offset.
TypstContextResult typst_context_at(const char *source, uint32_t utf16_offset);

/// Free a TypstContextResult.
void typst_free_context_result(TypstContextResult result);

/// Returns typst-ios crate version (static UTF-8 string).
const char *typst_version(void);
