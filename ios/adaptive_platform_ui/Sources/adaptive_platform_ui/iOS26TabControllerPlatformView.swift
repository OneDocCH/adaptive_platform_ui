import Flutter
import UIKit

/// Holds the controller's view. Says when it joins or leaves a window, so the controller can be
/// attached to and detached from the view controller hosting the Flutter view, and when its width
/// settles.
private final class TabControllerContainerView: UIView {
    var onMovedToWindow: (() -> Void)?
    var onRemovedFromWindow: (() -> Void)?
    var onWidthChanged: (() -> Void)?
    private var lastWidth: CGFloat = 0

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { onMovedToWindow?() } else { onRemovedFromWindow?() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard window != nil, bounds.width > 0, abs(bounds.width - lastWidth) > 0.5 else { return }
        lastWidth = bounds.width
        onWidthChanged?()
    }
}

/// The iOS 26+ native tab bar drawn by a `UITabBarController` built from `UITab`s, created instead of
/// `iOS26TabBarPlatformView` when the Flutter side asks for `useTabBarController`.
///
/// A search destination becomes a `UISearchTab`. iOS 26 detaches it from the other tabs on its own;
/// iOS 27 does so only for the tab named by `prominentTabIdentifier`, which only a tab bar
/// controller offers, so this view names it there. The search tab opens no search field of its own:
/// a tap is reported like any other, and the app decides what it does.
///
/// It answers the same channel methods as `iOS26TabBarPlatformView`, so the Flutter side drives
/// both alike. The tab bar never minimizes natively: the Flutter scaffold scales the whole view as
/// the page scrolls.
@available(iOS 26.0, *)
final class iOS26TabControllerPlatformView: NSObject, FlutterPlatformView, UITabBarControllerDelegate {
    private let channel: FlutterMethodChannel
    private let container = TabControllerContainerView()
    private let controller = UITabBarController()
    private let images = TabBarItemImages()

    private var labels: [String] = []
    private var sources = TabBarItemImages.Sources()
    private var searchFlags: [Bool] = []
    private var badgeCounts: [Int?] = []
    private var badgeTexts: [String?] = []
    private var badgeColors: [Int?] = []
    private var badgeTextColors: [Int?] = []
    private var selectedIndex = 0
    private var unselectedTint: UIColor?

    init(frame: CGRect, viewId: Int64, args: Any?, messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(
            name: "adaptive_platform_ui/ios26_tab_bar_\(viewId)",
            binaryMessenger: messenger
        )
        super.init()

        let dict = (args as? [String: Any]) ?? [:]
        readItems(from: dict)
        if let index = (dict["selectedIndex"] as? NSNumber)?.intValue { selectedIndex = index }

        container.frame = frame
        container.backgroundColor = .clear
        controller.delegate = self
        // The Flutter scaffold minimizes the bar by scaling this view; UIKit has no scroll to follow.
        controller.tabBarMinimizeBehavior = .never
        controller.view.backgroundColor = .clear
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: container.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        container.onMovedToWindow = { [weak self] in self?.attachToHostingController() }
        // Flutter disposes a platform view without a callback, and the hosting view controller
        // would otherwise keep the controller alive after the bar has gone.
        container.onRemovedFromWindow = { [weak self] in self?.detachFromHostingController() }
        container.onWidthChanged = { [weak self] in self?.scheduleLabelRemeasure() }

        applyStyle(dict)
        applyBrightness(isDark: (dict["isDark"] as? NSNumber)?.boolValue ?? false)
        applyDirectionality(isRtl: (dict["isRtl"] as? NSNumber)?.boolValue ?? false)
        rebuildTabs()

        channel.setMethodCallHandler { [weak self] call, result in
            guard let self = self else { result(nil); return }
            self.handle(call, result: result)
        }
    }

    func view() -> UIView { container }

    // MARK: - Channel

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = (call.arguments as? [String: Any]) ?? [:]
        switch call.method {
        case "getIntrinsicSize":
            let size = controller.tabBar.sizeThatFits(
                CGSize(width: container.bounds.width, height: .greatestFiniteMagnitude)
            )
            result(["width": Double(container.bounds.width), "height": Double(size.height)])

        case "setItems":
            readItems(from: args)
            if let index = (args["selectedIndex"] as? NSNumber)?.intValue { selectedIndex = index }
            rebuildTabs()
            result(nil)

        case "setSelectedIndex":
            if let index = (args["index"] as? NSNumber)?.intValue {
                selectedIndex = index
                applySelection()
            }
            result(nil)

        case "setStyle":
            applyStyle(args)
            result(nil)

        case "setBrightness":
            applyBrightness(isDark: (args["isDark"] as? NSNumber)?.boolValue ?? false)
            result(nil)

        case "setDirectionality":
            applyDirectionality(isRtl: (args["isRtl"] as? NSNumber)?.boolValue ?? false)
            result(nil)

        case "setMinimizeBehavior":
            // Handled by the Flutter scaffold, which scales this view (see `tabBarMinimizeBehavior`).
            result(nil)

        case "setHidden":
            container.isHidden = (args["hidden"] as? NSNumber)?.boolValue ?? false
            result(nil)

        case "setBadgeCounts":
            readBadges(from: args)
            applyBadges()
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Reading the Flutter payloads

    private func readItems(from dict: [String: Any]) {
        labels = (dict["labels"] as? [String]) ?? []
        sources = TabBarItemImages.Sources(from: dict)
        searchFlags = (dict["searchFlags"] as? [Bool]) ?? []
        readBadges(from: dict)
    }

    private func readBadges(from dict: [String: Any]) {
        badgeCounts = ((dict["badgeCounts"] as? [NSNumber?]) ?? []).map { $0?.intValue }
        badgeTexts = ((dict["badgeTexts"] as? [Any?]) ?? []).map { $0 as? String }
        badgeColors = ((dict["badgeColors"] as? [NSNumber?]) ?? []).map { $0?.intValue }
        badgeTextColors = ((dict["badgeTextColors"] as? [NSNumber?]) ?? []).map { $0?.intValue }
    }

    // MARK: - Tabs

    /// Brings the tabs in line with the destinations: rebuilt when their count or kinds change,
    /// updated in place otherwise, so a badge or an icon change does not replace them.
    private func rebuildTabs() {
        let count = labels.count
        let isSearch = (0..<count).map { $0 < searchFlags.count && searchFlags[$0] }
        var tabs = controller.tabs
        let reusable = tabs.count == count
            && zip(tabs, isSearch).allSatisfy { ($0 is UISearchTab) == $1 }
        if !reusable {
            tabs = (0..<count).map { makeTab(index: $0, isSearch: isSearch[$0]) }
            controller.setTabs(tabs, animated: false)
            scheduleLabelRemeasure()
        }

        for (index, tab) in tabs.enumerated() {
            tab.title = labels[index]
            guard !(tab is UISearchTab) else { continue }
            let pair = images.images(at: index, in: sources, unselectedTint: unselectedTint) {
                [weak self, weak tab] loaded in
                // A download lands later; skip it if the tab has been replaced since.
                guard let self = self, let tab = tab, self.controller.tabs.contains(tab) else { return }
                self.apply(loaded, to: tab)
            }
            apply(pair, to: tab)
        }

        applyProminence()
        applySelection()
        applyBadges()
    }

    private func makeTab(index: Int, isSearch: Bool) -> UITab {
        let provider: (UITab) -> UIViewController = { _ in Self.makePlaceholderController() }
        if isSearch {
            let tab = UISearchTab(viewControllerProvider: provider)
            tab.automaticallyActivatesSearch = false
            return tab
        }
        return UITab(
            title: labels[index],
            image: nil,
            identifier: "adaptive_platform_ui.tab.\(index)",
            viewControllerProvider: provider
        )
    }

    private func apply(_ pair: TabBarItemImages.Pair, to tab: UITab) {
        tab.image = pair.image
        if #available(iOS 26.1, *) {
            tab.selectedImage = pair.selectedImage
        }
    }

    /// Has the bar measure its labels again on the next run loop.
    ///
    /// iOS 26 measures a controller's tab labels in its first layout, before the search tab has
    /// moved out and while the bar is still settling, and keeps those sizes: the selected label is
    /// cut short and the next one drops below its icon. Setting a title again is what makes it
    /// measure anew; nothing else that is public does (a layout pass or new tabs do not).
    private func scheduleLabelRemeasure() {
        DispatchQueue.main.async { [weak self] in
            for tab in self?.controller.tabs ?? [] {
                let title = tab.title
                tab.title = title + " "
                tab.title = title
            }
        }
    }

    /// Names the search tab as the prominent one, which is what detaches it on iOS 27.
    private func applyProminence() {
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) {
            let identifier = controller.tabs.first { $0 is UISearchTab }?.identifier
            if controller.prominentTabIdentifier != identifier {
                controller.prominentTabIdentifier = identifier
            }
        }
        #endif
    }

    private func applySelection() {
        let tabs = controller.tabs
        guard selectedIndex >= 0, selectedIndex < tabs.count else { return }
        if controller.selectedTab !== tabs[selectedIndex] {
            controller.selectedTab = tabs[selectedIndex]
        }
    }

    /// Returns the badge for the destination at [index]: its text when it has one, else its count
    /// above zero, capped at "99+".
    private func badgeValue(at index: Int) -> String? {
        if index < badgeTexts.count, let text = badgeTexts[index], !text.isEmpty { return text }
        guard index < badgeCounts.count, let count = badgeCounts[index], count > 0 else { return nil }
        return count > 99 ? "99+" : String(count)
    }

    /// Puts each destination's badge on its tab, without touching titles or images: a badge update
    /// is the most frequent change and needs no image work.
    private func applyBadges() {
        for (index, tab) in controller.tabs.enumerated() {
            tab.badgeValue = badgeValue(at: index)
        }
        applyBadgeColors()
    }

    /// Colours each badge on the items the controller made for the tabs: `UITab` carries a badge's
    /// value only. The items are the controller's own, so only their properties are set, never the
    /// list itself. They come in the tabs' order (observed on iOS 26 and 27, not documented); a
    /// count that differs skips the colours rather than putting them on the wrong tab.
    private func applyBadgeColors() {
        guard let items = controller.tabBar.items, items.count == labels.count else { return }
        for (index, item) in items.enumerated() {
            let background = index < badgeColors.count ? badgeColors[index] : nil
            item.badgeColor = background.map(Self.color(fromARGB:))
            let text = index < badgeTextColors.count ? badgeTextColors[index] : nil
            let attributes: [NSAttributedString.Key: Any]? = text.map {
                [.foregroundColor: Self.color(fromARGB: $0)]
            }
            item.setBadgeTextAttributes(attributes, for: .normal)
            item.setBadgeTextAttributes(attributes, for: .selected)
        }
    }

    // MARK: - Appearance

    private func applyStyle(_ dict: [String: Any]) {
        if let argb = (dict["tint"] as? NSNumber)?.intValue {
            controller.tabBar.tintColor = Self.color(fromARGB: argb)
        }
        if let argb = (dict["backgroundColor"] as? NSNumber)?.intValue {
            controller.tabBar.barTintColor = Self.color(fromARGB: argb)
        }
        if let argb = (dict["unselectedItemTint"] as? NSNumber)?.intValue {
            let tint = Self.color(fromARGB: argb)
            let changed = tint != unselectedTint
            unselectedTint = tint
            controller.tabBar.unselectedItemTintColor = tint
            // Unselected images are drawn in this colour, so they are redrawn with it.
            if changed, !controller.tabs.isEmpty { rebuildTabs() }
        }
    }

    /// Draws the bar in the app's brightness rather than the system's. The controller takes its
    /// traits from the view controller it is attached to, not from the container, so it is told
    /// directly.
    private func applyBrightness(isDark: Bool) {
        let style: UIUserInterfaceStyle = isDark ? .dark : .light
        container.overrideUserInterfaceStyle = style
        controller.overrideUserInterfaceStyle = style
    }

    private func applyDirectionality(isRtl: Bool) {
        let attribute: UISemanticContentAttribute = isRtl ? .forceRightToLeft : .forceLeftToRight
        container.semanticContentAttribute = attribute
        controller.view.semanticContentAttribute = attribute
        controller.tabBar.semanticContentAttribute = attribute
        controller.traitOverrides.layoutDirection = isRtl ? .rightToLeft : .leftToRight
    }

    // MARK: - Hosting

    /// Makes the controller a child of the view controller hosting the Flutter view, so it gets
    /// appearance and trait updates like any embedded controller.
    private func attachToHostingController() {
        guard controller.parent == nil else { return }
        var responder: UIResponder? = container.next
        while let current = responder, !(current is UIViewController) {
            responder = current.next
        }
        guard let parent = responder as? UIViewController else { return }
        parent.addChild(controller)
        controller.didMove(toParent: parent)
    }

    /// Undoes `attachToHostingController` once the bar has left the window.
    private func detachFromHostingController() {
        guard controller.parent != nil else { return }
        controller.willMove(toParent: nil)
        controller.removeFromParent()
    }

    /// Creates the empty, transparent page a tab stands for: the pages themselves are Flutter's.
    private static func makePlaceholderController() -> UIViewController {
        let controller = UIViewController()
        controller.view.backgroundColor = .clear
        controller.view.isUserInteractionEnabled = false
        return controller
    }

    private static func color(fromARGB argb: Int) -> UIColor {
        return UIColor(
            red: CGFloat((argb >> 16) & 0xFF) / 255,
            green: CGFloat((argb >> 8) & 0xFF) / 255,
            blue: CGFloat(argb & 0xFF) / 255,
            alpha: CGFloat((argb >> 24) & 0xFF) / 255
        )
    }

    // MARK: - UITabBarControllerDelegate

    /// Reports a tap through `valueChanged`, as `iOS26TabBarPlatformView` does, and lets the tab be
    /// selected; Flutter answers with `setSelectedIndex` when it keeps a different one.
    func tabBarController(_ tabBarController: UITabBarController, shouldSelectTab tab: UITab) -> Bool {
        guard let index = tabBarController.tabs.firstIndex(where: { $0 === tab }) else { return true }
        selectedIndex = index
        channel.invokeMethod("valueChanged", arguments: ["index": index])
        return true
    }
}
