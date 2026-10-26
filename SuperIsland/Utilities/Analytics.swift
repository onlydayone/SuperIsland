import Foundation

/// Analytics completely disabled in clean fork.
enum Analytics {
    static func start() {}
    static func track(_ event: String, properties: [String: Any]? = nil) {}
}
