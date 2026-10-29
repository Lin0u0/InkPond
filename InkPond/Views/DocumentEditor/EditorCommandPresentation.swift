import SwiftUI
import UIKit

/// An editing presentation is anchored to a particular loaded buffer, not just a
/// path: switching away and back must not revive an asynchronous insertion.
struct EditorCommandAnchor: Equatable {
    let projectID: String
    let fileName: String
    let loadToken: UUID
    let selection: NSRange
    let restoreFocus: Bool

    func matches(projectID: String, fileName: String, loadToken: UUID, writable: Bool) -> Bool {
        writable && self.projectID == projectID && self.fileName == fileName && self.loadToken == loadToken
    }
}

@MainActor @Observable
final class EditorCommandTarget {
    private weak var textView: UITextView?
    private(set) var canUndo = false
    private(set) var canRedo = false

    func register(_ view: UITextView) { textView = view }
    func refresh() {
        canUndo = textView?.isEditable == true && textView?.undoManager?.canUndo == true
        canRedo = textView?.isEditable == true && textView?.undoManager?.canRedo == true
    }
    var selection: NSRange? { textView?.selectedRange }
    func undo() { guard textView?.isEditable == true else { return }; textView?.undoManager?.undo(); refresh() }
    func redo() { guard textView?.isEditable == true else { return }; textView?.undoManager?.redo(); refresh() }
}

enum EditorCommandPanel: Equatable { case commands, symbols, snippets }

struct EditorCommandGeometry: Equatable {
    let bounds: CGRect
    let region: CGRect
    let needsPanel: Bool
    var localBounds: CGRect = .zero
    var safeInsets: EdgeInsets = EdgeInsets()
    var expandedRegions: [CGRect] = []

    func canPresent(minimumSize: CGSize) -> Bool {
        region.width >= minimumSize.width && region.height >= minimumSize.height
    }

    static func usable(in bounds: CGRect, excluding exclusions: [CGRect]) -> CGRect {
        guard bounds.width > 40, bounds.height > 40 else { return .zero }
        // Keep the existing 20-point editor boundary around both the exterior
        // and active reserved margins; no control is placed on a fold edge.
        return SlideshowUsableRegion.largest(in: bounds.insetBy(dx: 20, dy: 20),
                                            excluding: exclusions.map { $0.insetBy(dx: -20, dy: -20) })
    }
}

struct EditorCommandGeometryKey: PreferenceKey {
    static var defaultValue: EditorCommandGeometry? { nil }
    static func reduce(value: inout EditorCommandGeometry?, nextValue: () -> EditorCommandGeometry?) {
        if let next = nextValue() { value = next }
    }
}

struct EditorCommandRegionHost<Content: View>: View {
    let panel: EditorCommandPanel?
    let interactionEnabled: Bool
    let content: () -> Content

    var body: some View {
        GeometryReader { proxy in
            let geometry = measure(proxy)
            ZStack(alignment: .topLeading) {
                Color.clear
                    .allowsHitTesting(false)
                    .preference(key: EditorCommandGeometryKey.self, value: geometry)
                if panel != nil {
                    let usable = interactionEnabled && geometry.canPresent(minimumSize: EditorCommandRecovery.minimumSize)
                    content()
                        .frame(width: geometry.region.width, height: geometry.region.height)
                        .clipped()
                        .offset(x: geometry.region.minX, y: geometry.region.minY)
                        .opacity(usable ? 1 : 0)
                        .allowsHitTesting(usable)
                        .accessibilityHidden(!usable)
                }
            }
        }
    }

    private func measure(_ proxy: GeometryProxy) -> EditorCommandGeometry {
        let insets = proxy.safeAreaInsets
        // This overlay already occupies the keyboard-resized source slot.
        // Insets describe that placement; subtracting them again double-counts it.
        let bounds = CGRect(origin: .zero, size: proxy.size)
        var exclusions: [CGRect] = []
        var needsPanel = false
        #if compiler(>=6.2) && INKPOND_DUO_SDK
        if #available(iOS 27.1, *) {
            let divisions = proxy.reservedRegions(kind: .division, layoutDirectionBehavior: .fixed).filter(\.isActive)
            needsPanel = !divisions.isEmpty
            let regions = divisions + proxy.reservedRegions(kind: .occlusion, layoutDirectionBehavior: .fixed).filter(\.isActive)
            exclusions = regions.map { region in
                CGRect(x: region.frame.minX - region.margins.leading,
                       y: region.frame.minY - region.margins.top,
                       width: region.frame.width + region.margins.leading + region.margins.trailing,
                       height: region.frame.height + region.margins.top + region.margins.bottom)
            }
        }
        #endif
        return EditorCommandGeometry(bounds: proxy.frame(in: .global),
                                     region: EditorCommandGeometry.usable(in: bounds, excluding: exclusions),
                                     needsPanel: needsPanel,
                                     localBounds: CGRect(origin: .zero, size: proxy.size),
                                     safeInsets: insets, expandedRegions: exclusions)
    }
}

/// Applied only to Labels inside the confined command List, never native Menus.
struct EditorCommandLabelStyle: LabelStyle {
    static let symbolColumn: CGFloat = 24

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .top, spacing: 8) {
            configuration.icon
                .font(.system(size: 20))
                .frame(width: Self.symbolColumn, alignment: .center)
            configuration.title
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct EditorCommandRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, 16)
            .contentShape(Rectangle())
            .background(configuration.isPressed ? Color.primary.opacity(0.08) : Color.clear)
            .listRowInsets(EdgeInsets())
    }
}

struct EditorCommandSymbol: Identifiable {
    let id: Int
    let literal: String
    var insertion: String { literal == "⇥" ? "  " : literal }
    var title: String { L10n.keyboardSymbolAccessibilityLabel(for: literal) + "  " + literal }
    static let all = ["⇥", "#", "$", "=", "*", "_", "{", "}", "[", "]", "(", ")", "<", ">", "@", "/"]
        .enumerated().map { EditorCommandSymbol(id: $0.offset, literal: $0.element) }
}

/// Size the non-scrolling title/Done row at the actual Dynamic Type category.
/// Reserve one whole command row too: clipping a header is never a fallback.
enum EditorCommandHeader {
    static func minimumSize(title: String, done: String, width: CGFloat,
                            category: UIContentSizeCategory) -> CGSize {
        let traits = UITraitCollection(preferredContentSizeCategory: category)
        let headline = UIFont.preferredFont(forTextStyle: .headline, compatibleWith: traits)
        let body = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits)
        let doneWidth = max(44, ceil((done as NSString).size(withAttributes: [.font: body]).width))
        if category.isAccessibilityCategory {
            let titleWidth = max(1, width - 32)
            let titleHeight = ceil((title as NSString).boundingRect(
                with: CGSize(width: titleWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: headline], context: nil).height)
            return CGSize(width: max(128, 32 + doneWidth),
                          height: titleHeight + max(44, ceil(body.lineHeight)) + 1 + 44)
        }
        let titleWidth = max(1, width - 32 - 8 - doneWidth)
        let titleHeight = ceil((title as NSString).boundingRect(
            with: CGSize(width: titleWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: headline], context: nil).height)
        return CGSize(width: 32 + 8 + doneWidth + 44,
                      height: max(44, max(titleHeight, ceil(body.lineHeight))) + 1 + 44)
    }
}

extension DynamicTypeSize {
    var commandContentSizeCategory: UIContentSizeCategory {
        switch self {
        case .xSmall: .extraSmall
        case .small: .small
        case .medium: .medium
        case .large: .large
        case .xLarge: .extraLarge
        case .xxLarge: .extraExtraLarge
        case .xxxLarge: .extraExtraExtraLarge
        case .accessibility1: .accessibilityMedium
        case .accessibility2: .accessibilityLarge
        case .accessibility3: .accessibilityExtraLarge
        case .accessibility4: .accessibilityExtraExtraLarge
        case .accessibility5: .accessibilityExtraExtraExtraLarge
        @unknown default: .large
        }
    }
}

/// Bounded diagnostic history only; no source or search-query state is accepted.
enum EditorCommandDiagnosticRing {
    static func appending(_ sample: String, to samples: [String]) -> [String] {
        guard samples.last != sample else { return samples }
        return Array((samples + [sample]).suffix(6))
    }
}

/// A pending presentation never outlives its captured loaded buffer.
struct EditorCommandPendingOpen {
    let anchor: EditorCommandAnchor
    let source: String

    func isCurrent(current: EditorCommandAnchor, source: String) -> Bool {
        anchor.matches(projectID: current.projectID, fileName: current.fileName,
                       loadToken: current.loadToken, writable: true)
            && anchor.selection == current.selection && self.source == source
    }

    func canOpen(current: EditorCommandAnchor, source: String, keyboardTransitionInFlight: Bool,
                 geometry: EditorCommandGeometry?, minimum: CGSize) -> Bool {
        guard isCurrent(current: current, source: source), !keyboardTransitionInFlight,
              let geometry else { return false }
        return geometry.canPresent(minimumSize: minimum)
    }
}

/// Design 1217: only a genuinely insufficient full-header viewport uses the
/// pinned icon row. Title/search/results share the existing vertical scroller.
enum EditorCommandRecovery {
    static let minimumSize = CGSize(width: 112, height: 89) // 8+44+8+44+8; 44+divider+44

    static func isNeeded(region: CGSize, fullHeaderMinimum: CGSize,
                         category: UIContentSizeCategory = .large) -> Bool {
        if region.width < fullHeaderMinimum.width || region.height < fullHeaderMinimum.height { return true }
        guard category == .accessibilityExtraExtraExtraLarge else { return false }
        // At maximum AX, keep the compact header while even a natural word
        // from the primary command cannot fit its content column. This is a
        // localized typography width, not a device/orientation or keyboard rule.
        let font = UIFont.preferredFont(forTextStyle: .body,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: category))
        let wordWidth = L10n.tr("editor.command.insert_snippet")
            .split(whereSeparator: { $0.isWhitespace })
            .map { ceil((String($0) as NSString).size(withAttributes: [.font: font]).width) }
            .max() ?? 0
        let readableRowWidth = 32 + EditorCommandLabelStyle.symbolColumn + 8 + wordWidth
        return region.width < readableRowWidth
    }
}

/// Design 1224 conservative path: an uncoordinated undersize is NOT proof
/// of stable layout. Keep the mounted session, but latch it nonmodal until
/// an explicit More continuation. Geometry recovery alone cannot resume it.
struct EditorCommandSessionSafety {
    private(set) var awaitingExplicitResume = false

    mutating func observe(region: CGSize) {
        if region.width < EditorCommandRecovery.minimumSize.width ||
            region.height < EditorCommandRecovery.minimumSize.height {
            awaitingExplicitResume = true
        }
    }

    mutating func resumeExplicitly(region: CGSize) -> Bool {
        guard region.width >= EditorCommandRecovery.minimumSize.width,
              region.height >= EditorCommandRecovery.minimumSize.height else { return false }
        awaitingExplicitResume = false
        return true
    }
}
