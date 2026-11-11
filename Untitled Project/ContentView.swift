import SwiftUI

enum MenuTab: String, CaseIterable, Identifiable {
    case quotas = "Cotas"
    case sessions = "Sessões"
    case friday = "Friday"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .quotas:
            "gauge.with.dots.needle.33percent"
        case .sessions:
            "bubble.left.and.bubble.right.fill"
        case .friday:
            "bolt.shield.fill"
        }
    }
}

struct ContentView: View {
    let store: UsageStore

    @State private var selectedTab: MenuTab
    @State private var selectedProviderID: ProviderUsage.ID?

    init(
        store: UsageStore,
        selectedTab: MenuTab = .quotas,
        selectedProviderID: ProviderUsage.ID? = nil
    ) {
        self.store = store
        self._selectedTab = State(initialValue: selectedTab)
        self._selectedProviderID = State(initialValue: selectedProviderID)
    }

    var body: some View {
        VStack(spacing: 8.5) {
            MenuTabBar(
                selectedTab: $selectedTab,
                activeSessionCount: store.activeConversations.count,
                attentionCount: store.fridaySnapshot.attentionCount
            )

            switch selectedTab {
            case .quotas:
                QuotasTabContent(
                    store: store,
                    selectedProviderID: $selectedProviderID,
                    onOpenFridayTab: {
                        withAnimation(.smooth(duration: 0.22)) {
                            selectedTab = .friday
                        }
                    }
                )
            case .sessions:
                SessionsTabContent(
                    conversations: store.activeConversations,
                    dailyUsage: store.fridaySnapshot.dailyUsage
                )
            case .friday:
                FridayTabContent(snapshot: store.fridaySnapshot)
            }

            Divider()
                .opacity(0.4)

            HStack {
                Button {
                    Task {
                        await store.refresh()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(store.isRefreshing ? 360 : 0))
                            .animation(
                                store.isRefreshing
                                    ? .linear(duration: 1).repeatForever(autoreverses: false)
                                    : .default,
                                value: store.isRefreshing
                            )
                        Text(store.isRefreshing ? "Atualizando…" : "Atualizar")
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(store.isRefreshing)

                Spacer()

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "power")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Encerrar")
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 2)
        }
        .padding(10)
        .frame(width: 374)
        .background(.regularMaterial)
        .task {
            await store.refreshIfStale()
        }
    }
}

// MARK: - Top Tab Bar

private struct MenuTabBar: View {
    @Binding var selectedTab: MenuTab
    let activeSessionCount: Int
    let attentionCount: Int

    var body: some View {
        HStack(spacing: 5) {
            ForEach(MenuTab.allCases) { tab in
                let isSelected = selectedTab == tab
                Button {
                    withAnimation(.smooth(duration: 0.22)) {
                        selectedTab = tab
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 10, weight: .semibold))

                        Text(tab.rawValue)
                            .font(.caption.weight(.semibold))

                        if tab == .sessions, activeSessionCount > 0 {
                            Text("\(activeSessionCount)")
                                .font(.system(size: 9.5, weight: .bold).monospacedDigit())
                                .padding(.horizontal, 4.5)
                                .padding(.vertical, 1)
                                .background(Color.primary.opacity(0.12), in: Capsule())
                        }

                        if tab == .friday, attentionCount > 0 {
                            Text("\(attentionCount)")
                                .font(.system(size: 9.5, weight: .bold).monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4.5)
                                .padding(.vertical, 1)
                                .background(Color.orange, in: Capsule())
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5.5)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .background(
                        isSelected ? Color.primary.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
    }
}

// MARK: - Tab 1: Quotas

private struct QuotasTabContent: View {
    let store: UsageStore
    @Binding var selectedProviderID: ProviderUsage.ID?
    let onOpenFridayTab: () -> Void

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

            if !store.fridaySnapshot.waitingItems.isEmpty {
                CompactWaitingBanner(
                    items: store.fridaySnapshot.waitingItems,
                    onTap: onOpenFridayTab
                )
            }

            ActiveConversationsSection(conversations: store.activeConversations)
        }
    }
}

private struct CompactWaitingBanner: View {
    let items: [FridayWaitingItem]
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 7) {
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)

                if let first = items.first {
                    Text("\(first.who): \(first.summary.lowercased())")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if items.count > 1 {
                    Text("+\(items.count - 1)")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.orange)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6.5)
            .background(Color.orange.opacity(0.11), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.orange.opacity(0.35), lineWidth: 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Tab 2: Sessions (Active Context + Friday Daily Usage)

private struct SessionsTabContent: View {
    let conversations: [ActiveConversation]
    let dailyUsage: FridayDailyUsage

    var body: some View {
        VStack(spacing: 8.5) {
            ActiveConversationsSection(conversations: conversations)
            DailyUsageSection(dailyUsage: dailyUsage)
        }
    }
}

private struct DailyUsageSection: View {
    let dailyUsage: FridayDailyUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Consumo do Dia")
                    .font(.caption.weight(.semibold))

                if !dailyUsage.day.isEmpty {
                    Text("· \(dailyUsage.day)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                if let cost = dailyUsage.totalCostUSD, cost > 0 {
                    Text(String(format: "US$ %.2f (Claude)", cost))
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }

            if dailyUsage.projects.isEmpty {
                Text("Nenhum gasto de tokens registrado pelo friday-usage ainda.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
            } else {
                HStack(spacing: 6) {
                    TokenMetricPill(title: "Total", tokens: dailyUsage.totalTokens, emphasize: true)
                    TokenMetricPill(title: "Novo", tokens: dailyUsage.novo, emphasize: false)
                    TokenMetricPill(title: "Cache lido", tokens: dailyUsage.cacheLido, emphasize: false)
                    TokenMetricPill(title: "Saída", tokens: dailyUsage.saida, emphasize: false)
                }

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 6.5) {
                        ForEach(dailyUsage.projects.prefix(6)) { project in
                            ProjectUsageCard(project: project)
                        }
                    }
                }
                .frame(maxHeight: 210)
            }
        }
        .padding(10)
        .background(.background.opacity(0.62), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
        }
    }
}

private struct TokenMetricPill: View {
    let title: String
    let tokens: Int
    let emphasize: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1.5) {
            Text(title)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(ActiveConversation.formatTokens(tokens))
                .font(.caption2.monospacedDigit().weight(emphasize ? .bold : .semibold))
                .foregroundStyle(emphasize ? .primary : .secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6.5)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(emphasize ? 0.09 : 0.045), in: RoundedRectangle(cornerRadius: 6.5))
    }
}

private struct ProjectUsageCard: View {
    let project: FridayProjectUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(project.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)

                Spacer()

                if let cost = project.costUSD, cost > 0 {
                    Text(String(format: "US$ %.2f · ", cost))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }

                Text("\(ActiveConversation.formatTokens(project.totalTokens)) tokens")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.primary)
            }

            ForEach(project.sessions.prefix(4)) { session in
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(session.name)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    Text("\(session.chamadas) cham.")
                        .font(.system(size: 9.5).monospacedDigit())
                        .foregroundStyle(.tertiary)

                    Text(ActiveConversation.formatTokens(session.totalTokens))
                        .font(.caption2.monospacedDigit().weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(7.5)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7.5))
        .overlay {
            RoundedRectangle(cornerRadius: 7.5)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
    }
}

// MARK: - Tab 3: Friday (Waiting, Health & Backup, Scheduled Jobs)

private struct FridayTabContent: View {
    let snapshot: FridaySnapshot

    var body: some View {
        VStack(spacing: 8.5) {
            FridayWaitingSection(
                items: snapshot.waitingItems,
                closedMail: snapshot.closedMail
            )

            FridayHealthAndBackupSection(
                health: snapshot.health,
                backup: snapshot.backup
            )

            FridayScheduledJobsSection(jobs: snapshot.scheduledJobs)
        }
    }
}

private struct FridayWaitingSection: View {
    let items: [FridayWaitingItem]
    let closedMail: [FridayClosedMailItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Esperando Você")
                    .font(.caption.weight(.semibold))

                Spacer()

                Label(
                    items.isEmpty ? "Nada pendente" : "\(items.count) pendência(s)",
                    systemImage: items.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
                )
                .font(.caption2)
                .foregroundStyle(items.isEmpty ? Color.secondary : Color.orange)
            }

            if items.isEmpty {
                Text("Nenhuma sessão travada ou correio parado no momento.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                VStack(spacing: 6) {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(item.who)
                                    .font(.caption.weight(.semibold))

                                Text("· \(item.summary)")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                    .lineLimit(1)

                                Spacer()

                                Text(item.ageText)
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }

                            if let detail = item.detail {
                                Text(detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .padding(7)
                        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 7))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(Color.orange.opacity(0.28), lineWidth: 0.5)
                        }
                    }
                }
            }

            if !closedMail.isEmpty {
                let summary = closedMail
                    .map { "\($0.recipient) (\($0.unreadCount))" }
                    .joined(separator: ", ")
                Text("Correio de sessões fechadas: \(summary)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .background(.background.opacity(0.62), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
        }
    }
}

private struct FridayHealthAndBackupSection: View {
    let health: FridayHealthStatus
    let backup: FridayBackupStatus

    private var healthColor: Color {
        if health.failCount > 0 || health.testPassed == false {
            return .red
        }
        if health.warnCount > 0 {
            return .orange
        }
        return .green
    }

    private var healthSummaryText: String {
        if health.failCount > 0 {
            return "\(health.failCount) falha(s)"
        }
        if health.warnCount > 0 {
            return "\(health.warnCount) aviso(s)"
        }
        return "Tudo em ordem"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7.5) {
            HStack {
                Text("Saúde & Backup")
                    .font(.caption.weight(.semibold))

                Spacer()

                Text(healthSummaryText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(healthColor)
            }

            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Doctor")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                    Text(health.failCount == 0 && health.warnCount == 0 ? "OK" : "\(health.failCount)F / \(health.warnCount)W")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(healthColor)
                    if let age = health.doctorAgeText {
                        Text(age)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6.5)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Suíte de Testes")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                    if let passed = health.testPassed {
                        Text(passed ? "Passou (\(health.testCount))" : "Falhou")
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .foregroundStyle(passed ? .green : .red)
                    } else {
                        Text("—")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if let age = health.testAgeText {
                        Text(age)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6.5)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
            }

            BackupRowView(backup: backup)

            if !health.issues.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(health.issues.prefix(2), id: \.self) { issue in
                        Text("• \(issue)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
        }
        .padding(10)
        .background(.background.opacity(0.62), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
        }
    }
}

private struct BackupRowView: View {
    let backup: FridayBackupStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch backup.state {
            case .running(let percent, let stage, let remaining, let isStalled):
                HStack {
                    Text("Backup no Drive · \(stage)")
                        .font(.caption2.weight(.medium))
                    Spacer()
                    Text(String(format: "%.1f%% · %@", percent, isStalled ? "sem resposta" : remaining))
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(isStalled ? .red : .blue)
                }
                ProgressView(value: min(max(percent / 100, 0), 1))
                    .tint(isStalled ? .red : .blue)

            case .succeeded(let agoText, let addedText, let snapshot):
                HStack(alignment: .firstTextBaseline) {
                    Label("Último backup OK", systemImage: "externaldrive.fill.badge.checkmark")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text([addedText, snapshot.map { "#\($0.prefix(6))" }, agoText].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }

            case .failed(let agoText, let reason):
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Label("Backup falhou", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.red)
                        Spacer()
                        Text(agoText)
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if let reason, !reason.isEmpty {
                        Text(reason)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

            case .neverRun:
                Text("Backup no Drive: ainda não rodou.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(6.5)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
    }
}

private struct FridayScheduledJobsSection: View {
    let jobs: [FridayScheduledJob]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Jobs do Friday")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("\(jobs.count) configurados")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if jobs.isEmpty {
                Text("Nenhum LaunchAgent com.gbz.* encontrado.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                VStack(spacing: 5) {
                    ForEach(jobs) { job in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(color(for: job.state))
                                .frame(width: 6, height: 6)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(job.title)
                                    .font(.caption2.weight(.medium))
                                    .lineLimit(1)
                                Text(job.schedule)
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(.tertiary)
                            }

                            Spacer(minLength: 4)

                            if job.lastRunText != "—" {
                                Text(job.lastRunText)
                                    .font(.system(size: 9.5).monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }

                            Text(label(for: job.state))
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(color(for: job.state))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(color(for: job.state).opacity(0.12), in: Capsule())
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(.background.opacity(0.62), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
        }
    }

    private func label(for state: FridayScheduledJob.JobState) -> String {
        switch state {
        case .running: "rodando"
        case .ok: "ok"
        case .active: "ativo"
        case .failed(let text): text
        case .disabled: "desligado"
        }
    }

    private func color(for state: FridayScheduledJob.JobState) -> Color {
        switch state {
        case .running: .blue
        case .ok: .green
        case .active: .secondary
        case .failed: .red
        case .disabled: .orange
        }
    }
}

// MARK: - Active Conversations Section

private struct ActiveConversationsSection: View {
    let conversations: [ActiveConversation]

    private var countLabel: String {
        switch conversations.count {
        case 0:
            "Nenhuma aberta"
        case 1:
            "1 aberta"
        default:
            "\(conversations.count) abertas"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Conversas Ativas")
                    .font(.caption.weight(.semibold))

                Spacer()

                Label(countLabel, systemImage: "circle.fill")
                    .font(.caption2)
                    .foregroundStyle(conversations.isEmpty ? .tertiary : .secondary)
                    .symbolRenderingMode(.monochrome)
            }

            if conversations.isEmpty {
                Text("Nenhuma sessão ativa do Claude ou Codex no momento.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
            } else {
                VStack(spacing: 8) {
                    ForEach(conversations) { conversation in
                        ActiveConversationRow(conversation: conversation)
                    }
                }
            }
        }
        .padding(10)
        .background(.background.opacity(0.62), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
        }
    }
}

private struct ActiveConversationRow: View {
    let conversation: ActiveConversation

    private var providerColor: Color {
        switch conversation.tint {
        case .gray:
            .gray
        case .orange:
            .orange
        case .blue:
            .blue
        }
    }

    private var statusColor: Color {
        switch conversation.statusLevel {
        case .hardLimit:
            .red
        case .softWarning:
            .orange
        case .normal:
            providerColor
        }
    }

    @ViewBuilder
    private var iconView: some View {
        switch conversation.icon {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 10, weight: .semibold))
        case .asset(let name):
            Image(name)
                .resizable()
                .scaledToFit()
                .frame(width: 11, height: 11)
        }
    }

    var body: some View {
        VStack(spacing: 4.5) {
            HStack(alignment: .center, spacing: 6) {
                iconView
                    .foregroundStyle(providerColor)
                    .frame(width: 18, height: 18)
                    .background(providerColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 4.5))

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(conversation.name)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)

                    Text("· \(conversation.providerName)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Text("\(conversation.formattedTokens) tokens")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(statusColor)
            }

            ProgressView(value: conversation.fractionOfHardLimit)
                .tint(statusColor)

            HStack {
                Text(conversation.statusDetail)
                    .foregroundStyle(conversation.statusLevel == .normal ? .secondary : statusColor)

                Spacer()

                Text("Teto 500 mil")
                    .foregroundStyle(.tertiary)
            }
            .font(.caption2)
        }
        .padding(7.5)
        .background(providerColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(statusColor.opacity(conversation.statusLevel == .normal ? 0.14 : 0.4), lineWidth: 0.5)
        }
        .accessibilityElement(children: .combine)
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

    @ViewBuilder
    private var iconView: some View {
        switch provider.icon {
        case .symbol(let name):
            Image(systemName: name)
                .font(.caption.weight(.semibold))
        case .asset(let name):
            Image(name)
                .resizable()
                .scaledToFit()
                .frame(width: 12.5, height: 12.5)
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8.5) {
                HStack(spacing: 6) {
                    iconView
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

    private var geminiGroups: [GeminiModelGroup] {
        var orderedNames: [String] = []
        var groups: [String: [UsageLimit]] = [:]

        for limit in provider.limits {
            if groups[limit.name] == nil {
                orderedNames.append(limit.name)
            }
            groups[limit.name, default: []].append(limit)
        }

        return orderedNames.map { GeminiModelGroup(name: $0, limits: groups[$0] ?? []) }
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
            } else if provider.id == "gemini" {
                ForEach(geminiGroups) { group in
                    GeminiModelGroupView(group: group, color: color)
                }
            } else {
                ForEach(provider.limits) { limit in
                    DetailedLimitRow(limit: limit, color: color)
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

private struct GeminiModelGroup: Identifiable {
    var id: String { name }
    let name: String
    let limits: [UsageLimit]
}

private struct GeminiModelGroupView: View {
    let group: GeminiModelGroup
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(group.name)
                .font(.caption.weight(.semibold))

            VStack(spacing: 6) {
                ForEach(group.limits) { limit in
                    ModelSubLimitRow(limit: limit, color: color)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(color.opacity(0.14), lineWidth: 0.5)
        }
    }
}

private struct ModelSubLimitRow: View {
    let limit: UsageLimit
    let color: Color

    var body: some View {
        VStack(spacing: 3.5) {
            HStack(alignment: .firstTextBaseline) {
                Text(limit.window == .session ? "Sessão de 5 horas" : "Semanal")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)

                Spacer()

                Text("\(limit.remainingPercentage)% disponível")
                    .font(.caption2.monospacedDigit().weight(.semibold))
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

#Preview("Aba Cotas") {
    ContentView(
        store: UsageStore(
            providers: ProviderUsage.previewData,
            activeConversations: ActiveConversation.previewData,
            fridaySnapshot: .previewData,
            collectors: [],
            conversationCollector: nil,
            fridayCollector: nil
        ),
        selectedTab: .quotas
    )
}

#Preview("Aba Sessões") {
    ContentView(
        store: UsageStore(
            providers: ProviderUsage.previewData,
            activeConversations: ActiveConversation.previewData,
            fridaySnapshot: .previewData,
            collectors: [],
            conversationCollector: nil,
            fridayCollector: nil
        ),
        selectedTab: .sessions
    )
}

#Preview("Aba Friday") {
    ContentView(
        store: UsageStore(
            providers: ProviderUsage.previewData,
            activeConversations: ActiveConversation.previewData,
            fridaySnapshot: .previewData,
            collectors: [],
            conversationCollector: nil,
            fridayCollector: nil
        ),
        selectedTab: .friday
    )
}
