//
//  ContentView.swift
//  Expert
//

import SwiftUI
import Combine
import UserNotifications
import UniformTypeIdentifiers

private enum PracticeReminder {
    static let enabledKey = "practiceReminderEnabled"
    static let inactivityDaysKey = "practiceReminderInactivityDays"
    static let deliveryHourKey = "practiceReminderDeliveryHour"
    static let deliveryMinuteKey = "practiceReminderDeliveryMinute"
    static let soundEnabledKey = "practiceReminderSoundEnabled"
    static let notificationID = "expert.inactivity-reminder"
    static let availableIntervals = [3, 7, 14, 30]

    static func requestPermission() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    static func reschedule(for sessions: [PracticeSession], skills: [Skill]) {
        let center = UNUserNotificationCenter.current()
        let skillNotificationIDs = skills.map { notificationID(for: $0.id) }
        center.removePendingNotificationRequests(withIdentifiers: [notificationID] + skillNotificationIDs)

        let activeSkills = skills.filter { $0.archivedAt == nil }
        guard UserDefaults.standard.bool(forKey: enabledKey), !activeSkills.isEmpty else { return }

        let individuallyRemindedSkills = activeSkills.filter(\.reminderEnabled)
        if !individuallyRemindedSkills.isEmpty {
            for skill in individuallyRemindedSkills {
                schedule(
                    identifier: notificationID(for: skill.id),
                    title: "Time for \(skill.name)",
                    body: "A few focused minutes can keep your progress moving.",
                    mostRecentActivity: sessions.filter { $0.skillID == skill.id }.map(\.startedAt).max() ?? skill.startedAt ?? Date(),
                    inactivityDays: skill.reminderDays,
                    deliveryHour: skill.reminderHour,
                    deliveryMinute: skill.reminderMinute,
                    soundEnabled: UserDefaults.standard.object(forKey: soundEnabledKey) as? Bool ?? true
                )
            }
            return
        }

        let defaults = UserDefaults.standard
        let inactivityDays = defaults.object(forKey: inactivityDaysKey) as? Int ?? 7
        let deliveryHour = defaults.object(forKey: deliveryHourKey) as? Int ?? 10
        let deliveryMinute = defaults.object(forKey: deliveryMinuteKey) as? Int ?? 0
        let soundEnabled = defaults.object(forKey: soundEnabledKey) as? Bool ?? true

        let mostRecentActivity = sessions.map(\.startedAt).max()
            ?? activeSkills.compactMap(\.startedAt).max()
            ?? Date()
        schedule(
            identifier: notificationID,
            title: "Keep your skills moving",
            body: "It has been a while since your last practice session. A few focused minutes can keep your progress going.",
            mostRecentActivity: mostRecentActivity,
            inactivityDays: inactivityDays,
            deliveryHour: deliveryHour,
            deliveryMinute: deliveryMinute,
            soundEnabled: soundEnabled
        )
    }

    private static func schedule(identifier: String, title: String, body: String, mostRecentActivity: Date, inactivityDays: Int, deliveryHour: Int, deliveryMinute: Int, soundEnabled: Bool) {
        let calendar = Calendar.current
        let inactiveDay = calendar.date(byAdding: .day, value: inactivityDays, to: mostRecentActivity) ?? Date()
        let inactiveDate = calendar.date(bySettingHour: deliveryHour, minute: deliveryMinute, second: 0, of: inactiveDay) ?? inactiveDay
        let deliveryDate = max(inactiveDate, calendar.date(byAdding: .minute, value: 1, to: Date()) ?? Date())
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = soundEnabled ? .default : nil
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: deliveryDate)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)))
    }

    private static func notificationID(for skillID: UUID) -> String { "\(notificationID).\(skillID.uuidString)" }

    static func cancel(skillID: UUID) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [notificationID(for: skillID)])
    }

    static func cancel() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [notificationID])
    }
}

private enum AppPalette {
    static let electricBlue = Color(red: 0.23, green: 0.56, blue: 1.00)
    static let aqua = Color(red: 0.18, green: 0.82, blue: 0.79)
    static let violet = Color(red: 0.65, green: 0.42, blue: 1.00)
    static let background = Color(uiColor: .systemBackground)
    static let secondaryBackground = Color(uiColor: .secondarySystemBackground)
    static let primaryText = Color(uiColor: .label)
    static let secondaryText = Color(uiColor: .secondaryLabel)

    static let headingGradient = LinearGradient(
        colors: [electricBlue, aqua, violet],
        startPoint: .leading,
        endPoint: .trailing
    )
}

private enum AppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

@MainActor
final class AppNavigation: ObservableObject {
    @Published private(set) var rootID = UUID()

    func returnHome() {
        rootID = UUID()
    }
}

// MARK: - Skill Storage

@MainActor
final class SkillStore: ObservableObject {
    @Published private(set) var skills: [Skill] = []
    @Published private(set) var sessions: [PracticeSession] = []
    @Published private(set) var activeSession: ActivePracticeSession?

    private let defaults: UserDefaults
    private let storageKey = "savedSkills"
    private let sessionsKey = "practiceSessions"
    private let activeSessionKey = "activePracticeSession"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
        PracticeReminder.reschedule(for: sessions, skills: skills)
    }

    func save(_ skill: Skill) {
        guard !skills.contains(where: { $0.id == skill.id }) else { return }
        skills.insert(skill, at: 0)
        persist()
    }

    func addPracticeTime(_ seconds: Int, to skillID: UUID) {
        addSession(to: skillID, duration: seconds, date: Date(), note: "")
    }

    func addSession(to skillID: UUID, duration: Int, date: Date, note: String) {
        guard duration > 0,
              let index = skills.firstIndex(where: { $0.id == skillID }) else { return }
        let session = PracticeSession(
            skillID: skillID,
            startedAt: date,
            durationSeconds: duration,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        sessions.insert(session, at: 0)
        skills[index].totalSeconds += duration
        persist()
    }

    func rename(skillID: UUID, to name: String) {
        guard let index = skills.firstIndex(where: { $0.id == skillID }) else { return }
        skills[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        persist()
    }

    func updatePreferences(skillID: UUID, weeklyGoalSeconds: Int, masteryTargetSeconds: Int, reminderEnabled: Bool, reminderDays: Int, reminderHour: Int, reminderMinute: Int) {
        guard let index = skills.firstIndex(where: { $0.id == skillID }) else { return }
        skills[index].weeklyGoalSeconds = max(0, weeklyGoalSeconds)
        skills[index].masteryTargetSeconds = max(900, masteryTargetSeconds)
        skills[index].reminderEnabled = reminderEnabled
        skills[index].reminderDays = reminderDays
        skills[index].reminderHour = reminderHour
        skills[index].reminderMinute = reminderMinute
        persist()
    }

    func setArchived(_ archived: Bool, skillID: UUID) {
        guard let index = skills.firstIndex(where: { $0.id == skillID }) else { return }
        skills[index].archivedAt = archived ? Date() : nil
        persist()
    }

    func delete(skillID: UUID) {
        PracticeReminder.cancel(skillID: skillID)
        skills.removeAll { $0.id == skillID }
        sessions.removeAll { $0.skillID == skillID }
        if activeSession?.skillID == skillID { activeSession = nil }
        persist()
    }

    func deleteAllData() {
        for skill in skills { PracticeReminder.cancel(skillID: skill.id) }
        skills.removeAll()
        sessions.removeAll()
        activeSession = nil
        persist()
    }

    func sessions(for skillID: UUID) -> [PracticeSession] {
        sessions.filter { $0.skillID == skillID }.sorted { $0.startedAt > $1.startedAt }
    }

    func deleteSession(_ session: PracticeSession) {
        sessions.removeAll { $0.id == session.id }
        if let index = skills.firstIndex(where: { $0.id == session.skillID }) {
            skills[index].totalSeconds = max(0, skills[index].totalSeconds - session.durationSeconds)
        }
        persist()
    }

    func updateSession(_ session: PracticeSession, date: Date, duration: Int, note: String) {
        guard duration > 0,
              let sessionIndex = sessions.firstIndex(where: { $0.id == session.id }),
              let skillIndex = skills.firstIndex(where: { $0.id == session.skillID }) else { return }

        let updatedSession = PracticeSession(
            id: session.id,
            skillID: session.skillID,
            startedAt: date,
            durationSeconds: duration,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        sessions[sessionIndex] = updatedSession
        let durationDifference = duration - session.durationSeconds
        skills[skillIndex].totalSeconds = max(0, skills[skillIndex].totalSeconds + durationDifference)
        persist()
    }

    func beginOrResumeSession(for skillID: UUID) {
        if activeSession?.skillID == skillID { return }
        guard activeSession == nil else { return }
        activeSession = ActivePracticeSession(skillID: skillID)
        persist()
    }

    func togglePause() {
        guard var activeSession else { return }
        if activeSession.isPaused {
            activeSession.resume()
        } else {
            activeSession.pause()
        }
        self.activeSession = activeSession
        persist()
    }

    func pauseActiveSession() {
        guard var activeSession, !activeSession.isPaused else { return }
        activeSession.pause()
        self.activeSession = activeSession
        persist()
    }

    @discardableResult
    func finishActiveSession(note: String = "") -> PracticeSession? {
        guard let activeSession else { return nil }
        let duration = max(1, activeSession.elapsedSeconds)
        let session = PracticeSession(
            skillID: activeSession.skillID,
            startedAt: activeSession.originalStartedAt,
            durationSeconds: duration,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard let index = skills.firstIndex(where: { $0.id == activeSession.skillID }) else { return nil }
        sessions.insert(session, at: 0)
        skills[index].totalSeconds += duration
        self.activeSession = nil
        persist()
        return session
    }

    func cancelActiveSession() {
        activeSession = nil
        persist()
    }

    var backup: ExpertBackup {
        ExpertBackup(exportedAt: Date(), skills: skills, sessions: sessions)
    }

    func restore(_ backup: ExpertBackup) {
        for skill in skills { PracticeReminder.cancel(skillID: skill.id) }
        skills = backup.skills
        sessions = backup.sessions
        activeSession = nil
        persist()
    }

    private func load() {
        guard let data = defaults.data(forKey: storageKey),
              let savedSkills = try? JSONDecoder().decode([Skill].self, from: data) else {
            return
        }
        skills = savedSkills
        if let sessionsData = defaults.data(forKey: sessionsKey),
           let savedSessions = try? JSONDecoder().decode([PracticeSession].self, from: sessionsData) {
            sessions = savedSessions
        }
        if let activeData = defaults.data(forKey: activeSessionKey) {
            activeSession = try? JSONDecoder().decode(ActivePracticeSession.self, from: activeData)
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(skills) else { return }
        defaults.set(data, forKey: storageKey)
        if let sessionsData = try? JSONEncoder().encode(sessions) {
            defaults.set(sessionsData, forKey: sessionsKey)
        }
        if let activeSession,
           let activeData = try? JSONEncoder().encode(activeSession) {
            defaults.set(activeData, forKey: activeSessionKey)
        } else {
            defaults.removeObject(forKey: activeSessionKey)
        }
        PracticeReminder.reschedule(for: sessions, skills: skills)
    }
}

// MARK: - ContentView

/// App entry view used by `ExpertApp`.
///
/// This wraps `HomeView` so the default Xcode template (which expects `ContentView`) compiles.
struct ContentView: View {
    @EnvironmentObject private var appNavigation: AppNavigation
    @AppStorage("appearancePreference") private var appearanceRawValue = AppearancePreference.system.rawValue

    var body: some View {
        NavigationStack {
            HomeView()
        }
        .id(appNavigation.rootID)
        .preferredColorScheme(appearance.colorScheme)
    }

    private var appearance: AppearancePreference {
        AppearancePreference(rawValue: appearanceRawValue) ?? .system
    }
}

// MARK: - HomeView

struct HomeView: View {

    @State private var isPulsing: Bool = false
    @EnvironmentObject private var skillStore: SkillStore

    var body: some View {
        ZStack {
            AppPalette.background
                .ignoresSafeArea()

            VStack(spacing: 0) {

                // TOP THIRD — NEW SKILL
                VStack(spacing: 8) {
                    Text("New Skill")
                        .font(.custom("Menlo", size: 18).weight(.semibold))
                        .foregroundStyle(AppPalette.headingGradient)

                    Text("Start tracking something new")
                        .font(.custom("Menlo", size: 13))
                        .foregroundStyle(AppPalette.primaryText.opacity(0.55))

                    NavigationLink {
                        NewSkillNameView()
                    } label: {
                        PlusActionButton(isPulsing: $isPulsing)
                    }
                }
                .frame(maxHeight: .infinity)

                Divider().background(AppPalette.primaryText.opacity(0.15))

                // MIDDLE THIRD — PREVIOUS SKILL
                NavigationLink {
                    PreviousSkillsView()
                } label: {
                    VStack(spacing: 8) {
                        Text("My Skills")
                            .font(.custom("Menlo", size: 18).weight(.medium))
                            .foregroundStyle(AppPalette.headingGradient)

                        Text(skillStore.skills.isEmpty
                             ? "No saved skills yet"
                             : "\(skillStore.skills.count) saved")
                            .font(.custom("Menlo", size: 13))
                            .foregroundStyle(AppPalette.primaryText.opacity(0.55))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())

                Divider().background(AppPalette.primaryText.opacity(0.15))

                // BOTTOM THIRD — SKILL SUMMARY
                NavigationLink {
                    SkillSummaryView()
                } label: {
                    VStack(spacing: 8) {
                        Text("Skill Summary")
                            .font(.custom("Menlo", size: 18).weight(.medium))
                            .foregroundStyle(AppPalette.headingGradient)
                        Text("Progress, practice time, and milestones")
                            .font(.custom("Menlo", size: 13))
                            .foregroundStyle(AppPalette.primaryText.opacity(0.55))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())

                Divider().background(AppPalette.primaryText.opacity(0.15))

                // BOTTOM SECTION — SETTINGS
                NavigationLink {
                    AboutPrivacyView()
                } label: {
                    VStack(spacing: 8) {
                        Text("Settings")
                            .font(.custom("Menlo", size: 18).weight(.medium))
                            .foregroundStyle(AppPalette.headingGradient)
                        Text("About, privacy, and data")
                            .font(.custom("Menlo", size: 13))
                            .foregroundStyle(AppPalette.primaryText.opacity(0.55))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
            }
        }
        .onAppear {
            isPulsing = true
        }
    }
}

// MARK: - About & Privacy

private struct AboutPrivacyView: View {
    @EnvironmentObject private var skillStore: SkillStore
    @Environment(\.openURL) private var openURL
    @State private var isConfirmingDelete = false
    @State private var linkErrorMessage: String?
    @AppStorage("appearancePreference") private var appearanceRawValue = AppearancePreference.system.rawValue
    @AppStorage(PracticeReminder.enabledKey) private var practiceReminderEnabled = false
    @AppStorage(PracticeReminder.inactivityDaysKey) private var reminderInactivityDays = 7
    @AppStorage(PracticeReminder.deliveryHourKey) private var reminderDeliveryHour = 10
    @AppStorage(PracticeReminder.deliveryMinuteKey) private var reminderDeliveryMinute = 0
    @AppStorage(PracticeReminder.soundEnabledKey) private var reminderSoundEnabled = true
    @State private var notificationPermissionDenied = false
    @State private var isExportingBackup = false
    @State private var isImportingBackup = false
    @State private var pendingBackup: ExpertBackup?
    @State private var backupErrorMessage: String?

    private var settingsContent: some View {
        ZStack {
            AppPalette.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Expert")
                            .font(.custom("Menlo", size: 30).weight(.bold))
                            .foregroundStyle(AppPalette.headingGradient)
                        Text("Build mastery one focused session at a time.")
                            .foregroundStyle(AppPalette.primaryText.opacity(0.65))
                    }

                    AboutCard(title: "Privacy", systemImage: "hand.raised.fill") {
                        Text("Expert stores your skill names, practice notes, session dates, and durations locally on this device. The current version does not create accounts, show advertising, use analytics, sell personal information, or transmit your practice data to us or third parties.")
                        Text("Your information may be included in device backups according to your Apple backup settings. You can remove all Expert data using the button below, or by deleting the app.")
                        Button {
                            openExternalPage(
                                "https://nadolabs-apps.github.io/expert-support/",
                                name: "privacy policy"
                            )
                        } label: {
                            Label("Read Full Privacy Policy", systemImage: "arrow.up.right.square")
                        }
                        .buttonStyle(.plain)
                    }

                    AboutCard(title: "Appearance", systemImage: "circle.lefthalf.filled") {
                        Picker("Appearance", selection: $appearanceRawValue) {
                            ForEach(AppearancePreference.allCases) { appearance in
                                Text(appearance.title).tag(appearance.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    PracticeReminderCard(
                        isEnabled: $practiceReminderEnabled,
                        inactivityDays: $reminderInactivityDays,
                        deliveryHour: $reminderDeliveryHour,
                        deliveryMinute: $reminderDeliveryMinute,
                        soundEnabled: $reminderSoundEnabled
                    )

                    DataManagementCard(
                        isExporting: $isExportingBackup,
                        isImporting: $isImportingBackup,
                        isConfirmingDelete: $isConfirmingDelete
                    )

                    AboutCard(title: "App Information", systemImage: "info.circle.fill") {
                        HStack {
                            Text("Version")
                            Spacer()
                            Text(appVersion)
                                .foregroundStyle(AppPalette.primaryText.opacity(0.6))
                        }
                        Button {
                            openExternalPage(
                                "https://nadolabs-apps.github.io/expert-support/support.html",
                                name: "support page"
                            )
                        } label: {
                            Label("Contact Support", systemImage: "questionmark.circle")
                        }
                        .buttonStyle(.plain)
                    }

                    Text("Developed by Nado Labs 2026")
                        .font(.custom("Menlo", size: 11))
                        .foregroundStyle(AppPalette.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 2)

                }
                .padding()
            }
        }
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("About & Privacy")
                    .font(.custom("Menlo", size: 17).weight(.semibold))
                    .foregroundStyle(AppPalette.headingGradient)
            }
        }

    }

    private var basicAlertContent: some View {
        settingsContent
        .alert("Delete all Expert data?", isPresented: $isConfirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Everything", role: .destructive) {
                skillStore.deleteAllData()
            }
        } message: {
            Text("This permanently deletes all skills, sessions, notes, and active timers. This action cannot be undone.")
        }
        .alert(
            "Unable to Open Page",
            isPresented: isShowingLinkError
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(linkErrorMessage ?? "Please try again later.")
        }
        .alert("Notifications Are Off", isPresented: $notificationPermissionDenied) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Allow notifications for Expert in iPhone Settings if you want inactivity reminders.")
        }

    }

    private var alertContent: some View {
        basicAlertContent
        .alert("Replace current data?", isPresented: isShowingRestoreConfirmation) {
            Button("Cancel", role: .cancel) { pendingBackup = nil }
            Button("Restore", role: .destructive) {
                if let pendingBackup { skillStore.restore(pendingBackup) }
                pendingBackup = nil
            }
        } message: {
            Text("Restoring this backup replaces all skills and practice sessions currently on this device.")
        }
        .alert("Backup Error", isPresented: isShowingBackupError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(backupErrorMessage ?? "The backup could not be opened.")
        }

    }

    private var documentContent: some View {
        alertContent
        .fileExporter(
            isPresented: $isExportingBackup,
            document: ExpertBackupDocument(backup: skillStore.backup),
            contentType: .json,
            defaultFilename: "Expert-Backup"
        ) { result in
            if case .failure(let error) = result { backupErrorMessage = error.localizedDescription }
        }
        .fileImporter(isPresented: $isImportingBackup, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                pendingBackup = try JSONDecoder().decode(ExpertBackup.self, from: data)
            } catch {
                backupErrorMessage = "This does not appear to be a valid Expert backup. \(error.localizedDescription)"
            }
        }

    }

    var body: some View {
        documentContent
        .onChange(of: practiceReminderEnabled) { _, isEnabled in
            if isEnabled {
                Task {
                    let allowed = await PracticeReminder.requestPermission()
                    if allowed {
                        PracticeReminder.reschedule(for: skillStore.sessions, skills: skillStore.skills)
                    } else {
                        practiceReminderEnabled = false
                        PracticeReminder.reschedule(for: skillStore.sessions, skills: skillStore.skills)
                        notificationPermissionDenied = true
                    }
                }
            } else {
                PracticeReminder.reschedule(for: skillStore.sessions, skills: skillStore.skills)
            }
        }
        .onChange(of: reminderInactivityDays) { _, _ in rescheduleReminderIfEnabled() }
        .onChange(of: reminderDeliveryHour) { _, _ in rescheduleReminderIfEnabled() }
        .onChange(of: reminderDeliveryMinute) { _, _ in rescheduleReminderIfEnabled() }
        .onChange(of: reminderSoundEnabled) { _, _ in rescheduleReminderIfEnabled() }
    }

    private func rescheduleReminderIfEnabled() {
        guard practiceReminderEnabled else { return }
        PracticeReminder.reschedule(for: skillStore.sessions, skills: skillStore.skills)
    }

    private var isShowingLinkError: Binding<Bool> {
        optionalMessageBinding($linkErrorMessage)
    }

    private var isShowingBackupError: Binding<Bool> {
        optionalMessageBinding($backupErrorMessage)
    }

    private var isShowingRestoreConfirmation: Binding<Bool> {
        Binding(
            get: { pendingBackup != nil },
            set: { if !$0 { pendingBackup = nil } }
        )
    }

    private func optionalMessageBinding(_ message: Binding<String?>) -> Binding<Bool> {
        Binding(
            get: { message.wrappedValue != nil },
            set: { if !$0 { message.wrappedValue = nil } }
        )
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }

    private func openExternalPage(_ address: String, name: String) {
        guard let url = URL(string: address) else {
            linkErrorMessage = "The \(name) address is invalid."
            return
        }

        openURL(url) { accepted in
            if !accepted {
                linkErrorMessage = "iOS could not open the \(name). Check your connection and try again."
            }
        }
    }
}

private struct AboutCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    init(title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: systemImage)
                .font(.custom("Menlo", size: 17).weight(.semibold))
                .foregroundStyle(AppPalette.aqua)
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .font(.custom("Menlo", size: 13))
            .foregroundStyle(AppPalette.primaryText.opacity(0.78))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(AppPalette.primaryText.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(AppPalette.primaryText.opacity(0.1), lineWidth: 1)
        }
    }
}

private struct DataManagementCard: View {
    @Binding var isExporting: Bool
    @Binding var isImporting: Bool
    @Binding var isConfirmingDelete: Bool

    var body: some View {
        AboutCard(title: "Your Data", systemImage: "internaldrive.fill") {
            Text("All learning records are controlled on this device. Deleting all data permanently removes every skill, practice session, note, and paused timer from Expert.")
            Button("Export Backup", systemImage: "square.and.arrow.up") { isExporting = true }
            Button("Restore Backup", systemImage: "square.and.arrow.down") { isImporting = true }
            Text("Export a backup before changing devices or deleting the app. Restoring replaces the records currently on this device.")
                .foregroundStyle(AppPalette.secondaryText)
            Button("Delete All App Data", systemImage: "trash", role: .destructive) {
                isConfirmingDelete = true
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.red.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

private struct PracticeReminderCard: View {
    @Binding var isEnabled: Bool
    @Binding var inactivityDays: Int
    @Binding var deliveryHour: Int
    @Binding var deliveryMinute: Int
    @Binding var soundEnabled: Bool

    var body: some View {
        AboutCard(title: "Practice Reminder", systemImage: "bell.fill") {
            Toggle("Inactivity reminders", isOn: $isEnabled)
            if isEnabled {
                Divider()
                Picker("Remind me after", selection: $inactivityDays) {
                    ForEach(PracticeReminder.availableIntervals, id: \.self) { days in
                        Text(days == 1 ? "1 day" : "\(days) days").tag(days)
                    }
                }
                DatePicker("Preferred time", selection: timeBinding, displayedComponents: .hourAndMinute)
                Toggle("Notification sound", isOn: $soundEnabled)
            }
            Text("Expert sends one gentle reminder after your chosen period without logged practice. Logging time resets the reminder.")
                .foregroundStyle(AppPalette.secondaryText)
        }
    }

    private var timeBinding: Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: deliveryHour, minute: deliveryMinute, second: 0, of: Date()) ?? Date() },
            set: {
                let parts = Calendar.current.dateComponents([.hour, .minute], from: $0)
                deliveryHour = parts.hour ?? 10
                deliveryMinute = parts.minute ?? 0
            }
        )
    }
}

// MARK: - PlusActionButton

private struct PlusActionButton: View {
    // MARK: Constants

    /// You can tweak these to match Option B energy (electric blue / aqua).
    private enum Style {
        static let size: CGFloat = 88
        static let innerSize: CGFloat = 82
        static let cornerRadius: CGFloat = size / 2

        // Option B accents (no strict brand colours yet; these are safe placeholders)
        static let electricBlue: Color = Color(red: 0.23, green: 0.56, blue: 1.00) // ~ #3A8FFF
        static let aqua: Color = Color(red: 0.18, green: 0.82, blue: 0.79)         // ~ #2ED2C9
    }

    // MARK: Inputs

    @Binding var isPulsing: Bool

    // MARK: Body

    var body: some View {
        ZStack {
            // Outer glow ring (animated)
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Style.electricBlue.opacity(isPulsing ? 0.40 : 0.20),
                            Style.electricBlue.opacity(0.00)
                        ],
                        center: .center,
                        startRadius: 6,
                        endRadius: isPulsing ? 78 : 60
                    )
                )
                .frame(width: Style.size * 1.9, height: Style.size * 1.9)
                .scaleEffect(isPulsing ? 1.02 : 0.95)
                .animation(
                    .easeInOut(duration: 1.8).repeatForever(autoreverses: true),
                    value: isPulsing
                )

            // Button face
            Circle()
                .fill(AppPalette.primaryText.opacity(0.06))
                .overlay(
                    Circle()
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Style.electricBlue.opacity(0.95),
                                    Style.aqua.opacity(0.75)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 2
                        )
                )
                .frame(width: Style.size, height: Style.size)
                .shadow(color: Style.electricBlue.opacity(0.35), radius: 14, x: 0, y: 0)
                .shadow(color: Style.aqua.opacity(0.20), radius: 22, x: 0, y: 0)

            // Plus icon
            Image(systemName: "plus")
                .font(.custom("Menlo", size: 30).weight(.semibold))
                .foregroundStyle(AppPalette.primaryText)
                .accessibilityHidden(true)
        }
        .contentShape(Circle())
        .accessibilityLabel("Add a skill")
        .accessibilityHint("Starts the Become Expert workflow to create a new skill to master.")
    }
}

// MARK: - New Skill Flow

struct NewSkillNameView: View {

    @State private var skillName: String = ""
    @State private var isValid: Bool = false
    @State private var createdSkill: Skill?
    @State private var weeklyGoalSeconds = 7_200
    @State private var masteryTargetSeconds = Skill.tenThousandHours
    @EnvironmentObject private var skillStore: SkillStore

    var body: some View {
        ZStack {
            AppPalette.background.ignoresSafeArea()

            VStack(spacing: 20) {
                Text("Name Your Skill")
                    .font(.custom("Menlo", size: 24).weight(.semibold))
                    .foregroundStyle(AppPalette.headingGradient)

                VStack(spacing: 10) {
                    TextField("Enter skill", text: $skillName)
                        .padding()
                        .background(AppPalette.primaryText.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(AppPalette.primaryText)
                        .padding(.horizontal)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .onChange(of: skillName) { _, newValue in
                            validate(name: newValue)
                        }

                    if !isValid && !skillName.isEmpty {
                        Text("Please enter at least 2 characters.")
                            .font(.custom("Menlo", size: 14))
                            .foregroundStyle(.red.opacity(0.8))
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Practice Plan")
                        .font(.custom("Menlo", size: 16).weight(.semibold))
                    Picker("Weekly goal", selection: $weeklyGoalSeconds) {
                        Text("30 minutes").tag(1_800)
                        Text("1 hour").tag(3_600)
                        Text("2 hours").tag(7_200)
                        Text("5 hours").tag(18_000)
                    }
                    Picker("Mastery target", selection: $masteryTargetSeconds) {
                        Text("Build a habit · 100h").tag(360_000)
                        Text("Become proficient · 1,000h").tag(3_600_000)
                        Text("Pursue mastery · 10,000h").tag(Skill.tenThousandHours)
                    }
                }
                .font(.custom("Menlo", size: 14))
                .padding()
                .background(AppPalette.primaryText.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal)

                Spacer()

                Button {
                    let skill = Skill(
                        name: skillName.trimmingCharacters(in: .whitespacesAndNewlines),
                        totalSeconds: 0,
                        startedAt: Date(),
                        weeklyGoalSeconds: weeklyGoalSeconds,
                        masteryTargetSeconds: masteryTargetSeconds
                    )
                    skillStore.save(skill)
                    createdSkill = skill
                } label: {
                    Text("Continue")
                        .font(.custom("Menlo", size: 17).weight(.semibold))
                        .foregroundStyle(AppPalette.background)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(isValid ? AppPalette.primaryText : AppPalette.primaryText.opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal)
                }
                .disabled(!isValid)
                .padding(.bottom, 24)
            }
            .padding(.top, 40)
        }
        .onAppear { validate(name: skillName) }
        .navigationDestination(item: $createdSkill) { skill in
            NewSkillOverviewView(skill: skill)
        }
    }

    private func validate(name: String) {
        isValid = name.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
    }
}

// MARK: - Skill Model + Milestones (lightweight for flow)

nonisolated struct Skill: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    var totalSeconds: Int
    var startedAt: Date?
    var archivedAt: Date?
    var weeklyGoalSeconds: Int
    var masteryTargetSeconds: Int
    var reminderEnabled: Bool
    var reminderDays: Int
    var reminderHour: Int
    var reminderMinute: Int

    init(id: UUID = UUID(), name: String, totalSeconds: Int, startedAt: Date? = Date(), archivedAt: Date? = nil, weeklyGoalSeconds: Int = 7_200, masteryTargetSeconds: Int = 36_000_000, reminderEnabled: Bool = false, reminderDays: Int = 7, reminderHour: Int = 10, reminderMinute: Int = 0) {
        self.id = id
        self.name = name
        self.totalSeconds = totalSeconds
        self.startedAt = startedAt
        self.archivedAt = archivedAt
        self.weeklyGoalSeconds = weeklyGoalSeconds
        self.masteryTargetSeconds = masteryTargetSeconds
        self.reminderEnabled = reminderEnabled
        self.reminderDays = reminderDays
        self.reminderHour = reminderHour
        self.reminderMinute = reminderMinute
    }

    static let tenThousandHours: Int = 10_000 * 3600

    private enum CodingKeys: String, CodingKey {
        case id, name, totalSeconds, startedAt, archivedAt, weeklyGoalSeconds, masteryTargetSeconds
        case reminderEnabled, reminderDays, reminderHour, reminderMinute
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        totalSeconds = try container.decode(Int.self, forKey: .totalSeconds)
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        archivedAt = try container.decodeIfPresent(Date.self, forKey: .archivedAt)
        weeklyGoalSeconds = try container.decodeIfPresent(Int.self, forKey: .weeklyGoalSeconds) ?? 7_200
        masteryTargetSeconds = try container.decodeIfPresent(Int.self, forKey: .masteryTargetSeconds) ?? Self.tenThousandHours
        reminderEnabled = try container.decodeIfPresent(Bool.self, forKey: .reminderEnabled) ?? false
        reminderDays = try container.decodeIfPresent(Int.self, forKey: .reminderDays) ?? 7
        reminderHour = try container.decodeIfPresent(Int.self, forKey: .reminderHour) ?? 10
        reminderMinute = try container.decodeIfPresent(Int.self, forKey: .reminderMinute) ?? 0
    }
}

nonisolated struct ExpertBackup: Codable {
    let exportedAt: Date
    let skills: [Skill]
    let sessions: [PracticeSession]
}

struct ExpertBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var backup: ExpertBackup

    init(backup: ExpertBackup) { self.backup = backup }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        backup = try JSONDecoder().decode(ExpertBackup.self, from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return FileWrapper(regularFileWithContents: try encoder.encode(backup))
    }
}

nonisolated struct PracticeSession: Identifiable, Hashable, Codable {
    let id: UUID
    let skillID: UUID
    let startedAt: Date
    let durationSeconds: Int
    let note: String

    init(id: UUID = UUID(), skillID: UUID, startedAt: Date, durationSeconds: Int, note: String) {
        self.id = id
        self.skillID = skillID
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
        self.note = note
    }
}

extension PracticeSession {
    var formattedDuration: String {
        let hours = durationSeconds / 3600
        let minutes = (durationSeconds % 3600) / 60
        let seconds = durationSeconds % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(seconds)s" }
        return "\(seconds)s"
    }
}

struct ActivePracticeSession: Codable, Hashable {
    let skillID: UUID
    let originalStartedAt: Date
    var runningSince: Date?
    var accumulatedSeconds: Int

    init(skillID: UUID) {
        self.skillID = skillID
        self.originalStartedAt = Date()
        self.runningSince = Date()
        self.accumulatedSeconds = 0
    }

    var isPaused: Bool { runningSince == nil }

    var elapsedSeconds: Int {
        accumulatedSeconds + (runningSince.map { max(0, Int(Date().timeIntervalSince($0))) } ?? 0)
    }

    mutating func pause() {
        guard let runningSince else { return }
        accumulatedSeconds += max(0, Int(Date().timeIntervalSince(runningSince)))
        self.runningSince = nil
    }

    mutating func resume() {
        guard isPaused else { return }
        runningSince = Date()
    }
}

// MARK: - Skill Summary

struct SkillSummaryView: View {
    @EnvironmentObject private var skillStore: SkillStore

    var body: some View {
        ZStack {
            AppPalette.background.ignoresSafeArea()

            if activeSkills.isEmpty {
                ContentUnavailableView(
                    "No Skills Yet",
                    systemImage: "chart.bar",
                    description: Text("Create a skill to begin building your summary.")
                )
                .foregroundStyle(AppPalette.primaryText)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("This Week")
                                .font(.custom("Menlo", size: 18).weight(.semibold))
                            HStack {
                                SummaryMetric(value: formattedWeeklyTime, label: "Practice")
                                Spacer()
                                SummaryMetric(value: "\(weeklySessions.count)", label: "Sessions")
                                Spacer()
                                SummaryMetric(value: mostPracticedSkill, label: "Top Skill")
                            }
                        }
                        .padding(16)
                        .background(AppPalette.primaryText.opacity(0.07))
                        .clipShape(RoundedRectangle(cornerRadius: 14))

                        ForEach(activeSkills) { skill in
                            NavigationLink {
                                SkillSummaryDetailView(skill: skill)
                            } label: {
                                SkillSummaryRow(skill: skill)
                            }
                            .buttonStyle(PressScaleButtonStyle())
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Skill Summary")
                    .font(.custom("Menlo", size: 17).weight(.semibold))
                    .foregroundStyle(AppPalette.headingGradient)
            }
        }
    }

    private var activeSkills: [Skill] {
        skillStore.skills.filter { $0.archivedAt == nil }
    }

    private var weeklySessions: [PracticeSession] {
        guard let week = Calendar.current.dateInterval(of: .weekOfYear, for: Date()) else { return [] }
        return skillStore.sessions.filter { week.contains($0.startedAt) }
    }

    private var formattedWeeklyTime: String {
        let seconds = weeklySessions.reduce(0) { $0 + $1.durationSeconds }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    private var mostPracticedSkill: String {
        let totals = Dictionary(grouping: weeklySessions, by: \.skillID).mapValues { $0.reduce(0) { $0 + $1.durationSeconds } }
        guard let id = totals.max(by: { $0.value < $1.value })?.key else { return "—" }
        return skillStore.skills.first(where: { $0.id == id })?.name ?? "—"
    }
}

private struct SummaryMetric: View {
    let value: String
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.custom("Menlo", size: 14).weight(.semibold)).lineLimit(1)
            Text(label).font(.custom("Menlo", size: 11)).foregroundStyle(AppPalette.secondaryText)
        }
    }
}

private struct SkillSummaryRow: View {
    let skill: Skill

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(skill.name)
                        .font(.custom("Menlo", size: 18).weight(.semibold))
                        .foregroundStyle(AppPalette.primaryText)
                    Text("First Focus • 15 minutes")
                        .font(.custom("Menlo", size: 13))
                        .foregroundStyle(AppPalette.primaryText.opacity(0.55))
                }
                Spacer()
                Text("\(Int(skill.firstLevelProgress * 100))%")
                    .font(.custom("Menlo", size: 15).weight(.semibold))
                    .foregroundStyle(AppPalette.primaryText.opacity(0.8))
                Image(systemName: "chevron.right")
                    .font(.custom("Menlo", size: 12).weight(.semibold))
                    .foregroundStyle(AppPalette.primaryText.opacity(0.4))
            }

            ProgressView(value: skill.firstLevelProgress)
                .tint(Color(red: 0.18, green: 0.82, blue: 0.79))
        }
        .padding(16)
        .background(AppPalette.primaryText.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(AppPalette.primaryText.opacity(0.1), lineWidth: 1)
        }
    }
}

struct SkillSummaryDetailView: View {
    let skill: Skill
    @EnvironmentObject private var skillStore: SkillStore
    @State private var isEditingSessions = false
    @State private var sessionToEdit: PracticeSession?

    var body: some View {
        ZStack {
            AppPalette.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 20) {
                    VStack(spacing: 8) {
                        Text(currentSkill.name)
                            .font(.custom("Menlo", size: 30).weight(.bold))
                            .foregroundStyle(AppPalette.headingGradient)
                        Text("Your learning journey")
                            .foregroundStyle(AppPalette.primaryText.opacity(0.6))

                        Button {
                            withAnimation { isEditingSessions.toggle() }
                        } label: {
                            Label(
                                isEditingSessions ? "Done Editing" : "Edit Logged Time",
                                systemImage: isEditingSessions ? "checkmark.circle.fill" : "pencil"
                            )
                            .font(.custom("Menlo", size: 14).weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AppPalette.electricBlue)
                        .disabled(skillSessions.isEmpty)
                        .opacity(skillSessions.isEmpty ? 0.55 : 1)

                        if skillSessions.isEmpty {
                            Text("There are no saved sessions to edit yet.")
                                .font(.custom("Menlo", size: 12))
                                .foregroundStyle(AppPalette.secondaryText)
                        }
                    }
                    .padding(.top, 20)

                    VStack(spacing: 0) {
                        MetadataRow(
                            icon: "calendar",
                            title: "Started Learning",
                            value: currentSkill.formattedStartDate
                        )
                        Divider().overlay(AppPalette.primaryText.opacity(0.1))
                        MetadataRow(
                            icon: "clock",
                            title: "Total Practice Time",
                            value: currentSkill.formattedTotalTime
                        )
                        Divider().overlay(AppPalette.primaryText.opacity(0.1))
                        MetadataRow(
                            icon: "flag.checkered",
                            title: "Current Level",
                            value: currentSkill.currentLevelDescription
                        )
                        Divider().overlay(AppPalette.primaryText.opacity(0.1))
                        MetadataRow(icon: "number", title: "Sessions", value: "\(skillSessions.count)")
                        Divider().overlay(AppPalette.primaryText.opacity(0.1))
                        MetadataRow(icon: "chart.bar", title: "Average Session", value: averageSessionTime)
                        Divider().overlay(AppPalette.primaryText.opacity(0.1))
                        MetadataRow(icon: "calendar.badge.clock", title: "Last Practiced", value: lastPracticed)
                    }
                    .background(AppPalette.primaryText.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("First Focus Progress")
                            Spacer()
                            Text("\(Int(currentSkill.firstLevelProgress * 100))%")
                        }
                        .font(.custom("Menlo", size: 15).weight(.semibold))
                        .foregroundStyle(AppPalette.primaryText)

                        ProgressView(value: currentSkill.firstLevelProgress)
                            .tint(Color(red: 0.18, green: 0.82, blue: 0.79))

                        Text("\(currentSkill.formattedTotalTime) of 15 minutes")
                            .font(.custom("Menlo", size: 13))
                            .foregroundStyle(AppPalette.primaryText.opacity(0.55))
                    }
                    .padding(16)
                    .background(AppPalette.primaryText.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Mastery Progress")
                            Spacer()
                            Text("\(Int(currentSkill.progress * 100))%")
                        }
                        .font(.custom("Menlo", size: 15).weight(.semibold))
                        .foregroundStyle(AppPalette.primaryText)

                        ProgressView(value: currentSkill.progress)
                            .tint(Color(red: 0.23, green: 0.56, blue: 1.0))
                        Text("Toward \(currentSkill.masteryTargetSeconds / 3600) hours")
                            .font(.custom("Menlo", size: 13))
                            .foregroundStyle(AppPalette.primaryText.opacity(0.55))
                    }
                    .padding(16)
                    .background(AppPalette.primaryText.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                    PracticeActivityView(sessions: skillSessions)

                    if !skillSessions.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Session History")
                                    .font(.custom("Menlo", size: 18).weight(.semibold))
                                    .foregroundStyle(AppPalette.primaryText)
                            }

                            Label(
                                "Log time honestly. Inaccurate entries will make your mastery progression inaccurate.",
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .font(.custom("Menlo", size: 12))
                            .foregroundStyle(.orange)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.orange.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 10))

                            ForEach(skillSessions) { session in
                                SessionRow(
                                    session: session,
                                    isEditing: isEditingSessions,
                                    onEdit: { sessionToEdit = session },
                                    onDelete: { skillStore.deleteSession(session) }
                                )
                            }
                        }
                    }
                }
                .padding()
            }
        }
        .navigationTitle("Summary")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $sessionToEdit) { session in
            EditPracticeSessionView(session: session)
                .environmentObject(skillStore)
        }
    }

    private var skillSessions: [PracticeSession] {
        skillStore.sessions(for: skill.id)
    }

    private var currentSkill: Skill {
        skillStore.skills.first(where: { $0.id == skill.id }) ?? skill
    }

    private var averageSessionTime: String {
        guard !skillSessions.isEmpty else { return "—" }
        let average = skillSessions.reduce(0) { $0 + $1.durationSeconds } / skillSessions.count
        return PracticeSession(skillID: skill.id, startedAt: Date(), durationSeconds: average, note: "").formattedDuration
    }

    private var lastPracticed: String {
        skillSessions.first?.startedAt.formatted(date: .abbreviated, time: .omitted) ?? "Not yet"
    }
}

private struct MetadataRow: View {
    let icon: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundStyle(Color(red: 0.18, green: 0.82, blue: 0.79))
            Text(title)
                .foregroundStyle(AppPalette.primaryText.opacity(0.65))
            Spacer()
            Text(value)
                .fontWeight(.semibold)
                .foregroundStyle(AppPalette.primaryText)
                .multilineTextAlignment(.trailing)
        }
        .padding(16)
    }
}

private struct PracticeActivityView: View {
    let sessions: [PracticeSession]
    private let calendar = Calendar.current
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 5), count: 7)
    private let weekdaySymbols = ["S", "M", "T", "W", "T", "F", "S"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Practice Activity")
                .font(.custom("Menlo", size: 18).weight(.semibold))

            HStack {
                SummaryMetric(value: "\(currentStreak)", label: "Current Streak")
                Spacer()
                SummaryMetric(value: "\(longestStreak)", label: "Longest Streak")
                Spacer()
                SummaryMetric(value: "\(monthPracticeDays)", label: "Days This Month")
            }

            Text(Date().formatted(.dateTime.month(.wide).year()))
                .font(.custom("Menlo", size: 13).weight(.semibold))

            LazyVGrid(columns: columns, spacing: 7) {
                ForEach(weekdaySymbols.indices, id: \.self) { index in
                    Text(weekdaySymbols[index])
                        .font(.custom("Menlo", size: 10))
                        .foregroundStyle(AppPalette.secondaryText)
                }

                ForEach(monthCells.indices, id: \.self) { index in
                    monthCell(for: monthCells[index])
                }
            }
        }
        .padding(16)
        .background(AppPalette.primaryText.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private func monthCell(for date: Date?) -> some View {
        if let date {
            let isPracticeDay = practiceDays.contains(calendar.startOfDay(for: date))
            let fontWeight: Font.Weight = isPracticeDay ? .bold : .regular
            let backgroundColor = isPracticeDay ? AppPalette.aqua.opacity(0.35) : Color.clear

            Text("\(calendar.component(.day, from: date))")
                .font(.custom("Menlo", size: 11).weight(fontWeight))
                .frame(maxWidth: .infinity, minHeight: 28)
                .background(backgroundColor)
                .clipShape(Circle())
        } else {
            Color.clear
                .frame(height: 28)
        }
    }

    private var practiceDays: Set<Date> { Set(sessions.map { calendar.startOfDay(for: $0.startedAt) }) }

    private var monthCells: [Date?] {
        guard let month = calendar.dateInterval(of: .month, for: Date()),
              let days = calendar.range(of: .day, in: .month, for: Date()) else { return [] }
        let leading = calendar.component(.weekday, from: month.start) - 1
        return Array(repeating: nil, count: leading) + days.compactMap { day in
            calendar.date(byAdding: .day, value: day - 1, to: month.start)
        }.map(Optional.some)
    }

    private var monthPracticeDays: Int {
        guard let month = calendar.dateInterval(of: .month, for: Date()) else { return 0 }
        return practiceDays.filter(month.contains).count
    }

    private var currentStreak: Int {
        guard !practiceDays.isEmpty else { return 0 }
        var day = calendar.startOfDay(for: Date())
        if !practiceDays.contains(day), let yesterday = calendar.date(byAdding: .day, value: -1, to: day) { day = yesterday }
        var count = 0
        while practiceDays.contains(day) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return count
    }

    private var longestStreak: Int {
        let sorted = practiceDays.sorted()
        guard !sorted.isEmpty else { return 0 }
        var longest = 1
        var current = 1
        for index in 1..<sorted.count {
            if calendar.dateComponents([.day], from: sorted[index - 1], to: sorted[index]).day == 1 {
                current += 1
                longest = max(longest, current)
            } else {
                current = 1
            }
        }
        return longest
    }
}

// MARK: - Previous Skills

struct PreviousSkillsView: View {
    @EnvironmentObject private var skillStore: SkillStore

    var body: some View {
        ZStack {
            AppPalette.background.ignoresSafeArea()

            if activeSkills.isEmpty {
                ContentUnavailableView(
                    "No Skills Yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Create a skill and it will appear here.")
                )
                .foregroundStyle(AppPalette.primaryText)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(activeSkills) { skill in
                            NavigationLink {
                                NewSkillOverviewView(skill: skill)
                            } label: {
                                PreviousSkillRow(skill: skill)
                            }
                            .buttonStyle(PressScaleButtonStyle())
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("My Skills")
                    .font(.custom("Menlo", size: 17).weight(.semibold))
                    .foregroundStyle(AppPalette.headingGradient)
            }
            if skillStore.skills.contains(where: { $0.archivedAt != nil }) {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink("Archived") { ArchivedSkillsView() }
                }
            }
        }
    }

    private var activeSkills: [Skill] {
        skillStore.skills.filter { $0.archivedAt == nil }
    }
}

private struct ArchivedSkillsView: View {
    @EnvironmentObject private var skillStore: SkillStore

    var body: some View {
        ZStack {
            AppPalette.background.ignoresSafeArea()
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(skillStore.skills.filter { $0.archivedAt != nil }) { skill in
                        NavigationLink { NewSkillOverviewView(skill: skill) } label: {
                            PreviousSkillRow(skill: skill)
                        }
                    }
                }
                .padding()
            }
        }
        .navigationTitle("Archived")
    }
}

private struct PreviousSkillRow: View {
    let skill: Skill

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(skill.name)
                    .font(.custom("Menlo", size: 18).weight(.semibold))
                    .foregroundStyle(AppPalette.primaryText)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.custom("Menlo", size: 13).weight(.semibold))
                    .foregroundStyle(AppPalette.primaryText.opacity(0.45))
            }

            ProgressView(value: skill.progress)
                .tint(Color(red: 0.23, green: 0.56, blue: 1.0))

            Text("\(formattedTime) practiced • \(Int(skill.progress * 100))% of \(skill.masteryTargetSeconds / 3600) hours")
                .font(.custom("Menlo", size: 13))
                .foregroundStyle(AppPalette.primaryText.opacity(0.6))
        }
        .padding(16)
        .background(AppPalette.primaryText.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(AppPalette.primaryText.opacity(0.1), lineWidth: 1)
        }
    }

    private var formattedTime: String {
        let hours = skill.totalSeconds / 3600
        let minutes = (skill.totalSeconds % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }
}

struct Milestone: Identifiable, Hashable {
    let id: UUID = UUID()
    let title: String
    let targetSeconds: Int

    var formattedTarget: String {
        if targetSeconds < 3600 { return "\(targetSeconds / 60)m" }
        return "\(targetSeconds / 3600)h"
    }
}

extension Skill {
    /// Returns a basic set of milestones on the path to 10,000 hours.
    /// You can refine these later (e.g., 10h, 25h, 50h, 100h, 250h, 500h, 1k, 2.5k, 5k, 10k).
    var milestones: [Milestone] {
        let standardMilestones: [Milestone] = [
            Milestone(title: "First Focus", targetSeconds: 900),
            Milestone(title: "First Hour", targetSeconds: 3_600),
            Milestone(title: "Building Momentum", targetSeconds: 18_000),
            Milestone(title: "Level 1", targetSeconds: 36_000),
            Milestone(title: "Level 2", targetSeconds: 90_000),
            Milestone(title: "Level 3", targetSeconds: 180_000),
            Milestone(title: "100 Hours", targetSeconds: 360_000),
            Milestone(title: "250 Hours", targetSeconds: 900_000),
            Milestone(title: "500 Hours", targetSeconds: 1_800_000),
            Milestone(title: "1,000 Hours", targetSeconds: 3_600_000),
            Milestone(title: "2,500 Hours", targetSeconds: 9_000_000),
            Milestone(title: "5,000 Hours", targetSeconds: 18_000_000),
            Milestone(title: "Mastery", targetSeconds: Skill.tenThousandHours)
        ]
        var applicable = standardMilestones.filter { $0.targetSeconds < masteryTargetSeconds }
        applicable.append(Milestone(title: "Your Goal", targetSeconds: masteryTargetSeconds))
        return applicable
    }

    /// Progress from 0 to 1 toward this skill's chosen mastery target.
    var progress: Double {
        guard masteryTargetSeconds > 0 else { return 0 }
        return min(1.0, Double(totalSeconds) / Double(masteryTargetSeconds))
    }

    var firstLevelProgress: Double {
        let firstLevelSeconds = milestones.first?.targetSeconds ?? 15 * 60
        return min(1.0, Double(totalSeconds) / Double(firstLevelSeconds))
    }

    var formattedStartDate: String {
        guard let startedAt else { return "Not recorded" }
        return startedAt.formatted(date: .abbreviated, time: .omitted)
    }

    var formattedTotalTime: String {
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    var currentLevelDescription: String {
        let completedMilestones = milestones.filter { totalSeconds >= $0.targetSeconds }.count
        return completedMilestones == 0 ? "Level 1" : "Level \(min(completedMilestones + 1, milestones.count))"
    }

    var nextMilestone: Milestone? {
        milestones.first { totalSeconds < $0.targetSeconds }
    }

    var nextMilestoneProgress: Double {
        guard let nextMilestone else { return 1 }
        let previousTarget = milestones.last(where: { $0.targetSeconds < nextMilestone.targetSeconds })?.targetSeconds ?? 0
        let range = nextMilestone.targetSeconds - previousTarget
        return min(1, max(0, Double(totalSeconds - previousTarget) / Double(range)))
    }
}

struct NewSkillOverviewView: View {
    let skill: Skill
    @EnvironmentObject private var skillStore: SkillStore
    @State private var isShowingTimer = false
    @State private var isRenaming = false
    @State private var isAddingSession = false
    @State private var isEditingPreferences = false
    @State private var isConfirmingDelete = false
    @Environment(\.dismiss) private var dismiss

    private var currentSkill: Skill {
        skillStore.skills.first(where: { $0.id == skill.id }) ?? skill
    }

    var body: some View {
        ZStack {
            AppPalette.background.ignoresSafeArea()

            VStack(spacing: 16) {
                Text(currentSkill.name)
                    .font(.custom("Menlo", size: 28).weight(.bold))
                    .foregroundStyle(AppPalette.headingGradient)

                // Progress to 10,000 hours
                VStack(spacing: 8) {
                    ProgressView(value: currentSkill.nextMilestoneProgress)
                        .progressViewStyle(.linear)
                        .tint(AppPalette.primaryText)
                        .padding(.horizontal)
                    Text(nextMilestoneText)
                        .font(.custom("Menlo", size: 14).weight(.medium))
                        .foregroundStyle(AppPalette.primaryText.opacity(0.8))
                }
                .padding(.top, 8)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Weekly Goal")
                        Spacer()
                        Text("\(weeklyPracticeText) / \(formatDuration(currentSkill.weeklyGoalSeconds))")
                    }
                    .font(.custom("Menlo", size: 14).weight(.semibold))
                    ProgressView(value: weeklyGoalProgress)
                        .tint(AppPalette.aqua)
                }
                .padding(.horizontal)

                Divider().background(AppPalette.primaryText.opacity(0.15))

                // Milestones
                VStack(alignment: .leading, spacing: 8) {
                    Text("Milestones")
                        .font(.custom("Menlo", size: 18).weight(.semibold))
                        .foregroundStyle(AppPalette.primaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)

                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach(currentSkill.milestones) { milestone in
                                HStack {
                                    Text(milestone.title)
                                        .foregroundStyle(AppPalette.primaryText)
                                    Spacer()
                                    Text(milestone.formattedTarget)
                                        .foregroundStyle(AppPalette.primaryText.opacity(0.7))
                                }
                                .padding()
                                .background(AppPalette.primaryText.opacity(0.06))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            }

                            if !skillStore.sessions(for: currentSkill.id).isEmpty {
                                Text("Recent Sessions")
                                    .font(.custom("Menlo", size: 18).weight(.semibold))
                                    .foregroundStyle(AppPalette.primaryText)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, 10)

                                ForEach(skillStore.sessions(for: currentSkill.id).prefix(5)) { session in
                                    SessionRow(session: session)
                                }
                            }
                        }
                        .padding(.horizontal)
                        .padding(.bottom, 16)
                    }
                }

                Spacer()

                // Placeholder for next step (e.g., start timer or finish setup)
                Button {
                    isShowingTimer = true
                } label: {
                    Text(timerButtonTitle)
                        .font(.custom("Menlo", size: 17).weight(.semibold))
                        .foregroundStyle(AppPalette.background)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(AppPalette.primaryText)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal)
                }
                .disabled(isAnotherSkillTracking)
                .opacity(isAnotherSkillTracking ? 0.45 : 1)
                .padding(.bottom, 24)
            }
            .padding(.top, 24)
        }
        .sheet(isPresented: $isShowingTimer) {
            PracticeTimerView(skill: currentSkill)
                .environmentObject(skillStore)
        }
        .sheet(isPresented: $isRenaming) {
            RenameSkillView(skill: currentSkill)
                .environmentObject(skillStore)
        }
        .sheet(isPresented: $isAddingSession) {
            ManualSessionView(skill: currentSkill)
                .environmentObject(skillStore)
        }
        .sheet(isPresented: $isEditingPreferences) {
            SkillPreferencesView(skill: currentSkill)
                .environmentObject(skillStore)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Rename", systemImage: "pencil") { isRenaming = true }
                    Button("Add Past Session", systemImage: "plus.circle") { isAddingSession = true }
                    Button("Goals & Reminders", systemImage: "slider.horizontal.3") { isEditingPreferences = true }
                    Button(currentSkill.archivedAt == nil ? "Archive" : "Unarchive", systemImage: "archivebox") {
                        skillStore.setArchived(currentSkill.archivedAt == nil, skillID: currentSkill.id)
                        if currentSkill.archivedAt == nil { dismiss() }
                    }
                    Button("Delete Skill", systemImage: "trash", role: .destructive) { isConfirmingDelete = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert("Delete \(currentSkill.name)?", isPresented: $isConfirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                skillStore.delete(skillID: currentSkill.id)
                dismiss()
            }
        } message: {
            Text("This also deletes its complete practice history. This cannot be undone.")
        }
    }

    private var timerButtonTitle: String {
        if skillStore.activeSession?.skillID == currentSkill.id { return "Resume Tracking Time" }
        if isAnotherSkillTracking { return "Another Session Is Active" }
        return "Start Tracking Time"
    }

    private var isAnotherSkillTracking: Bool {
        guard let activeSession = skillStore.activeSession else { return false }
        return activeSession.skillID != currentSkill.id
    }

    private var nextMilestoneText: String {
        guard let milestone = currentSkill.nextMilestone else { return "All milestones completed" }
        return "\(currentSkill.formattedTotalTime) • Next: \(milestone.formattedTarget)"
    }

    private var weeklyPracticeSeconds: Int {
        let interval = Calendar.current.dateInterval(of: .weekOfYear, for: Date())
        return skillStore.sessions(for: currentSkill.id)
            .filter { interval?.contains($0.startedAt) == true }
            .reduce(0) { $0 + $1.durationSeconds }
    }

    private var weeklyGoalProgress: Double {
        guard currentSkill.weeklyGoalSeconds > 0 else { return 0 }
        return min(1, Double(weeklyPracticeSeconds) / Double(currentSkill.weeklyGoalSeconds))
    }

    private var weeklyPracticeText: String { formatDuration(weeklyPracticeSeconds) }

    private func formatDuration(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }
}

private struct SkillPreferencesView: View {
    let skill: Skill
    @EnvironmentObject private var skillStore: SkillStore
    @Environment(\.dismiss) private var dismiss
    @State private var weeklyGoalMinutes: Int
    @State private var masteryTargetHours: Int
    @State private var reminderEnabled: Bool
    @State private var reminderDays: Int
    @State private var reminderTime: Date

    init(skill: Skill) {
        self.skill = skill
        _weeklyGoalMinutes = State(initialValue: max(1, skill.weeklyGoalSeconds / 60))
        _masteryTargetHours = State(initialValue: max(1, skill.masteryTargetSeconds / 3600))
        _reminderEnabled = State(initialValue: skill.reminderEnabled)
        _reminderDays = State(initialValue: skill.reminderDays)
        _reminderTime = State(initialValue: Calendar.current.date(bySettingHour: skill.reminderHour, minute: skill.reminderMinute, second: 0, of: Date()) ?? Date())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Weekly Goal") {
                    Stepper("\(weeklyGoalMinutes) minutes per week", value: $weeklyGoalMinutes, in: 15...10_000, step: 15)
                }
                Section("Mastery Target") {
                    Picker("Target", selection: $masteryTargetHours) {
                        Text("100 hours").tag(100)
                        Text("1,000 hours").tag(1_000)
                        Text("10,000 hours").tag(10_000)
                    }
                    Stepper("Custom: \(masteryTargetHours) hours", value: $masteryTargetHours, in: 1...50_000, step: 50)
                }
                Section("Skill Reminder") {
                    Toggle("Remind me about \(skill.name)", isOn: $reminderEnabled)
                    if reminderEnabled {
                        Picker("After", selection: $reminderDays) {
                            ForEach(PracticeReminder.availableIntervals, id: \.self) { Text("\($0) days").tag($0) }
                        }
                        DatePicker("Time", selection: $reminderTime, displayedComponents: .hourAndMinute)
                    }
                    Text("The master notification switch in Settings must also be enabled.")
                        .foregroundStyle(AppPalette.secondaryText)
                }
            }
            .font(.custom("Menlo", size: 14))
            .navigationTitle("Goals & Reminders")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let time = Calendar.current.dateComponents([.hour, .minute], from: reminderTime)
                        skillStore.updatePreferences(
                            skillID: skill.id,
                            weeklyGoalSeconds: weeklyGoalMinutes * 60,
                            masteryTargetSeconds: masteryTargetHours * 3600,
                            reminderEnabled: reminderEnabled,
                            reminderDays: reminderDays,
                            reminderHour: time.hour ?? 10,
                            reminderMinute: time.minute ?? 0
                        )
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct SessionRow: View {
    let session: PracticeSession
    var isEditing = false
    var onEdit: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.fill")
                .foregroundStyle(Color(red: 0.18, green: 0.82, blue: 0.79))
            VStack(alignment: .leading, spacing: 3) {
                Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .foregroundStyle(AppPalette.primaryText)
                if !session.note.isEmpty {
                    Text(session.note)
                        .font(.custom("Menlo", size: 12))
                        .foregroundStyle(AppPalette.primaryText.opacity(0.55))
                        .lineLimit(2)
                }
            }
            Spacer()
            Text(session.formattedDuration)
                .font(.custom("Menlo", size: 13).weight(.semibold))
                .foregroundStyle(AppPalette.primaryText.opacity(0.75))
            if isEditing, let onEdit {
                Button(action: onEdit) {
                    Image(systemName: "pencil.circle.fill")
                        .font(.title2)
                        .foregroundStyle(AppPalette.electricBlue)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit session")
            }
        }
        .padding()
        .background(AppPalette.primaryText.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contextMenu {
            if let onDelete {
                Button("Delete Session", systemImage: "trash", role: .destructive, action: onDelete)
            }
        }
    }
}

private struct EditPracticeSessionView: View {
    let session: PracticeSession
    @EnvironmentObject private var skillStore: SkillStore
    @Environment(\.dismiss) private var dismiss
    @State private var date: Date
    @State private var hours: Int
    @State private var minutes: Int
    @State private var note: String

    init(session: PracticeSession) {
        self.session = session
        _date = State(initialValue: session.startedAt)
        _hours = State(initialValue: session.durationSeconds / 3600)
        _minutes = State(initialValue: (session.durationSeconds % 3600) / 60)
        _note = State(initialValue: session.note)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(
                        "Only correct genuine logging mistakes. False time will make your mastery progression inaccurate.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.custom("Menlo", size: 13))
                    .foregroundStyle(.orange)
                }

                Section("Session Details") {
                    DatePicker("Date", selection: $date, in: ...Date())
                    Stepper("Hours: \(hours)", value: $hours, in: 0...24)
                    Stepper("Minutes: \(minutes)", value: $minutes, in: 0...59)
                    TextField("Optional note", text: $note, axis: .vertical)
                }
            }
            .font(.custom("Menlo", size: 14))
            .navigationTitle("Edit Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        skillStore.updateSession(
                            session,
                            date: date,
                            duration: hours * 3600 + minutes * 60,
                            note: note
                        )
                        dismiss()
                    }
                    .disabled(hours == 0 && minutes == 0)
                }
            }
        }
    }
}

private struct RenameSkillView: View {
    let skill: Skill
    @EnvironmentObject private var skillStore: SkillStore
    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(skill: Skill) {
        self.skill = skill
        _name = State(initialValue: skill.name)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Skill name", text: $name)
            }
            .navigationTitle("Rename Skill")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        skillStore.rename(skillID: skill.id, to: name)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).count < 2)
                }
            }
        }
    }
}

private struct ManualSessionView: View {
    let skill: Skill
    @EnvironmentObject private var skillStore: SkillStore
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()
    @State private var hours = 0
    @State private var minutes = 15
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Date", selection: $date, in: ...Date())
                Stepper("Hours: \(hours)", value: $hours, in: 0...24)
                Stepper("Minutes: \(minutes)", value: $minutes, in: 0...59, step: 5)
                TextField("Optional note", text: $note, axis: .vertical)
            }
            .navigationTitle("Add Past Session")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        skillStore.addSession(
                            to: skill.id,
                            duration: hours * 3600 + minutes * 60,
                            date: date,
                            note: note
                        )
                        dismiss()
                    }
                    .disabled(hours == 0 && minutes == 0)
                }
            }
        }
    }
}

// MARK: - Practice Timer

struct PracticeTimerView: View {
    let skill: Skill

    @EnvironmentObject private var skillStore: SkillStore
    @EnvironmentObject private var appNavigation: AppNavigation
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @State private var completedSession: PracticeSession?
    @State private var isConfirmingCancel = false

    var body: some View {
        NavigationStack {
            ZStack {
                AppPalette.background.ignoresSafeArea()

                if let completedSession {
                    SessionCompleteView(skill: currentSkill, session: completedSession) {
                        dismiss()
                    }
                } else {
                    VStack(spacing: 24) {
                        Spacer()

                        Text(skill.name)
                            .font(.custom("Menlo", size: 24).weight(.semibold))
                            .foregroundStyle(AppPalette.headingGradient)

                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            Text(formattedElapsedTime)
                                .font(.custom("Menlo", size: 52).weight(.light))
                                .foregroundStyle(AppPalette.primaryText)
                                .contentTransition(.numericText())
                                .accessibilityLabel("Elapsed practice time")
                        }

                        HStack(spacing: 8) {
                            Circle()
                                .fill(isPaused ? .orange : Color(red: 0.18, green: 0.82, blue: 0.79))
                                .frame(width: 8, height: 8)
                            Text(isPaused ? "Session paused" : "Tracking in progress")
                                .font(.custom("Menlo", size: 14).weight(.medium))
                                .foregroundStyle(AppPalette.primaryText.opacity(0.65))
                        }

                        TextField("Optional session note", text: $note, axis: .vertical)
                            .padding()
                            .background(AppPalette.primaryText.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .foregroundStyle(AppPalette.primaryText)
                            .padding(.horizontal)

                        Spacer()

                        HStack(spacing: 12) {
                            Button {
                                skillStore.togglePause()
                            } label: {
                                Label(isPaused ? "Resume" : "Pause", systemImage: isPaused ? "play.fill" : "pause.fill")
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(AppPalette.primaryText.opacity(0.12))
                                    .foregroundStyle(AppPalette.primaryText)
                                    .clipShape(RoundedRectangle(cornerRadius: 14))
                            }

                            Button {
                                completedSession = skillStore.finishActiveSession(note: note)
                            } label: {
                                Label("Stop", systemImage: "stop.fill")
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(AppPalette.primaryText)
                                    .foregroundStyle(AppPalette.background)
                                    .clipShape(RoundedRectangle(cornerRadius: 14))
                            }
                        }
                        .font(.custom("Menlo", size: 15).weight(.semibold))
                        .padding(.horizontal)
                        .padding(.bottom, 24)
                    }
                }
            }
            .navigationTitle("Practice Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if completedSession == nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { isConfirmingCancel = true }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        skillStore.pauseActiveSession()
                        appNavigation.returnHome()
                    } label: {
                        Label("Home", systemImage: "house.fill")
                    }
                }
            }
        }
        .interactiveDismissDisabled()
        .onAppear { skillStore.beginOrResumeSession(for: skill.id) }
        .alert("Discard this session?", isPresented: $isConfirmingCancel) {
            Button("Keep Practicing", role: .cancel) {}
            Button("Discard", role: .destructive) {
                skillStore.cancelActiveSession()
                dismiss()
            }
        } message: {
            Text("The elapsed practice time will not be saved.")
        }
    }

    private var currentSkill: Skill {
        skillStore.skills.first(where: { $0.id == skill.id }) ?? skill
    }

    private var isPaused: Bool {
        skillStore.activeSession?.isPaused ?? false
    }

    private var formattedElapsedTime: String {
        let elapsed = skillStore.activeSession?.elapsedSeconds ?? 0
        let hours = elapsed / 3600
        let minutes = (elapsed % 3600) / 60
        let seconds = elapsed % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}

private struct SessionCompleteView: View {
    let skill: Skill
    let session: PracticeSession
    let done: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(Color(red: 0.18, green: 0.82, blue: 0.79))
            Text("Session Saved")
                .font(.custom("Menlo", size: 26).weight(.bold))
                .foregroundStyle(AppPalette.headingGradient)
            Text("\(session.formattedDuration) logged")
                .font(.custom("Menlo", size: 18).weight(.semibold))
                .foregroundStyle(AppPalette.primaryText.opacity(0.8))
            VStack(spacing: 8) {
                ProgressView(value: skill.nextMilestoneProgress)
                    .tint(Color(red: 0.18, green: 0.82, blue: 0.79))
                Text(skill.nextMilestone.map { "Next: \($0.title) at \($0.formattedTarget)" } ?? "All milestones complete")
                    .font(.custom("Menlo", size: 13))
                    .foregroundStyle(AppPalette.primaryText.opacity(0.6))
            }
            .padding()
            Spacer()
            Button("Done", action: done)
                .font(.custom("Menlo", size: 17).weight(.semibold))
                .foregroundStyle(AppPalette.background)
                .frame(maxWidth: .infinity)
                .padding()
                .background(AppPalette.primaryText)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .padding()
        }
    }
}

// MARK: - Placeholder Screens

struct PlaceholderView: View {

    let title: String

    var body: some View {
        ZStack {
            AppPalette.background.ignoresSafeArea()

            Text(title)
                .font(.custom("Menlo", size: 28).weight(.semibold))
                .foregroundStyle(AppPalette.primaryText)
        }
    }
}

// MARK: - PressScaleButtonStyle

/// A minimal press interaction: scales down slightly on touch.
/// Keeps the Home screen feeling responsive without adding visual clutter.
private struct PressScaleButtonStyle: ButtonStyle {
    // MARK: Body

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Preview

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentViewPreviewHost()
    }
}

@MainActor
private struct ContentViewPreviewHost: View {
    @StateObject private var skillStore: SkillStore
    @StateObject private var appNavigation = AppNavigation()

    init() {
        let previewDefaults = UserDefaults(suiteName: "Expert.ContentViewPreview") ?? .standard
        _skillStore = StateObject(wrappedValue: SkillStore(defaults: previewDefaults))
    }

    var body: some View {
        ContentView()
            .environmentObject(skillStore)
            .environmentObject(appNavigation)
    }
}
