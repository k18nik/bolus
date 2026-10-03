import SwiftUI

enum AppTab: Hashable {
    case today, diary, add, analytics, more
}

struct RootView: View {
    @Environment(DiaryStore.self) private var store
    @Environment(AppLockController.self) private var lock
    @Environment(\.scenePhase) private var scenePhase
    var startupError: String?
    @State private var tab: AppTab = .today
    @State private var showAdd = false
    @State private var addSection: AddSection = .glucose

    private var theme: BolusTheme { BolusTheme.named(store.preferences.themeID) }

    var body: some View {
        ZStack {
            if store.preferences.onboardingCompleted {
                tabs
            } else {
                OnboardingView()
            }
            if lock.isLocked {
                LockView().transition(.opacity)
            } else if scenePhase != .active && store.preferences.appLockEnabled {
                // Hides diary content in the app switcher.
                theme.background.ignoresSafeArea().overlay(Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(theme.accent))
            }
        }
        .environment(\.theme, theme)
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .tint(theme.accent)
    }

    private var tabSelection: Binding<AppTab> {
        Binding(get: { tab }, set: { value in
            if value == .add {
                addSection = .glucose
                showAdd = true
            } else {
                tab = value
            }
        })
    }

    private var tabs: some View {
        TabView(selection: tabSelection) {
            NavigationStack { TodayView(onAdd: openAdd(_:), startupError: startupError) }
                .tabItem { Label("Сегодня", systemImage: "house") }
                .tag(AppTab.today)
            NavigationStack { DiaryView(onAdd: { openAdd(.glucose) }) }
                .tabItem { Label("Дневник", systemImage: "book") }
                .tag(AppTab.diary)
            Color.clear
                .tabItem { Label("Добавить", systemImage: "plus.circle.fill") }
                .tag(AppTab.add)
            NavigationStack { AnalyticsView() }
                .tabItem { Label("Аналитика", systemImage: "chart.xyaxis.line") }
                .tag(AppTab.analytics)
            NavigationStack { MoreView() }
                .tabItem { Label("Ещё", systemImage: "square.grid.2x2") }
                .tag(AppTab.more)
        }
        .sheet(isPresented: $showAdd) {
            NavigationStack { AddEntryView(initialSection: addSection) }
                .environment(\.theme, theme)
        }
    }

    private func openAdd(_ section: AddSection) {
        addSection = section
        showAdd = true
    }
}

/// All sections that do not fit into the tab bar.
struct MoreView: View {
    @Environment(\.theme) private var theme

    var body: some View {
        List {
            Section {
                NavigationLink { BolusView() } label: { Label("Болюс", systemImage: "function") }
                NavigationLink { FoodView() } label: { Label("Еда", systemImage: "fork.knife") }
                NavigationLink { CycleView() } label: { Label("Цикл", systemImage: "moon") }
                NavigationLink { AIView() } label: { Label("AI-ассистент", systemImage: "sparkles") }
                NavigationLink { ReportsView() } label: { Label("Отчёты и экспорт", systemImage: "square.and.arrow.down") }
            }
            Section {
                NavigationLink { ProfileView() } label: { Label("Профиль терапии", systemImage: "cross.case") }
                NavigationLink { HealthSyncView() } label: { Label("Apple «Здоровье»", systemImage: "heart") }
                NavigationLink { SettingsView() } label: { Label("Настройки", systemImage: "gearshape") }
            }
            Section {
                Label("Данные хранятся только на этом iPhone", systemImage: "lock.shield")
                    .font(.footnote)
                    .foregroundStyle(theme.muted)
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.background.ignoresSafeArea())
        .navigationTitle("Ещё")
    }
}

struct LockView: View {
    @Environment(AppLockController.self) private var lock
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "lock.shield").font(.system(size: 54)).foregroundStyle(theme.accent)
            Text("bolus.").font(.largeTitle.weight(.bold)).foregroundStyle(theme.text)
            Text("Дневник защищён. Используйте \(AppLockController.biometryName).")
                .font(.subheadline).foregroundStyle(theme.muted).multilineTextAlignment(.center)
            if let message = lock.message { Notice(text: message, style: .error) }
            Button { Task { await lock.unlock() } } label: { Label("Открыть дневник", systemImage: "faceid") }
                .buttonStyle(PrimaryButtonStyle())
            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background.ignoresSafeArea())
        .task { await lock.unlock() }
    }
}
