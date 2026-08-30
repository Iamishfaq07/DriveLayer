import Foundation

// MARK: - Engine

/// Coolant temperature, read in the context of what the engine is being asked to do.
///
/// The point of this rule is the difference between "96 °C" and "96 °C, which is
/// normal for your car on a climb this steep". It reaches for the learned baseline
/// for the current context first and falls back to the profile's generic band.
struct EngineTemperatureRule: InsightRule {
    let identifier = "engine.temperature"

    func evaluate(_ context: InsightContext) -> [DriveInsight] {
        guard let coolant = context.value(.coolantTemperatureC, freshWithin: 60) else { return [] }

        let isClimbing = (context.gradient?.percent ?? 0) >= 3
        let baselineContext: BaselineContext = isClimbing ? .climbing : .warmedUp
        let baseline = context.bestBaseline(.coolantTemperatureC, preferring: baselineContext)
        let range = context.profile?.operatingRange(for: .coolantTemperatureC, condition: .warmedUp)
        let rangeStatus = range?.status(for: coolant) ?? .unknown

        var evidence: [InsightSourceDatum] = [
            .measured("Coolant", String(format: "%.0f °C", coolant))
        ]
        if let baseline, baseline.isEstablished {
            evidence.append(.measured("Your usual on \(baselineContext.displayName)",
                                      String(format: "%.0f–%.0f °C", baseline.percentile10, baseline.percentile90)))
        }
        if let gradient = context.gradient, isClimbing {
            evidence.append(.estimated("Gradient", String(format: "%.1f%%", gradient.percent)))
        }

        // Anything the profile calls attention-worthy is reported regardless of habit:
        // a car that always runs hot has learned a baseline that should not silence this.
        if rangeStatus >= .attention {
            return [DriveInsight(
                id: "engine.temperature.high",
                category: .vehicle,
                severity: rangeStatus,
                title: rangeStatus == .critical ? "ENGINE TEMPERATURE HIGH" : "ENGINE RUNNING HOT",
                summary: String(format: "Coolant is at %.0f °C, above the normal operating band for this engine.", coolant),
                details: "If the temperature keeps climbing, or a warning appears on the dashboard, stop somewhere safe and let the engine cool before continuing.",
                confidence: 0.9,
                sourceData: evidence,
                recommendedAction: rangeStatus == .critical
                    ? "Stop somewhere safe when you can and let the engine cool."
                    : "Keep an eye on the temperature gauge.",
                createdAt: context.now,
                expiresAt: context.now.addingTimeInterval(300)
            )]
        }

        // A reassuring insight is worth showing only when the driver might otherwise
        // worry: high-ish reading, but normal for these conditions.
        guard let baseline, baseline.isEstablished else { return [] }
        let delta = baseline.delta(from: coolant)
        if coolant >= baseline.percentile90 && !delta.isSignificant && isClimbing {
            return [DriveInsight(
                id: "engine.temperature.normal-for-climb",
                category: .vehicle,
                severity: .normal,
                title: "ENGINE NORMAL",
                summary: "Engine temperature is within your normal range for a climb of this intensity.",
                confidence: 0.75,
                sourceData: evidence,
                createdAt: context.now,
                expiresAt: context.now.addingTimeInterval(600)
            )]
        }
        if delta.isSignificant && delta.direction == .above {
            return [DriveInsight(
                id: "engine.temperature.above-baseline",
                category: .vehicle,
                severity: .watch,
                title: "ENGINE WARMER THAN USUAL",
                summary: String(format: "Coolant is running about %.0f °C above your usual for %@.",
                                abs(delta.absolute), baselineContext.displayName),
                details: "This is still within the engine's normal operating band. DriveLayer is flagging it because it differs from this car's own pattern, which can be an early sign of a cooling system issue.",
                confidence: 0.7,
                sourceData: evidence,
                recommendedAction: "Worth mentioning at your next service if it continues.",
                createdAt: context.now,
                expiresAt: context.now.addingTimeInterval(900)
            )]
        }
        return []
    }
}

/// Battery voltage against its own history. The example the product was designed
/// around: a slow decline that no single reading would reveal.
struct BatteryHealthRule: InsightRule {
    let identifier = "battery.health"

    func evaluate(_ context: InsightContext) -> [DriveInsight] {
        guard let voltage = context.value(.controlModuleVoltageV, freshWithin: 300) else { return [] }
        let isRunning = context.telemetry?.isEngineRunning(now: context.now)
        let condition: OperatingCondition = isRunning == false ? .engineOff : .engineRunning
        let range = context.profile?.operatingRange(for: .controlModuleVoltageV, condition: condition)
        let rangeStatus = range?.status(for: voltage) ?? .unknown

        var evidence: [InsightSourceDatum] = [
            .measured("Voltage", String(format: "%.2f V", voltage))
        ]

        if rangeStatus >= .attention {
            let isLow = voltage < (range?.normalLow ?? 12)
            return [DriveInsight(
                id: "battery.out-of-range",
                category: .battery,
                severity: rangeStatus,
                title: isLow ? "LOW SYSTEM VOLTAGE" : "HIGH SYSTEM VOLTAGE",
                summary: String(format: "System voltage is %.2f V with the engine %@, outside the normal band.",
                                voltage, isRunning == false ? "off" : "running"),
                details: isLow
                    ? "Low voltage with the engine running usually points at the charging system or a tired battery. It can also make other systems report faults that aren't real."
                    : "Sustained high voltage can damage electronics and usually points at the voltage regulator.",
                confidence: 0.85,
                sourceData: evidence,
                recommendedAction: "Have the battery and charging system tested.",
                createdAt: context.now,
                expiresAt: context.now.addingTimeInterval(3_600)
            )]
        }

        // The trend case: each reading looks fine, the direction does not.
        guard let baseline = context.bestBaseline(.controlModuleVoltageV, preferring: .engineOff),
              baseline.isEstablished,
              let trendOverWindow = baseline.trendOverWindow,
              trendOverWindow <= -0.2 else { return [] }

        evidence.append(.measured("Your usual", String(format: "%.2f V", baseline.median)))
        evidence.append(.estimated("Trend", String(format: "%.2f V over %d days", trendOverWindow, baseline.windowDays)))

        return [DriveInsight(
            id: "battery.declining-trend",
            category: .battery,
            severity: .watch,
            title: "BATTERY WATCH",
            summary: "Battery voltage has been trending below your normal baseline.",
            details: String(format: "Your usual resting voltage is around %.2f V. Over the last %d days it has drifted by about %.2f V. A gradual decline like this often shows up before a battery struggles to start the car in cold weather.",
                            baseline.median, baseline.windowDays, trendOverWindow),
            confidence: 0.7,
            sourceData: evidence,
            recommendedAction: "Consider having the battery tested before a long trip.",
            createdAt: context.now,
            expiresAt: context.now.addingTimeInterval(24 * 3_600)
        )]
    }
}

/// Engine load compared with the driver's own history, with terrain taken into account
/// before anything is called unusual.
struct EngineLoadRule: InsightRule {
    let identifier = "engine.load"

    func evaluate(_ context: InsightContext) -> [DriveInsight] {
        guard context.isDriving,
              let load = context.value(.engineLoadPercent, freshWithin: 20) else { return [] }
        let isClimbing = (context.gradient?.percent ?? 0) >= 3
        let baselineContext: BaselineContext = isClimbing ? .climbing : .cruising
        guard let baseline = context.bestBaseline(.engineLoadPercent, preferring: baselineContext),
              baseline.isEstablished else { return [] }

        let delta = baseline.delta(from: load)
        guard delta.isSignificant, delta.direction == .above else { return [] }

        var summary = String(format: "Engine load is running higher than your usual for %@.", baselineContext.displayName)
        if isClimbing {
            summary = "Engine load is higher than your usual, which is expected on a gradient this steep."
        }

        return [DriveInsight(
            id: "engine.load.above-baseline",
            category: .vehicle,
            severity: isClimbing ? .normal : .watch,
            title: isClimbing ? "WORKING HARDER" : "HIGHER LOAD THAN USUAL",
            summary: summary,
            details: isClimbing
                ? nil
                : "Sustained load above your own pattern on level ground can be associated with a dragging brake, low tyre pressure, extra weight, or a restricted air filter. DriveLayer can see the load, not the cause.",
            confidence: 0.65,
            sourceData: [
                .measured("Engine load", String(format: "%.0f%%", load)),
                .measured("Your usual", String(format: "%.0f–%.0f%%", baseline.percentile10, baseline.percentile90))
            ],
            createdAt: context.now,
            expiresAt: context.now.addingTimeInterval(600)
        )]
    }
}

// MARK: - Fuel, terrain and weather

struct FuelRule: InsightRule {
    let identifier = "fuel.level"

    func evaluate(_ context: InsightContext) -> [DriveInsight] {
        guard let status = context.fuelStatus, let level = status.levelPercent.value else { return [] }
        guard status.isLow else { return [] }

        var evidence: [InsightSourceDatum] = [.measured("Tank level", String(format: "%.0f%%", level))]
        var summary = String(format: "Fuel is down to about %.0f%%.", level)
        if let range = status.estimatedRangeKm.value {
            evidence.append(.estimated("Estimated range", String(format: "%.0f km", range)))
            summary = String(format: "About %.0f km of estimated range remaining.", range)
        }

        return [DriveInsight(
            id: "fuel.low",
            category: .fuel,
            severity: level <= 7 ? .attention : .watch,
            title: "FUEL LOW",
            summary: summary,
            details: status.estimatedRangeKm.basis,
            confidence: 0.8,
            sourceData: evidence,
            recommendedAction: "Plan a fuel stop.",
            createdAt: context.now,
            expiresAt: context.now.addingTimeInterval(1_800)
        )]
    }
}

struct TerrainRule: InsightRule {
    let identifier = "terrain.feature"

    func evaluate(_ context: InsightContext) -> [DriveInsight] {
        guard context.isDriving, let feature = context.terrainFeature else { return [] }
        return [DriveInsight(
            id: "terrain.\(feature.kind.rawValue)",
            category: .terrain,
            severity: .normal,
            title: feature.headline.uppercased(),
            summary: feature.detail(),
            confidence: 0.6,
            sourceData: [
                .estimated("Length", String(format: "%.1f km", feature.lengthMetres / 1_000)),
                .estimated("Average gradient", String(format: "%.1f%%", feature.averageGradientPercent))
            ],
            createdAt: context.now,
            expiresAt: context.now.addingTimeInterval(600)
        )]
    }
}

struct WeatherRule: InsightRule {
    let identifier = "weather.ahead"

    func evaluate(_ context: InsightContext) -> [DriveInsight] {
        context.weatherChanges.prefix(2).map { change in
            DriveInsight(
                id: "weather.\(change.kind.rawValue)",
                category: .weather,
                severity: change.severity,
                title: change.headline,
                summary: change.detail,
                confidence: 0.7,
                sourceData: [
                    .estimated("Distance ahead", String(format: "%.0f km", change.distanceMetres / 1_000))
                ],
                createdAt: context.now,
                expiresAt: change.expectedAt.addingTimeInterval(900)
            )
        }
    }
}

// MARK: - Maintenance, documents, diagnostics, diesel

struct MaintenanceRule: InsightRule {
    let identifier = "maintenance.due"

    func evaluate(_ context: InsightContext) -> [DriveInsight] {
        context.maintenanceStatuses
            .filter { $0.status >= .watch }
            .prefix(2)
            .map { due in
                DriveInsight(
                    id: "maintenance.\(due.item.id.uuidString)",
                    category: .maintenance,
                    severity: due.status,
                    title: due.isOverdue ? "\(due.item.name.uppercased()) OVERDUE" : due.item.name.uppercased(),
                    summary: due.summary,
                    details: due.item.source == .genericDefault
                        ? "This interval is a generic default, not a figure from your manufacturer. Check your owner's manual and correct it if needed."
                        : due.item.note,
                    confidence: due.item.source.isVehicleSpecific ? 0.85 : 0.6,
                    sourceData: [
                        InsightSourceDatum(label: "Interval source",
                                           formattedValue: due.item.source.label,
                                           provenance: due.item.source == .genericDefault ? .inferred : .measured)
                    ],
                    createdAt: context.now,
                    expiresAt: context.now.addingTimeInterval(24 * 3_600),
                    isDrivingSafeToDisplay: false
                )
            }
    }
}

struct DocumentExpiryRule: InsightRule {
    let identifier = "documents.expiry"

    func evaluate(_ context: InsightContext) -> [DriveInsight] {
        context.documents
            .filter { $0.status(now: context.now) >= .watch }
            .sorted { ($0.daysUntilExpiry(now: context.now) ?? 0) < ($1.daysUntilExpiry(now: context.now) ?? 0) }
            .prefix(2)
            .map { document in
                let days = document.daysUntilExpiry(now: context.now) ?? 0
                let expired = days < 0
                return DriveInsight(
                    id: "document.\(document.id.uuidString)",
                    category: .maintenance,
                    severity: document.status(now: context.now),
                    title: expired ? "\(document.kind.displayName.uppercased()) EXPIRED" : "\(document.kind.displayName.uppercased()) EXPIRING",
                    summary: expired
                        ? "Your \(document.kind.displayName.lowercased()) expired \(-days) days ago."
                        : "Your \(document.kind.displayName.lowercased()) expires in \(days) days.",
                    confidence: 0.9,
                    createdAt: context.now,
                    expiresAt: context.now.addingTimeInterval(24 * 3_600),
                    isDrivingSafeToDisplay: false
                )
            }
    }
}

struct TroubleCodeRule: InsightRule {
    let identifier = "diagnostics.codes"

    func evaluate(_ context: InsightContext) -> [DriveInsight] {
        guard !context.troubleCodes.isEmpty else { return [] }
        // The most serious code leads; the rest are counted rather than listed.
        let explained = context.troubleCodes.map { ($0, DTCCatalog.explanation(for: $0.code)) }
        guard let worst = explained.max(by: { $0.1.seriousness.status < $1.1.seriousness.status }) else { return [] }
        let others = explained.count - 1

        var summary = "\(worst.0.code): \(worst.1.standardDefinition)."
        if others > 0 {
            summary += " \(others) other code\(others == 1 ? "" : "s") also stored."
        }

        return [DriveInsight(
            id: "diagnostics.\(worst.0.code)",
            category: .vehicle,
            severity: worst.1.seriousness.status,
            title: "TROUBLE CODE STORED",
            summary: summary,
            details: worst.1.plainLanguage,
            confidence: worst.1.isGenericFallback ? 0.5 : 0.85,
            sourceData: [
                InsightSourceDatum(label: "Source", formattedValue: worst.1.source,
                                   provenance: worst.1.isGenericFallback ? .inferred : .measured)
            ],
            recommendedAction: worst.1.drivingGuidance,
            createdAt: context.now,
            expiresAt: context.now.addingTimeInterval(6 * 3_600)
        )]
    }
}

struct DieselUsageRule: InsightRule {
    let identifier = "diesel.usage"

    func evaluate(_ context: InsightContext) -> [DriveInsight] {
        guard let assessment = context.dieselAssessment,
              assessment.isApplicable,
              assessment.status >= .watch else { return [] }

        var evidence: [InsightSourceDatum] = []
        if let fraction = assessment.shortTripFraction.value {
            evidence.append(InsightSourceDatum(label: "Short drives",
                                               formattedValue: "\(Int((fraction * 100).rounded()))% of \(assessment.tripsConsidered)",
                                               provenance: assessment.shortTripFraction.provenance))
        }
        if let warmUp = assessment.warmUpCompletionRate.value {
            evidence.append(InsightSourceDatum(label: "Reached operating temperature",
                                               formattedValue: "\(Int((warmUp * 100).rounded()))% of drives",
                                               provenance: assessment.warmUpCompletionRate.provenance))
        }

        return [DriveInsight(
            id: "diesel.usage-pattern",
            category: .diesel,
            severity: assessment.status,
            title: "DIESEL USAGE",
            summary: assessment.explanation,
            details: assessment.dpf.hasAnyValue
                ? nil
                : "Direct particulate filter data is unavailable on this vehicle, so this is based on your driving pattern rather than a filter reading.",
            confidence: 0.6,
            sourceData: evidence,
            recommendedAction: assessment.recommendation,
            createdAt: context.now,
            expiresAt: context.now.addingTimeInterval(24 * 3_600),
            isDrivingSafeToDisplay: false
        )]
    }
}

/// Compares the drive that just finished with the driver's usual run of the same route.
struct TripComparisonRule: InsightRule {
    let identifier = "trip.comparison"

    func evaluate(_ context: InsightContext) -> [DriveInsight] {
        guard !context.isDriving,
              let lastTrip = context.recentTrips.filter(\.isComplete).max(by: { $0.startedAt < $1.startedAt }),
              let comparison = TripComparisonEngine.compare(lastTrip, against: context.recentTrips),
              let summary = comparison.summary else { return [] }

        return [DriveInsight(
            id: "trip.comparison.\(lastTrip.id.uuidString)",
            category: .efficiency,
            severity: .normal,
            title: "COMPARED WITH USUAL",
            summary: summary,
            details: "Compared against \(comparison.comparableTripCount) previous drives between the same start and end areas. DriveLayer reports what these figures moved together with, not what caused what.",
            confidence: 0.65,
            sourceData: [
                .measured("This drive", String(format: "%.0f min", comparison.durationSeconds / 60)),
                .measured("Typical", String(format: "%.0f min", comparison.typicalDurationSeconds / 60))
            ],
            createdAt: context.now,
            expiresAt: context.now.addingTimeInterval(12 * 3_600),
            isDrivingSafeToDisplay: false
        )]
    }
}
