//
//  Logger+Categories.swift
//  WakeFlowFinal
//
//  Centralized os.Logger categories for unified logging via Apple's
//  OSLog framework. Logs are accessible in Console.app and via the
//  `log` CLI tool, persisted by the system across app launches and
//  device restarts (subject to system retention policy).
//

import Foundation
import OSLog

extension Logger {
    /// Subsystem used for every WakeFlow Logger. Falls back to the
    /// hardcoded bundle identifier in case Info.plist is missing it
    /// (e.g. early during launch on simulator).
    private static let subsystem: String = {
        Bundle.main.bundleIdentifier ?? "com.marvin.wakeflowfinal"
    }()

    /// AlarmKit scheduling, alarm playback, audio session for alarm sound,
    /// volume enforcement, vibration loop, alarm state replay.
    static let alarm = Logger(subsystem: subsystem, category: "alarm")

    /// NFC tag scanning, NFC availability checks, NFC button presses,
    /// NFC-based alarm activation/stopping flows.
    static let nfc = Logger(subsystem: subsystem, category: "nfc")

    /// User notification scheduling/cancellation, notification permission
    /// flows, fallback/backup notifications, daily reminder.
    static let notifications = Logger(subsystem: subsystem, category: "notifications")

    /// Phantom-alarm investigation logs, app-kill warnings, defensive
    /// reconciliation between AlarmKit state and persisted alarm list.
    /// These are signal-rich entries that must survive in Console.app.
    static let criticalAlerts = Logger(subsystem: subsystem, category: "criticalAlerts")

    /// App launch, scene foreground/background transitions, view
    /// onAppear/onDisappear, persistence of saved alarms, sleep-time UI.
    static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
}
