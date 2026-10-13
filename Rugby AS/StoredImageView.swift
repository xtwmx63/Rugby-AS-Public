import SwiftUI

/// Local images appear when decoded without holding up navigation or scrolling.
/// The identity check prevents a reused row from briefly showing another photo.
struct StoredImageView<ImageContent: View, Placeholder: View>: View {
    let name: String?
    var maxDimension: CGFloat = 360
    @ViewBuilder var content: (Image) -> ImageContent
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var loadedImage: UIImage?
    @State private var loadedRequest: String?

    private var request: String { "\(maxDimension)-\(name ?? "")" }

    var body: some View {
        Group {
            if let image = currentImage {
                content(Image(uiImage: image))
            } else {
                placeholder()
            }
        }
        .task(id: request) {
            let requested = request
            guard let name else {
                loadedImage = nil
                loadedRequest = requested
                return
            }
            let image = await ImageStorage.loadThumbnail(named: name, maxDimension: maxDimension)
            guard !Task.isCancelled else { return }
            loadedImage = image
            loadedRequest = requested
        }
    }

    private var currentImage: UIImage? {
        if loadedRequest == request { return loadedImage }
        guard let name else { return nil }
        return ImageStorage.cachedThumbnail(named: name, maxDimension: maxDimension)
    }
}
