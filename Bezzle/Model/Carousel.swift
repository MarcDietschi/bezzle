import CoreGraphics

/// Social carousels: an artboard of slides side by side, designed as one, so that what runs from
/// one slide into the next lines up across the cut; it is exported a picture per slide. Its width
/// is always a whole number of slides, and its height a slide's.
nonisolated enum Carousel {
    /// A slide size the platforms take, in pixels.
    struct Format: Identifiable, Hashable {
        let name: String
        let size: CGSize
        /// Where it is posted.
        let platforms: String
        var id: String { name }
    }

    static let formats: [Format] = [
        Format(name: "Portrait 4:5", size: CGSize(width: 1080, height: 1350), platforms: "Instagram, LinkedIn, Facebook"),
        Format(name: "Square 1:1", size: CGSize(width: 1080, height: 1080), platforms: "Instagram, LinkedIn, Facebook"),
        Format(name: "Tall 3:4", size: CGSize(width: 1080, height: 1440), platforms: "Instagram"),
        Format(name: "Story 9:16", size: CGSize(width: 1080, height: 1920), platforms: "TikTok"),
    ]

    /// How many slides a carousel can have: as many as Instagram takes.
    static let counts = 1...20
    /// How many a new one starts with.
    static let startingCount = 3

    static func format(of slide: CGSize) -> Format? { formats.first { $0.size == slide } }

    static func clamped(_ count: Int) -> Int { min(max(count, counts.lowerBound), counts.upperBound) }
}

nonisolated extension Node {
    /// A carousel: an artboard cut into slides.
    var isCarousel: Bool { kind == .artboard && slideSize != nil }

    /// How many slides a carousel is, by its width; one for anything else.
    var slideCount: Int {
        guard isCarousel, let slide = slideSize, slide.width > 0 else { return 1 }
        return Carousel.clamped(Int((frame.width / slide.width).rounded()))
    }

    /// Each slide, in the carousel's own coordinates, first to last.
    var slideRects: [CGRect] {
        guard isCarousel, let slide = slideSize else { return [CGRect(origin: .zero, size: frame.size)] }
        return (0..<slideCount).map { CGRect(x: CGFloat($0) * slide.width, y: 0, width: slide.width, height: slide.height) }
    }

    /// The size a carousel of `count` slides is.
    func carouselSize(count: Int) -> CGSize {
        guard let slide = slideSize else { return frame.size }
        return CGSize(width: slide.width * CGFloat(Carousel.clamped(count)), height: slide.height)
    }
}

nonisolated extension BezzleDocument {
    /// Keeps each carousel whole slides wide and a slide high, its top left where it is, after a
    /// change that sized it some other way, such as a width typed in.
    mutating func fitCarousels() {
        for node in nodes where node.isCarousel {
            let size = node.carouselSize(count: node.slideCount)
            if node.frame.size != size { update(node.id) { $0.frame.size = size } }
        }
    }
}
