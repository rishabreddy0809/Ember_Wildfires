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

    /// Detections that pass the sensor on/off toggles. This is a display choice, not a data filter.
    var displayedDetections: [FireDetection] {
        visibleSensors.count == Sensor.allCases.count ? detections : detections.filter { visibleSensors.contains($0.sensor) }
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
        let cost = Sensor.allCases.count * query.dayCount
        if let wait = rateLimiter.waitTime(forCost: cost) {
            error = .rateLimited(retryAfter: wait)
            return
        }
        rateLimiter.record(cost: cost)

        let q = query
        let client = FIRMSClient(mapKey: key)
        isLoading = true
        defer { isLoading = false; loadingStatus = "" }

        do {
            loadingStatus = "Contacting FIRMS…"
            // MODIS and VIIRS are downloaded separately and at the same time.
            async let modisPages = client.fetchCSV(for: .modis, query: q)
            async let viiirsPages = client.fetchCSV(for: .viirs, query: q)
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
            emptyResultNotice = combined.isEmpty
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
    private func apply(raw: [FireDetection], query q: FireQuery, fetchedAt: Date, fromCache: Bool) async {
        loadingStatus = "Processing (\(pipeline.steps.map(\.name).joined(separator: " → ")))…"
        let processed = (try? await pipeline.run(raw)) ?? raw
        rawDetections = raw
        detections = processed
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
        selectionStack.removeAll { !visibleSensors.contains($0.sensor) }
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
