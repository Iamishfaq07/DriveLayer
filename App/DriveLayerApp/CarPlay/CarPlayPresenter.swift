import Foundation
import UIKit
#if canImport(CarPlay)
import CarPlay
#endif

#if canImport(CarPlay)
/// Builds and refreshes the CarPlay templates.
///
/// Everything shown here is already interpreted by the time it arrives: the presenter
/// formats, orders by urgency, and does no analysis of its own. Refreshes are on a
/// slow timer because a driver does not need a screen that changes every second.
///
/// The root is a tab bar over three grids and a list, not one scrolling list. A grid
/// tile shows a value at a glance - the thing a dashboard is for - and tapping it
/// pushes the same interpreted sentence the old single list showed as detail text.
/// This is the ceiling CarPlay allows a driving-task app: `CPGridTemplate`,
/// `CPListTemplate`, `CPInformationTemplate`, `CPAlertTemplate` and `CPTabBarTemplate`
/// are the whole vocabulary. There is no custom canvas, no chart, and no template
/// that draws anything DriveLayer did not already have the data for.
///
/// One template is presented rather than pushed: the critical alert. CarPlay caps a
/// tab's navigation stack at two templates (the tab's own root, plus one push), which
/// every grid-to-detail tap here already uses. `CPAlertTemplate` does not count
/// against that stack - it is shown modally on top of whatever is visible - which is
/// the only reason there is room for it at all.
@MainActor
final class CarPlayPresenter {

    private let interfaceController: CPInterfaceController
    private var refreshTimer: Timer?

    private let vehicleGrid = CPGridTemplate(title: "Vehicle", gridButtons: [])
    private let tripGrid = CPGridTemplate(title: "Trip", gridButtons: [])
    private let aheadGrid = CPGridTemplate(title: "Ahead", gridButtons: [])
    private let copilotList = CPListTemplate(title: "Ask Harrier", sections: [])

    /// The one critical insight already popped as an alert, so a condition that
    /// persists across refreshes does not interrupt again every ten seconds - only a
    /// genuinely new critical insight does. `.watch` and `.attention` never alert;
    /// they stay on the passive urgent tile, which is the only place a driver has to
    /// go looking for them.
    private var alertedInsightID: String?
    private var isAlertPresented = false

    /// Speech capture for the voice entry point. On-device only, and it refuses to
    /// listen at all on a phone that cannot recognise speech locally.
    private let voice = VoiceCapture()
    private static let listeningStateIdentifier = "listening"

    /// CarPlay connects on its own scene, so it needs a reference to the running app's
    /// state. This is the one place a shared instance is justified.
    private var environment: AppEnvironment? { AppEnvironment.active }

    init(interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
    }

    func start() {
        vehicleGrid.tabTitle = "Vehicle"
        vehicleGrid.tabImage = UIImage(systemName: "car.fill")

        tripGrid.tabTitle = "Trip"
        tripGrid.tabImage = UIImage(systemName: "speedometer")

        aheadGrid.tabTitle = "Ahead"
        aheadGrid.tabImage = UIImage(systemName: "binoculars.fill")

        copilotList.tabTitle = "Ask Harrier"
        copilotList.tabImage = UIImage(systemName: "questionmark.bubble.fill")
        copilotList.emptyViewTitleVariants = ["DriveLayer"]
        copilotList.emptyViewSubtitleVariants = ["Open DriveLayer on your iPhone to add a vehicle."]

        let tabs = CPTabBarTemplate(templates: [vehicleGrid, tripGrid, aheadGrid, copilotList])
        interfaceController.setRootTemplate(tabs, animated: false, completion: nil)

        refresh()
        // Ten seconds is frequent enough for status and slow enough to be ignorable.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        // The car is gone; a microphone still open would have nothing to show for it.
        voice.cancel()
    }

    // MARK: - Building

    private func refresh() {
        guard let environment else {
            let placeholder = [CPGridButton(titleVariants: ["Open DriveLayer"],
                                            image: tileImage(symbolName: "iphone", status: nil)) { _ in }]
            vehicleGrid.updateGridButtons(atLeastTwo(placeholder))
            tripGrid.updateGridButtons(atLeastTwo(placeholder))
            aheadGrid.updateGridButtons(atLeastTwo(placeholder))
            copilotList.updateSections([])
            return
        }
        vehicleGrid.updateGridButtons(atLeastTwo(vehicleButtons(environment)))
        tripGrid.updateGridButtons(atLeastTwo(tripButtons(environment)))
        aheadGrid.updateGridButtons(atLeastTwo(aheadButtons(environment)))
        copilotList.updateSections([copilotSection()])
        presentCriticalAlertIfNeeded(environment)
    }

    // MARK: - Vehicle tab

    private func vehicleButtons(_ environment: AppEnvironment) -> [CPGridButton] {
        let drive = environment.drive
        var buttons: [CPGridButton] = []

        // Urgent first: if something needs attention, it leads, and its shape encodes
        // severity rather than topic - that is the one axis that matters most here.
        if let insight = InsightEngine.headline(drive.insights), insight.severity >= .watch {
            buttons.append(CPGridButton(titleVariants: [insight.title],
                                        image: statusShapeImage(insight.severity)) { [weak self] _ in
                self?.presentInformation(title: insight.title,
                                         lines: [insight.summary, insight.details, insight.recommendedAction].compactMap { $0 })
            })
        }

        let health = drive.health
        buttons.append(CPGridButton(titleVariants: [health?.overall.label ?? "No data"],
                                    image: tileImage(symbolName: InsightCategory.vehicle.symbolName,
                                                     status: health?.overall)) { [weak self] _ in
            self?.presentInformation(title: "Vehicle",
                                     lines: [health.map { "\($0.overall.label) — \($0.headline)" } ?? "Not enough data yet."])
        })

        // Same battery reading the health screen and "How's the battery" already use -
        // this is not a new judgment, just a new place to glance at the existing one.
        if let battery = health?.system(.battery), battery.status != .unknown {
            buttons.append(CPGridButton(titleVariants: [battery.headline],
                                        image: tileImage(symbolName: InsightCategory.battery.symbolName,
                                                         status: battery.status)) { [weak self] _ in
                self?.presentInformation(title: "Battery", lines: [battery.headline, battery.detail].compactMap { $0 })
            })
        }

        if !drive.hyperion.isSilent {
            let hyperion = drive.hyperion
            buttons.append(CPGridButton(titleVariants: [hyperion.overall.label],
                                        image: tileImage(symbolName: "engine.combustion.fill",
                                                         status: hyperion.overall)) { [weak self] _ in
                self?.presentInformation(title: "Hyperion", lines: [hyperion.overall.label])
            })
        }

        return buttons
    }

    // MARK: - Trip tab

    /// Range, the last completed drive, and what's next for service - "how far can I
    /// go, how did the last drive go, what does the car need" - kept apart from the
    /// Vehicle tab's "how is it doing right now" so neither grid grows past a glance.
    private func tripButtons(_ environment: AppEnvironment) -> [CPGridButton] {
        let drive = environment.drive
        let formatter = environment.formatter
        var buttons: [CPGridButton] = []

        let rangeKm = drive.fuelStatus.estimatedRangeKm.value
        let rangeText = formatter.distance(kilometres: rangeKm, fractionDigits: 0)
        let fuelSeverity = severity(forCategory: .fuel, in: drive.insights)
        buttons.append(CPGridButton(titleVariants: rangeText.map { ["\($0) \(formatter.distanceUnitLabel)"] } ?? ["No data"],
                                    image: tileImage(symbolName: InsightCategory.fuel.symbolName,
                                                     status: rangeText == nil ? nil : (fuelSeverity ?? .normal))) { [weak self] _ in
            self?.presentInformation(title: "Range",
                                     lines: [rangeText.map { "~\($0) \(formatter.distanceUnitLabel) estimated" } ?? "Not available yet."])
        })

        // The same snapshot the widgets and Siri read - written once per analysis
        // pass, not recomputed here, so this tile can never disagree with them.
        if let snapshot = WidgetSnapshotStore.read(), let distanceKm = snapshot.lastTripDistanceKm {
            let distanceText = formatter.distance(kilometres: distanceKm, fractionDigits: 1) ?? "—"
            let detail = [formatter.duration(seconds: snapshot.lastTripDurationSeconds),
                          formatter.economy(kmPerLitre: snapshot.lastTripEconomyKmPerLitre).map { "\($0) \(formatter.economyUnitLabel)" }]
                .compactMap { $0 }.joined(separator: " · ")
            buttons.append(CPGridButton(titleVariants: ["\(distanceText) \(formatter.distanceUnitLabel)"],
                                        image: tileImage(symbolName: InsightCategory.trip.symbolName, status: nil)) { [weak self] _ in
                let line = detail.isEmpty ? "\(distanceText) \(formatter.distanceUnitLabel)"
                                          : "\(distanceText) \(formatter.distanceUnitLabel) · \(detail)"
                self?.presentInformation(title: "Last drive", lines: [line])
            })
        }

        if let maintenance = drive.health?.system(.maintenance), maintenance.status != .unknown {
            buttons.append(CPGridButton(titleVariants: [maintenance.headline],
                                        image: tileImage(symbolName: InsightCategory.maintenance.symbolName,
                                                         status: maintenance.status)) { [weak self] _ in
                self?.presentInformation(title: "Next service", lines: [maintenance.headline])
            })
        }

        // Cost per distance, from the same snapshot the widgets read. Descriptive
        // rather than judged: DriveLayer has no opinion about what a kilometre ought
        // to cost, so this tile carries no status colour.
        if let snapshot = WidgetSnapshotStore.read(), let cost = snapshot.costPerKilometre {
            let perDisplayUnit = formatter.unitSystem == .metric ? cost : cost / 0.621_371
            let amount = formatter.decimal(perDisplayUnit, fractionDigits: 2) ?? "—"
            buttons.append(CPGridButton(titleVariants: ["\(amount) / \(formatter.distanceUnitLabel)"],
                                        image: tileImage(symbolName: InsightCategory.efficiency.symbolName,
                                                         status: nil)) { [weak self] _ in
                self?.presentInformation(title: "Running cost",
                                         lines: ["About \(amount) per \(formatter.distanceUnitLabel), averaged over the fills you have priced."])
            })
        }

        return buttons
    }

    // MARK: - Ahead tab

    private func aheadButtons(_ environment: AppEnvironment) -> [CPGridButton] {
        let drive = environment.drive
        let formatter = environment.formatter
        let weatherSeverity = severity(forCategory: .weather, in: drive.insights)
        var buttons: [CPGridButton] = []

        // Reachability leads this tab, because it is the only tile here with a
        // consequence: rain ahead changes how you drive, a shortfall changes whether
        // you stop. This is also the tile that most wants to be in the car rather than
        // on the phone - it answers a question that only exists while driving.
        if let verdict = drive.journeyReserve, verdict != .unknown {
            buttons.append(CPGridButton(titleVariants: [reserveTitle(verdict, formatter: formatter)],
                                        image: tileImage(symbolName: "fuelpump.arrowtriangle.right",
                                                         status: verdict.status)) { [weak self] _ in
                self?.presentInformation(title: drive.destination?.name ?? "Your destination",
                                         lines: [drive.journeySentence].compactMap { $0 })
            })
        }

        if let change = drive.weatherChanges.first {
            buttons.append(CPGridButton(titleVariants: [change.headline.capitalized],
                                        image: tileImage(symbolName: InsightCategory.weather.symbolName,
                                                         status: weatherSeverity ?? .normal)) { [weak self] _ in
                self?.presentInformation(title: change.headline.capitalized, lines: [change.detail])
            })
        } else if let weather = drive.currentWeather {
            buttons.append(CPGridButton(titleVariants: [weather.condition.displayName],
                                        image: tileImage(symbolName: InsightCategory.weather.symbolName,
                                                         status: weatherSeverity)) { [weak self] _ in
                self?.presentInformation(title: "Weather", lines: [weather.condition.displayName])
            })
        }

        if let terrain = drive.terrainFeature {
            let terrainSeverity = severity(forCategory: .terrain, in: drive.insights)
            buttons.append(CPGridButton(titleVariants: [terrain.headline],
                                        image: tileImage(symbolName: InsightCategory.terrain.symbolName,
                                                         status: terrainSeverity ?? .normal)) { [weak self] _ in
                self?.presentInformation(title: terrain.headline, lines: [terrain.detail()])
            })
        }

        return buttons
    }

    /// The reserve as a tile title: a number and a word, not a sentence.
    ///
    /// The full sentence is one tap away on the information template. What fits on a
    /// tile at a glance is whether you make it and by how much - "+84 km spare" or
    /// "62 km short" - and the distance is in the driver's own units because a figure
    /// in kilometres to someone reading miles is worse than no figure.
    private func reserveTitle(_ verdict: FuelIntelligence.ReserveVerdict,
                              formatter: DisplayFormatter) -> String {
        func distance(_ kilometres: Double) -> String {
            let value = formatter.distance(kilometres: kilometres, fractionDigits: 0) ?? "—"
            return "\(value) \(formatter.distanceUnitLabel)"
        }
        switch verdict {
        case let .comfortable(reserve): return "\(distance(reserve)) spare"
        case let .tight(reserve): return "\(distance(reserve)) spare"
        case let .insufficient(shortfall): return "\(distance(shortfall)) short"
        case .unknown: return "No estimate"
        }
    }

    /// A grid needs at least two buttons to read as a grid rather than a stray tile.
    /// Padding here keeps that guarantee in one place instead of at every call site.
    private func atLeastTwo(_ buttons: [CPGridButton]) -> [CPGridButton] {
        guard buttons.count < 2 else { return buttons }
        var padded = buttons
        while padded.count < 2 {
            padded.append(CPGridButton(titleVariants: ["Nothing to report"],
                                       image: tileImage(symbolName: "checkmark.circle", status: .normal)) { _ in })
        }
        return padded
    }

    // MARK: - Ask Harrier

    /// All of the copilot's example questions, not a shortened preview of them - each
    /// one already routes to a real, non-stub answer, the same ones the phone app's
    /// copilot gives. A list scrolls; there was never a reason to cut it down to four.
    private func copilotSection() -> CPListSection {
        var items: [CPListItem] = []

        // Speaking comes first because it is the only entry here that takes a question
        // this list does not already contain.
        if #available(iOS 27.0, *) {
            let speak = CPListItem(text: "Ask a question", detailText: "Speak to Harrier")
            speak.handler = { [weak self] _, completion in
                self?.listen()
                completion()
            }
            items.append(speak)
        }

        items += LocalCopilot.exampleQuestions.map { question -> CPListItem in
            let item = CPListItem(text: question, detailText: nil)
            item.handler = { [weak self] _, completion in
                self?.answer(question)
                completion()
            }
            return item
        }
        return CPListSection(items: items, header: "Ask Harrier", sectionIndexTitle: nil)
    }

    /// A question whose answer is already computed. The rule matcher answers these
    /// instantly and exactly; handing them to a language model would add latency and
    /// no accuracy, which is the wrong trade at the wheel.
    private func answer(_ question: String) {
        guard let environment else { return }
        let snapshot = environment.drive.copilotSnapshot()
        let answer = LocalCopilot.respond(to: question, snapshot: snapshot)
        // The spoken form, not the detailed one: this is being read at the wheel.
        presentInformation(title: question, lines: [answer.spokenText])
    }

    // MARK: - Voice

    /// Listens, then answers whatever was actually asked.
    ///
    /// `CPVoiceControlTemplate` became available to a driving-task app in iOS 27;
    /// before that this list was the only way to ask anything, which is why the entry
    /// point above is gated rather than the template merely being avoided.
    ///
    /// CarPlay requires that recording only happens while this template is on screen,
    /// and that is also the honest thing to show: the template going up is the
    /// driver's evidence that the microphone is open, and it coming down is the
    /// evidence that it closed.
    @available(iOS 27.0, *)
    private func listen() {
        guard let environment else { return }
        let listening = CPVoiceControlState(identifier: Self.listeningStateIdentifier,
                                            titleVariants: ["Listening…", "Listening"],
                                            image: nil,
                                            repeats: false)
        let template = CPVoiceControlTemplate(voiceControlStates: [listening])
        interfaceController.presentTemplate(template, animated: true, completion: nil)

        Task { @MainActor in
            let unavailable = await voice.start { [weak self] transcript in
                self?.answerSpoken(transcript, environment: environment)
            }
            if let unavailable {
                // Nothing is listening, so the template would be a lie. Take it down
                // and say why in the same breath.
                interfaceController.dismissTemplate(animated: true, completion: nil)
                presentInformation(title: "Can't listen", lines: [unavailable.message])
            }
        }
    }

    /// Answers a spoken question through the model-backed copilot.
    ///
    /// This is the one place the model earns its latency: a sentence a driver actually
    /// said will rarely match the rule matcher's keywords, and `FoundationModelsCopilot`
    /// falls back to that matcher by itself when the model cannot help. Its answer is
    /// still guarded, so speaking cannot get a number past a check that typing could not.
    @available(iOS 27.0, *)
    private func answerSpoken(_ question: String, environment: AppEnvironment) {
        let snapshot = environment.drive.copilotSnapshot()
        Task { @MainActor in
            let answer = try? await FoundationModelsCopilot().answer(question: question, snapshot: snapshot)
            interfaceController.dismissTemplate(animated: true, completion: nil)
            presentInformation(title: question,
                               lines: [answer?.spokenText ?? "I couldn't work that one out. Try one of the questions in the list."])
        }
    }

    // MARK: - Critical alert

    /// Interrupts with a modal alert for a genuinely critical insight, once per
    /// distinct insight. Everything below `.critical` stays passive on the urgent
    /// tile - a colour and a shape a driver can check when they choose to, not a
    /// pop-up they did not ask for. This is deliberately conservative: CarPlay review
    /// treats driver interruptions as a safety question, not a feature to reach for.
    private func presentCriticalAlertIfNeeded(_ environment: AppEnvironment) {
        guard !isAlertPresented,
              let insight = InsightEngine.headline(environment.drive.insights),
              insight.severity == .critical,
              insight.id != alertedInsightID else { return }

        alertedInsightID = insight.id
        isAlertPresented = true
        let dismiss = CPAlertAction(title: "Dismiss", style: .cancel) { [weak self] _ in
            self?.isAlertPresented = false
        }
        // Two variants, longest first: CarPlay picks whichever fits the screen it's
        // presenting on, and the short form still says what matters on its own.
        let alert = CPAlertTemplate(titleVariants: ["\(insight.title) — \(insight.summary)", insight.title],
                                    actions: [dismiss])
        interfaceController.presentTemplate(alert, animated: true, completion: nil)
    }

    // MARK: - Shared

    private func presentInformation(title: String, lines: [String]) {
        let items = lines.prefix(3).map { CPInformationItem(title: nil, detail: $0) }
        let template = CPInformationTemplate(title: title,
                                             layout: .leading,
                                             items: Array(items),
                                             actions: [])
        interfaceController.pushTemplate(template, animated: true, completion: nil)
    }

    /// The worst severity among insights for a category, if any exist. Weather and
    /// terrain have no rollup field of their own the way health and Hyperion do, so
    /// this is how their tiles get a colour at all - reusing InsightEngine's own
    /// judgment rather than the presenter inventing one.
    private func severity(forCategory category: InsightCategory, in insights: [DriveInsight]) -> SemanticStatus? {
        let matching = insights.filter { $0.category == category && $0.isDrivingSafeToDisplay }
        guard !matching.isEmpty else { return nil }
        return SemanticStatus.rollUp(matching.map(\.severity))
    }

    /// A tile icon: a fixed glyph for what it is, tinted by how it is doing. `nil`
    /// status means no judgment is available and gets the app's plain accent colour -
    /// not `.unknown`, which would read as "something is wrong and we can't see it"
    /// for a tile that is simply descriptive, like weather with no active change.
    private func tileImage(symbolName: String, status: SemanticStatus?) -> UIImage {
        let rgb = status.map { Palette.status($0, .dark) } ?? Palette.accent(.dark)
        return symbolImage(symbolName, rgb: rgb)
    }

    /// A tile icon whose *shape* carries severity, for the one tile where that is the
    /// most important thing to read at a glance without colour.
    private func statusShapeImage(_ status: SemanticStatus) -> UIImage {
        symbolImage(status.symbolName, rgb: Palette.status(status, .dark))
    }

    private func symbolImage(_ symbolName: String, rgb: RGB) -> UIImage {
        let color = UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        let configuration = UIImage.SymbolConfiguration(pointSize: 30, weight: .semibold)
        let base = UIImage(systemName: symbolName, withConfiguration: configuration) ?? UIImage()
        return base.withTintColor(color, renderingMode: .alwaysOriginal)
    }
}
#endif
