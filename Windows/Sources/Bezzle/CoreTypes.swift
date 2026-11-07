import Foundation
import BezzleCore

// Which of two same-named types the app means: the core's geometry (Web/Platform/CGGeometry.swift,
// which stands in for Foundation's), and Foundation's UUID rather than WinSDK's C one.
typealias CGPoint = BezzleCore.CGPoint
typealias CGSize = BezzleCore.CGSize
typealias CGRect = BezzleCore.CGRect
typealias UUID = Foundation.UUID
