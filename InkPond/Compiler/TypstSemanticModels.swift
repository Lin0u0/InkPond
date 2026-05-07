//
//  TypstSemanticModels.swift
//  InkPond
//

import Foundation

struct TypstCompletionValueInfo: Equatable, Sendable {
    let label: String
    let insertText: String
    let detail: String?
}

struct TypstCompletionParamInfo: Equatable, Sendable {
    let name: String
    let docs: String?
    let input: String?
    let defaultValue: String?
    let values: [TypstCompletionValueInfo]
    let positional: Bool
    let named: Bool
    let variadic: Bool
    let required: Bool
    let settable: Bool
}

struct TypstCompletionSymbolInfo: Equatable, Sendable {
    enum Kind: UInt32, Sendable {
        case keyword = 0
        case function = 1
        case value = 2
        case type = 3
        case module = 4
        case local = 5
    }

    let name: String
    let kind: Kind
    let detail: String?
    let utf16Location: Int?
    let utf16ScopeEnd: Int?
    let params: [TypstCompletionParamInfo]
}

struct TypstLabelEntry: Equatable, Sendable {
    let name: String
    let kind: String
}

struct TypstBibliographyEntry: Equatable, Sendable {
    let key: String
    let type: String
    let title: String?

    var completionDetail: String {
        guard let title, !title.isEmpty else { return type }
        return "\(type): \(title)"
    }
}

struct TypstContextNodeInfo: Equatable, Sendable {
    let kind: String
    let location: Int
    let length: Int
}

/// Raw values mirror Rust `SyntaxKind` debug names returned by `typst_context_at`.
enum TypstContextKind: String, Sendable {
    case args = "Args"
    case blockComment = "BlockComment"
    case code = "Code"
    case codeBlock = "CodeBlock"
    case conditional = "Conditional"
    case contentBlock = "ContentBlock"
    case equation = "Equation"
    case forLoop = "ForLoop"
    case funcCall = "FuncCall"
    case lineComment = "LineComment"
    case markup = "Markup"
    case math = "Math"
    case moduleImport = "ModuleImport"
    case moduleInclude = "ModuleInclude"
    case named = "Named"
    case raw = "Raw"
    case rawDelim = "RawDelim"
    case rawLang = "RawLang"
    case str = "Str"
    case whileLoop = "WhileLoop"
}

struct TypstCursorContext: Equatable, Sendable {
    let nodes: [TypstContextNodeInfo]
    let functionName: String?

    var kindPath: [String] {
        nodes.map(\.kind)
    }

    func contains(_ kind: String) -> Bool {
        kindPath.contains(kind)
    }

    func contains(_ kind: TypstContextKind) -> Bool {
        contains(kind.rawValue)
    }
}
