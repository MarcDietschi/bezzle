// What the Mac's Photoshop reader takes from Accelerate: four planes of samples interleaved into
// pixels. Here in plain Swift, over pointers, so it stays quick in a debug build too.

public typealias vImagePixelCount = UInt
public typealias vImage_Flags = UInt32
public typealias vImage_Error = Int
public let kvImageNoFlags: Int = 0
public let kvImageNoError: Int = 0

public struct vImage_Buffer {
    public var data: UnsafeMutableRawPointer!
    public var height: vImagePixelCount
    public var width: vImagePixelCount
    public var rowBytes: Int
    public init(data: UnsafeMutableRawPointer!, height: vImagePixelCount, width: vImagePixelCount, rowBytes: Int) {
        self.data = data
        self.height = height
        self.width = width
        self.rowBytes = rowBytes
    }
}

/// Writes the four planes into `dest`'s pixels in the order given, as Apple's does whatever the
/// name says of their colours.
public func vImageConvert_Planar8toARGB8888(_ a: UnsafePointer<vImage_Buffer>, _ r: UnsafePointer<vImage_Buffer>, _ g: UnsafePointer<vImage_Buffer>,
                                            _ b: UnsafePointer<vImage_Buffer>, _ dest: UnsafePointer<vImage_Buffer>, _ flags: vImage_Flags) -> vImage_Error {
    let planes = [a.pointee, r.pointee, g.pointee, b.pointee]
    let out = dest.pointee
    let w = Int(out.width), h = Int(out.height)
    var y = 0
    while y < h {
        let line = out.data.assumingMemoryBound(to: UInt8.self) + y * out.rowBytes
        for k in 0..<4 {
            let plane = planes[k]
            let from = UnsafePointer(plane.data.assumingMemoryBound(to: UInt8.self)) + y * plane.rowBytes
            var x = 0
            while x < w {
                line[x * 4 + k] = from[x]
                x += 1
            }
        }
        y += 1
    }
    return kvImageNoError
}
