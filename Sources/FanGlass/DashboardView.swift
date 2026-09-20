// DashboardView.swift — sensor group cards + combined history chart.
import SwiftUI
import Charts

struct DashboardView: View {
    @EnvironmentObject var state: AppState
    var onScrolled: ((Bool) -> Void)? = nil

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14),
                           GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    /// "1 probe" / "12 probes". The English value carries automatic grammar
    /// agreement markup (`^[%lld probe](inflect: true)`), and only the
    /// AttributedString initializer resolves it — `String(localized:)` hands the
    /// markup back verbatim, which would land on screen. Interpolating the count
    /// into the key (rather than formatting afterwards) is what gives the
    /// inflection engine a number to agree with; the key is still "%lld probes".
    private static func probeCount(_ count: Int) -> String {
        String(AttributedString(localized: "\(count) probes").characters)
    }

    var body: some View {
        GlassScrollView(topMargin: 68, onScrolled: onScrolled) {
            VStack(alignment: .leading, spacing: 16) {
                if state.scanning {
                    scanningState
                } else if state.groups.isEmpty {
                    emptyState
                } else {
                    overviewCard
                    GlassSectionHeader(
                        title: String(localized: "Sensors"),
                        detail: Self.probeCount(state.groups.reduce(0) { $0 + $1.keys.count })
                    )
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(state.groups) { group in
                            SensorGroupCard(group: group)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 14)
        }
    }

    private var scanningState: some View {
        GlassCard {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text("Scanning SMC sensors…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
        }
    }

    private var emptyState: some View {
        GlassCard {
            VStack(spacing: 8) {
                Image(systemName: "thermometer.variable")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text("No sensors found")
                    .font(.headline)
                Text("Could not read temperature data from the SMC.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        }
    }

    private var overviewCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Temperature trend")
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text(String(format: String(localized: "Hottest %.0f°C"), state.hottestTemperature))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(state.temperatureColor(state.hottestTemperature))
                }

                let series = state.groups.filter { !$0.history.isEmpty && $0.id != "other" }.prefix(6)
                Chart {
                    ForEach(Array(series), id: \.id) { group in
                        ForEach(group.history, id: \.time) { sample in
                            LineMark(
                                x: .value(String(localized: "Time"), sample.time),
                                y: .value(String(localized: "Temperature"), sample.value),
                                series: .value(String(localized: "Group"), group.name)
                            )
                            .foregroundStyle(by: .value(String(localized: "Group"), group.name))
                            .interpolationMethod(.catmullRom)
                            .lineStyle(StrokeStyle(lineWidth: 1.8))
                        }
                    }
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartLegend(.hidden)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .minute, count: 1)) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 4]))
                            .foregroundStyle(Color.secondary.opacity(0.25))
                        AxisValueLabel(format: .dateTime.minute().second(), centered: true)
                            .font(.system(size: 9))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 4]))
                            .foregroundStyle(Color.secondary.opacity(0.25))
                        AxisValueLabel()
                            .font(.system(size: 9))
                    }
                }
                .frame(height: 170)

                HStack(spacing: 14) {
                    ForEach(Array(series), id: \.id) { group in
                        HStack(spacing: 5) {
                            Circle()
                                .fill(state.temperatureColor(group.value))
                                .frame(width: 6, height: 6)
                            Text(group.name)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Text(String(format: "%.0f°", group.value))
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                        }
                    }
                }
            }
        }
    }
}

struct SensorGroupCard: View {
    @EnvironmentObject var state: AppState
    let group: SensorGroupState

    var body: some View {
        GlassCard(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(group.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    // The probe count is a bare number: String(), not a
                    // LocalizedStringKey that would resolve to "%lld".
                    Text(String(group.keys.count))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.12)))
                }

                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(String(format: "%.1f", group.value))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(state.temperatureColor(group.value))
                        .contentTransition(.numericText())
                    Text("°C")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Sparkline(
                    values: group.history.suffix(60).map(\.value),
                    color: state.temperatureColor(group.value)
                )
                .frame(height: 28)
            }
        }
    }
}
