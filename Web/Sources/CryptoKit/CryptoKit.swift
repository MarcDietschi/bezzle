// Here only so that the shared sources' "import CryptoKit" finds a module. What Bezzle takes from
// CryptoKit is in BezzleCore/Platform, in the core's own module, where it can stand in for
// Foundation's own CGFloat, CGPoint, CGSize and CGRect (see Platform/CGGeometry.swift).

// It brings Foundation, as the framework does: sqrt, sin and the rest come with it.
@_exported import Foundation
