//  FireStore.swift
//  Holds the app's state and runs the steps in order:
//  load the cache → download → parse → process → classify → show.
//  The views read from this object and call its methods. They never touch the network directly.
//
//  A worldwide download is around 100,000 detections, so anything the views show about
//  the whole set (what is displayed, the per-region totals) is worked out once here when
//  the data or the display choice changes, not on every redraw.

import Foundation
import Observation
import MapKit

@Observable
final class FireStore {

    // MARK: Query being edited in the sidebar
    var query = FireQuery()

    // MARK: Data
    /// Exactly what FIRMS returned (MODIS + VIIRS combined). Exported.
    private(set) var rawDetections: [FireDetection] = []
    /// What the processing pipeline returned. Right now it is identical to `rawDetections`.
    private(set) var detections: [FireDetection] = []
    /// P(wildfire) from the harmonized MODIS + VIIRS random forest, by detection id.
    private(set) var wildfireScores: [UUID: Float] = [:]
    /// The same scores in the order of `detections` (-1 where there is none).
    private var scoreList: [Float] = []
    /// Index into `WorldRegion.all` for each of `detections`.
    private var regionList: [Int] = []
    /// How many detections fall in each twentieth of the probability scale, for the Model view.
    private(set) var scoreHistogram = [Int](repeating: 0, count: 20)
    /// Probability cut for "wildfire". Lower catches more small fires; higher removes more
    /// non-wildfire detections. Defaults to the value chosen on 2020 data.
    private(set) var mlThreshold: Float = WildfireClassifier.threshold
    /// The query that produced the data currently shown, which can differ from `query` while you edit.
    private(set) var loadedQuery: FireQuery?
    private(set) var lastUpdated: Date?
    private(set) var isShowingCachedData = false
    private(set) var skippedRows = 0
    /// Goes up by one each time new data is published, so the views know when to redraw.
    private(set) var dataVersion = 0

    // MARK: What is on screen (rebuilt by `rebuildDisplay`)
    /// Detections that pass the sensor toggles and, in ML mode, the wildfire classifier.
    /// This is a display choice: the raw data, cache, and CSV export are never filtered.
    private(set) var displayedDetections: [FireDetection] = []
    /// Totals for everything displayed.
    private(set) var world = RegionSummary()
    /// Totals for each part of the world that has at least one displayed detection, busiest first.
    private(set) var regions: [RegionSummary] = []

    // MARK: Status
    private(set) var isLoading = false
    private(set) var loadingStatus = ""
    var error: FIRMSError?
    /// Shown when a download succeeds but finds nothing.
    private(set) var emptyResultNotice = false

    // MARK: View state
    var mode: AppMode = .globe
    var fx = SceneFX()
    var visibleSensors: Set<Sensor> = [.modis, .viirs]
    /// When on, only detections the harmonized ML model classifies as wildfire are shown.
    private(set) var mlFilter = false
    var mapStyle: MapStyleChoice = .satellite
    var regionSearch = ""
    private(set) var selectedRegionID: String?
    /// Every detection under the last click, nearest first. Overlapping points are kept separate, never merged.
    var selectionStack: [FireDetection] = []
    var selectionIndex = 0
    var showInspector = true
    /// Increase this to ask the map to zoom to the query area.
    private(set) var zoomRequest = 0
    /// What the map is showing now, used by "Use Visible Map Area".
    var visibleMapBounds: GeoBounds?
    /// Asks the globe and the map to center on a coordinate. The counter makes each request unique.
    private(set) var focusRequest: (id: Int, coordinate: CLLocationCoordinate2D)?
    /// Asks the globe to turn to a region and the map to zoom to it.
    private(set) var regionFocus: (id: Int, region: RegionSummary)?
    /// Shows the CSV save panel.
    var isExporting = false

    // MARK: Internals
    private var rateLimiter = RateLimiter()
    private var refreshTask: Task<Void, Never>?
    let pipeline = ProcessingPipeline.current

    init() {
        if let m = UserDefaults.standard.string(forKey: "mode"), let mode = AppMode(rawValue: m) { self.mode = mode }
    }

    // MARK: Derived values

    var selected: FireDetection? {
        selectionStack.indices.contains(selectionIndex) ? selectionStack[selectionIndex] : nil
    }

    var selectedRegion: RegionSummary? {
        guard let id = selectedRegionID else { return nil }
        return regions.first { $0.id == id }
    }

    /// Regions that match the sidebar search.
    var visibleRegions: [RegionSummary] {
        let q = regionSearch.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return regions }
        return regions.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.continent.localizedCaseInsensitiveContains(q) }
    }

    func count(_ sensor: Sensor) -> Int { sensor == .modis ? totalModis : totalViirs }
    private var totalModis = 0
    private var totalViirs = 0

    /// How many loaded detections the model classifies as wildfire at the current sensitivity.
    private(set) var wildfireCount = 0

    func isDisplayed(_ d: FireDetection) -> Bool {
        visibleSensors.contains(d.sensor) && (!mlFilter || isWildfire(d))
    }

    func wildfireProbability(_ d: FireDetection) -> Float? { wildfireScores[d.id] }

    func isWildfire(_ d: FireDetection) -> Bool { (wildfireScores[d.id] ?? 0) >= mlThreshold }

    /// Count for one sensor as currently shown (after the ML filter, if it is on).
    func shownCount(_ sensor: Sensor) -> Int { sensor == .modis ? world.modis : world.viirs }

    /// The name of the region a detection falls in.
    func regionName(of d: FireDetection) -> String {
        WorldRegion.all[WorldRegion.index(latitude: d.latitude, longitude: d.longitude)].name
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
            displayChanged()
        }
    }

    func setThreshold(_ value: Float) {
        guard abs(value - mlThreshold) > 0.0001 else { return }
        mlThreshold = value
        displayChanged()
    }

    /// Changes whenever what the globe and the map should draw changes.
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
    /// How long a saved download counts as current. FIRMS itself updates every few minutes at most.
    static let freshFor: TimeInterval = 10 * 60

    /// Called once at launch: show the cache right away, then refresh in the background.
    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        if let snapshot = await DetectionCache.load() {
            query = snapshot.query
            isLoading = true
            loadingStatus = "Opening the saved download…"
            await ingest(modis: snapshot.modisPages, viirs: snapshot.viirsPages, query: snapshot.query,
                         fetchedAt: snapshot.fetchedAt, fromCache: true)
            isLoading = false
            loadingStatus = ""
        }
        zoomRequest += 1
        // A saved copy from the last few minutes is as new as FIRMS has, so don't ask again.
        let isFresh = lastUpdated.map { Date().timeIntervalSince($0) < Self.freshFor } ?? false
        if !isFresh, UserDefaults.standard.object(forKey: "refreshOnLaunch") as? Bool ?? true { refresh() }
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
            async let viirsPages = client.fetchCSV(for: .viirs, query: fetch)
            let (m, v) = try await (modisPages, viirsPages)
            try Task.checkCancellation()

            let now = Date()
            await ingest(modis: m, viirs: v, query: q, fetchedAt: now, fromCache: false)
            emptyResultNotice = rawDetections.isEmpty
            try? await DetectionCache.save(CachedSnapshot(fetchedAt: now, query: q, modisPages: m, viirsPages: v))
        } catch is CancellationError {
            // The user cancelled, so leave the current data as it is.
        } catch {
            self.error = FIRMSError.from(error)
            // Keep showing whatever was loaded before (often the cache), and label it as such.
            if !rawDetections.isEmpty { isShowingCachedData = true }
        }
    }

    /// Parses the CSV pages of both sensors and publishes the result.
    private func ingest(modis: [String], viirs: [String], query q: FireQuery, fetchedAt: Date, fromCache: Bool) async {
        loadingStatus = "Reading detections…"
        async let m = FIRMSParser.parse(pages: modis, sensor: .modis, source: q.modisSource)
        async let v = FIRMSParser.parse(pages: viirs, sensor: .viirs, source: q.viirsSource)
        let (modisResult, viirsResult) = await (m, v)
        skippedRows = modisResult.skipped + viirsResult.skipped
        await apply(raw: modisResult.detections + viirsResult.detections, query: q, fetchedAt: fetchedAt, fromCache: fromCache)
    }

    /// Sends raw detections through the processing pipeline and publishes the result.
    /// `raw` may include the context day before the query range: the ML model uses it
    /// (it looks one day back), but only detections inside the range are shown and exported.
    ///
    /// The detections are published as soon as they are ready, so the globe fills at once.
    /// The wildfire scores follow a moment later, when the classifier has been through them.
    private func apply(raw: [FireDetection], query q: FireQuery, fetchedAt: Date, fromCache: Bool) async {
        loadingStatus = "Processing \(raw.count.grouped) detections…"
        let processed = (try? await pipeline.run(raw)) ?? raw
        let first = FireQuery.firmsDateString(q.startDate), last = FireQuery.firmsDateString(q.endDate)
        let inRange = { (d: FireDetection) in d.acqDate >= first && d.acqDate <= last }
        let shown = processed.filter(inRange)
        let regionOf = await WorldRegion.assign(shown)

        rawDetections = raw.filter(inRange)
        detections = shown
        wildfireScores = [:]
        scoreList = [Float](repeating: -1, count: shown.count)
        regionList = regionOf
        scoreHistogram = [Int](repeating: 0, count: 20)
        dataVersion += 1
        loadedQuery = q
        lastUpdated = fetchedAt
        isShowingCachedData = fromCache
        clearSelection()
        rebuildDisplay()
        applyLaunchArguments()

        loadingStatus = "Classifying with the MODIS + VIIRS model…"
        let version = dataVersion
        let scores = await WildfireClassifier.scores(for: processed)
        guard version == dataVersion else { return }   // newer data arrived while this was running
        wildfireScores = scores
        scoreList = shown.map { scores[$0.id] ?? -1 }
        var histogram = [Int](repeating: 0, count: 20)
        for s in scoreList where s >= 0 { histogram[min(19, Int(s * 20))] += 1 }
        scoreHistogram = histogram
        // With the filter on, what is displayed depends on the scores, so the views must redraw.
        if mlFilter { dataVersion += 1 }
        rebuildDisplay()
        if UserDefaults.standard.bool(forKey: "wildfires"), !mlFilter { displayMode = .wildfireML }
    }

    private var hasAppliedLaunchArguments = false

    /// `-region "Central Africa"`, `-pick 4.5,20.1` and `-wildfires YES` select something as
    /// soon as the first data arrives, alongside `-mode Map`. Handy for demos.
    private func applyLaunchArguments() {
        guard !hasAppliedLaunchArguments, !detections.isEmpty else { return }
        hasAppliedLaunchArguments = true
        let defaults = UserDefaults.standard
        if let name = defaults.string(forKey: "region"), let r = regions.first(where: { $0.name == name }) {
            selectRegion(r)
        }
        if let parts = defaults.string(forKey: "pick")?.split(separator: ",").compactMap({ Double($0) }), parts.count == 2 {
            pick(latitude: parts[0], longitude: parts[1], tolerance: 0.6)
            if let d = selected { focus(on: d) }
        }
    }

    /// The display choice (sensors, ML filter, sensitivity) changed.
    private func displayChanged() {
        rebuildDisplay()
        selectionStack.removeAll { !isDisplayed($0) }
        selectionIndex = 0
    }

    /// Works out what is shown and the totals for each region, in one pass over the data.
    private func rebuildDisplay() {
        let showModis = visibleSensors.contains(.modis), showViirs = visibleSensors.contains(.viirs)
        let cut = mlThreshold, onlyWildfire = mlFilter
        let days = (loadedQuery ?? query).dayCount
        let fallback = WorldRegion.all.count - 1

        var shown: [FireDetection] = []
        shown.reserveCapacity(detections.count)
        var perRegion = [RegionAccumulator](repeating: RegionAccumulator(), count: WorldRegion.all.count)
        var whole = RegionAccumulator()
        var modis = 0, viirs = 0, wildfire = 0

        for (i, d) in detections.enumerated() {
            let score = i < scoreList.count ? scoreList[i] : -1
            let isFire = score >= cut
            if d.sensor == .modis { modis += 1 } else { viirs += 1 }
            if isFire { wildfire += 1 }
            guard d.sensor == .modis ? showModis : showViirs else { continue }
            if onlyWildfire && !isFire { continue }
            shown.append(d)
            let r = i < regionList.count ? regionList[i] : fallback
            perRegion[r].add(d, isWildfire: isFire, isScored: score >= 0)
            whole.add(d, isWildfire: isFire, isScored: score >= 0)
        }

        totalModis = modis
        totalViirs = viirs
        wildfireCount = wildfire
        displayedDetections = shown
        world = whole.summary(name: (loadedQuery ?? query).areaName, continent: "", days: days)
        regions = perRegion.enumerated()
            .filter { $0.element.count > 0 }
            .map { $0.element.summary(name: WorldRegion.all[$0.offset].name, continent: WorldRegion.all[$0.offset].continent, days: days) }
            .sorted { $0.count > $1.count }
        if let id = selectedRegionID, !regions.contains(where: { $0.id == id }) { selectedRegionID = nil }
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

    // MARK: Regions

    /// Selects a region (or none). The globe turns to it and the map zooms to it.
    func selectRegion(_ region: RegionSummary?) {
        selectedRegionID = region?.id
        clearSelection()
        if let region { regionFocus = ((regionFocus?.id ?? 0) + 1, region) }
    }

    func stepRegion(_ delta: Int) {
        let list = visibleRegions
        guard !list.isEmpty else { return }
        let current = list.firstIndex { $0.id == selectedRegionID }
        let next = current.map { ($0 + delta + list.count) % list.count } ?? (delta > 0 ? 0 : list.count - 1)
        selectRegion(list[next])
    }

    // MARK: Selection

    func select(stack: [FireDetection]) {
        selectionStack = stack
        selectionIndex = 0
        if !stack.isEmpty { showInspector = true }
    }

    /// Selects one detection and brings it into view on the globe or the map.
    func show(_ detection: FireDetection) {
        select(stack: [detection])
        focus(on: detection)
    }

    /// A click on the globe at a coordinate. Selects every displayed detection within
    /// `tolerance` degrees, nearest first. With none nearby, selects the region instead.
    func pick(latitude: Double, longitude: Double, tolerance: Double) {
        let cosLat = max(0.05, cos(latitude * .pi / 180))
        var found: [(Double, Int)] = []
        for (i, d) in displayedDetections.enumerated() {
            let dy = d.latitude - latitude
            guard abs(dy) <= tolerance else { continue }
            var dx = abs(d.longitude - longitude)
            if dx > 180 { dx = 360 - dx }
            dx *= cosLat
            let dist = dx * dx + dy * dy
            if dist <= tolerance * tolerance { found.append((dist, i)) }
        }
        if !found.isEmpty {
            found.sort { $0.0 < $1.0 }
            select(stack: found.prefix(24).map { displayedDetections[$0.1] })
            return
        }
        let name = WorldRegion.all[WorldRegion.index(latitude: latitude, longitude: longitude)].name
        if let region = regions.first(where: { $0.name == name }) {
            selectedRegionID = region.id
            clearSelection()
        } else {
            clearSelection()
        }
    }

    /// The displayed detection closest to a place, if one is within `tolerance` degrees.
    /// Changes nothing; the globe uses it to show what the pointer is over.
    func nearest(latitude: Double, longitude: Double, tolerance: Double) -> FireDetection? {
        let cosLat = max(0.05, cos(latitude * .pi / 180))
        var best = tolerance * tolerance, bestIndex = -1
        for (i, d) in displayedDetections.enumerated() {
            let dy = d.latitude - latitude
            guard abs(dy) <= tolerance else { continue }
            var dx = abs(d.longitude - longitude)
            if dx > 180 { dx = 360 - dx }
            dx *= cosLat
            let dist = dx * dx + dy * dy
            if dist <= best { best = dist; bestIndex = i }
        }
        return bestIndex >= 0 ? displayedDetections[bestIndex] : nil
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
        displayChanged()
    }

    // MARK: Export

    /// Default filename such as "firms_Whole_world_2026-11-14_to_2026-11-15.csv".
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

/// The three views in the middle of the window.
enum AppMode: String, CaseIterable, Identifiable {
    case globe = "Globe", map = "Map", model = "Model"
    var id: String { rawValue }
}

/// Globe effects the user can switch on and off.
struct SceneFX: Equatable {
    var clouds = true
    var spin = false
}

/// What is shown. The ML option uses both sensors, harmonized, and hides detections
/// the classifier judges not to be wildfire (farm or prescribed burns, industrial heat, false alarms).
enum DisplayMode: String, CaseIterable, Identifiable {
    case both, modis, viirs, wildfireML
    var id: String { rawValue }
    var shortLabel: String {
        switch self {
        case .modis: "MODIS"
        case .viirs: "VIIRS"
        case .both: "Both"
        case .wildfireML: "Wildfires"
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

/// The base map styles for the Map view.
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

/// How busy a region is, from detections per day. A reading aid, not a danger rating.
nonisolated enum Activity: String, Sendable {
    case intense = "Intense", active = "Active", quiet = "Quiet"

    init(perDay: Double) {
        self = perDay >= 2500 ? .intense : (perDay >= 250 ? .active : .quiet)
    }
}

/// The totals for one region, or for everything displayed.
nonisolated struct RegionSummary: Identifiable, Equatable, Sendable {
    var name = ""
    var continent = ""
    var days = 1
    var count = 0
    var modis = 0
    var viirs = 0
    /// Detections the model scored, and how many of those it calls wildfire at the current sensitivity.
    var scored = 0
    var wildfire = 0
    var night = 0
    var highConfidence = 0
    var peakFRP = 0.0
    var totalFRP = 0.0
    var medianFRP: Double?
    /// The middle of the detections (not of the region's box), so the globe turns to where the fires are.
    var latitude = 0.0
    var longitude = 0.0
    /// The box that holds every detection in the region.
    var bounds = GeoBounds.world
    /// The five strongest detections by fire radiative power.
    var top: [FireDetection] = []

    var id: String { name }
    var activity: Activity { Activity(perDay: Double(count) / Double(max(days, 1))) }

    static func == (a: RegionSummary, b: RegionSummary) -> Bool {
        a.name == b.name && a.count == b.count && a.modis == b.modis && a.wildfire == b.wildfire && a.days == b.days
    }
}

/// Collects the running totals for a region while `rebuildDisplay` walks the detections.
private nonisolated struct RegionAccumulator {
    var count = 0, modis = 0, viirs = 0, scored = 0, wildfire = 0, night = 0, highConfidence = 0
    var x = 0.0, y = 0.0, z = 0.0
    var west = 180.0, east = -180.0, south = 90.0, north = -90.0
    var frps: [Double] = []
    var top: [FireDetection] = []

    mutating func add(_ d: FireDetection, isWildfire: Bool, isScored: Bool) {
        count += 1
        if d.sensor == .modis { modis += 1 } else { viirs += 1 }
        if isScored { scored += 1 }
        if isWildfire { wildfire += 1 }
        if d.dayNight == .night { night += 1 }
        switch d.confidence {
        case .percent(let p): if p >= 80 { highConfidence += 1 }
        case .category(let c): if c == .high { highConfidence += 1 }
        case .unknown: break
        }
        // Average as points on a sphere, so regions that cross 180° still get a sensible middle.
        let phi = d.latitude * .pi / 180, lam = d.longitude * .pi / 180
        x += cos(phi) * cos(lam); y += cos(phi) * sin(lam); z += sin(phi)
        west = min(west, d.longitude); east = max(east, d.longitude)
        south = min(south, d.latitude); north = max(north, d.latitude)

        guard let frp = d.frp else { return }
        frps.append(frp)
        if top.count < 5 || frp > (top.last?.frp ?? 0) {
            let at = top.firstIndex { ($0.frp ?? 0) < frp } ?? top.count
            top.insert(d, at: at)
            if top.count > 5 { top.removeLast() }
        }
    }

    func summary(name: String, continent: String, days: Int) -> RegionSummary {
        var s = RegionSummary(name: name, continent: continent, days: days, count: count, modis: modis, viirs: viirs,
                              scored: scored, wildfire: wildfire, night: night, highConfidence: highConfidence)
        let sorted = frps.sorted()
        s.peakFRP = sorted.last ?? 0
        s.totalFRP = sorted.reduce(0, +)
        s.medianFRP = sorted.isEmpty ? nil : sorted[sorted.count / 2]
        if count > 0 {
            s.latitude = atan2(z, (x * x + y * y).squareRoot()) * 180 / .pi
            s.longitude = atan2(y, x) * 180 / .pi
            let pad = 0.6
            s.bounds = GeoBounds(west: max(-180, west - pad), south: max(-90, south - pad),
                                 east: min(180, east + pad), north: min(90, north + pad))
        }
        s.top = top
        return s
    }
}
