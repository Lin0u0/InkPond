//
//  ScrollEdgeEffectSupport.swift
//  InkPond
//

import SwiftUI
import UIKit

extension View {
    @ViewBuilder
    func softScrollEdgeEffect(for edges: Edge.Set = .all) -> some View {
        if #available(iOS 26, *) {
            scrollEdgeEffectStyle(.soft, for: edges)
                .scrollEdgeEffectHidden(false, for: edges)
        } else {
            self
        }
    }

    @ViewBuilder
    func scrollEdgeElementContainer(edge: UIRectEdge = .top) -> some View {
        if #available(iOS 26, *) {
            self.background {
                ScrollEdgeElementContainerBridge(edge: edge)
                    .allowsHitTesting(false)
            }
        } else {
            self
        }
    }

}

extension UIScrollView {
    func applySoftScrollEdgeEffects() {
        guard #available(iOS 26, *) else { return }

        topEdgeEffect.style = .soft
        bottomEdgeEffect.style = .soft
        leftEdgeEffect.style = .soft
        rightEdgeEffect.style = .soft
        topEdgeEffect.isHidden = false
        bottomEdgeEffect.isHidden = false
        leftEdgeEffect.isHidden = false
        rightEdgeEffect.isHidden = false
    }
}

private struct ScrollEdgeElementContainerBridge: UIViewRepresentable {
    let edge: UIRectEdge

    func makeUIView(context: Context) -> ScrollEdgeElementContainerBridgeView {
        let view = ScrollEdgeElementContainerBridgeView()
        view.edge = edge
        return view
    }

    func updateUIView(_ uiView: ScrollEdgeElementContainerBridgeView, context: Context) {
        uiView.edge = edge
        uiView.scheduleRefresh()
    }
}

private final class ScrollEdgeElementContainerBridgeView: UIView {
    var edge: UIRectEdge = .top {
        didSet { scheduleRefresh() }
    }

    private weak var interactionHost: UIView?
    private var managedInteractions: [UIInteraction] = []
    private var refreshWorkItem: DispatchWorkItem?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        scheduleRefresh()
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        scheduleRefresh()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scheduleRefresh()
    }

    func scheduleRefresh() {
        refreshWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.refreshInteractions()
        }
        refreshWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    private func refreshInteractions() {
        guard #available(iOS 26, *) else { return }
        removeManagedInteractions()

        guard let window, bounds.width > 0, bounds.height > 0 else { return }
        let host = superview ?? self
        interactionHost = host
        let candidates = candidateScrollViews(in: window)

        for scrollView in candidates {
            scrollView.applySoftScrollEdgeEffects()
            let interaction = UIScrollEdgeElementContainerInteraction()
            interaction.scrollView = scrollView
            interaction.edge = edge
            host.addInteraction(interaction)
            managedInteractions.append(interaction)
        }
    }

    private func removeManagedInteractions() {
        guard let interactionHost else {
            managedInteractions.removeAll()
            return
        }

        for interaction in managedInteractions {
            interactionHost.removeInteraction(interaction)
        }
        managedInteractions.removeAll()
    }

    private func candidateScrollViews(in root: UIView) -> [UIScrollView] {
        let bridgeFrame = convert(bounds, to: root)
        return collectScrollViews(in: root).filter { scrollView in
            guard scrollView.window === window,
                  !scrollView.isHidden,
                  scrollView.alpha > 0,
                  scrollView.bounds.width > 0,
                  scrollView.bounds.height > 0 else {
                return false
            }

            let scrollFrame = scrollView.convert(scrollView.bounds, to: root)
            guard scrollFrame.width > 0, scrollFrame.height > 0 else { return false }
            guard edge == .left || edge == .right || scrollFrame.height >= bridgeFrame.height else {
                return false
            }

            let overlapsHorizontally = scrollFrame.maxX > bridgeFrame.minX
                && scrollFrame.minX < bridgeFrame.maxX
            guard overlapsHorizontally else { return false }

            switch edge {
            case .top:
                return scrollFrame.minY <= bridgeFrame.maxY + 120
                    && scrollFrame.maxY > bridgeFrame.maxY
            case .bottom:
                return scrollFrame.maxY >= bridgeFrame.minY - 120
                    && scrollFrame.minY < bridgeFrame.minY
            case .left:
                return scrollFrame.minX <= bridgeFrame.maxX + 120
                    && scrollFrame.maxX > bridgeFrame.maxX
            case .right:
                return scrollFrame.maxX >= bridgeFrame.minX - 120
                    && scrollFrame.minX < bridgeFrame.minX
            default:
                return false
            }
        }
    }

    private func collectScrollViews(in view: UIView) -> [UIScrollView] {
        var result: [UIScrollView] = []
        if let scrollView = view as? UIScrollView {
            result.append(scrollView)
        }

        for subview in view.subviews {
            result.append(contentsOf: collectScrollViews(in: subview))
        }
        return result
    }
}
