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

    /// Flattened (day, metric, value) rows for a grouped/stacked bar chart.
    private struct Point: Identifiable {
        let id = UUID()
        let day: Date
        let metric: String
        let value: Int
    }

    private var points: [Point] {
        store.series(days: range.rawValue).flatMap { d in
            [
                Point(day: d.day, metric: "Keystrokes", value: d.keystrokes),
                Point(day: d.day, metric: "Clicks", value: d.clicks),
            ]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("History")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                .foregroundStyle(by: .value("Metric", point.metric))
                .position(by: .value("Metric", point.metric))
            }
            .chartForegroundStyleScale([
                "Keystrokes": Color.accentColor,
                "Clicks": Color.orange,
            ])
            .chartLegend(position: .bottom, spacing: 4)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: range == .week ? 1 : 5)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.day().month(.narrow))
                }
            }
            .frame(height: 140)
        }
    }
}
