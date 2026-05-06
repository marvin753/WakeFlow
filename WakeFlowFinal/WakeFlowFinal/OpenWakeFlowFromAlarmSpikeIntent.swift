//
//  OpenWakeFlowFromAlarmSpikeIntent.swift
//  WakeFlowFinal
//

#if DEBUG
import AlarmKit
import AppIntents
import Foundation
import OSLog
import SwiftUI
import UIKit

enum AlarmKitSpikeDefaults {
    static let secondaryIntentRanAtKey = "alarmKitSpikeSecondaryIntentRanAt"
    static let secondaryIntentRunCountKey = "alarmKitSpikeSecondaryIntentRunCount"
    static let pendingAlarmIDKey = "alarmKitSpikePendingAlarmID"
    static let activeAlarmKitSpikeTypeKey = "alarmKitSpikeActiveAlarmKitSpikeType"
    static let pendingPlainNotificationIDKey = "plainNotificationSpikePendingRequestID"
    static let pendingPlainNotificationFireDateKey = "plainNotificationSpikePendingFireDate"
    static let verificationConsumedKey = "alarmKitSpikeVerificationConsumed"
    static let logKey = "alarmKitSpikeLog"

    static var defaults: UserDefaults {
        UserDefaults.standard
    }

    static func appendLog(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let entry = "[\(timestamp)] \(message)"
        Logger.criticalAlerts.debug("\(entry, privacy: .public)")

        var entries = defaults.stringArray(forKey: logKey) ?? []
        entries.append(entry)
        if entries.count > 200 {
            entries.removeFirst(entries.count - 200)
        }

        defaults.set(entries, forKey: logKey)
        defaults.synchronize()
    }

    static func logEntries() -> [String] {
        defaults.synchronize()
        return defaults.stringArray(forKey: logKey) ?? []
    }

    static func logPrefix(for spikeType: String?) -> String {
        switch spikeType {
        case "combined":
            return "Combined Spike"
        case "plain":
            return "Plain Notification Spike"
        default:
            return "AlarmKit Spike"
        }
    }
}

enum SpikeLogFilter: String, CaseIterable, Identifiable {
    case all
    case alarmKit
    case plain
    case combined

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "All"
        case .alarmKit:
            return "AlarmKit"
        case .plain:
            return "Plain"
        case .combined:
            return "Combined"
        }
    }

    func includes(_ entry: String) -> Bool {
        switch self {
        case .all:
            return true
        case .alarmKit:
            return entry.contains("AlarmKit Spike:")
        case .plain:
            return entry.contains("Plain Notification Spike:")
        case .combined:
            return entry.contains("Combined Spike:")
        }
    }
}

// API verified against iOS 26.4 SDK and Apple docs: LiveActivityIntent inherits AppIntent;
// supportedModes = .foreground(.immediate) is valid, and openAppWhenRun is kept for compatibility.
// Assumes LiveActivityIntent perform() runs in app process; if cross-process behavior is observed
// during the spike, fail the spike and request App Group migration.
// The "WakeFlow öffnen" title may truncate on the lockscreen; TODO compare fallback title "Öffnen".
@available(iOS 26.0, *)
struct OpenWakeFlowFromAlarmSpikeIntent: LiveActivityIntent {
    static var title: LocalizedStringResource {
        "WakeFlow öffnen"
    }

    static var supportedModes: IntentModes {
        .foreground(.immediate)
    }

    static var openAppWhenRun: Bool {
        true
    }

    func perform() async throws -> some IntentResult {
        let defaults = AlarmKitSpikeDefaults.defaults
        let logPrefix = AlarmKitSpikeDefaults.logPrefix(for: defaults.string(forKey: AlarmKitSpikeDefaults.activeAlarmKitSpikeTypeKey))
        let now = Date().timeIntervalSince1970
        let currentCount = defaults.integer(forKey: AlarmKitSpikeDefaults.secondaryIntentRunCountKey)

        defaults.set(now, forKey: AlarmKitSpikeDefaults.secondaryIntentRanAtKey)
        defaults.set(currentCount + 1, forKey: AlarmKitSpikeDefaults.secondaryIntentRunCountKey)
        defaults.synchronize()

        AlarmKitSpikeDefaults.appendLog("\(logPrefix): secondary intent perform() wrote marker at \(now), run count \(currentCount + 1)")
        return .result()
    }
}

@MainActor
final class AlarmKitSpikeForegroundVerifier {
    static let shared = AlarmKitSpikeForegroundVerifier()

    private var observer: NSObjectProtocol?

    private init() {}

    func register() {
        guard observer == nil else { return }

        observer = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            let didBecomeActiveAt = Date()
            Task { @MainActor in
                await self?.verifyAfterForeground(didBecomeActiveAt: didBecomeActiveAt)
            }
        }

        AlarmKitSpikeDefaults.appendLog("AlarmKit Spike: foreground verifier registered")
    }

    private func verifyAfterForeground(didBecomeActiveAt: Date) async {
        guard #available(iOS 26.0, *) else { return }

        let defaults = AlarmKitSpikeDefaults.defaults
        defaults.synchronize()
        let logPrefix = AlarmKitSpikeDefaults.logPrefix(for: defaults.string(forKey: AlarmKitSpikeDefaults.activeAlarmKitSpikeTypeKey))

        guard defaults.bool(forKey: AlarmKitSpikeDefaults.verificationConsumedKey) == false else {
            return
        }

        try? await Task.sleep(for: .milliseconds(500))

        for attempt in 1...3 {
            defaults.synchronize()

            let pendingAlarmIDString = defaults.string(forKey: AlarmKitSpikeDefaults.pendingAlarmIDKey)
            let markerValue = defaults.object(forKey: AlarmKitSpikeDefaults.secondaryIntentRanAtKey) as? TimeInterval

            guard let markerValue else {
                if let pendingAlarmIDString {
                    AlarmKitSpikeDefaults.appendLog("\(logPrefix): foreground marker missing on attempt \(attempt)/3 with pending alarm \(pendingAlarmIDString)")
                    if attempt < 3 {
                        try? await Task.sleep(for: .milliseconds(500))
                        continue
                    }
                }
                return
            }

            let markerAge = Date().timeIntervalSince1970 - markerValue
            guard markerAge <= 30 else {
                AlarmKitSpikeDefaults.appendLog("\(logPrefix): foreground marker ignored because it is \(String(format: "%.2f", markerAge))s old")
                return
            }

            defaults.set(true, forKey: AlarmKitSpikeDefaults.verificationConsumedKey)

            let alarms: [AlarmKit.Alarm]
            do {
                // AlarmManager.shared.alarms verified sync throws in iOS 26.4 SDK; verifier is async only for delayed/retry marker reads.
                alarms = try AlarmKit.AlarmManager.shared.alarms
            } catch {
                AlarmKitSpikeDefaults.appendLog("\(logPrefix): failed to read alarms during foreground verification: \(error)")
                clearIntentMarkers(defaults: defaults, shouldClearPendingAlarmID: false)
                return
            }

            AlarmKitSpikeDefaults.appendLog("\(logPrefix): raw AlarmKit alarms count after foreground = \(alarms.count)")

            let pendingAlarmID = pendingAlarmIDString.flatMap(UUID.init(uuidString:))
            let matchedAlarm = pendingAlarmID.flatMap { id in
                alarms.first { $0.id == id }
            }

            if let pendingAlarmID {
                if let matchedAlarm {
                    AlarmKitSpikeDefaults.appendLog("\(logPrefix): matched alarm \(pendingAlarmID) state after foreground = \(matchedAlarm.state)")
                } else {
                    AlarmKitSpikeDefaults.appendLog("\(logPrefix): pending alarm \(pendingAlarmID) absent after foreground")
                }
            } else {
                AlarmKitSpikeDefaults.appendLog("\(logPrefix): no pending alarm ID stored during foreground verification")
            }

            let activationDelta = didBecomeActiveAt.timeIntervalSince1970 - markerValue
            AlarmKitSpikeDefaults.appendLog("\(logPrefix): intent perform() to didBecomeActive delta = \(String(format: "%.2f", activationDelta))s")

            clearIntentMarkers(defaults: defaults, shouldClearPendingAlarmID: matchedAlarm == nil)
            return
        }
    }

    private func clearIntentMarkers(defaults: UserDefaults, shouldClearPendingAlarmID: Bool) {
        defaults.removeObject(forKey: AlarmKitSpikeDefaults.secondaryIntentRanAtKey)
        defaults.removeObject(forKey: AlarmKitSpikeDefaults.secondaryIntentRunCountKey)
        if shouldClearPendingAlarmID {
            defaults.removeObject(forKey: AlarmKitSpikeDefaults.pendingAlarmIDKey)
            defaults.removeObject(forKey: AlarmKitSpikeDefaults.activeAlarmKitSpikeTypeKey)
        }
        defaults.synchronize()
    }
}

struct AlarmKitSpikeLogView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var logEntries = AlarmKitSpikeDefaults.logEntries()
    @State private var selectedFilter: SpikeLogFilter = .all

    private var filteredLogEntries: [String] {
        logEntries.filter { selectedFilter.includes($0) }
    }

    private var displayedLogText: String {
        if filteredLogEntries.isEmpty {
            return "No spike logs for selected filter."
        }
        return filteredLogEntries.joined(separator: "\n")
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Picker("Spike Type", selection: $selectedFilter) {
                    ForEach(SpikeLogFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .padding()

                ScrollView {
                    Text(displayedLogText)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
            .navigationTitle("Spike Log")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fertig") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                logEntries = AlarmKitSpikeDefaults.logEntries()
            }
        }
    }
}
#endif
