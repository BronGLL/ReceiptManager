import SwiftUI
import Charts

struct StatisticsView: View {
    @StateObject private var vm = StatisticsViewModel()

    // Formatter to show just day of month, e.g., "4"
    private let dayFormatter: DateFormatter = {
        let df = DateFormatter()
        df.setLocalizedDateFormatFromTemplate("d") // day of month without leading zeros in many locales
        return df
    }()

    // Formatter for month labels if you ever want to customize non-daily cases
    private let monthFormatter: DateFormatter = {
        let df = DateFormatter()
        df.setLocalizedDateFormatFromTemplate("MMM yyyy")
        return df
    }()

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header

                filters

                // Custom range controls
                if vm.selectedRange == .custom {
                    customRangeControls
                }

                lastMonthCard

                chartSection
            }
            .padding()
        }
        .navigationTitle("Statistics")
        .task { await vm.loadIfNeeded() }
        .refreshable {
            await vm.reload()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await vm.reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")
            }
        }
        .alert("Error", isPresented: Binding(
            get: { vm.errorMessage != nil },
            set: { _ in vm.errorMessage = nil }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(vm.errorMessage ?? "")
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.fill")
                .resizable()
                .scaledToFit()
                .frame(height: 80)
                .foregroundStyle(.tint)

            Text("Spending Overview")
                .font(.title2)
                .fontWeight(.semibold)

            if vm.isLoading {
                ProgressView().padding(.top, 4)
            }
        }
    }

    private var filters: some View {
        VStack(spacing: 12) {
            // Date Range
            Picker("Date Range", selection: $vm.selectedRange) {
                ForEach(StatisticsViewModel.DateRangePreset.allCases) { preset in
                    Text(preset.rawValue).tag(preset)
                }
            }
            .pickerStyle(.segmented)

            // Store filter
            HStack {
                Text("Store")
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    ForEach(vm.availableStores, id: \.self) { store in
                        Button(store) { vm.selectedStore = store }
                    }
                } label: {
                    HStack {
                        Text(vm.selectedStore)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.thinMaterial, in: Capsule())
                }
            }
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }

    private var customRangeControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Custom Date Range")
                .font(.headline)

            HStack(spacing: 12) {
                DatePicker("Start", selection: $vm.customStart, displayedComponents: [.date])
                    .datePickerStyle(.compact)
                DatePicker("End", selection: $vm.customEnd, displayedComponents: [.date])
                    .datePickerStyle(.compact)
            }

            // Optional: quick set buttons
            HStack {
                Button("This Month") {
                    let cal = Calendar.current
                    let now = Date()
                    let comps = cal.dateComponents([.year, .month], from: now)
                    let start = cal.date(from: comps) ?? now
                    vm.customStart = start
                    vm.customEnd = now
                }
                .buttonStyle(.bordered)

                Button("Last 30 Days") {
                    let now = Date()
                    if let start = Calendar.current.date(byAdding: .day, value: -30, to: now) {
                        vm.customStart = start
                        vm.customEnd = now
                    }
                }
                .buttonStyle(.bordered)
            }
            .foregroundStyle(.secondary)
            .font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }

    private var lastMonthCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Last Month Total")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("$\(vm.lastMonthTotal, specifier: "%.2f")")
                .font(.title2.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Totals Over Time")
                .font(.headline)

            // Total for items included in the chart
            let chartTotal = vm.buckets.reduce(0.0) { $0 + $1.total }
            VStack(alignment: .leading, spacing: 6) {
                Text("Chart Total")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("$\(chartTotal, specifier: "%.2f")")
                    .font(.title3.weight(.semibold))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.quaternary, lineWidth: 1)
            )

            if vm.buckets.isEmpty {
                Text("No data for selected filters.")
                    .foregroundStyle(.secondary)
            } else {
                if vm.selectedRange == .thisMonth {
                    // THIS MONTH: Use Date x-axis + show day-of-month labels (thinned).
                    Chart(vm.buckets) { bucket in
                        BarMark(
                            x: .value("Period", bucket.start), // Date axis
                            y: .value("Total", bucket.total)
                        )
                        .foregroundStyle(.tint)
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading)
                    }
                    .chartXAxis {
                        // Show every Nth day label; render as just the day-of-month.
                        let step = 3 // adjust to taste
                        let starts = vm.buckets.map { $0.start }
                        let visibleStarts = stride(from: 0, to: starts.count, by: max(step, 1)).map { starts[$0] }

                        AxisMarks(values: visibleStarts) { value in
                            AxisGridLine()
                            AxisTick()
                            AxisValueLabel {
                                if let date = value.as(Date.self) {
                                    Text(dayFormatter.string(from: date))
                                        .font(.caption2)
                                        .lineLimit(1)
                                        .fixedSize()
                                }
                            }
                        }
                    }
                    .frame(height: 240)
                } else if vm.selectedRange == .custom {
                    // CUSTOM: Use Date x-axis, daily granularity (like thisMonth), show day-of-month labels.
                    Chart(vm.buckets) { bucket in
                        BarMark(
                            x: .value("Period", bucket.start),
                            y: .value("Total", bucket.total)
                        )
                        .foregroundStyle(.tint)
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading)
                    }
                    .chartXAxis {
                        // Choose a step based on span length: if long, increase step
                        let count = vm.buckets.count
                        let step = max(1, count / 12) // aim ~12 labels max
                        let starts = vm.buckets.map { $0.start }
                        let visibleStarts = stride(from: 0, to: starts.count, by: step).map { starts[$0] }

                        AxisMarks(values: visibleStarts) { value in
                            AxisGridLine()
                            AxisTick()
                            AxisValueLabel {
                                if let date = value.as(Date.self) {
                                    // Show just day if within same month; otherwise show short date
                                    Text(dayFormatter.string(from: date))
                                        .font(.caption2)
                                        .lineLimit(1)
                                        .fixedSize()
                                }
                            }
                        }
                    }
                    .frame(height: 240)
                } else {
                    // OTHER PRESETS: Keep original string labels and default spacing.
                    Chart(vm.buckets) { bucket in
                        BarMark(
                            x: .value("Period", bucket.label), // categorical axis
                            y: .value("Total", bucket.total)
                        )
                        .foregroundStyle(.tint)
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading)
                    }
                    .chartXAxis {
                        AxisMarks() // default behavior, preserves your previous monthly spacing/labels
                    }
                    .frame(height: 240)
                }
            }

            // Breakdown by store underneath the chart
            VStack(alignment: .leading, spacing: 8) {
                Text("By Store")
                    .font(.headline)

                if vm.storeBreakdown.isEmpty {
                    Text("No store totals for the selected filters.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(vm.storeBreakdown.enumerated()), id: \.offset) { _, entry in
                        HStack {
                            Text(entry.store)
                            Spacer()
                            Text("$\(entry.total, specifier: "%.2f")")
                                .bold()
                        }
                        .font(.subheadline)
                    }
                }
            }
            .padding(.top, 8)

            // Spending statistics
            spendingStatsSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }

    // MARK: - Spending Stats

    private var spendingStatsSection: some View {
        let totalAcrossBuckets = vm.buckets.reduce(0.0) { $0 + $1.total }
        let receiptCount = vm.filteredReceipts.count
        let avgPerReceipt = receiptCount > 0 ? totalAcrossBuckets / Double(receiptCount) : 0.0

        // Average per day
        let avgPerDay: Double = {
            guard !vm.buckets.isEmpty else { return 0.0 }
            let cal = Calendar.current

            switch vm.selectedRange {
            case .thisMonth, .custom:
                // daily buckets: average bucket total
                let sum = totalAcrossBuckets
                return sum / Double(vm.buckets.count)

            case .last3Months, .thisYear:
                // monthly buckets: average per-day by dividing each month by its days, then averaging
                let perDayValues: [Double] = vm.buckets.map { b in
                    let days = cal.range(of: .day, in: .month, for: b.start)?.count ?? 30
                    return days > 0 ? (b.total / Double(days)) : 0.0
                }
                let sum = perDayValues.reduce(0, +)
                return sum / Double(perDayValues.count)
            }
        }()

        // Average per month
        let avgPerMonth: Double = {
            guard !vm.buckets.isEmpty else { return 0.0 }
            let cal = Calendar.current

            switch vm.selectedRange {
            case .last3Months, .thisYear:
                // monthly buckets: mean of monthly totals
                return totalAcrossBuckets / Double(vm.buckets.count)

            case .thisMonth, .custom:
                // daily buckets: group by (year, month) and average monthly sums
                var monthlyTotals: [DateComponents: Double] = [:]
                for b in vm.buckets {
                    let comps = cal.dateComponents([.year, .month], from: b.start)
                    monthlyTotals[comps, default: 0.0] += b.total
                }
                let totals = Array(monthlyTotals.values)
                let sum = totals.reduce(0, +)
                return totals.isEmpty ? 0.0 : sum / Double(totals.count)
            }
        }()

        return VStack(alignment: .leading, spacing: 8) {
            Text("Spending Stats")
                .font(.headline)

            HStack {
                Text("Average per day")
                Spacer()
                Text("$\(avgPerDay, specifier: "%.2f")").bold()
            }
            HStack {
                Text("Average per month")
                Spacer()
                Text("$\(avgPerMonth, specifier: "%.2f")").bold()
            }
            HStack {
                Text("Receipts in range")
                Spacer()
                Text("\(receiptCount)").bold()
            }
            HStack {
                Text("Average per receipt")
                Spacer()
                Text("$\(avgPerReceipt, specifier: "%.2f")").bold()
            }
        }
        .padding(.top, 8)
    }
}

#Preview {
    NavigationStack { StatisticsView() }
}
