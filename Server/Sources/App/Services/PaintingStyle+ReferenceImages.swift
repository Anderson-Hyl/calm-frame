import CalmFrameKit

extension PaintingStyle {
    /// Style anchor image filenames under
    /// `Server/Resources/ReferencePaintings/` (public domain, same source as
    /// the client's bundled paintings). The mapping is server-side: Kit is
    /// frozen, and the filenames are a server deployment detail, not a
    /// shared contract.
    static let referenceImageFiles: [PaintingStyle: String] = [
        .oilPainting1800s: "oilPainting1800s.jpg",
        .oldPostcard: "oldPostcard.jpg",
        .gothicNight: "gothicNight.jpg",
    ]
}
