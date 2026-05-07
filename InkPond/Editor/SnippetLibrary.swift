//
//  SnippetLibrary.swift
//  InkPond
//

import Foundation

enum SnippetLibrary {
    static let builtIn: [Snippet] = [
        // MARK: - Document Setup
        Snippet(
            title: BuiltInSnippetText.basicDocument,
            category: BuiltInSnippetText.documentSetup,
            body: """
            #set page(paper: "a4")
            #set text(font: "New Computer Modern", size: 11pt)

            $0
            """,
            keywords: ["page", "setup", "document", "template"],
            isBuiltIn: true
        ),
        Snippet(
            title: BuiltInSnippetText.articleTemplate,
            category: BuiltInSnippetText.documentSetup,
            body: """
            #set page(paper: "a4", margin: 2.5cm)
            #set text(font: "New Computer Modern", size: 11pt)
            #set par(justify: true)
            #set heading(numbering: "1.1")

            #align(center)[
              #text(size: 18pt, weight: "bold")[$0]
              #v(0.5em)
              #text(size: 12pt)[Author Name]
              #v(0.5em)
              #text(size: 10pt, fill: gray)[#datetime.today().display()]
            ]

            #v(1em)

            *Abstract.* #lorem(50)

            = Introduction

            """,
            keywords: ["article", "paper", "academic", "template"],
            isBuiltIn: true
        ),
        Snippet(
            title: BuiltInSnippetText.letterTemplate,
            category: BuiltInSnippetText.documentSetup,
            body: """
            #set page(paper: "a4", margin: 2.5cm)
            #set text(size: 11pt)

            #align(right)[
              Your Name \\
              Your Address \\
              #datetime.today().display()
            ]

            #v(2em)

            Recipient Name \\
            Recipient Address

            #v(1em)

            Dear $0,

            #lorem(30)

            Sincerely,

            Your Name
            """,
            keywords: ["letter", "mail", "correspondence"],
            isBuiltIn: true
        ),
        Snippet(
            title: BuiltInSnippetText.presentationSlide,
            category: BuiltInSnippetText.documentSetup,
            body: """
            #set page(width: 25.4cm, height: 14.29cm, margin: 2cm)
            #set text(size: 20pt)

            #align(center + horizon)[
              #text(size: 36pt, weight: "bold")[$0]
            ]
            """,
            keywords: ["slide", "presentation", "16:9", "deck"],
            isBuiltIn: true
        ),

        // MARK: - Layout
        Snippet(
            title: BuiltInSnippetText.twoColumns,
            category: BuiltInSnippetText.layout,
            body: "#columns(2)[$0]",
            keywords: ["columns", "layout", "two"],
            isBuiltIn: true
        ),
        Snippet(
            title: BuiltInSnippetText.centeredBlock,
            category: BuiltInSnippetText.layout,
            body: "#align(center)[$0]",
            keywords: ["center", "align", "middle"],
            isBuiltIn: true
        ),
        Snippet(
            title: BuiltInSnippetText.pageBreak,
            category: BuiltInSnippetText.layout,
            body: "#pagebreak()\n$0",
            keywords: ["page", "break", "newpage"],
            isBuiltIn: true
        ),

        // MARK: - Figure & Table
        Snippet(
            title: BuiltInSnippetText.figureWithCaption,
            category: BuiltInSnippetText.figureAndTable,
            body: """
            #figure(
              image("$0"),
              caption: [Caption text],
            ) <fig:label>
            """,
            keywords: ["figure", "image", "caption", "label"],
            isBuiltIn: true
        ),
        Snippet(
            title: BuiltInSnippetText.tableTwoColumns,
            category: BuiltInSnippetText.figureAndTable,
            body: """
            #figure(
              table(
                columns: 2,
                [*Header 1*], [*Header 2*],
                [$0], [],
              ),
              caption: [Caption text],
            )
            """,
            keywords: ["table", "grid", "two", "columns"],
            isBuiltIn: true
        ),
        Snippet(
            title: BuiltInSnippetText.tableThreeColumns,
            category: BuiltInSnippetText.figureAndTable,
            body: """
            #figure(
              table(
                columns: 3,
                [*Header 1*], [*Header 2*], [*Header 3*],
                [$0], [], [],
              ),
              caption: [Caption text],
            )
            """,
            keywords: ["table", "grid", "three", "columns"],
            isBuiltIn: true
        ),
        Snippet(
            title: BuiltInSnippetText.codeBlockWithCaption,
            category: BuiltInSnippetText.figureAndTable,
            body: """
            #figure(
              ```$0
              code here
              ```,
              caption: [Caption text],
            )
            """,
            keywords: ["code", "figure", "caption", "listing"],
            isBuiltIn: true
        ),

        // MARK: - Math
        Snippet(
            title: BuiltInSnippetText.inlineMath,
            category: BuiltInSnippetText.math,
            body: "$$$0$",
            keywords: ["math", "inline", "equation"],
            isBuiltIn: true
        ),
        Snippet(
            title: BuiltInSnippetText.displayMath,
            category: BuiltInSnippetText.math,
            body: "$ $0 $",
            keywords: ["math", "display", "equation", "block"],
            isBuiltIn: true
        ),
        Snippet(
            title: BuiltInSnippetText.alignedEquations,
            category: BuiltInSnippetText.math,
            body: """
            $ $0 &= a \\\\ &= b $
            """,
            keywords: ["math", "align", "equations", "multiline"],
            isBuiltIn: true
        ),
        Snippet(
            title: BuiltInSnippetText.matrix,
            category: BuiltInSnippetText.math,
            body: """
            $ mat(
              $0, 0;
              0, 1;
            ) $
            """,
            keywords: ["math", "matrix", "linear algebra"],
            isBuiltIn: true
        ),

        // MARK: - Bibliography
        Snippet(
            title: BuiltInSnippetText.bibliographySetup,
            category: BuiltInSnippetText.bibliography,
            body: "#bibliography(\"$0.bib\")",
            keywords: ["bibliography", "references", "bib"],
            isBuiltIn: true
        ),
        Snippet(
            title: BuiltInSnippetText.citation,
            category: BuiltInSnippetText.bibliography,
            body: "@$0",
            keywords: ["cite", "citation", "reference"],
            isBuiltIn: true
        ),

        // MARK: - Code
        Snippet(
            title: BuiltInSnippetText.codeBlock,
            category: BuiltInSnippetText.code,
            body: "```$0\ncode\n```",
            keywords: ["code", "block", "listing", "raw"],
            isBuiltIn: true
        ),
        Snippet(
            title: BuiltInSnippetText.inlineCode,
            category: BuiltInSnippetText.code,
            body: "`$0`",
            keywords: ["code", "inline", "raw", "monospace"],
            isBuiltIn: true
        ),
    ]

    static var categoryOrder: [String] {
        [
            BuiltInSnippetText.documentSetup,
            BuiltInSnippetText.layout,
            BuiltInSnippetText.figureAndTable,
            BuiltInSnippetText.math,
            BuiltInSnippetText.bibliography,
            BuiltInSnippetText.code,
        ]
    }
}

private enum BuiltInSnippetText {
    static var documentSetup: String { L10n.tr("snippet.builtin.category.document_setup") }
    static var layout: String { L10n.tr("snippet.builtin.category.layout") }
    static var figureAndTable: String { L10n.tr("snippet.builtin.category.figure_table") }
    static var math: String { L10n.tr("snippet.builtin.category.math") }
    static var bibliography: String { L10n.tr("snippet.builtin.category.bibliography") }
    static var code: String { L10n.tr("snippet.builtin.category.code") }

    static var basicDocument: String { L10n.tr("snippet.builtin.title.basic_document") }
    static var articleTemplate: String { L10n.tr("snippet.builtin.title.article_template") }
    static var letterTemplate: String { L10n.tr("snippet.builtin.title.letter_template") }
    static var presentationSlide: String { L10n.tr("snippet.builtin.title.presentation_slide") }
    static var twoColumns: String { L10n.tr("snippet.builtin.title.two_columns") }
    static var centeredBlock: String { L10n.tr("snippet.builtin.title.centered_block") }
    static var pageBreak: String { L10n.tr("snippet.builtin.title.page_break") }
    static var figureWithCaption: String { L10n.tr("snippet.builtin.title.figure_with_caption") }
    static var tableTwoColumns: String { L10n.tr("snippet.builtin.title.table_two_columns") }
    static var tableThreeColumns: String { L10n.tr("snippet.builtin.title.table_three_columns") }
    static var codeBlockWithCaption: String { L10n.tr("snippet.builtin.title.code_block_with_caption") }
    static var inlineMath: String { L10n.tr("snippet.builtin.title.inline_math") }
    static var displayMath: String { L10n.tr("snippet.builtin.title.display_math") }
    static var alignedEquations: String { L10n.tr("snippet.builtin.title.aligned_equations") }
    static var matrix: String { L10n.tr("snippet.builtin.title.matrix") }
    static var bibliographySetup: String { L10n.tr("snippet.builtin.title.bibliography_setup") }
    static var citation: String { L10n.tr("snippet.builtin.title.citation") }
    static var codeBlock: String { L10n.tr("snippet.builtin.title.code_block") }
    static var inlineCode: String { L10n.tr("snippet.builtin.title.inline_code") }
}
