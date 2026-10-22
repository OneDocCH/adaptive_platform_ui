import Flutter
import UIKit

/// Resolves a tab's unselected and selected images from what Flutter describes for it: a file or a
/// network URL (drawn as a round avatar), a Flutter asset, or an SF Symbol / bundle image name.
///
/// Mirrors what `iOS26TabBarPlatformView` does for its items on iOS 26+, in one place both tab bar
/// views can share. `iOS26TabBarPlatformView` still carries its own copy and can move onto this.
final class TabBarItemImages {
    /// The image sources for every destination, by index, as the Flutter side sends them.
    struct Sources {
        var symbols: [String] = []
        var selectedSymbols: [String] = []
        var assetIcons: [String] = []
        var selectedAssetIcons: [String] = []
        var fileIcons: [String] = []
        var selectedFileIcons: [String] = []
        var networkIcons: [String] = []
        var selectedNetworkIcons: [String] = []

        init() {}

        /// Reads the sources from a creation or `setItems` payload.
        init(from dict: [String: Any]) {
            symbols = (dict["sfSymbols"] as? [String]) ?? []
            selectedSymbols = (dict["selectedSfSymbols"] as? [String]) ?? []
            assetIcons = (dict["assetIcons"] as? [String]) ?? []
            selectedAssetIcons = (dict["selectedAssetIcons"] as? [String]) ?? []
            fileIcons = (dict["fileIcons"] as? [String]) ?? []
            selectedFileIcons = (dict["selectedFileIcons"] as? [String]) ?? []
            networkIcons = (dict["networkIcons"] as? [String]) ?? []
            selectedNetworkIcons = (dict["selectedNetworkIcons"] as? [String]) ?? []
        }
    }

    /// A tab's two images; either may be nil when the destination describes none.
    struct Pair {
        var image: UIImage?
        var selectedImage: UIImage?
    }

    private static let iconSize = CGSize(width: 26, height: 26)

    private let cache = NSCache<NSString, UIImage>()

    /// Resolves the images for the destination at [index].
    ///
    /// A network image not cached yet resolves to a placeholder at once and to the downloaded
    /// avatar later, through [onLoaded] on the main queue. An unselected image is drawn in
    /// [unselectedTint] when one is given, and left to the bar's tint otherwise.
    func images(
        at index: Int,
        in sources: Sources,
        unselectedTint: UIColor?,
        onLoaded: @escaping (Pair) -> Void
    ) -> Pair {
        if let runtime = runtimeImages(at: index, in: sources, onLoaded: onLoaded) {
            return runtime
        }
        if let asset = Self.value(sources.assetIcons, index) {
            let selectedAsset = Self.value(sources.selectedAssetIcons, index) ?? asset
            let image = Self.assetImage(asset)
            let selected = Self.assetImage(selectedAsset) ?? image
            return Pair(
                image: Self.tinted(image, unselectedTint),
                selectedImage: selected?.withRenderingMode(.alwaysTemplate)
            )
        }
        if let symbol = Self.value(sources.symbols, index) {
            let selectedSymbol = Self.value(sources.selectedSymbols, index) ?? symbol
            return Pair(
                image: Self.tinted(Self.namedImage(symbol), unselectedTint),
                selectedImage: Self.namedImage(selectedSymbol)?.withRenderingMode(.alwaysTemplate)
            )
        }
        return Pair()
    }

    // MARK: - File and network images

    /// Resolves a destination given a file or a network URL, or returns nil when it has neither.
    private func runtimeImages(
        at index: Int,
        in sources: Sources,
        onLoaded: @escaping (Pair) -> Void
    ) -> Pair? {
        let file = Self.value(sources.fileIcons, index) ?? ""
        let selectedFile = Self.value(sources.selectedFileIcons, index) ?? file
        let url = Self.value(sources.networkIcons, index) ?? ""
        let selectedURL = Self.value(sources.selectedNetworkIcons, index) ?? url
        guard !(file.isEmpty && url.isEmpty && selectedFile.isEmpty && selectedURL.isEmpty) else {
            return nil
        }

        let image = loadedAvatar(file: file, url: url)
        let selected = loadedAvatar(file: selectedFile, url: selectedURL)
        var pair = Pair(
            image: Self.original(image ?? Self.placeholder),
            selectedImage: Self.original(selected ?? image ?? Self.placeholder)
        )

        // Fetch whichever of the two is a URL not downloaded yet, then report the pair again. The
        // selected URL falls back to the unselected one, so a single download can fill both.
        let pending = [(url, image == nil), (selectedURL, selected == nil)]
            .filter { !$0.0.isEmpty && $0.1 }
            .map { $0.0 }
        for pendingURL in Set(pending) {
            fetchAvatar(pendingURL) { avatar in
                guard let avatar = avatar else { return }
                if pendingURL == url, image == nil { pair.image = Self.original(avatar) }
                if pendingURL == selectedURL, selected == nil {
                    pair.selectedImage = Self.original(avatar)
                }
                onLoaded(pair)
            }
        }
        return pair
    }

    /// Returns the avatar for [file] or an already downloaded [url], or nil when neither is at hand.
    private func loadedAvatar(file: String, url: String) -> UIImage? {
        if !file.isEmpty, let image = UIImage(contentsOfFile: file) {
            return Self.avatar(from: image)
        }
        if !url.isEmpty, let cached = cache.object(forKey: url as NSString) {
            return Self.avatar(from: cached)
        }
        return nil
    }

    /// Downloads [urlString] once and hands the avatar to [completion] on the main queue.
    private func fetchAvatar(_ urlString: String, completion: @escaping (UIImage?) -> Void) {
        if let cached = cache.object(forKey: urlString as NSString) {
            completion(Self.avatar(from: cached))
            return
        }
        guard let url = URL(string: urlString) else {
            completion(nil)
            return
        }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self = self, let data = data, let image = UIImage(data: data) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            self.cache.setObject(image, forKey: urlString as NSString)
            let avatar = Self.avatar(from: image)
            DispatchQueue.main.async { completion(avatar) }
        }.resume()
    }

    // MARK: - Drawing

    private static var placeholder: UIImage? { UIImage(systemName: "person.crop.circle") }

    /// Returns the non-empty value at [index], or nil.
    private static func value(_ values: [String], _ index: Int) -> String? {
        guard index < values.count, !values[index].isEmpty else { return nil }
        return values[index]
    }

    /// Loads an SF Symbol, falling back to a bundle image of that name.
    private static func namedImage(_ name: String) -> UIImage? {
        return UIImage(systemName: name) ?? UIImage(named: name)
    }

    /// Loads a Flutter asset, scaled down to the tab icon size.
    private static func assetImage(_ asset: String) -> UIImage? {
        let key = FlutterDartProject.lookupKey(forAsset: asset)
        return UIImage(named: key).map { resized($0) }
    }

    /// Draws [image] in [tint] for the unselected state, or leaves it to the bar's tint.
    private static func tinted(_ image: UIImage?, _ tint: UIColor?) -> UIImage? {
        guard let tint = tint else { return image?.withRenderingMode(.alwaysTemplate) }
        return image?.withTintColor(tint, renderingMode: .alwaysOriginal)
    }

    private static func original(_ image: UIImage?) -> UIImage? {
        return image?.withRenderingMode(.alwaysOriginal)
    }

    /// Scales [image] down to fit the tab icon size; a smaller image is returned as is.
    private static func resized(_ image: UIImage) -> UIImage {
        let size = image.size
        guard size.width > iconSize.width || size.height > iconSize.height else { return image }
        let ratio = min(iconSize.width / size.width, iconSize.height / size.height)
        let newSize = CGSize(width: size.width * ratio, height: size.height * ratio)
        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    /// Crops [image] to a circle the size of a tab icon, filling it.
    private static func avatar(from image: UIImage) -> UIImage {
        return UIGraphicsImageRenderer(size: iconSize).image { _ in
            UIBezierPath(ovalIn: CGRect(origin: .zero, size: iconSize)).addClip()
            let scale = max(iconSize.width / image.size.width, iconSize.height / image.size.height)
            let scaled = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let origin = CGPoint(
                x: (iconSize.width - scaled.width) / 2,
                y: (iconSize.height - scaled.height) / 2
            )
            image.draw(in: CGRect(origin: origin, size: scaled))
        }
    }
}
