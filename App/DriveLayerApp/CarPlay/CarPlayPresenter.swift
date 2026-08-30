import Foundation
#if canImport(CarPlay)
import CarPlay
#endif

#if canImport(CarPlay)
/// Builds and refreshes the CarPlay templates.
///
/// Everything shown here is already interpreted by the time it arrives: the presenter
/// formats, orders by urgency, and does no analysis of its own. Refreshes are on a
/// slow timer because a driver does not need a screen that changes every second.
@MainActor
final class CarPlayPresenter {

    private let interfaceController: CPInterfaceController
    private var refreshTimer: Timer?
    private let rootTemplate = CPListTemplate(title: "DriveLayer", sections: [])

    /// CarPlay connects on its own scene, so it needs a reference to the running app's
    /// state. This is the one place a shared instance is justified.
    private var environment: AppEnvironment? { AppEnvironment.active }

    init(interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
    }

    func start() {
        rootTemplate.emptyViewTitleVariants = ["DriveLayer"]
        rootTemplate.emptyViewSubtitleVariants = ["Open DriveLayer on your iPhone to add a vehicle."]
        interfaceController.setRootTemplate(rootTemplate, animated: false, completion: nil)
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
            rootTemplate.updateSections([])
            return
        }
        rootTemplate.updateSections([statusSection(environment), copilotSection()])
    }

    private func statusSection(_ environment: AppEnvironment) -> CPListSection {
        let drive = environment.drive
        let formatter = environment.formatter
        var items: [CPListItem] = []

        // Urgent first: if something needs attention, it leads.
        if let headline = InsightEngine.headline(drive.insights), headline.severity >= .watch {
            let item = CPListItem(text: headline.title, detailText: headline.summary)
            item.handler = { [weak self] _, completion in
                self?.presentInformation(title: headline.title,
                                         lines: [headline.summary, headline.details, headline.recommendedAction].compactMap { $0 })
                completion()
            }
            items.append(item)
        }

        let health = drive.health
        items.append(CPListItem(text: "Vehicle",
                                detailText: health.map { "\($0.overall.label) — \($0.headline)" } ?? "Not enough data"))

        let range = formatter.distance(kilometres: drive.fuelStatus.estimatedRangeKm.value, fractionDigits: 0)
        items.append(CPListItem(text: "Range",
                                detailText: range.map { "~\($0) \(formatter.distanceUnitLabel) estimated" } ?? "Not available"))

        if let change = drive.weatherChanges.first {
            items.append(CPListItem(text: change.headline.capitalized, detailText: change.detail))
        } else if let weather = drive.currentWeather {
            items.append(CPListItem(text: "Weather", detailText: weather.condition.displayName))
        }

        if let terrain = drive.terrainFeature {
            items.append(CPListItem(text: terrain.headline, detailText: terrain.detail()))
        }

        // Replaces a diesel row that could never appear on this car: DieselGuardian
        // returns notApplicable for a petrol profile, so the condition was dead for the
        // only vehicle DriveLayer supports.
        if !drive.hyperion.isSilent {
            items.append(CPListItem(text: "Hyperion", detailText: drive.hyperion.overall.label))
        }

        return CPListSection(items: items, header: environment.selectedVehicle?.nickname ?? "DriveLayer", sectionIndexTitle: nil)
    }

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
        return CPListSection(items: items, header: "Ask copilot", sectionIndexTitle: nil)
    }

    private func answer(_ question: String) {
        guard let environment else { return }
        let snapshot = environment.drive.copilotSnapshot()
        let answer = LocalCopilot.respond(to: question, snapshot: snapshot)
        // The spoken form, not the detailed one: this is being read at the wheel.
        presentInformation(title: question, lines: [answer.spokenText])
    }

    private func presentInformation(title: String, lines: [String]) {
        let items = lines.prefix(3).map { CPInformationItem(title: nil, detail: $0) }
        let template = CPInformationTemplate(title: title,
                                             layout: .leading,
                                             items: Array(items),
                                             actions: [])
        interfaceController.pushTemplate(template, animated: true, completion: nil)
    }
}
#endif
