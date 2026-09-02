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
/// The root is a tab bar over two grids and a list, not one scrolling list. A grid
/// tile shows a value at a glance - the thing a dashboard is for - and tapping it
/// pushes the same interpreted sentence the old single list showed as detail text.
/// This is the ceiling CarPlay allows a driving-task app: `CPGridTemplate`,
/// `CPListTemplate`, `CPInformationTemplate` and `CPTabBarTemplate` are the whole
/// vocabulary. There is no custom canvas, no chart, and no template that draws
/// anything DriveLayer did not already have the data for.
@MainActor
final class CarPlayPresenter {

    private let interfaceController: CPInterfaceController
    private var refreshTimer: Timer?

    private let vehicleGrid = CPGridTemplate(title: "Vehicle", gridButtons: [])
    private let aheadGrid = CPGridTemplate(title: "Ahead", gridButtons: [])
    private let copilotList = CPListTemplate(title: "Ask Harrier", sections: [])

    /// CarPlay connects on its own scene, so it needs a reference to the running app's
    /// state. This is the one place a shared instance is justified.
    private var environment: AppEnvironment? { AppEnvironment.active }

    init(interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
    }

    func start() {
        vehicleGrid.tabTitle = "Vehicle"
        vehicleGrid.tabImage = UIImage(systemName: "car.fill")

        aheadGrid.tabTitle = "Ahead"
        aheadGrid.tabImage = UIImage(systemName: "binoculars.fill")

        copilotList.tabTitle = "Ask Harrier"
        copilotList.tabImage = UIImage(systemName: "questionmark.bubble.fill")
        copilotList.emptyViewTitleVariants = ["DriveLayer"]
        copilotList.emptyViewSubtitleVariants = ["Open DriveLayer on your iPhone to add a vehicle."]

        let tabs = CPTabBarTemplate(templates: [vehicleGrid, aheadGrid, copilotList])
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
    }

    // MARK: - Building

    private func refresh() {
        guard let environment else {
            let placeholder = [CPGridButton(titleVariants: ["Open DriveLayer"],
                                            image: tileImage(symbolName: "iphone", status: nil)) { _ in }]
            vehicleGrid.updateGridButtons(atLeastTwo(placeholder))
            aheadGrid.updateGridButtons(atLeastTwo(placeholder))
            copilotList.updateSections([])
            return
        }
        vehicleGrid.updateGridButtons(atLeastTwo(vehicleButtons(environment)))
        aheadGrid.updateGridButtons(atLeastTwo(aheadButtons(environment)))
        copilotList.updateSections([copilotSection()])
    }

    // MARK: - Vehicle tab

    private func vehicleButtons(_ environment: AppEnvironment) -> [CPGridButton] {
        let drive = environment.drive
        let formatter = environment.formatter
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

        let rangeKm = drive.fuelStatus.estimatedRangeKm.value
        let rangeText = formatter.distance(kilometres: rangeKm, fractionDigits: 0)
        let fuelSeverity = severity(forCategory: .fuel, in: drive.insights)
        buttons.append(CPGridButton(titleVariants: rangeText.map { ["\($0) \(formatter.distanceUnitLabel)"] } ?? ["No data"],
                                    image: tileImage(symbolName: InsightCategory.fuel.symbolName,
                                                     status: rangeText == nil ? nil : (fuelSeverity ?? .normal))) { [weak self] _ in
            self?.presentInformation(title: "Range",
                                     lines: [rangeText.map { "~\($0) \(formatter.distanceUnitLabel) estimated" } ?? "Not available yet."])
        })

        // Replaces a diesel tile that could never appear on this car: DieselGuardian
        // returns notApplicable for a petrol profile, so the condition was dead for the
        // only vehicle DriveLayer supports.
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

    // MARK: - Ahead tab

    private func aheadButtons(_ environment: AppEnvironment) -> [CPGridButton] {
        let drive = environment.drive
        let weatherSeverity = severity(forCategory: .weather, in: drive.insights)
        var buttons: [CPGridButton] = []

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

    /// A short list of questions rather than free-form voice: the answers are already
    /// computed, and picking from four is safer at speed than dictating a sentence.
    private func copilotSection() -> CPListSection {
        let questions = Array(LocalCopilot.exampleQuestions.prefix(4))
        let items = questions.map { question -> CPListItem in
            let item = CPListItem(text: question, detailText: nil)
            item.handler = { [weak self] _, completion in
                self?.answer(question)
                completion()
            }
            return item
        }
        return CPListSection(items: items, header: "Ask Harrier", sectionIndexTitle: nil)
    }

    private func answer(_ question: String) {
        guard let environment else { return }
        let snapshot = environment.drive.copilotSnapshot()
        let answer = LocalCopilot.respond(to: question, snapshot: snapshot)
        // The spoken form, not the detailed one: this is being read at the wheel.
        presentInformation(title: question, lines: [answer.spokenText])
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
