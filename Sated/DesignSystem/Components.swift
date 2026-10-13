import SwiftUI

/// A ring that fills with progress, like the Activity rings. Draws in `color`, or the tint.
struct ProgressRing<Label: View>: View {
    var progress: Double
    var lineWidth: CGFloat = 10
    var color: Color?
    @ViewBuilder var label: () -> Label

    var body: some View {
        let fill = color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.tint)
        ZStack {
            Circle()
                .stroke(fill.opacity(0.2), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(fill, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            label()
        }
        .animation(.smooth, value: progress)
    }
}

extension ProgressRing where Label == EmptyView {
    init(progress: Double, lineWidth: CGFloat = 10, color: Color? = nil) {
        self.init(progress: progress, lineWidth: lineWidth, color: color, label: { EmptyView() })
    }
}

/// A card container used on Today, Trends and food details.
struct Card<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
    }
}

/// A rounded tinted square holding an SF Symbol, used in lists.
struct SymbolTile: View {
    var systemName: String
    var size: CGFloat = 34

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.5, weight: .medium))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.tint)
            .frame(width: size, height: size)
            .background(.tint.opacity(0.15), in: .rect(cornerRadius: size * 0.26))
            .accessibilityHidden(true)
    }
}

/// A section heading over a card, in the grouped-list style.
struct SectionHeader<Trailing: View>: View {
    var title: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title2.bold())
            Spacer()
            trailing()
        }
        .padding(.horizontal, 4)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: String) {
        self.init(title: title, trailing: { EmptyView() })
    }
}

/// A macro's ring with its grams inside, and the goal underneath.
struct MacroRingTile: View {
    var macro: Macro
    var value: Double
    var goal: Double

    var body: some View {
        VStack(spacing: 8) {
            ProgressRing(progress: goal > 0 ? value / goal : 0, lineWidth: 7, color: macro.color) {
                Text(Grams.text(value))
                    .font(.subheadline.bold())
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
            }
            .frame(width: 56, height: 56)
            VStack(spacing: 1) {
                Text(macro.name).font(.footnote.weight(.semibold))
                Text("of \(Grams.text(goal)) g")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(macro.name)
        .accessibilityValue("\(Grams.text(value)) of \(Grams.text(goal)) grams")
    }
}

/// A macro row: name, a bar with the goal marked, and grams against the goal.
struct MacroBarRow: View {
    var macro: Macro
    var value: Double
    var goal: Double

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 2).fill(macro.color).frame(width: 8, height: 8)
                Text(macro.name).font(.subheadline)
            }
            .frame(width: 76, alignment: .leading)
            GeometryReader { proxy in
                let scale = max(goal * 1.4, value, 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(macro.color).frame(width: proxy.size.width * value / scale)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(.secondary)
                        .frame(width: 2, height: 14)
                        .offset(x: proxy.size.width * goal / scale - 1)
                }
                .frame(height: 6)
                .frame(maxHeight: .infinity)
            }
            .frame(height: 14)
            Text("\(Grams.text(value))\(Text(" / \(Grams.text(goal)) g").foregroundStyle(.secondary))")
                .font(.subheadline)
                .monospacedDigit()
                .frame(width: 92, alignment: .trailing)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(macro.name)
        .accessibilityValue("\(Grams.text(value)) of \(Grams.text(goal)) grams")
    }
}

/// The small "on-device" capsule shown on Coach and the voice screen.
struct OnDeviceBadge: View {
    var body: some View {
        Label("On-device", systemImage: "lock.fill")
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 12)
            .frame(height: 32)
            .glassEffect(.regular, in: .capsule)
    }
}
