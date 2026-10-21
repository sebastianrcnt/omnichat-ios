import SwiftUI
import Charts

/// OpenUI's charts with Swift Charts. `RadarChart` falls back to grouped bars and `RadialChart` to a donut.
struct OUIChart: View {
    @Environment(\.theme) private var theme
    let component: OUIComponent
    let scope: OUIScope

    struct Point: Identifiable {
        var id: Int
        var label: String
        var series: String
        var value: Double
        var x: Double = 0
    }

    /// Series colours: the accent first, then hues that stay apart from it and each other in light and dark.
    static func palette(_ theme: DSTheme) -> [Color] {
        [theme.accent,
         Color(light: 0x0F9D8F, dark: 0x2DD4BF),
         Color(light: 0xE08E1B, dark: 0xF0A33A),
         Color(light: 0xD9466F, dark: 0xF472A0),
         Color(light: 0x4F6EF7, dark: 0x7C93FD),
         Color(light: 0x6B9E1F, dark: 0xA3D95B)]
    }

    private var labels: [String] { component.list("labels").map(\.stringForm) }

    /// Category points of `labels` × `series`, in order.
    private var seriesPoints: [Point] {
        var out: [Point] = []
        let labels = labels
        for (s, series) in component.components("series").enumerated() {
            let name = series.string("category") ?? series.string("name") ?? "Series \(s + 1)"
            for (i, v) in series.list("values").enumerated() where i < labels.count {
                out.append(Point(id: out.count, label: labels[i], series: name, value: v.toNumber))
            }
        }
        return out
    }

    /// One-dimensional points: `labels` with `values`, or `Slice`s.
    private var slicePoints: [Point] {
        let values = component.list("values")
        if values.isEmpty {
            return component.components("labels").enumerated().map { i, slice in
                Point(id: i, label: slice.string("category") ?? "", series: slice.string("category") ?? "", value: slice.number("value") ?? 0)
            }
        }
        return labels.enumerated().compactMap { i, label in
            i < values.count ? Point(id: i, label: label, series: label, value: values[i].toNumber) : nil
        }
    }

    var body: some View {
        let c = component
        // Pies are square-ish and read fine smaller.
        let height = CGFloat(c.number("height") ?? (["PieChart", "RadialChart"].contains(c.type) ? 170 : 200))
        Group {
            switch c.type {
            case "BarChart", "RadarChart":
                bars(seriesPoints, stacked: c.string("variant") == "stacked", horizontal: false)
            case "HorizontalBarChart":
                bars(seriesPoints, stacked: c.string("variant") == "stacked", horizontal: true)
            case "LineChart":
                lines(seriesPoints, area: false)
            case "AreaChart":
                lines(seriesPoints, area: true)
            case "PieChart", "RadialChart":
                pie(slicePoints, donut: c.string("variant") == "donut" || c.type == "RadialChart")
            case "SingleStackedBarChart":
                stackedBar(slicePoints)
            case "ScatterChart":
                scatter
            default:
                EmptyView()
            }
        }
        .frame(height: c.type == "SingleStackedBarChart" ? nil : (c.type == "HorizontalBarChart" ? max(height, CGFloat(labels.count) * 32 + 40) : height))
        .font(DS.Typography.uiCaption)
        .modifier(AxisLabels(x: c.string("xLabel"), y: c.string("yLabel")))
        .padding(.top, DS.Spacing.xs)
    }

    /// Axis titles only when the program gives them (an empty one still takes room).
    private struct AxisLabels: ViewModifier {
        var x: String?
        var y: String?

        func body(content: Content) -> some View {
            switch (x, y) {
            case let (x?, y?): content.chartXAxisLabel(x).chartYAxisLabel(y)
            case let (x?, nil): content.chartXAxisLabel(x)
            case let (nil, y?): content.chartYAxisLabel(y)
            case (nil, nil): content
            }
        }
    }

    private func seriesNames(_ points: [Point]) -> [String] {
        var names: [String] = []
        for p in points where !names.contains(p.series) { names.append(p.series) }
        return names
    }

    private func colors(_ count: Int) -> [Color] {
        let palette = Self.palette(theme)
        return (0..<max(count, 1)).map { palette[$0 % palette.count] }
    }

    @ViewBuilder private func bars(_ points: [Point], stacked: Bool, horizontal: Bool) -> some View {
        let names = seriesNames(points)
        let grouped = names.count > 1 && !stacked
        Chart(points) { p in
            if horizontal {
                if grouped {
                    BarMark(x: .value("Value", p.value), y: .value("Label", p.label))
                        .foregroundStyle(by: .value("Series", p.series))
                        .position(by: .value("Series", p.series))
                        .cornerRadius(3)
                } else {
                    BarMark(x: .value("Value", p.value), y: .value("Label", p.label))
                        .foregroundStyle(by: .value("Series", p.series))
                        .cornerRadius(3)
                }
            } else if grouped {
                BarMark(x: .value("Label", p.label), y: .value("Value", p.value))
                    .foregroundStyle(by: .value("Series", p.series))
                    .position(by: .value("Series", p.series))
                    .cornerRadius(3)
            } else {
                BarMark(x: .value("Label", p.label), y: .value("Value", p.value))
                    .foregroundStyle(by: .value("Series", p.series))
                    .cornerRadius(3)
            }
        }
        .chartForegroundStyleScale(domain: names, range: colors(names.count))
        .chartLegend(names.count > 1 ? .visible : .hidden)
    }

    @ViewBuilder private func lines(_ points: [Point], area: Bool) -> some View {
        let names = seriesNames(points)
        let interpolation: InterpolationMethod = switch component.string("variant") {
        case "natural": .catmullRom
        case "step": .stepCenter
        default: .linear
        }
        Chart(points) { p in
            if area {
                AreaMark(x: .value("Label", p.label), y: .value("Value", p.value), stacking: names.count > 1 ? .standard : .unstacked)
                    .foregroundStyle(by: .value("Series", p.series))
                    .interpolationMethod(interpolation)
                    .opacity(0.35)
            }
            LineMark(x: .value("Label", p.label), y: .value("Value", p.value))
                .foregroundStyle(by: .value("Series", p.series))
                .interpolationMethod(interpolation)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            if !area && labels.count <= 16 {
                PointMark(x: .value("Label", p.label), y: .value("Value", p.value))
                    .foregroundStyle(by: .value("Series", p.series))
                    .symbolSize(24)
            }
        }
        .chartForegroundStyleScale(domain: names, range: colors(names.count))
        .chartLegend(names.count > 1 ? .visible : .hidden)
    }

    @ViewBuilder private func pie(_ points: [Point], donut: Bool) -> some View {
        let names = points.map(\.label)
        Chart(points) { p in
            SectorMark(angle: .value("Value", max(0, p.value)), innerRadius: .ratio(donut ? 0.58 : 0), angularInset: 1.5)
                .cornerRadius(3)
                .foregroundStyle(by: .value("Label", p.label))
        }
        .chartForegroundStyleScale(domain: names, range: colors(names.count))
        .chartLegend(position: .trailing, alignment: .center, spacing: DS.Spacing.lg)
    }

    @ViewBuilder private func stackedBar(_ points: [Point]) -> some View {
        let names = points.map(\.label)
        Chart(points) { p in
            BarMark(x: .value("Value", p.value))
                .foregroundStyle(by: .value("Label", p.label))
        }
        .chartForegroundStyleScale(domain: names, range: colors(names.count))
        .chartXAxis(.hidden)
        .frame(height: 64)
    }

    @ViewBuilder private var scatter: some View {
        let points = component.components("datasets").enumerated().flatMap { s, set in
            set.components("points").enumerated().map { i, point in
                Point(id: s * 10_000 + i, label: "", series: set.string("name") ?? "Set \(s + 1)",
                      value: point.number("y") ?? 0, x: point.number("x") ?? 0)
            }
        }
        let names = seriesNames(points)
        Chart(points) { p in
            PointMark(x: .value("X", p.x), y: .value("Y", p.value))
                .foregroundStyle(by: .value("Series", p.series))
        }
        .chartForegroundStyleScale(domain: names, range: colors(names.count))
        .chartLegend(names.count > 1 ? .visible : .hidden)
    }
}
