import Foundation
import OSLog

struct RoutingTrace: Sendable {
    let id: UUID
    private let receivedAt: UInt64
    private let processStartedAt: UInt64

    init?(processStartedAt: UInt64?) {
        guard RoutingDiagnostics.isEnabled, let processStartedAt else { return nil }
        id = UUID()
        receivedAt = DispatchTime.now().uptimeNanoseconds
        self.processStartedAt = processStartedAt
    }

    func mark(_ stage: String, details: String = "") {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = Self.milliseconds(now - receivedAt)
        let processAge = Self.milliseconds(now - processStartedAt)
        RoutingDiagnostics.write(
            "link id=\(id.uuidString) stage=\(stage) elapsed_ms=\(elapsed) app_age_ms=\(processAge) details=\(details)")
    }

    private static func milliseconds(_ nanoseconds: UInt64) -> UInt64 {
        nanoseconds / 1_000_000
    }
}

enum RoutingDiagnostics {
    static let isEnabled = ProcessInfo.processInfo.arguments.contains("--debug-routing")

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "ContextRoute",
        category: "Routing")

    static func write(_ message: String) {
        guard isEnabled else { return }
        logger.notice("\(message, privacy: .public)")
    }

    static func logCachePreparation(startedAt: UInt64, handlerCount: Int, routeCount: Int) {
        guard isEnabled else { return }
        let elapsed = (DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
        write("routing-cache-prepared elapsed_ms=\(elapsed) handler_count=\(handlerCount) route_count=\(routeCount)")
    }

    static func logAppStage(_ stage: String, startedAt: UInt64?) {
        guard isEnabled, let startedAt else { return }
        let elapsed = (DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
        write("app-launch stage=\(stage) app_age_ms=\(elapsed)")
    }
}
