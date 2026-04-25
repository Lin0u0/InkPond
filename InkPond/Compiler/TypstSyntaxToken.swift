//
//  TypstSyntaxToken.swift
//  InkPond
//

import Foundation

struct TypstSyntaxToken: Equatable, Sendable {
    enum Kind: UInt32, Sendable {
        case comment = 0
        case punctuation = 1
        case escape = 2
        case strong = 3
        case emphasis = 4
        case link = 5
        case raw = 6
        case label = 7
        case reference = 8
        case heading = 9
        case listMarker = 10
        case listTerm = 11
        case mathDelimiter = 12
        case mathOperator = 13
        case keyword = 14
        case operatorToken = 15
        case number = 16
        case string = 17
        case function = 18
        case interpolated = 19
        case error = 20
    }

    let location: Int
    let length: Int
    let kind: Kind
}
