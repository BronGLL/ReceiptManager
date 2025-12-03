import Foundation
import Combine

@MainActor
final class StatisticsViewModel: ObservableObject {

    enum DateRangePreset: String, CaseIterable, Identifiable {
        case thisMonth = "This Month"
        case last3Months = "Last 3 Months"
        case thisYear = "This Year"
        case custom = "Custom"

        var id: String { rawValue }
    }

    // Inputs / Filters
    @Published var selectedRange: DateRangePreset = .thisMonth {
        didSet { scheduleRecompute() }
    }
    @Published var selectedStore: String = "Any" {
        didSet { scheduleRecompute() }
    }

    // Custom date range (used when selectedRange == .custom)
    // Defaults: start = start of current month, end = now
    @Published var customStart: Date = {
        let cal = Calendar.current
        let now = Date()
        let comps = cal.dateComponents([.year, .month], from: now)
        return cal.date(from: comps) ?? now
    }() {
        didSet { scheduleRecompute() }
    }
    @Published var customEnd: Date = Date() {
        didSet { scheduleRecompute() }
    }

    // Data
    @Published private(set) var receipts: [Receipt] = [] {
        didSet {
            rebuildAvailableStores()
            scheduleRecompute()
        }
    }
    @Published private(set) var isLoading: Bool = false
    @Published var errorMessage: String?

    // Derived lists
    // Display labels for store filter. Index 0 is "Any".
    @Published private(set) var availableStores: [String] = ["Any"]

    // Map display label -> canonical key for filtering
    private var storeDisplayToCanonical: [String: String] = [:]

    // Cached derived values (instead of heavy computed properties)
    @Published private(set) var filteredReceipts: [Receipt] = []
    @Published private(set) var buckets: [Bucket] = []
    @Published private(set) var isComputing: Bool = false

    // New: breakdown by store for currently filtered data
    @Published private(set) var storeBreakdown: [(store: String, total: Double)] = []

    private let firestore = FirestoreService()
    private var hasLoaded = false

    // Cancellation for recompute
    private var recomputeTask: Task<Void, Never>?

    // MARK: - Public API

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await load()
    }

    func reload() async {
        await load(force: true)
    }

    // Total for last month (calendar previous month)
    // Use component-based comparison to avoid TZ/UTC boundary issues and normalize 2-digit years.
    var lastMonthTotal: Double {
        let cal = Calendar.current
        let now = Date()
        guard let lastMonthDate = cal.date(byAdding: .month, value: -1, to: now) else { return 0 }

        let lastMonthComps = cal.dateComponents([.year, .month], from: lastMonthDate)
        guard let lastMonth = lastMonthComps.month, let lastYear = lastMonthComps.year else { return 0 }

        return receipts
            .reduce(0) { sum, r in
                let normalized = normalizeYearIfNeeded(r.date)
                let comps = cal.dateComponents([.year, .month], from: normalized)
                if comps.year == lastYear && comps.month == lastMonth {
                    return sum + r.totalAmount
                } else {
                    return sum
                }
            }
    }

    // Buckets for bar chart
    // For .thisMonth -> daily buckets
    // For others -> monthly buckets (except .custom which uses daily)
    struct Bucket: Identifiable {
        let id = UUID()
        let label: String
        let start: Date
        let end: Date
        let total: Double
    }

    // MARK: - Private

    private func load(force: Bool = false) async {
        if isLoading { return }
        if hasLoaded && !force { return }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let fetched = try await firestore.fetchReceipts()
            receipts = fetched
            hasLoaded = true
            // scheduleRecompute() is called by receipts didSet
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // Canonicalize store names to make filtering robust to case and punctuation differences
    nonisolated private func canonicalStore(_ name: String) -> String {
        // Lowercase, trim whitespace, and strip trailing punctuation like periods.
        let lowered = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = lowered.trimmingCharacters(in: CharacterSet(charactersIn: ".!?,;:"))
        return stripped
    }

    private func rebuildAvailableStores() {
        // Build a map canonical -> first-seen display label to avoid duplicates
        var canonicalToDisplay: [String: String] = [:]

        for raw in receipts.map({ $0.storeName }) {
            let canonical = canonicalStore(raw)
            if canonicalToDisplay[canonical] == nil {
                // Prefer a nicely capitalized version of the first seen raw value for display
                canonicalToDisplay[canonical] = raw
            }
        }

        // Sort display labels by case-insensitive compare
        let displayStores = canonicalToDisplay.values.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

        availableStores = ["Any"] + displayStores

        // Build display -> canonical map for filtering
        var displayToCanonical: [String: String] = [:]
        for (canon, display) in canonicalToDisplay {
            displayToCanonical[display] = canon
        }
        storeDisplayToCanonical = displayToCanonical

        // Keep selectedStore if still present; otherwise reset to Any
        if !availableStores.contains(selectedStore) {
            selectedStore = "Any"
        }
    }

    // Normalize a date if its year is 0...99 by mapping to 2000 + year
    // This handles receipts whose year is stored as "25" instead of "2025".
    nonisolated private func normalizeYearIfNeeded(_ date: Date) -> Date {
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
        if let y = comps.year, (0...99).contains(y) {
            comps.year = 2000 + y
            return cal.date(from: comps) ?? date
        }
        return date
    }

    // Returns (start, end, granularity)
    // end is exclusive upper bound
    // This helper is pure: it does not read actor-isolated state.
    nonisolated private func dateBounds(for preset: DateRangePreset, customStart: Date, customEnd: Date) -> (Date, Date, Granularity) {
        let cal = Calendar.current
        let now = Date()

        switch preset {
        case .thisMonth:
            let comps = cal.dateComponents([.year, .month], from: now)
            let start = cal.date(from: comps) ?? cal.startOfDay(for: now)
            let end = cal.date(byAdding: .month, value: 1, to: start) ?? now
            return (start, end, .day)

        case .last3Months:
            let comps = cal.dateComponents([.year, .month], from: now)
            let monthStart = cal.date(from: comps) ?? cal.startOfDay(for: now)
            let start = cal.date(byAdding: .month, value: -2, to: monthStart) ?? monthStart
            let end = cal.date(byAdding: .month, value: 1, to: monthStart) ?? monthStart
            return (start, end, .month)

        case .thisYear:
            let comps = cal.dateComponents([.year], from: now)
            let start = cal.date(from: comps) ?? cal.startOfDay(for: now)
            let end = cal.date(byAdding: .year, value: 1, to: start) ?? now
            return (start, end, .month)

        case .custom:
            // Use provided customStart/customEnd; ensure valid order (start < end)
            if customStart < customEnd {
                return (customStart, customEnd, .day) // daily buckets for custom range
            } else {
                // Return an empty range (end == start), will yield no data
                return (customStart, customStart, .day)
            }
        }
    }

    private enum Granularity {
        case day
        case month
    }

    // MARK: - Recompute pipeline

    private func scheduleRecompute() {
        // Cancel any ongoing recompute
        recomputeTask?.cancel()

        // Launch a new recompute task
        recomputeTask = Task {
            await recompute()
        }
    }

    private func recompute() async {
        // Mark computing on main
        await MainActor.run { self.isComputing = true }

        // Capture inputs snapshot to avoid races (on main actor)
        let currentReceipts = receipts
        let currentRange = selectedRange
        let currentStoreDisplay = selectedStore
        let currentCustomStart = customStart
        let currentCustomEnd = customEnd
        let selectedCanonical = storeDisplayToCanonical[currentStoreDisplay]

        // Do heavy work off-main
        let result = await Task.detached(priority: .userInitiated) { () -> (filtered: [Receipt], buckets: [Bucket], breakdown: [(String, Double)]) in
            // Step 1: filter by range and store
            let (start, end, granularity) = self.dateBounds(for: currentRange, customStart: currentCustomStart, customEnd: currentCustomEnd)

            let filtered = currentReceipts.filter { r in
                // store filter (use canonical)
                if let selCanon = selectedCanonical, currentStoreDisplay != "Any" {
                    let rCanon = self.canonicalStore(r.storeName)
                    if rCanon != selCanon { return false }
                }
                // date range (normalize year; end is exclusive)
                let d = self.normalizeYearIfNeeded(r.date)
                if d < start { return false }
                if d >= end { return false }
                return true
            }

            // Step 2: aggregate buckets
            let buckets = self.buildBucketsOnePass(from: start, to: end, granularity: granularity, receipts: filtered)

            // Step 3: breakdown by store (group by canonical, display first-seen raw)
            var totalsByCanon: [String: Double] = [:]
            var displayForCanon: [String: String] = [:]
            for r in filtered {
                let canon = self.canonicalStore(r.storeName)
                totalsByCanon[canon, default: 0] += r.totalAmount
                if displayForCanon[canon] == nil {
                    displayForCanon[canon] = r.storeName
                }
            }
            var breakdown: [(String, Double)] = totalsByCanon.map { (canon, total) in
                let display = displayForCanon[canon] ?? canon
                return (display, total)
            }
            // Sort descending by total
            breakdown.sort { $0.1 > $1.1 }

            return (filtered, buckets, breakdown)
        }.value

        // Publish on main if not cancelled
        guard !Task.isCancelled else { return }
        await MainActor.run {
            self.filteredReceipts = result.filtered
            self.buckets = result.buckets
            self.storeBreakdown = result.breakdown
            self.isComputing = false
        }
    }

    // O(N + B) bucketing: single pass aggregation by bucket key, then emit contiguous buckets
    nonisolated private func buildBucketsOnePass(from start: Date, to end: Date, granularity: Granularity, receipts: [Receipt]) -> [Bucket] {
        let cal = Calendar.current

        // Normalize start and end to bucket boundaries (end is exclusive)
        let normalizedStart: Date
        let exclusiveEnd: Date

        switch granularity {
        case .day:
            normalizedStart = cal.startOfDay(for: start)
            exclusiveEnd = cal.startOfDay(for: end)
        case .month:
            let compsStart = cal.dateComponents([.year, .month], from: start)
            normalizedStart = cal.date(from: compsStart) ?? start
            let compsEnd = cal.dateComponents([.year, .month], from: end)
            exclusiveEnd = cal.date(from: compsEnd) ?? end
        }

        // Aggregate totals per bucket key
        var totals: [Date: Double] = [:]
        totals.reserveCapacity(64)

        for r in receipts {
            let normalizedDate = normalizeYearIfNeeded(r.date)
            let key: Date
            switch granularity {
            case .day:
                key = cal.startOfDay(for: normalizedDate)
            case .month:
                let comps = cal.dateComponents([.year, .month], from: normalizedDate)
                key = cal.date(from: comps) ?? normalizedDate
            }
            totals[key, default: 0] += r.totalAmount
        }

        // Produce contiguous buckets between normalizedStart and exclusiveEnd
        var output: [Bucket] = []
        var cursor = normalizedStart

        let dfDay: DateFormatter = {
            let df = DateFormatter()
            df.dateStyle = .short
            df.timeStyle = .none
            return df
        }()

        let dfMonth: DateFormatter = {
            let df = DateFormatter()
            df.dateFormat = "MMM yyyy"
            return df
        }()

        while cursor < exclusiveEnd {
            let next: Date
            let label: String

            switch granularity {
            case .day:
                next = cal.date(byAdding: .day, value: 1, to: cursor) ?? cursor
                label = dfDay.string(from: cursor)
            case .month:
                next = cal.date(byAdding: .month, value: 1, to: cursor) ?? cursor
                label = dfMonth.string(from: cursor)
            }

            let total = totals[cursor] ?? 0
            output.append(Bucket(label: label, start: cursor, end: next, total: total))
            cursor = next
        }

        return output
    }

    private func monthLabel(for date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "MMM yyyy"
        return df.string(from: date)
    }
}
