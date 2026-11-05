import Foundation

nonisolated public func CACurrentMediaTime() -> CFTimeInterval { ProcessInfo.processInfo.systemUptime }
public typealias CFTimeInterval = Double
