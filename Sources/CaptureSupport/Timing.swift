import Foundation

public enum Timing {
    public static func measure<T>(_ label: String, execute block: () throws -> T) rethrows -> T {
        let start = Date()
        let result = try block()
        let duration = Date().timeIntervalSince(start)
        print(String(format: "%@ in %.3f s", label, duration))
        return result
    }
}
