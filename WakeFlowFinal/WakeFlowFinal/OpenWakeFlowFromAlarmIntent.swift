//
//  OpenWakeFlowFromAlarmIntent.swift
//  WakeFlowFinal
//

import AppIntents
import Foundation
import OSLog

enum WakeFlowAlarmKitLaunchMarker {
    nonisolated static let alarmIDKey = "openedFromAlarmKitAlarmID"
    nonisolated static let timestampKey = "openedFromAlarmKitAlarmTimestamp"
}

@available(iOS 26.0, *)
struct OpenWakeFlowFromAlarmIntent: LiveActivityIntent {
    static var title: LocalizedStringResource {
        "WakeFlow öffnen"
    }

    static var supportedModes: IntentModes {
        .foreground(.immediate)
    }

    static var openAppWhenRun: Bool {
        true
    }

    @Parameter(title: "alarmID")
    var alarmID: String

    init(alarmID: String) {
        self.alarmID = alarmID
    }

    init() {
        self.alarmID = ""
    }

    func perform() async throws -> some IntentResult {
        let defaults = UserDefaults.standard
        defaults.set(alarmID, forKey: WakeFlowAlarmKitLaunchMarker.alarmIDKey)
        defaults.set(Date().timeIntervalSince1970, forKey: WakeFlowAlarmKitLaunchMarker.timestampKey)
        defaults.synchronize()

        Logger.alarm.notice("AlarmKit Secondary Intent geöffnet für Alarm: \(alarmID, privacy: .public)")
        return .result()
    }
}
