import SwiftUI
import UIKit

/// Opt-in, read-only inspection of the scroll view enclosing the tree content.
struct ProjectFileScrollProbe: UIViewRepresentable {
    static var isEnabled: Bool {
        if ProcessInfo.processInfo.arguments.contains("-UITestFileScrollDiagnostics") { return true }
        let value = Bundle.main.object(forInfoDictionaryKey: "INKPOND_FILE_SCROLL_DIAGNOSTICS")
        if let enabled = value as? Bool { return enabled }
        return (value as? String)?.uppercased() == "YES"
    }

    var publish: (String) -> Void

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.publish = publish
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        uiView.publish = publish
    }

    static func dismantleUIView(_ uiView: ProbeView, coordinator: ()) {
        uiView.stop()
        uiView.publish = nil
    }

    final class ProbeView: UIView {
        var publish: ((String) -> Void)?
        private var displayLink: CADisplayLink?
        private final class DisplayProxy: NSObject {
            weak var owner: ProbeView?
            @objc func tick(_ link: CADisplayLink) { owner?.tick(link.timestamp) }
        }
        private struct PanFrame {
            let id: UInt
            let owner: UInt
            let state: Int
            let touches: Int
            let translation: CGPoint
            let velocity: CGPoint
        }
        private struct Frame {
            let time: CFTimeInterval
            let scrollID: UInt
            let offset: CGPoint
            let bounds: CGRect
            let size: CGSize
            let raw: UIEdgeInsets
            let adjusted: UIEdgeInsets
            let minimum: CGPoint
            let maximum: CGPoint
            let rect: CGRect
            let clipped: CGRect
            let clips: [(UInt, CGRect)]
            let pans: [PanFrame]
            let localTranslation: CGPoint
            let localVelocity: CGPoint
        }
        private var ring = [Frame?](repeating: nil, count: 180)
        private var cursor = 0
        private var count = 0
        private var wasTouching = false
        private var lastSummary: CFTimeInterval = 0
        private var frozen = ""

        private func identity(_ object: AnyObject) -> UInt {
            UInt(bitPattern: Unmanaged.passUnretained(object).toOpaque())
        }
        private var previousHeader = ""
        private var headerLogCount = 0
        private var previous = ""
        private weak var historyWindow: UIWindow?
        private var transitions: [String] = []

        override func didMoveToWindow() {
            super.didMoveToWindow()
            stop()
            guard let window else { return }
            if historyWindow !== window {
                historyWindow = window
                transitions.removeAll()
                previous = ""
                frozen = ""
            }
            // The run loop retains only the proxy; it holds this view weakly.
            let proxy = DisplayProxy()
            proxy.owner = self
            let link = CADisplayLink(target: proxy, selector: #selector(DisplayProxy.tick(_:)))
            displayLink = link
            link.add(to: .main, forMode: .common)
        }

        func stop() {
            displayLink?.invalidate()
            displayLink = nil
            ring = [Frame?](repeating: nil, count: 180)
            cursor = 0
            count = 0
            wasTouching = false
            lastSummary = 0
        }

        private func tick(_ time: CFTimeInterval) {
            guard let window else { return }
            var views: [UIView] = []
            var ancestor = superview
            while let view = ancestor, views.count < 32 {
                views.append(view)
                ancestor = view.superview
            }
            guard let scroll = views.compactMap({ $0 as? UIScrollView }).first else {
                if time - lastSummary >= 0.5 { lastSummary = time; sample() }
                return
            }
            var pans: [PanFrame] = []
            var touching = scroll.isTracking
            // Public recognizers only, including ancestors that may move a sheet.
            for view in views {
                for case let pan as UIPanGestureRecognizer in (view.gestureRecognizers ?? []).prefix(12) {
                    touching = touching || pan.numberOfTouches > 0 || pan.state == .began || pan.state == .changed
                    pans.append(PanFrame(id: identity(pan), owner: identity(view),
                                         state: pan.state.rawValue, touches: pan.numberOfTouches,
                                         translation: pan.translation(in: window), velocity: pan.velocity(in: window)))
                }
            }
            if touching || wasTouching {
                let rect = scroll.convert(scroll.bounds, to: window)
                var clipped = rect.intersection(window.bounds)
                var clips: [(UInt, CGRect)] = []
                var parent = scroll.superview
                var depth = 0
                while let view = parent, depth < 32 {
                    if view.clipsToBounds {
                        clipped = clipped.intersection(view.convert(view.bounds, to: window))
                        clips.append((identity(view), clipped))
                    }
                    parent = view.superview
                    depth += 1
                }
                let inset = scroll.adjustedContentInset
                let minimum = CGPoint(x: -inset.left, y: -inset.top)
                let maximum = CGPoint(x: max(minimum.x, scroll.contentSize.width - scroll.bounds.width + inset.right),
                                      y: max(minimum.y, scroll.contentSize.height - scroll.bounds.height + inset.bottom))
                ring[cursor] = Frame(time: time, scrollID: identity(scroll), offset: scroll.contentOffset,
                                     bounds: scroll.bounds, size: scroll.contentSize, raw: scroll.contentInset,
                                     adjusted: inset, minimum: minimum, maximum: maximum,
                                     rect: rect, clipped: clipped, clips: clips, pans: pans,
                                     localTranslation: scroll.panGestureRecognizer.translation(in: scroll),
                                     localVelocity: scroll.panGestureRecognizer.velocity(in: scroll))
                cursor = (cursor + 1) % ring.count
                count = min(count + 1, ring.count)
            }
            if wasTouching && !touching {
                freezeHistory()
                lastSummary = time
                sample()
            } else if !touching && time - lastSummary >= 0.5 {
                lastSummary = time
                sample()
            }
            wasTouching = touching
        }

        private func freezeHistory() {
            func n(_ value: CGFloat) -> String { String(format: "%.1f", Double(value)) }
            func point(_ p: CGPoint) -> String { "\(n(p.x)),\(n(p.y))" }
            func rect(_ r: CGRect) -> String {
                r.isNull ? "null" : "\(point(r.origin)),\(n(r.width)),\(n(r.height))"
            }
            func inset(_ i: UIEdgeInsets) -> String { "\(n(i.top)),\(n(i.left)),\(n(i.bottom)),\(n(i.right))" }
            var rows: [String] = []
            var bytes = 0
            // Newest 80, emitted chronologically; drop whole older rows to bound output.
            for age in 0..<min(count, 80) {
                guard let f = ring[(cursor - 1 - age + ring.count) % ring.count] else { continue }
                let pans = f.pans.map {
                    "\($0.id)@\($0.owner):\($0.state)/\($0.touches):\(point($0.translation))/\(point($0.velocity))"
                }.joined(separator: ";")
                let clips = f.clips.map { "\($0.0):\(rect($0.1))" }.joined(separator: ";")
                let row = "t=\(String(format: "%.4f", f.time)) s=\(f.scrollID) o=\(point(f.offset)) b=\(rect(f.bounds)) c=\(n(f.size.width)),\(n(f.size.height)) i=\(inset(f.raw)) a=\(inset(f.adjusted)) min=\(point(f.minimum)) max=\(point(f.maximum)) win=\(rect(f.rect)) clip=\(rect(f.clipped)) localTV=\(point(f.localTranslation))/\(point(f.localVelocity)) clips=[\(clips)] pans=[\(pans)]"
                guard bytes + row.utf8.count + 1 <= 15000 else { break }
                rows.append(row)
                bytes += row.utf8.count + 1
            }
            frozen = "frames[post-touch,ring=\(count)/180,last<=80; inset=TLBR; pan=id@view:state/touches:windowTranslation/velocity]\n" + rows.reversed().joined(separator: "\n")
        }

        /// Observes the same window only, without responder traversal or AX mutation.
        /// All bar descendants are included (not just UIButton: SwiftUI may host items).
        /// Never read text, labels, values, hints, item titles, or arbitrary identifiers.
        private func headerSnapshot() -> String {
            guard ProjectFileScrollProbe.isEnabled else { return "" }
            guard let window else { return "public-header-probe window=nil" }
            func row(_ view: UIView, _ location: String) -> String {
                let t = view.transform
                let role: String
                switch view.accessibilityIdentifier {
                case "project-files.done": role = "done"
                default: role = "other-or-absent"
                }
                let control = (view as? UIControl).map { " enabled=\($0.isEnabled) selected=\($0.isSelected)" } ?? ""
                return "\(location) id=\(identity(view)) type=\(String(describing: type(of: view))) role=\(role) frame=\(view.frame) bounds=\(view.bounds) windowRect=\(view.convert(view.bounds, to: window)) transform=[\(t.a),\(t.b),\(t.c),\(t.d),\(t.tx),\(t.ty)] hidden=\(view.isHidden) alpha=\(view.alpha) clips=\(view.clipsToBounds) interaction=\(view.isUserInteractionEnabled) axElement=\(view.isAccessibilityElement) axHidden=\(view.accessibilityElementsHidden) axModal=\(view.accessibilityViewIsModal) axGroup=\(view.shouldGroupAccessibilityChildren) axTraits=\(view.accessibilityTraits.rawValue) axFrame=\(view.accessibilityFrame)\(control)"
            }
            // Bounded DFS; identify UINavigationBar by public type, never private names.
            var pending: [UIView] = [window]
            var visited = 0
            var bars: [UINavigationBar] = []
            while let view = pending.popLast(), visited < 512 {
                visited += 1
                if let bar = view as? UINavigationBar { bars.append(bar) }
                pending.append(contentsOf: view.subviews.prefix(64).reversed())
            }
            var lines = ["public-header-probe scope=probe-window bars=\(bars.count) visited=\(visited) searchTruncated=\(!pending.isEmpty) windowBounds=\(window.bounds) sizeClasses=\(window.traitCollection.horizontalSizeClass.rawValue),\(window.traitCollection.verticalSizeClass.rawValue)"]
            for (index, bar) in bars.prefix(4).enumerated() {
                lines.append(row(bar, "bar[\(index)]"))
                var ancestor = bar.superview
                var depth = 0
                while let view = ancestor, depth < 16 {
                    lines.append(row(view, "bar[\(index)].ancestor[\(depth)]"))
                    ancestor = view.superview
                    depth += 1
                }
                lines.append("bar[\(index)] ancestorsTruncated=\(ancestor != nil)")
                var descendants: [(UIView, Int)] = bar.subviews.prefix(64).reversed().map { ($0, 1) }
                var count = 0
                while let (view, depth) = descendants.popLast(), count < 64 {
                    lines.append(row(view, "bar[\(index)].child[\(count)] depth=\(depth)"))
                    count += 1
                    if depth < 12 {
                        descendants.append(contentsOf: view.subviews.prefix(64).reversed().map { ($0, depth + 1) })
                    } else if !view.subviews.isEmpty {
                        lines.append("bar[\(index)] childDepthTruncated=true")
                    }
                }
                lines.append("bar[\(index)] childrenTruncated=\(!descendants.isEmpty)")
            }
            lines.append("barsTruncated=\(bars.count > 4)")
            // Keep whole rows so a cut cannot masquerade as a complete measurement.
            var result = ""
            for line in lines {
                guard result.utf8.count + line.utf8.count < 24000 else {
                    result += "outputTruncated=true\n"
                    break
                }
                result += line + "\n"
            }
            // At most 24 changed snapshots per probe lifetime; latest remains in AX
            // diagnostic value even after the console budget is exhausted.
            if result != previousHeader {
                previousHeader = result
                if headerLogCount < 24 {
                    headerLogCount += 1
                    NSLog("%@", "headerSnapshot[\(headerLogCount)/24] " + result)
                }
            }
            return result
        }

        private func sample() {
            var lines: [String] = []
            var ancestor = superview
            var depth = 0
            var scrollIndex = 0
            while let view = ancestor, depth < 32 {
                // Types and geometry only: never labels, values, paths, or text.
                let gestures = (view.gestureRecognizers ?? []).prefix(12).map {
                    "\(String(describing: type(of: $0)))#\(identity($0)):enabled=\($0.isEnabled),state=\($0.state.rawValue)"
                }.joined(separator: ";")
                lines.append("ancestor[\(depth)] id=\(identity(view)) type=\(String(describing: type(of: view))) frame=\(view.frame) bounds=\(view.bounds) interaction=\(view.isUserInteractionEnabled) hidden=\(view.isHidden) alpha=\(view.alpha) clips=\(view.clipsToBounds) gestures=[\(gestures)]")
                if let scroll = view as? UIScrollView {
                    lines.append("scroll[\(scrollIndex)] depth=\(depth) bounds=\(scroll.bounds) contentSize=\(scroll.contentSize) contentOffset=\(scroll.contentOffset) adjustedInsets=\(scroll.adjustedContentInset) isScrollEnabled=\(scroll.isScrollEnabled) userInteraction=\(scroll.isUserInteractionEnabled) panState=\(scroll.panGestureRecognizer.state.rawValue) tracking=\(scroll.isTracking) dragging=\(scroll.isDragging) decelerating=\(scroll.isDecelerating)")
                    if let window = scroll.window {
                        let windowRect = scroll.convert(scroll.bounds, to: window)
                        let visibleRect = scroll.convert(
                            scroll.bounds.inset(by: scroll.adjustedContentInset), to: window
                        ).intersection(window.bounds)
                        lines.append("scroll[\(scrollIndex)] windowRect=\(windowRect) adjustedVisibleRect=\(visibleRect)")
                        if scrollIndex == 0 {
                            let tuple = "offset=\(scroll.contentOffset),pan=\(scroll.panGestureRecognizer.state.rawValue),tracking=\(scroll.isTracking),dragging=\(scroll.isDragging),translation=\(scroll.panGestureRecognizer.translation(in: scroll)),velocity=\(scroll.panGestureRecognizer.velocity(in: scroll))"
                            if transitions.last != tuple {
                                transitions.append(tuple)
                                if transitions.count > 12 { transitions.removeFirst() }
                            }
                            // Mirror the helper's upward drag geometry: exclude
                            // adjusted chrome, inset 16pt, start 10% above bottom,
                            // then move upward by 40% of the content viewport.
                            let content = visibleRect.insetBy(
                                dx: min(16, visibleRect.width / 4),
                                dy: min(16, visibleRect.height / 4)
                            )
                            if !content.isEmpty {
                                let start = CGPoint(x: content.midX, y: content.maxY - content.height * 0.1)
                                let end = CGPoint(x: start.x, y: start.y - content.height * 0.4)
                                for (name, point) in [("start", start), ("end", end)] {
                                    let target = window.hitTest(point, with: nil)
                                    var candidate = target
                                    var belongsToScroll = false
                                    while let current = candidate {
                                        if current === scroll { belongsToScroll = true; break }
                                        candidate = current.superview
                                    }
                                    let targetType = target.map { String(describing: type(of: $0)) } ?? "nil"
                                    lines.append("dragHit[\(name)] windowPoint=\(point) targetType=\(targetType) includesExactScroll=\(belongsToScroll)")
                                }
                            }
                        }
                    }
                    scrollIndex += 1
                }
                ancestor = view.superview
                depth += 1
            }
            let summary = "public-scroll-probe scrollCount=\(scrollIndex) ancestorsTruncated=\(ancestor != nil)\ntransitions[nearest,last12]=\(transitions.joined(separator: " -> "))\n" + lines.joined(separator: "\n")
            let snapshot = headerSnapshot() + String(summary.prefix(8000)) + "\n" + frozen
            guard snapshot != previous else { return }
            previous = snapshot
            publish?(snapshot)
        }
    }
}

/// Separate, noninteractive AX endpoint; it does not expose project content.
struct ProjectFileScrollDiagnosticValue: UIViewRepresentable {
    var value: String

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = true
        view.accessibilityIdentifier = "project-files.scroll-diagnostics"
        view.accessibilityLabel = "Scroll diagnostics"
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        uiView.accessibilityValue = value
    }
}
