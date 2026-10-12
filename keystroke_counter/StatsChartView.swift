//
//  StatsChartView.swift
//  keystroke_counter
//
//  Swift Charts bar chart of per-day keystrokes and clicks, with a 7 / 30 day
//  range switch.
//

import SwiftUI
import Charts

/// The range of history the chart shows.
enum ChartRange: Int, CaseIterable, Identifiable {
    case week = 7
    case month = 30

    var id: Int { rawValue }
    var label: String { self == .week ? "7 Days" : "30 Days" }
}

struct StatsChartView: View {
    let store: StatsStore
    @State private var range: ChartRange = .week
    @AppStorage("prioritiseCombinedCount") private var prioritiseCombinedCount = false

    /// Flattened (day, metric, value) rows for a grouped/stacked bar chart.
    private struct Point: Identifiable {
        let day: Date
        let metric: String
        let value: Int
        let goalReached: Bool

        var id: String {
            "\(day.timeIntervalSinceReferenceDate)-\(metric)"
        }
    }

    private var points: [Point] {
        store.series(days: range.rawValue).flatMap { d in
            let combined = d.keystrokes + d.clicks
            let reached = store.dailyGoal > 0 && combined >= store.dailyGoal
            if prioritiseCombinedCount {
                return [Point(day: d.day, metric: "Combined events", value: combined, goalReached: reached)]
            }
            return [
                Point(day: d.day, metric: "Keystrokes", value: d.keystrokes, goalReached: reached),
                Point(day: d.day, metric: "Clicks", value: d.clicks, goalReached: reached),
            ]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                // Title is provided by the enclosing collapsible section.
                Spacer()
                Picker("Range", selection: $range) {
                    ForEach(ChartRange.allCases) { r in
                        Text(r.label).tag(r)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
            }

            Chart(points) { point in
                BarMark(
                    x: .value("Day", point.day, unit: .day),
                    y: .value("Count", point.value)
                )
                .foregroundStyle(point.goalReached ? Color.green : (point.metric == "Clicks" ? Color.orange : Color.accentColor))
                .position(by: .value("Metric", point.metric))
                .accessibilityLabel("\(point.day.formatted(date: .abbreviated, time: .omitted)), \(point.metric)\(point.goalReached ? ", daily goal reached" : "")")
                .accessibilityValue("\(point.value)")
            }
            .chartLegend(.hidden)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: range == .week ? 1 : 5)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.day().month(.narrow))
                }
            }
            .frame(height: 140)

            HStack(spacing: 12) {
                legendItem(prioritiseCombinedCount ? "Combined events" : "Keystrokes", color: .accentColor)
                if !prioritiseCombinedCount {
                    legendItem("Clicks", color: .orange)
                }
            }
            if store.dailyGoal > 0 {
                legendItem("Daily goal reached (\(CountFormatter.grouped(store.dailyGoal)))", color: .green)
            }
        }
    }

    private func legendItem(_ title: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).foregroundStyle(.secondary)
        }
        .font(.caption2)
    }
}
