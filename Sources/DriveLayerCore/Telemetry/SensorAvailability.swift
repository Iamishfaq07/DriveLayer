import Foundation

enum SensorAvailability: Sendable, Equatable {
    case available(VehicleTelemetry.Entry)
    case waitingForFirstReading
    case stale(lastUpdated: Date)
    case suspect(reason: String?)
    case temporarilyUnavailable(reason: String?)
    case unsupported
    case adapterDisconnected
}

extension InsightContext {
    func availability(_ metric: VehicleMetric,
                      freshWithin interval: TimeInterval = 30) -> SensorAvailability {
        guard isAdapterConnected else { return .adapterDisconnected }
        if let entry = trustedEntry(metric, freshWithin: interval) { return .available(entry) }
        if let entry = lastKnownEntry(metric) {
            if entry.quality != .good {
                return .suspect(reason: entry.rejectionReason ?? telemetry?.rejectionReason(metric))
            }
            if now.timeIntervalSince(entry.timestamp) > interval { return .stale(lastUpdated: entry.timestamp) }
            return .temporarilyUnavailable(reason: telemetry?.rejectionReason(metric))
        }
        if let telemetry, let reason = telemetry.rejectionReason(metric) {
            return .suspect(reason: reason)
        }
        if let capabilities {
            let descriptor = OBDPIDCatalog.allDescriptors.first { $0.metric == metric }
            if let descriptor, !capabilities.canAttempt(descriptor.pid) { return .unsupported }
        }
        return .waitingForFirstReading
    }
}
