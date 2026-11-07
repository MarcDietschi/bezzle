import Foundation

// An artboard's own card on Windows, as the Mac's (SelectionInspector.artboardCard): its size
// from the presets, its design laid out again for the new size (the shared Adapting); or a
// carousel's format and slides; whether its layers adapt, and whether it clips them.

extension WindowsCore {
    /// What the Artboard card shows of one artboard.
    public struct ArtboardCard {
        public let isCarousel: Bool
        /// The preset its size is, or nil for a size of its own.
        public let preset: String?
        public let size: CGSize
        /// A carousel's slides: how big, which format, how many.
        public let slide: CGSize?
        public let format: String?
        public let platforms: String?
        public let slides: Int
        /// Whether its design is laid out again when it changes size, and whether it clips.
        public let adapts: Bool
        public let clips: Bool
    }

    public static func artboardCard(_ id: UUID) -> ArtboardCard? {
        guard let b = design?.node(id), b.isArtboard else { return nil }
        let format = b.slideSize.flatMap(Carousel.format(of:))
        return ArtboardCard(isCarousel: b.isCarousel, preset: Preset.matching(b.frame.size)?.title.key, size: b.frame.size,
                            slide: b.slideSize, format: format?.title.key, platforms: format?.platforms, slides: b.slideCount,
                            adapts: b.pinsLayers != true, clips: b.clips)
    }

    /// The presets, by group (Devices: iPhone, Android…), as the Size menu lists them.
    public static var presetGroups: [(title: String, presets: [(title: String, size: CGSize)])] {
        Preset.Group.allCases.map { g in (g.title.key, Preset.all(in: g).map { ($0.title.key, $0.size) }) }
    }

    /// The carousels' formats: their names, slide sizes and where they are posted.
    public static var carouselFormats: [(title: String, size: CGSize, platforms: String)] {
        Carousel.formats.map { ($0.title.key, $0.size, $0.platforms) }
    }
    public static var slideCounts: ClosedRange<Int> { Carousel.counts }

    /// Artboards at a new size, each design laid out again for it, as one step.
    public static func resizeArtboards(_ ids: [UUID], to size: CGSize) {
        endPreview()
        guard let doc = design else { return }
        var laid: [UUID: Node] = [:]
        let next = Editing.apply(to: doc) { laid = Adapting.resize(&$0, ids, to: { _ in size }) }
        design = next
        Adapting.finish(laid, in: next)
    }

    /// Shows the artboard at a size pointed at in the menu, its design laid out for it; nil
    /// shows it as it is.
    public static func previewArtboard(_ id: UUID, size: CGSize?) {
        endPreview()
        guard let size, let doc = design, let change = Adapting.preview(doc, of: id, to: size) else { return }
        preview(change)
    }

    /// Plain artboards made carousels of a format, as many slides as fit their width (at least
    /// as many as a new one has); their layers stay where they are.
    public static func makeCarousel(_ ids: [UUID], slide: CGSize) {
        edit { d in
            for id in ids {
                d.update(id) { n in
                    guard n.isArtboard else { return }
                    n.slideSize = slide
                    n.frame.size = n.carouselSize(count: max(Carousel.startingCount, Int((n.frame.width / slide.width).rounded())))
                }
            }
        }
    }

    /// Carousels' slides at another size; nil makes them plain artboards again.
    public static func setSlideSize(_ ids: [UUID], _ size: CGSize?) {
        edit { d in
            for id in ids {
                d.update(id) { n in
                    if let size { n.setSlideSize(size) } else { n.slideSize = nil }
                }
            }
        }
    }

    /// One slide's width or height, keeping the other.
    public static func setSlideSide(_ ids: [UUID], width: Double? = nil, height: Double? = nil) {
        edit { d in
            for id in ids {
                d.update(id) { n in
                    guard let s = n.slideSize else { return }
                    n.setSlideSize(CGSize(width: width.map { CGFloat($0) } ?? s.width, height: height.map { CGFloat($0) } ?? s.height))
                }
            }
        }
    }

    /// Slides added at a carousel's right, or taken away from there: `count` from how many it has.
    public static func setSlides(_ ids: [UUID], _ count: (Int) -> Int) {
        edit { d in
            for id in ids {
                d.update(id) { n in
                    guard n.isCarousel else { return }
                    n.frame.size = n.carouselSize(count: count(n.slideCount))
                }
            }
        }
    }

    /// Whether artboards lay their design out again when they change size.
    public static func setAdapts(_ ids: [UUID], _ adapts: Bool) {
        edit { d in for id in ids { d.update(id) { $0.pinsLayers = adapts ? nil : true } } }
    }

    /// Whether artboards hide what lies past their edges.
    public static func setClips(_ ids: [UUID], _ clips: Bool) {
        edit { d in for id in ids { d.update(id) { $0.clips = clips } } }
    }
}
