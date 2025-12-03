import Foundation

@MainActor
final class StatisticsViewModel: ObservableObject {

    enum DateRangePreset: String, CaseIterable, Identifiable {
        case thisMonth = "This Month"
        case last3Months = "Last 3 Months"
        case thisYear = "This Year"
        case allTime = "All-time"

        var id: String { rawValue }
    }

    // Inputs / Filters
    @Published var selectedRange: DateRangePreset = .thisMonth
    @Published var selectedStore: String = "Any"

    // Data
    @Published private(set) var receipts: [Receipt] = []
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var errorMessage: String?

    // Derived lists
    @Published private(set) var availableStores: [String] = ["Any"]

    private let firestore = FirestoreService()
    private var hasLoaded = false

    // MARK: - Public API

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await load()
    }

    func reload() async {
        await load(force: true)
    }

    // Total for last month (calendar previous month)
    var lastMonthTotal: Double {
        let cal = Calendar.current
        guard let lastMonth = cal.date(byAdding: .month, value: -1, to: Date()) else { return 0 }
        let comps = cal.dateComponents([.year, .month], from: lastMonth)
        guard
            let start = cal.date(from: comps),
            let end = cal.date(byAdding: DateComponents(month: 1, day: 0), to: start)
        else { return 0 }

        return receipts
            .filter { $0.date >= start && $0.date < end }
            .reduce(0) { $0 + $1.totalAmount }
    }

    // Filtered receipts based on current filters
    var filteredReceipts: [Receipt] {
        let (start, end, _) = dateBounds(for: selectedRange)
        return receipts.filter { r in
            let inRange = (start == nil || r.date >= start!) && (end == nil || r.date < end!)
            let storeMatch = (selectedStore == "Any" || r.storeName == selectedStore)
            return inRange && storeMatch
        }
    }

    // Buckets for bar chart
    // For .thisMonth -> daily buckets
    // For others -> monthly buckets
    struct Bucket: Identifiable {
        let id = UUID()
        let label: String
        let start: Date
        let end: Date
        let total: Double
    }

    var buckets: [Bucket] {
        let (startOpt, endOpt, granularity) = dateBounds(for: selectedRange)
        let source = filteredReceipts

        guard let start = startOpt else {
            // all-time without start -> compute min date in data
            guard let minDate = source.map({ $0.date }).min(),
                  let maxDate = source.map({ $0.date }).max() else { return [] }
            return buildBuckets(from: minDate, to: maxDate, granularity: granularity, receipts: source)
        }

        // If end missing, derive from data max or now
        let end = endOpt ?? (source.map { $0.date }.max() ?? Date())
        return buildBuckets(from: start, to: end, granularity: granularity, receipts: source)
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
            rebuildAvailableStores()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func rebuildAvailableStores() {
        let stores = Set(receipts.map { $0.storeName }).sorted()
        availableStores = ["Any"] + stores
        if !availableStores.contains(selectedStore) {
            selectedStore = "Any"
        }
    }

    // Returns (start, end, granularity)
    // end is exclusive upper bound
    private func dateBounds(for preset: DateRangePreset) -> (Date?, Date?, Granularity) {
        let cal = Calendar.current
        let now = Date()

        switch preset {
        case .thisMonth:
            let comps = cal.dateComponents([.year, .month], from: now)
            guard
                let start = cal.date(from: comps),
                let end = cal.date(byAdding: .month, value: 1, to: start)
            else { return (nil, nil, .day) }
            return (start, end, .day)

        case .last3Months:
            let comps = cal.dateComponents([.year, .month], from: now)
            guard
                let monthStart = cal.date(from: comps),
                let start = cal.date(byAdding: .month, value: -2, to: monthStart), // include current month -> 3 months window
                let end = cal.date(byAdding: .month, value: 1, to: monthStart)
            else { return (nil, nil, .month) }
            return (start, end, .month)

        case .thisYear:
            let comps = cal.dateComponents([.year], from: now)
            guard
                let start = cal.date(from: comps),
                let end = cal.date(byAdding: .year, value: 1, to: start)
            else { return (nil, nil, .month) }
            return (start, end, .month)

        case .allTime:
            // no explicit start/end; we’ll compute from data
            return (nil, nil, .month)
        }
    }

    private enum Granularity {
        case day
        case month
    }

    private func buildBuckets(from start: Date, to end: Date, granularity: Granularity, receipts: [Receipt]) -> [Bucket] {
        var buckets: [Bucket] = []
        let cal = Calendar.current

        switch granularity {
        case .day:
            guard var cursor = cal.startOfDay(for: start) as Date? else { return [] }
            let endDay = cal.startOfDay(for: end)
            while cursor < endDay {
                let next = cal.date(byAdding: .day, value: 1, to: cursor)!
                let total = receipts
                    .filter { $0.date >= cursor && $0.date < next }
                    .reduce(0) { $0 + $1.totalAmount }

                let label = DateFormatter.localizedString(from: cursor, dateStyle: .short, timeStyle: .none)
                buckets.append(Bucket(label: label, start: cursor, end: next, total: total))
                cursor = next
            }

        case .month:
            let comps = cal.dateComponents([.year, .month], from: start)
            guard var cursor = cal.date(from: comps) else { return [] }
            let endMonth = cal.dateComponents([.year, .month], from: end)
            while cursor < end {
                let next = cal.date(byAdding: .month, value: 1, to: cursor)!
                let total = receipts
                    .filter { $0.date >= cursor && $0.date < next }
                    .reduce(0) { $0 + $1.totalAmount }

                let label = monthLabel(for: cursor)
                buckets.append(Bucket(label: label, start: cursor, end: next, total: total))

                // Break if we’ve reached or exceeded end's month start
                if let endMonthStart = cal.date(from: endMonth), next >= endMonthStart && next >= end { break }
                cursor = next
            }
        }

        return buckets
    }

    private func monthLabel(for date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "MMM yyyy"
        return df.string(from: date)
    }
}
