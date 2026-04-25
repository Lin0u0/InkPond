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

struct TypstContextNodeInfo: Equatable, Sendable {
    let kind: String
    let location: Int
    let length: Int
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
}
