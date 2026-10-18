import SwiftUI

struct ContentView: View {
    let store: UsageStore

    @State private var selectedProviderID: ProviderUsage.ID?

    var body: some View {
        VStack(spacing: 8.5) {
            HStack(alignment: .top, spacing: 8.5) {
                ForEach(store.providers) { provider in
                    ProviderSummaryCard(
                        provider: provider,
                        isSelected: selectedProviderID == provider.id
                    ) {
                        withAnimation(.smooth(duration: 0.28)) {
                            selectedProviderID = selectedProviderID == provider.id
                                ? nil
                                : provider.id
                        }
                    }
                }
            }

            if let selectedProviderID {
                ForEach(store.providers) { provider in
                    if provider.id == selectedProviderID {
                        ProviderDetails(provider: provider)
                            .transition(
                                .asymmetric(
                                    insertion: .opacity.combined(
                                        with: .scale(scale: 0.985, anchor: .top)
                                    ),
                                    removal: .opacity
                                )
                            )
                    }
                }
            }
        }
        .padding(10)
        .frame(width: 374)
        .background(.regularMaterial)
        .task {
            await store.refreshIfStale()
        }
    }
}

private struct ProviderSummaryCard: View {
    let provider: ProviderUsage
    let isSelected: Bool
    let action: () -> Void

    private var color: Color {
        switch provider.tint {
        case .gray:
            .gray
        case .orange:
            .orange
        case .blue:
            .blue
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8.5) {
                HStack(spacing: 6) {
                    Image(systemName: provider.symbolName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(color)
                        .frame(width: 21, height: 21)
                        .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))

                    Text(provider.name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isSelected ? 180 : 0))
                }

                AlwaysVisibleLimits(
                    session: provider.sessionLimit,
                    weekly: provider.weeklyLimit,
                    color: color
                )
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(9)
            .background(color.opacity(isSelected ? 0.15 : 0.09), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(color.opacity(isSelected ? 0.55 : 0.16), lineWidth: isSelected ? 1 : 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(isSelected ? "Ocultar" : "Mostrar") detalhes de \(provider.name)")
    }
}

private struct AlwaysVisibleLimits: View {
    let session: UsageLimit?
    let weekly: UsageLimit?
    let color: Color

    var body: some View {
        VStack(spacing: 5) {
            PercentageLine(
                title: "Sessão",
                remainingPercentage: session?.remainingPercentage,
                color: color
            )

            PercentageLine(
                title: "Semanal",
                remainingPercentage: weekly?.remainingPercentage,
                color: color
            )
        }
    }
}

private struct PercentageLine: View {
    let title: LocalizedStringKey
    let remainingPercentage: Int?
    let color: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Spacer(minLength: 2)

            if let remainingPercentage {
                Text(remainingPercentage, format: .percent.scale(1))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(statusColor(for: remainingPercentage))
            } else {
                Text("—")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func statusColor(for remainingPercentage: Int) -> Color {
        switch remainingPercentage {
        case ...15:
            .red
        case ...35:
            .orange
        default:
            color
        }
    }
}

private struct ProviderDetails: View {
    let provider: ProviderUsage

    @State private var selectedTab: DetailTab = .usage

    private var color: Color {
        switch provider.tint {
        case .gray:
            .gray
        case .orange:
            .orange
        case .blue:
            .blue
        }
    }

    var body: some View {
        VStack(spacing: 9) {
            HStack {
                Text(provider.name)
                    .font(.caption.weight(.semibold))

                Spacer()

                Label(provider.sessionState.label, systemImage: "circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.monochrome)
            }

            if let reason = provider.unavailableReason {
                UnavailableProviderMessage(reason: reason, color: color)
            } else {
                DetailTabSelector(
                    selectedTab: $selectedTab,
                    hasModelLimits: !provider.modelLimits.isEmpty,
                    color: color
                )

                if selectedTab == .usage {
                    ForEach([provider.sessionLimit, provider.weeklyLimit].compactMap(\.self)) { limit in
                        DetailedLimitRow(limit: limit, color: color)
                    }
                } else {
                    ForEach(provider.modelLimits) { limit in
                        DetailedLimitRow(limit: limit, color: color)
                    }
                }
            }
        }
        .padding(10)
        .background(.background.opacity(0.62), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(color.opacity(0.2), lineWidth: 0.5)
        }
    }
}

private struct UnavailableProviderMessage: View {
    let reason: String
    let color: Color

    var body: some View {
        Label {
            Text(reason)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(color)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
    }
}

private enum DetailTab: Equatable {
    case usage
    case models
}

private struct DetailTabSelector: View {
    @Binding var selectedTab: DetailTab

    let hasModelLimits: Bool
    let color: Color

    var body: some View {
        HStack(spacing: 3) {
            DetailTabButton(
                title: "Uso",
                systemImage: "gauge.with.dots.needle.50percent",
                isSelected: selectedTab == .usage,
                color: color
            ) {
                selectedTab = .usage
            }

            DetailTabButton(
                title: "Modelos",
                systemImage: "cpu",
                isSelected: selectedTab == .models,
                color: color
            ) {
                selectedTab = .models
            }
            .disabled(!hasModelLimits)
            .opacity(hasModelLimits ? 1 : 0.45)
        }
        .padding(2.5)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
    }
}

private struct DetailTabButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let isSelected: Bool
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .foregroundStyle(isSelected ? color : .secondary)
                .background(
                    isSelected ? color.opacity(0.14) : .clear,
                    in: RoundedRectangle(cornerRadius: 5)
                )
        }
        .buttonStyle(.plain)
    }
}

private struct DetailedLimitRow: View {
    let limit: UsageLimit
    let color: Color

    var body: some View {
        VStack(spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(limit.name)
                        .font(.caption.weight(.medium))

                    if let detail = limit.detail {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                Text("\(limit.remainingPercentage)% disponível")
                    .font(.caption.monospacedDigit().weight(.semibold))
            }

            ProgressView(value: limit.fraction)
                .tint(progressColor)

            HStack {
                Text("\(limit.usedPercentage)% usado")
                    .foregroundStyle(.secondary)

                Spacer()

                if let resetsAt = limit.resetsAt {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        ResetTime(resetsAt: resetsAt, now: context.date)
                    }
                } else if limit.usedPercentage == 0 {
                    // An untouched window has no renewal yet; that is not an error.
                    Text("Cota cheia")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Renovação indisponível")
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.caption2)
        }
        .accessibilityElement(children: .combine)
    }

    private var progressColor: Color {
        switch limit.remainingPercentage {
        case ...15:
            .red
        case ...35:
            .orange
        default:
            color
        }
    }
}

private struct ResetTime: View {
    let resetsAt: Date
    let now: Date

    var body: some View {
        let remaining = max(resetsAt.timeIntervalSince(now), 0)

        Label {
            Text(remaining == 0 ? "Renovando" : "Renova em \(durationText(for: remaining))")
        } icon: {
            Image(systemName: "clock")
        }
        .foregroundStyle(.secondary)
    }

    private func durationText(for interval: TimeInterval) -> String {
        let totalMinutes = Int(interval / 60)
        let days = totalMinutes / 1_440
        let hours = (totalMinutes % 1_440) / 60
        let minutes = totalMinutes % 60

        if days > 0 {
            return "\(days)d \(hours)h"
        }

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }

        return "\(minutes)m"
    }
}

#Preview {
    ContentView(store: UsageStore(providers: ProviderUsage.previewData, collectors: []))
}
