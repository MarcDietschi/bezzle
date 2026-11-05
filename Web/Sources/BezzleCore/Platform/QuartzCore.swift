@_exported import CoreGraphics

public func CACurrentMediaTime() -> CFTimeInterval { ProcessInfo.processInfo.systemUptime }
public typealias CFTimeInterval = Double
