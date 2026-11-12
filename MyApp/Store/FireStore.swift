//  FireStore.swift
//  Holds the app's state and runs the steps in order:
//  load the cache → download → parse → process → show on the map.
//  The views read from this object and call its methods. They never touch the network directly.

import Foundation
import Observation
import MapKit

@Observable
final class FireStore {

    // MARK: Query being edited in the sidebar
    var query = FireQuery()

    // MARK: Data
    /// Exactly what FIRMS returned (MODIS + VIIRS combined). Cached and exported.
    private(set) var rawDetections: [FireDetection] = []
    /// What the processing pipeline returned. This is what the map shows.
    /// Right now it is identical to `rawDetections`.
    private(set) var detections: [FireDetection] = []
    /// P(wildfire) from the harmonized MODIS + VIIRS random forest, by detection id.
    private(set) var wildfireScores: [UUID: Float] = [:]
    /// How many shown detections the model classifies as wildfire at the current sensitivity.
    var wildfireCount: Int { detections.lazy.filter { self.isWildfire($0) }.count }
    /// Probability cut for "wildfire". Lower catches more small fires; higher removes more
    /// non-wildfire detections. Defaults to the value chosen on 2020 data.
    var mlThreshold: Float = WildfireClassifier.threshold
    /// The query that produced the data currently shown, which can differ from `query` while you edit.
    private(set) var loadedQuery: FireQuery?
    private(set) var lastUpdated: Date?
    private(set) var isShowingCachedData = false
    private(set) var skippedRows = 0
    /// Goes up by one each time new data is published, so the map knows when to redraw.
    private(set) var dataVersion = 0

    // MARK: Status
    private(set) var isLoading = false
    private(set) var loadingStatus = ""
    var error: FIRMSError?
    /// Shown when a download succeeds but finds nothing.
    private(set) var emptyResultNotice = false

    // MARK: Map & selection
    var visibleSensors: Set<Sensor> = [.modis, .viirs]
    /// When on, the map shows only detections the harmonized ML model classifies as wildfire.
    private(set) var mlFilter = false
    var mapStyle: MapStyleChoice = .satellite
    /// Every detection under the last click, nearest first. Overlapping points are kept separate, never merged.
    var selectionStack: [FireDetection] = []
    var selectionIndex = 0
    var showInspector = false
    /// Increase this to ask the map to zoom to the query area.
    private(set) var zoomRequest = 0
    /// What the map is showing now, used by "Use Visible Map Area".
    var visibleMapBounds: GeoBounds?
    /// Asks the map to center on a coordinate. The counter makes each request unique.
    private(set) var focusRequest: (id: Int, coordinate: CLLocationCoordinate2D)?
    /// Shows the CSV save panel.
    var isExporting = false

    // MARK: Internals
    private var rateLimiter = RateLimiter()
    private var refreshTask: Task<Void, Never>?
    let pipeline = ProcessingPipeline.current

    // MARK: Derived values

    var selected: FireDetection? {
        selectionStack.indices.contains(selectionIndex) ? selectionStack[selectionIndex] : nil
    }

    func count(_ sensor: Sensor) -> Int { detections.lazy.filter { $0.sensor == sensor }.count }

    /// Detections that pass the sensor toggles and, in ML mode, the wildfire classifier.
    /// This is a display choice: the raw data, cache, and CSV export are never filtered.
    var displayedDetections: [FireDetection] {
        let all = visibleSensors.count == Sensor.allCases.count && !mlFilter
        return all ? detections : detections.filter(isDisplayed)
    }

    func isDisplayed(_ d: FireDetection) -> Bool {
        visibleSensors.contains(d.sensor) && (!mlFilter || isWildfire(d))
    }

    func wildfireProbability(_ d: FireDetection) -> Float? { wildfireScores[d.id] }

    func isWildfire(_ d: FireDetection) -> Bool { (wildfireScores[d.id] ?? 0) >= mlThreshold }

    /// Count for one sensor as currently shown (after the ML filter, if it is on).
    func shownCount(_ sensor: Sensor) -> Int {
        mlFilter ? detections.lazy.filter { $0.sensor == sensor && self.isWildfire($0) }.count : count(sensor)
    }

    /// MODIS only, VIIRS only, both raw, or both filtered by the harmonized ML model.
    var displayMode: DisplayMode {
        get {
            if mlFilter { return .wildfireML }
            if visibleSensors == [.modis] { return .modis }
            if visibleSensors == [.viirs] { return .viirs }
            return .both
        }
        set {
            mlFilter = newValue == .wildfireML && WildfireClassifier.isAvailable
            switch newValue {
            case .modis: visibleSensors = [.modis]
            case .viirs: visibleSensors = [.viirs]
            case .both, .wildfireML: visibleSensors = Set(Sensor.allCases)
            }
            selectionStack.removeAll { !isDisplayed($0) }
            selectionIndex = 0
        }
    }

    /// Changes whenever what the map should draw changes.
    struct DisplayKey: Hashable {
        let version: Int
        let sensors: Set<Sensor>
        let mlFilter: Bool
        let threshold: Float
    }
    var displayKey: DisplayKey {
        DisplayKey(version: dataVersion, sensors: visibleSensors, mlFilter: mlFilter, threshold: mlFilter ? mlThreshold : 0)
    }

    var hasMapKey: Bool { SecretsLoader.mapKey() != nil }

    /// True when the sidebar settings differ from the data on screen.
    var queryIsDirty: Bool { loadedQuery != nil && loadedQuery != query }

    // MARK: Lifecycle

    private var hasStarted = false

    /// Called once at launch: show the cache right away, then refresh in the background.
    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        if let snapshot = await DetectionCache.load() {
            query = snapshot.query
            await apply(raw: snapshot.detections, query: snapshot.query, fetchedAt: snapshot.fetchedAt, fromCache: true)
            zoomRequest += 1
        } else {
            zoomRequest += 1
        }
        if UserDefaults.standard.object(forKey: "refreshOnLaunch") as? Bool ?? true { refresh() }
    }

    // MARK: Refresh

    /// Starts a download, unless one is already running.
    func refresh() {
        guard !isLoading else { return }
        refreshTask = Task { await performRefresh() }
    }

    func cancelRefresh() { refreshTask?.cancel() }

    private func performRefresh() async {
        error = nil
        emptyResultNotice = false

        guard let key = SecretsLoader.mapKey() else { error = .missingKey; return }
        if let reason = query.bounds.validationError { error = .invalidArea(reason); return }

        // Cost = number of requests × days. This is a conservative estimate, since FIRMS counts larger requests as more than one transaction.
        // One extra day is downloaded before the range as context for the ML model (see apply).
        let cost = Sensor.allCases.count * (query.dayCount + 1)
        if let wait = rateLimiter.waitTime(forCost: cost) {
            error = .rateLimited(retryAfter: wait)
            return
        }
        rateLimiter.record(cost: cost)

        let q = query
        var fetch = q
        fetch.startDate = FireQuery.utc.date(byAdding: .day, value: -1, to: q.startDate) ?? q.startDate
        fetch.dayCount = q.dayCount + 1
        let client = FIRMSClient(mapKey: key)
        isLoading = true
        defer { isLoading = false; loadingStatus = "" }

        do {
            loadingStatus = "Contacting FIRMS…"
            // MODIS and VIIRS are downloaded separately and at the same time.
            async let modisPages = client.fetchCSV(for: .modis, query: fetch)
            async let viiirsPages = client.fetchCSV(for: .viirs, query: fetch)
            let (m, v) = try await (modisPages, viiirsPages)

            loadingStatus = "Parsing detections…"
            var combined: [FireDetection] = []
            var skipped = 0
            for page in m {
                let r = await FIRMSParser.parse(csv: page, sensor: .modis, source: q.modisSource)
                combined += r.detections; skipped += r.skipped
            }
            for page in v {
                let r = await FIRMSParser.parse(csv: page, sensor: .viirs, source: q.viirsSource)
                combined += r.detections; skipped += r.skipped
            }
            try Task.checkCancellation()

            let now = Date()
            skippedRows = skipped
            await apply(raw: combined, query: q, fetchedAt: now, fromCache: false)
            emptyResultNotice = rawDetections.isEmpty
            try? await DetectionCache.save(CachedSnapshot(fetchedAt: now, query: q, detections: combined))
        } catch is CancellationError {
            // The user cancelled, so leave the current data as it is.
        } catch {
            self.error = FIRMSError.from(error)
            // Keep showing whatever was loaded before (often the cache), and label it as such.
            if !rawDetections.isEmpty { isShowingCachedData = true }
        }
    }

    /// Sends raw detections through the processing pipeline and publishes the result.
    /// `raw` may include the context day before the query range: the ML model uses it
    /// (it looks one day back), but only detections inside the range are shown and exported.
    private func apply(raw: [FireDetection], query q: FireQuery, fetchedAt: Date, fromCache: Bool) async {
        loadingStatus = "Processing (\(pipeline.steps.map(\.name).joined(separator: " → ")))…"
        let processed = (try? await pipeline.run(raw)) ?? raw
        loadingStatus = "Classifying with harmonized MODIS + VIIRS model…"
        let scores = await WildfireClassifier.scores(for: processed)
        let first = FireQuery.firmsDateString(q.startDate), last = FireQuery.firmsDateString(q.endDate)
        let inRange = { (d: FireDetection) in d.acqDate >= first && d.acqDate <= last }
        rawDetections = raw.filter(inRange)
        detections = processed.filter(inRange)
        wildfireScores = scores
        dataVersion += 1
        loadedQuery = q
        lastUpdated = fetchedAt
        isShowingCachedData = fromCache
        clearSelection()
    }

    // MARK: Area

    func selectPreset(_ preset: AreaPreset) {
        query.areaName = preset.name
        query.bounds = preset.bounds
        zoomRequest += 1
    }

    func useVisibleMapArea() {
        guard let b = visibleMapBounds else { return }
        query.areaName = "Custom area"
        query.bounds = b
    }

    func zoomToArea() { zoomRequest += 1 }

    func focus(on detection: FireDetection) {
        focusRequest = ((focusRequest?.id ?? 0) + 1, detection.coordinate)
    }

    /// Transactions this app has used in the current 10-minute window, shown in Settings.
    var transactionsUsed: Int { rateLimiter.used() }

    // MARK: Selection

    func select(stack: [FireDetection]) {
        selectionStack = stack
        selectionIndex = 0
        if !stack.isEmpty { showInspector = true }
    }

    func clearSelection() {
        selectionStack = []
        selectionIndex = 0
    }

    func stepSelection(_ delta: Int) {
        guard !selectionStack.isEmpty else { return }
        selectionIndex = (selectionIndex + delta + selectionStack.count) % selectionStack.count
    }

    func toggle(_ sensor: Sensor) {
        if visibleSensors.contains(sensor) { visibleSensors.remove(sensor) } else { visibleSensors.insert(sensor) }
        selectionStack.removeAll { !isDisplayed($0) }
        selectionIndex = 0
    }

    // MARK: Export

    /// Default filename such as "firms_California_2026-11-06_to_2026-11-07.csv".
    var exportFilename: String {
        let q = loadedQuery ?? query
        let area = q.areaName.replacingOccurrences(of: " ", with: "_")
        return "firms_\(area)_\(FireQuery.firmsDateString(q.startDate))_to_\(FireQuery.firmsDateString(q.endDate)).csv"
    }

    /// The file being exported. It is built only when you choose Export, not on every redraw.
    private(set) var exportDocument: CSVDocument?

    /// Builds the CSV from the raw (unprocessed) detections and opens the save panel.
    func beginExport() {
        guard !rawDetections.isEmpty else { return }
        exportDocument = CSVDocument(text: CSVExporter.csv(for: rawDetections))
        isExporting = true
    }

    func dismissEmptyNotice() { emptyResultNotice = false }

    func clearCache() {
        DetectionCache.clear()
    }
}

/// What the map shows. The ML option uses both sensors, harmonized, and hides detections
/// the classifier judges not to be wildfire (farm or prescribed burns, industrial heat, false alarms).
enum DisplayMode: String, CaseIterable, Identifiable {
    case modis, viirs, both, wildfireML
    var id: String { rawValue }
    var shortLabel: String {
        switch self {
        case .modis: "MODIS"
        case .viirs: "VIIRS"
        case .both: "Both"
        case .wildfireML: "ML"
        }
    }
    var title: String {
        switch self {
        case .modis: "MODIS only"
        case .viirs: "VIIRS only"
        case .both: "MODIS + VIIRS (raw)"
        case .wildfireML: "Harmonized ML: wildfires only"
        }
    }
}

/// The base map styles available in the toolbar.
enum MapStyleChoice: String, CaseIterable, Identifiable {
    case satellite = "Satellite"
    case dark = "Dark"
    case standard = "Standard"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .satellite: "globe.americas.fill"
        case .dark: "moon.fill"
        case .standard: "map.fill"
        }
    }
}
