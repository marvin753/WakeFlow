//
//  ContentView.swift
//  WakeFlowFinal
//
//  Created by Viktor Rotgang on 03.02.26.
//

import SwiftUI
internal import Combine
import UserNotifications
import AVFoundation
import MediaPlayer
#if ENABLE_NFC
import CoreNFC
#endif
import AlarmKit
import ActivityKit
import OSLog


// MARK: - Collection Extension (Safe Array Access)
extension Collection {
    subscript(safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}

// #region agent log
// MARK: - Phantom Debug Logger (TEMP - debug session d6bfee)
enum PhantomDebug {
    static let sessionId = "d6bfee"
    static let logFileName = "wakeflow-phantom-debug.log"
    static let lock = NSLock()

    static var logFileURL: URL? {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        return docs.appendingPathComponent(logFileName)
    }

    static func log(_ location: String, _ message: String, data: [String: Any] = [:]) {
        let now = Date()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = iso.string(from: now)
        let consoleLine = "🔍 PHANTOM-DEBUG [\(timestamp)] [\(location)] \(message) | data=\(data)"
        Logger.criticalAlerts.debug("\(consoleLine, privacy: .public)")

        // Persist to file (survives app kills, readable via in-app viewer or Xcode container download)
        guard let url = logFileURL else { return }
        let line = consoleLine + "\n"
        guard let bytes = line.data(using: .utf8) else { return }

        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? bytes.write(to: url)
        } else if let handle = try? FileHandle(forWritingTo: url) {
            try? handle.seekToEnd()
            try? handle.write(contentsOf: bytes)
            try? handle.close()
        }
    }

    static func readAllLogs() -> String {
        guard let url = logFileURL,
              let data = try? Data(contentsOf: url),
              let str = String(data: data, encoding: .utf8) else {
            return "(no logs yet)"
        }
        return str
    }

    static func clearLogs() {
        guard let url = logFileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    @MainActor
    static func dumpBootState(reason: String) async {
        log("boot", "boot dump start: \(reason)", data: ["now": Date().description])

        // 1) UserDefaults inspection
        let defaults = UserDefaults.standard
        let savedAlarmsCount: Int = {
            guard let data = defaults.data(forKey: "savedAlarms"),
                  let alarms = try? JSONDecoder().decode([Alarm].self, from: data) else { return -1 }
            for a in alarms {
                log("boot.savedAlarms", "alarm",
                    data: [
                        "id": a.id.uuidString,
                        "time": a.time.description,
                        "isEnabled": a.isEnabled,
                        "label": a.label,
                        "repeatDays": Array(a.repeatDays).sorted(),
                        "sound": a.soundName
                    ])
            }
            return alarms.count
        }()
        let snapshotAlarmsCount: Int = {
            guard let data = defaults.data(forKey: "scheduledAlarmSnapshots"),
                  let alarms = try? JSONDecoder().decode([Alarm].self, from: data) else { return -1 }
            for a in alarms {
                log("boot.scheduledAlarmSnapshots", "snapshot",
                    data: [
                        "id": a.id.uuidString,
                        "time": a.time.description,
                        "isEnabled": a.isEnabled,
                        "label": a.label,
                        "repeatDays": Array(a.repeatDays).sorted()
                    ])
            }
            return alarms.count
        }()
        let activeAlarmID = defaults.string(forKey: "activeAlarmID") ?? "<nil>"
        let activeAlarmLabel = defaults.string(forKey: "activeAlarmLabel") ?? "<nil>"
        let activeAlarmStart = defaults.object(forKey: "activeAlarmStartTime") as? Date
        let openMarkerID = defaults.string(forKey: WakeFlowAlarmKitLaunchMarker.alarmIDKey) ?? "<nil>"
        let openMarkerTS = defaults.object(forKey: WakeFlowAlarmKitLaunchMarker.timestampKey) as? TimeInterval
        let spikePendingID = defaults.string(forKey: "alarmKitSpikePendingAlarmID") ?? "<nil>"
        let spikeActiveType = defaults.string(forKey: "alarmKitSpikeActiveAlarmKitSpikeType") ?? "<nil>"
        let plainPendingID = defaults.string(forKey: "plainNotificationSpikePendingRequestID") ?? "<nil>"
        let plainPendingFire = defaults.object(forKey: "plainNotificationSpikePendingFireDate") as? TimeInterval

        log("boot.userDefaults", "summary", data: [
            "savedAlarmsCount": savedAlarmsCount,
            "scheduledSnapshotsCount": snapshotAlarmsCount,
            "activeAlarmID": activeAlarmID,
            "activeAlarmLabel": activeAlarmLabel,
            "activeAlarmStart": activeAlarmStart?.description ?? "<nil>",
            "openMarkerAlarmID": openMarkerID,
            "openMarkerTimestamp": openMarkerTS ?? -1,
            "spikePendingAlarmID": spikePendingID,
            "spikeActiveType": spikeActiveType,
            "plainSpikePendingID": plainPendingID,
            "plainSpikePendingFire": plainPendingFire ?? -1
        ])

        // 2) AlarmKit pending alarms (iOS 26+)
        if #available(iOS 26.0, *) {
            do {
                let alarms = try AlarmKit.AlarmManager.shared.alarms
                log("boot.alarmKit", "alarmKit count", data: ["count": alarms.count])

                // Build expected enabled IDs from savedAlarms
                let expectedEnabled: Set<UUID> = {
                    guard let data = defaults.data(forKey: "savedAlarms"),
                          let saved = try? JSONDecoder().decode([Alarm].self, from: data) else { return [] }
                    return Set(saved.filter { $0.isEnabled }.map { $0.id })
                }()

                for a in alarms {
                    let isExpected = expectedEnabled.contains(a.id)
                    log("boot.alarmKit", isExpected ? "alarm (expected)" : "alarm (STALE - not in saved+enabled)",
                        data: [
                            "id": a.id.uuidString,
                            "state": String(describing: a.state),
                            "schedule": String(describing: a.schedule),
                            "isExpected": isExpected
                        ])
                }
                // Detect missing: alarm we expect to have scheduled but isn't in AlarmKit
                let actualIDs = Set(alarms.map { $0.id })
                let missing = expectedEnabled.subtracting(actualIDs)
                if !missing.isEmpty {
                    log("boot.alarmKit", "MISSING: enabled alarms not present in AlarmKit",
                        data: ["count": missing.count, "ids": missing.map { $0.uuidString }])
                }
            } catch {
                log("boot.alarmKit", "alarmKit query failed", data: ["error": error.localizedDescription])
            }
        }

        // 3) Pending UNNotificationRequests
        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        log("boot.unNotifications", "pending count", data: ["count": pending.count])
        for req in pending {
            log("boot.unNotifications", "pending",
                data: [
                    "identifier": req.identifier,
                    "title": req.content.title,
                    "trigger": String(describing: req.trigger),
                    "userInfo": String(describing: req.content.userInfo)
                ])
        }

        // 4) Delivered notifications
        let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
        log("boot.unNotifications", "delivered count", data: ["count": delivered.count])
        for n in delivered {
            log("boot.unNotifications", "delivered",
                data: [
                    "identifier": n.request.identifier,
                    "title": n.request.content.title,
                    "deliveredAt": n.date.description,
                    "userInfo": String(describing: n.request.content.userInfo)
                ])
        }

        log("boot", "boot dump end")
    }
}

struct PhantomLogView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var logText: String = "Loading..."

    var body: some View {
        NavigationView {
            ScrollView {
                Text(logText)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .textSelection(.enabled)
            }
            .navigationTitle("Phantom Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Schließen") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack {
                        if let url = PhantomDebug.logFileURL {
                            ShareLink(item: url) {
                                Image(systemName: "square.and.arrow.up")
                            }
                        }
                        Button("Leeren") {
                            PhantomDebug.clearLogs()
                            logText = PhantomDebug.readAllLogs()
                        }
                    }
                }
            }
            .onAppear { logText = PhantomDebug.readAllLogs() }
        }
    }
}
// #endregion

// MARK: - Alarm Model
struct Alarm: Identifiable, Hashable, Codable {
    var id: UUID
    var time: Date
    var isEnabled: Bool
    var label: String
    var repeatDays: Set<Int> // 1 = Sonntag, 2 = Montag, etc.
    var soundName: String
    var volume: Float = 1.0 // Lautstärke 0.25 - 0.8
    
    init(id: UUID = UUID(), time: Date, isEnabled: Bool, label: String, repeatDays: Set<Int>, soundName: String, volume: Float = 1.0) {
        self.id = id
        self.time = time
        self.isEnabled = isEnabled
        self.label = label
        self.repeatDays = repeatDays
        self.soundName = soundName
        self.volume = volume
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: Alarm, rhs: Alarm) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Available Sounds
let availableSounds: [(file: String, name: String)] = [
    ("alarm-clock-1.caf", "Wecker 1"),
    ("alarm-clock.caf", "Wecker 2"),
    ("classic-alarm.caf", "Klassisch"),
    ("digital-alarm-clock.caf", "Digital 1"),
    ("digital-alarm.caf", "Digital 2"),
    ("dreamscape-alarm-clock.caf", "Dreamscape"),
    ("electronic-alarm-clock.caf", "Elektronisch"),
    ("ringtone-028-380250.caf", "Klingelton")
]

@available(iOS 26.0, *)
private struct WakeFlowAlarmMetadata: AlarmKit.AlarmMetadata {
    let label: String
    let soundName: String
}

// MARK: - NFC Alarm Reader
#if ENABLE_NFC
enum NFCActionType {
    case activate
    case deactivate
}

class NFCAlarmReader: NSObject, ObservableObject, NFCNDEFReaderSessionDelegate {
    @Published var isScanned = false
    @Published var statusMessage = "Halte dein iPhone an\neinen NFC-Chip"

    private var nfcSession: NFCNDEFReaderSession?
    private var actionType: NFCActionType = .deactivate

    func startScanning(actionType: NFCActionType = .deactivate) {
        self.actionType = actionType
        Logger.nfc.debug("startScanning() aufgerufen")
        Logger.nfc.debug("NFCNDEFReaderSession.readingAvailable: \(NFCNDEFReaderSession.readingAvailable, privacy: .public)")

        guard NFCNDEFReaderSession.readingAvailable else {
            DispatchQueue.main.async {
                self.statusMessage = "NFC wird auf diesem\nGerät nicht unterstützt"
            }
            Logger.nfc.error("NFC nicht verfügbar auf diesem Gerät")
            return
        }

        isScanned = false

        DispatchQueue.main.async {
            self.statusMessage = "Scanner startet..."
        }

        nfcSession = NFCNDEFReaderSession(delegate: self, queue: DispatchQueue.main, invalidateAfterFirstRead: false)

        // Setze Texte je nach Action Type
        if actionType == .activate {
            nfcSession?.alertMessage = "Halte die Oberseite deines Handys an deinen WakeFlow"
            DispatchQueue.main.async {
                self.statusMessage = "Bereit zum Scannen!\nHalte die Oberseite deines Handys an deinen WakeFlow"
            }
        } else {
            nfcSession?.alertMessage = "Halte die Oberseite deines Handys an deinen WakeFlow um den Alarm zu stoppen"
            DispatchQueue.main.async {
                self.statusMessage = "Bereit zum Scannen!\nHalte die Oberseite deines Handys an deinen WakeFlow"
            }
        }

        nfcSession?.begin()

        Logger.nfc.info("NFC Scanner gestartet")
    }

    func readerSession(_ session: NFCNDEFReaderSession, didDetectNDEFs messages: [NFCNDEFMessage]) {
        // NFC-Tag erkannt!
        DispatchQueue.main.async {
            self.isScanned = true
            self.statusMessage = "✅ NFC-Chip erkannt!"

            if self.actionType == .activate {
                Logger.nfc.notice("NFC-Tag erkannt - Alarm wird aktiviert")
            } else {
                Logger.nfc.notice("NFC-Tag erkannt - Alarm wird gestoppt")
            }
        }

        // Unterschiedliche Nachrichten je nach Aktion
        if actionType == .activate {
            session.alertMessage = "✅ Erkannt! Alarm wird aktiviert..."
        } else {
            session.alertMessage = "✅ Erkannt! Alarm wird gestoppt..."
        }

        session.invalidate()
    }

    func readerSession(_ session: NFCNDEFReaderSession, didInvalidateWithError error: Error) {
        if let nfcError = error as? NFCReaderError {
            switch nfcError.code {
            case .readerSessionInvalidationErrorUserCanceled:
                Logger.nfc.notice("NFC Scan abgebrochen")
                DispatchQueue.main.async {
                    self.statusMessage = "Scan abgebrochen"
                }
            case .readerSessionInvalidationErrorFirstNDEFTagRead:
                // Tag wurde gelesen - das ist Erfolg!
                Logger.nfc.info("NFC-Tag erfolgreich gelesen")
            default:
                Logger.nfc.error("NFC Fehler: \(error.localizedDescription, privacy: .public)")
                DispatchQueue.main.async {
                    self.statusMessage = "Fehler beim Scannen"
                }
            }
        }
    }

    func readerSession(_ session: NFCNDEFReaderSession, didDetect tags: [NFCNDEFTag]) {
        // NDEF Tag erkannt
        if tags.count > 1 {
            session.alertMessage = "Mehr als ein Tag erkannt. Bitte nur einen Tag."
            return
        }

        guard let tag = tags.first else { return }

        session.connect(to: tag) { error in
            if let error = error {
                session.invalidate(errorMessage: "Verbindung fehlgeschlagen: \(error.localizedDescription)")
                return
            }

            tag.queryNDEFStatus { status, capacity, error in
                guard error == nil else {
                    session.invalidate(errorMessage: "Tag konnte nicht gelesen werden")
                    return
                }

                // Tag erkannt → Erfolg!
                DispatchQueue.main.async {
                    self.isScanned = true
                    self.statusMessage = "✅ NFC-Chip erkannt!"
                    Logger.nfc.notice("NFC-Tag gescannt - Alarm wird gestoppt")
                }

                session.alertMessage = "✅ Erkannt! Alarm wird gestoppt..."
                session.invalidate()
            }
        }
    }
}
#endif

// MARK: - Background Alarm Manager
class BackgroundAlarmManager: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = BackgroundAlarmManager()
    
    private var audioPlayer: AVAudioPlayer?
    private var checkTimer: Timer?
    private var volumeEnforceTimer: Timer?
    private var notificationTimer: Timer? // Timer für gestapelte Notifications
    @Published var isPlaying = false
    private var currentAlarmID: UUID?
    private var currentSoundURL: URL?
    private var alarmStartTime: Date?
    private var stopTimer: Timer?
    private var originalSystemVolume: Float = 0.0
    private var notificationCount: Int = 0 // Zähler für Notifications
    private var targetVolume: Float = 1.0 // Ziel-Lautstärke für aktuellen Alarm (0.25-0.8)
    private var notificationsPaused: Bool = false // Status ob Notifications pausiert sind
    private var vibrationTimer: Timer? // Timer für kontinuierliche Vibration
    private var silentPlayer: AVAudioPlayer? // Silent audio um App wach zu halten
    private var hasAuthorizedSystemAlarms = false
    private var usesSystemAlarmByID: [UUID: Bool] = [:]
    private let systemAlarmManager = AlarmKit.AlarmManager.shared
    private var alarmUpdatesTask: Task<Void, Never>?
    private var firedLocalAlarmKeys = Set<String>()
    private let localAlarmFireWindow: TimeInterval = 90
    private let scheduledAlarmSnapshotsKey = "scheduledAlarmSnapshots"

    override init() {
        super.init()
        setupAudioSession()
        startMonitoring()
        observeVolumeChanges()
        startSilentAudio() // Starte stillen Audio-Stream
        refreshSystemAlarmAuthorization()
        observeSystemAlarmUpdates()
    }
    
    // Konvertiere internen Wert (0.25-0.8) zu System-Slider (0-1.0)
    // Damit 0.8 wie "voll aufgedreht" aussieht
    private func internalToSystemVolume(_ internalVolume: Float) -> Float {
        return (internalVolume - 0.25) / 0.55
    }
    
    func setupAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            // WICHTIG: playback mit duckOthers - andere Apps werden leiser, aber wir können spielen
            try audioSession.setCategory(.playback, mode: .default, options: [.duckOthers])
            try audioSession.setActive(true, options: [])
            Logger.alarm.info("Audio Session konfiguriert (VOLLE POWER)")
        } catch {
            Logger.alarm.error("Audio Session Fehler: \(error.localizedDescription, privacy: .public)")
        }
    }
    
    /// Aggressiver Audio-Session-Aktivierungsversuch für Alarm-Wiedergabe
    private func forceActivateAudioSession() -> Bool {
        let audioSession = AVAudioSession.sharedInstance()
        
        // Versuch 1: Mit duckOthers (andere Apps werden leiser)
        do {
            try audioSession.setCategory(.playback, mode: .default, options: [.duckOthers])
            try audioSession.setActive(true, options: [.notifyOthersOnDeactivation])
            Logger.alarm.info("Audio Session aktiviert (duckOthers)")
            return true
        } catch {
            Logger.alarm.notice("duckOthers fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
        }
        
        // Versuch 2: Mit interruptSpokenAudioAndMixWithOthers (unterbricht andere Audio-Apps)
        do {
            try audioSession.setCategory(.playback, mode: .default, options: [.interruptSpokenAudioAndMixWithOthers])
            try audioSession.setActive(true, options: [.notifyOthersOnDeactivation])
            Logger.alarm.info("Audio Session aktiviert (interruptSpokenAudioAndMixWithOthers)")
            return true
        } catch {
            Logger.alarm.notice("interruptSpokenAudioAndMixWithOthers fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
        }
        
        // Versuch 3: Ohne Optionen (letzter Versuch)
        do {
            try audioSession.setCategory(.playback, mode: .default, options: [])
            try audioSession.setActive(true, options: [])
            Logger.alarm.info("Audio Session aktiviert (ohne Optionen)")
            return true
        } catch {
            Logger.alarm.error("Alle Audio Session Aktivierungsversuche fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
    
    private func observeVolumeChanges() {
        // Observer für System-Lautstärke
        try? AVAudioSession.sharedInstance().setActive(true)
        
        // Beobachte outputVolume Changes
        AVAudioSession.sharedInstance().addObserver(
            self,
            forKeyPath: "outputVolume",
            options: [.new],
            context: nil
        )
        
        Logger.alarm.debug("Volume Observer aktiviert")
    }
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "outputVolume" {
            if isPlaying {
                // Wenn Alarm läuft, setze Player-Volume auf Maximum
                enforceMaximumVolume()
            }
        }
    }
    
    private func enforceMaximumVolume() {
        // Setze Player immer auf Maximum, egal was System-Volume ist
        audioPlayer?.volume = 1.0
        Logger.alarm.debug("Lautstärke auf MAXIMUM erzwungen")
    }
    
    func startMonitoring() {
        checkTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkAlarms()
        }
        RunLoop.current.add(checkTimer!, forMode: .common)
        Logger.alarm.info("Alarm-Überwachung gestartet")
    }
    
    var alarmsToCheck: [Alarm] = []
    
    func updateAlarms(_ alarms: [Alarm]) {
        alarmsToCheck = alarms
    }

    private func loadSavedAlarmsFromDefaults() -> [Alarm] {
        guard let data = UserDefaults.standard.data(forKey: "savedAlarms"),
              let decoded = try? JSONDecoder().decode([Alarm].self, from: data) else {
            return []
        }
        return decoded
    }

    private func loadScheduledAlarmSnapshots() -> [UUID: Alarm] {
        guard let data = UserDefaults.standard.data(forKey: scheduledAlarmSnapshotsKey),
              let decoded = try? JSONDecoder().decode([Alarm].self, from: data) else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0) })
    }

    private func persistScheduledAlarmSnapshot(_ alarm: Alarm) {
        var snapshots = loadScheduledAlarmSnapshots()
        snapshots[alarm.id] = alarm
        if let encoded = try? JSONEncoder().encode(Array(snapshots.values)) {
            UserDefaults.standard.set(encoded, forKey: scheduledAlarmSnapshotsKey)
        }
    }

    private func removeScheduledAlarmSnapshot(id: UUID) {
        var snapshots = loadScheduledAlarmSnapshots()
        snapshots[id] = nil
        if snapshots.isEmpty {
            UserDefaults.standard.removeObject(forKey: scheduledAlarmSnapshotsKey)
            return
        }
        if let encoded = try? JSONEncoder().encode(Array(snapshots.values)) {
            UserDefaults.standard.set(encoded, forKey: scheduledAlarmSnapshotsKey)
        }
    }

    private func notificationPayload(for alarm: Alarm) -> [String: Any] {
        [
            "alarmID": alarm.id.uuidString,
            "alarmTime": alarm.time.timeIntervalSince1970,
            "alarmLabel": alarm.label,
            "alarmSoundName": alarm.soundName,
            "alarmVolume": NSNumber(value: alarm.volume)
        ]
    }

    private func alarmFromNotificationPayload(id alarmID: UUID, userInfo: [AnyHashable: Any]) -> Alarm? {
        guard let label = userInfo["alarmLabel"] as? String,
              let soundName = userInfo["alarmSoundName"] as? String else {
            return nil
        }

        let timeInterval = (userInfo["alarmTime"] as? TimeInterval) ?? Date().timeIntervalSince1970
        let volume: Float
        if let number = userInfo["alarmVolume"] as? NSNumber {
            volume = number.floatValue
        } else if let doubleValue = userInfo["alarmVolume"] as? Double {
            volume = Float(doubleValue)
        } else {
            volume = 1.0
        }

        return Alarm(
            id: alarmID,
            time: Date(timeIntervalSince1970: timeInterval),
            isEnabled: true,
            label: label,
            repeatDays: [],
            soundName: soundName,
            volume: volume
        )
    }

    private func resolveAlarm(id alarmID: UUID, userInfo: [AnyHashable: Any] = [:]) -> Alarm? {
        if let alarm = alarmsToCheck.first(where: { $0.id == alarmID }) {
            return alarm
        }
        if let alarm = loadSavedAlarmsFromDefaults().first(where: { $0.id == alarmID }) {
            return alarm
        }
        if let alarm = loadScheduledAlarmSnapshots()[alarmID] {
            return alarm
        }
        if let alarm = alarmFromNotificationPayload(id: alarmID, userInfo: userInfo) {
            return alarm
        }
        if let alarm = loadActiveAlarmState(), alarm.id == alarmID {
            return alarm
        }
        return nil
    }

    private func notificationSound(for alarm: Alarm) -> UNNotificationSound {
        let soundFileName = alarm.soundName.replacingOccurrences(of: ".caf", with: "") + ".caf"
        if Bundle.main.url(forResource: alarm.soundName.replacingOccurrences(of: ".caf", with: ""), withExtension: "caf") != nil {
            return UNNotificationSound(named: UNNotificationSoundName(rawValue: soundFileName))
        }
        Logger.notifications.notice("Notification Sound nicht gefunden (\(soundFileName, privacy: .public)), nutze default")
        return .default
    }

    private func notificationRequest(for alarm: Alarm, identifier: String, badge: Int, timeInterval: TimeInterval) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "⏰ WakeFlow Wecker"
        content.body = alarm.label
        content.sound = notificationSound(for: alarm)
        content.categoryIdentifier = "ALARM_CATEGORY"
        content.badge = NSNumber(value: badge)
        content.interruptionLevel = .timeSensitive
        content.userInfo = notificationPayload(for: alarm)

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: timeInterval, repeats: false)
        return UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
    }

    private func localFireKey(for alarm: Alarm, fireDate: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
        return "\(alarm.id.uuidString)-\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)-\(components.hour ?? 0)-\(components.minute ?? 0)"
    }

    private func shouldTriggerLocalAlarm(_ alarm: Alarm, now: Date) -> Bool {
        let calendar = Calendar.current
        let alarmComponents = calendar.dateComponents([.hour, .minute], from: alarm.time)
        guard let hour = alarmComponents.hour,
              let minute = alarmComponents.minute,
              let fireDate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) else {
            return false
        }

        let currentWeekday = calendar.component(.weekday, from: now)
        guard alarm.repeatDays.isEmpty || alarm.repeatDays.contains(currentWeekday) else {
            return false
        }

        let elapsed = now.timeIntervalSince(fireDate)
        guard elapsed >= 0 && elapsed < localAlarmFireWindow else {
            return false
        }

        let key = localFireKey(for: alarm, fireDate: fireDate)
        guard !firedLocalAlarmKeys.contains(key) else {
            return false
        }

        firedLocalAlarmKeys.insert(key)
        return true
    }
    
    private func checkAlarms() {
        if #available(iOS 26.0, *) {
            return
        }

        let now = Date()
        let calendar = Calendar.current
        let currentComponents = calendar.dateComponents([.hour, .minute, .second, .weekday], from: now)
        
        // Debug: Zeige aktuelle Zeit
        if currentComponents.second == 0 {
            Logger.alarm.debug("Checking alarms at \(currentComponents.hour ?? 0, privacy: .public):\(currentComponents.minute ?? 0, privacy: .public) Weekday: \(currentComponents.weekday ?? 0, privacy: .public)")
            Logger.alarm.debug("Active alarms count: \(self.alarmsToCheck.filter { $0.isEnabled }.count, privacy: .public)")
        }
        
        for alarm in alarmsToCheck where alarm.isEnabled {
            if shouldTriggerLocalAlarm(alarm, now: now), currentAlarmID != alarm.id {
                Logger.alarm.notice("ALARM TRIGGERED: \(alarm.label, privacy: .public)")
                playAlarm(alarm)
                currentAlarmID = alarm.id
            }
        }
    }
    
    func playAlarm(_ alarm: Alarm, shouldNotify: Bool = true) {
        // #region agent log
        let symbols = Thread.callStackSymbols.prefix(8).joined(separator: "\n")
        PhantomDebug.log("playAlarm", "ENTER",
            data: [
                "alarmID": alarm.id.uuidString,
                "label": alarm.label,
                "alarmTime": alarm.time.description,
                "now": Date().description,
                "isAlreadyPlaying": isPlaying,
                "shouldNotify": shouldNotify,
                "callStack": symbols
            ])
        // #endregion
        Logger.alarm.info("Versuche Sound zu laden: \(alarm.soundName, privacy: .public)")

        guard let soundURL = Bundle.main.url(
            forResource: alarm.soundName.replacingOccurrences(of: ".caf", with: ""),
            withExtension: "caf"
        ) else {
            Logger.alarm.error("Sound nicht gefunden: \(alarm.soundName, privacy: .public)")
            Logger.alarm.error("Gesuchter Dateiname: \(alarm.soundName.replacingOccurrences(of: ".caf", with: ""), privacy: .public)")
            return
        }
        
        currentSoundURL = soundURL
        currentAlarmID = alarm.id
        alarmStartTime = Date()
        targetVolume = alarm.volume // Setze Ziel-Lautstärke
        isPlaying = true
        
        // Speichere Alarm-Status persistent (für App-Neustart nach Kill)
        saveActiveAlarmState(alarm)
        
        Logger.alarm.notice("Alarm startet: \(alarm.label, privacy: .public)")
        Logger.alarm.info("Sound geladen: \(soundURL.lastPathComponent, privacy: .public)")
        Logger.alarm.info("Ziel-Lautstärke: \(Int(self.targetVolume * 100), privacy: .public)% (wird erzwungen)")
        
        // 1. Starte Audio ZUERST (das ist dein Sound!)
        playSoundLoop()
        
        // 2. Starte Volume-Enforce Timer (prüft alle 0.1 Sekunden!)
        startVolumeEnforcement()
        
        // 3. Starte kontinuierliche Vibration
        startVibration()
        
        // Notification-Spam ist ab der AlarmKit-Migration deaktiviert.
        // shouldNotify bleibt vorerst in der Signatur, damit bestehende Call-Sites klein bleiben.
        
        // Stoppe nach 10 Minuten automatisch
        stopTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: false) { [weak self] _ in
            Logger.alarm.notice("10 Minuten vorbei - Alarm stoppt automatisch")
            self?.stopAlarm()
        }
    }
    
    private func startVibration() {
        // Starte sofort eine Vibration
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.error) // Kräftige Vibration
        
        // Timer für kontinuierliche Vibration (alle 2 Sekunden)
        vibrationTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self, self.isPlaying else { return }
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.error) // Kräftige Vibration wie bei Fehler
            Logger.alarm.debug("Vibration ausgelöst")
        }
        
        RunLoop.current.add(vibrationTimer!, forMode: .common)
        Logger.alarm.info("Kontinuierliche Vibration gestartet (alle 2s)")
    }
    
    private func startVolumeEnforcement() {
        // Speichere aktuelle System-Volume
        let audioSession = AVAudioSession.sharedInstance()
        originalSystemVolume = audioSession.outputVolume
        
        // Setze System-Volume auf skalierte Lautstärke (0.25-0.8 → 0-1.0)
        let scaledVolume = internalToSystemVolume(targetVolume)
        setSystemVolume(scaledVolume)
        
        // Timer der KONTINUIERLICH SYSTEM-Volume auf Ziel-Lautstärke setzt
        volumeEnforceTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self, self.isPlaying else { return }
            
            // Konvertiere targetVolume (0.25-0.8) zu System-Volume (0-1.0)
            let scaledTargetVolume = self.internalToSystemVolume(self.targetVolume)
            let minAcceptableVolume = scaledTargetVolume - 0.01
            
            // 1. Prüfe System-Volume und erzwinge es IMMER auf scaledTargetVolume
            let currentSystemVolume = AVAudioSession.sharedInstance().outputVolume
            if currentSystemVolume < minAcceptableVolume {
                Logger.alarm.debug("System-Volume geändert: \(Int(currentSystemVolume * 100), privacy: .public)% → zurück auf \(Int(scaledTargetVolume * 100), privacy: .public)% (Intern \(Int(self.targetVolume * 100), privacy: .public)%)")
                self.setSystemVolume(scaledTargetVolume)
            }
            
            // 2. Prüfe ob Player noch spielt und auf Maximum steht
            if let player = self.audioPlayer {
                // Stelle sicher dass Player-Volume IMMER auf 1.0 bleibt
                if player.volume < 1.0 {
                    player.volume = 1.0
                    Logger.alarm.debug("Player-Volume zurückgesetzt auf MAXIMUM (1.0)")
                }
                
                // 3. Prüfe ob Player noch spielt
                if !player.isPlaying {
                    Logger.alarm.notice("Player gestoppt - aktiviere Audio Session und starte neu")
                    // Versuche Audio Session aggressiv zu aktivieren bevor wir neu starten
                    _ = self.forceActivateAudioSession()
                    let restarted = player.play()
                    Logger.alarm.notice("Player Neustart: \(restarted ? "Erfolgreich" : "Fehlgeschlagen", privacy: .public)")
                }
            }
            
            // 4. Halte Audio Session aktiv (mit duckOthers für bessere Kompatibilität)
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.duckOthers])
                try AVAudioSession.sharedInstance().setActive(true, options: [])
            } catch {
                // Silent fail - wird beim nächsten Player-Stopp durch forceActivateAudioSession gehandhabt
            }
        }
        
        RunLoop.current.add(volumeEnforceTimer!, forMode: .common)
        Logger.alarm.info("Volume-Enforcement Timer gestartet (alle 0.05s)")
        Logger.alarm.debug("Interne Lautstärke: \(Int(self.targetVolume * 100), privacy: .public)% (0.25-0.8)")
        Logger.alarm.debug("System-Volume erscheint als: \(Int(scaledVolume * 100), privacy: .public)% (skaliert auf 0-1.0)")
    }
    
    private func setSystemVolume(_ volume: Float) {
        // Nutze MPVolumeView um System-Volume zu setzen
        let volumeView = MPVolumeView(frame: .zero)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            if let slider = volumeView.subviews.first(where: { $0 is UISlider }) as? UISlider {
                slider.value = volume
                Logger.alarm.debug("System-Volume gesetzt auf: \(volume, privacy: .public)")
            }
        }
    }
    
    // LEGACY — nicht mehr verwendet ab AlarmKit-Migration. Wird in Phase 2 entfernt.
    private func sendSystemAlarmNotification(for alarm: Alarm) {
        // Reset counter
        notificationCount = 0
        
        // Sende erste Notification SOFORT
        sendSingleNotification(for: alarm, count: notificationCount)
        notificationCount += 1
        
        // Erstelle auch scheduled notifications als Backup (funktionieren auch wenn App gekillt wird!)
        scheduleBackupNotifications(for: alarm)
        
        // Timer für weitere Notifications (alle 3 Sekunden)
        notificationTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.sendSingleNotification(for: alarm, count: self.notificationCount)
            self.notificationCount += 1
            
            Logger.notifications.debug("Notification #\(self.notificationCount, privacy: .public) gesendet")
            
            // Stoppe nach 100 Notifications (5 Minuten)
            if self.notificationCount >= 100 {
                self.notificationTimer?.invalidate()
                self.notificationTimer = nil
                Logger.notifications.notice("Notification Timer gestoppt (100 erreicht)")
            }
        }
        
        RunLoop.current.add(notificationTimer!, forMode: .common)
        Logger.notifications.info("Notification Timer gestartet (alle 3s)")
        Logger.notifications.info("Erste Notification SOFORT gesendet")
    }
    
    // LEGACY — nicht mehr verwendet ab AlarmKit-Migration. Wird in Phase 2 entfernt.
    private func scheduleBackupNotifications(for alarm: Alarm) {
        // Entferne nur vorherige Backup-Notifications für genau diesen Alarm
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            // Entferne alte Backup-Requests für diesen Alarm
            let existingBackupIDs = requests
                .filter { $0.identifier.contains("backup-alarm-\(alarm.id.uuidString)-") }
                .map { $0.identifier }

            if !existingBackupIDs.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: existingBackupIDs)
            }

            // iOS Limit: max 64 pending notifications pro App
            let maxPending = 64
            let currentPending = requests.count - existingBackupIDs.count
            let availableSlots = max(0, maxPending - currentPending)
            let desired = 60
            let scheduleCount = min(desired, availableSlots)

            if scheduleCount == 0 {
                Logger.notifications.notice("Keine verfügbaren Slots für Backup-Notifications (Limit erreicht)")
                return
            }

            // Erstelle scheduled notifications (alle 3 Sekunden)
            for i in 1...scheduleCount {
                let content = UNMutableNotificationContent()
                content.title = "⏰ \(alarm.label)"
                content.body = "Wecker klingelt - Öffne die App zum Stoppen"
                content.interruptionLevel = .timeSensitive // [CRITICAL MESSAGING DEAKTIVIERT — war .critical]
                content.sound = self.notificationSound(for: alarm)
                content.badge = NSNumber(value: i)
                content.categoryIdentifier = "ALARM_CATEGORY"
                content.userInfo = self.notificationPayload(for: alarm)

                let timeInterval = TimeInterval(i * 3)
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: timeInterval, repeats: false)

                let request = UNNotificationRequest(
                    identifier: "backup-alarm-\(alarm.id.uuidString)-\(i)",
                    content: content,
                    trigger: trigger
                )

                center.add(request) { error in
                    if let error = error {
                        Logger.notifications.error("Backup Notification \(i, privacy: .public) Fehler: \(error.localizedDescription, privacy: .public)")
                    } else if i == 1 || i == scheduleCount {
                        Logger.notifications.info("Backup Notification \(i, privacy: .public) geplant für +\(timeInterval, privacy: .public)s")
                    }
                }
            }

            Logger.notifications.info("\(scheduleCount, privacy: .public) Backup Notifications geplant (Sound + Vibration)")
        }
    }
    
    // LEGACY — nicht mehr verwendet ab AlarmKit-Migration. Wird in Phase 2 entfernt.
    private func sendSingleNotification(for alarm: Alarm, count: Int) {
        // Wenn pausiert, sende keine Notification
        guard !notificationsPaused else {
            Logger.notifications.debug("Notifications sind pausiert (App ist offen)")
            return
        }
        
        let content = UNMutableNotificationContent()
        content.title = "⏰ \(alarm.label)"
        content.body = "Wecker klingelt - Öffne die App zum Stoppen"
        
        // [CRITICAL MESSAGING DEAKTIVIERT] — Standard interruption
        content.interruptionLevel = .timeSensitive // [CRITICAL MESSAGING DEAKTIVIERT — war .critical]

        // [CRITICAL MESSAGING DEAKTIVIERT] — Standard sound
        content.sound = notificationSound(for: alarm)
        
        // Badge
        content.badge = NSNumber(value: count + 1)
        
        // Category mit Action
        content.categoryIdentifier = "ALARM_CATEGORY"
        content.userInfo = notificationPayload(for: alarm)
        
        // Unique identifier für jede Notification
        let request = UNNotificationRequest(
            identifier: "wakeflow-alarm-\(alarm.id.uuidString)-\(count)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil // Sofort senden!
        )
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                Logger.notifications.error("Notification \(count, privacy: .public) Fehler: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
    
    private func playSoundLoop() {
        guard let soundURL = currentSoundURL else { return }

        // WICHTIG: Audio Session AGGRESSIV aktivieren bevor Player erstellt wird
        let sessionActivated = forceActivateAudioSession()
        if !sessionActivated {
            Logger.alarm.notice("Audio Session konnte nicht aktiviert werden - versuche trotzdem zu spielen")
        }
        
        do {
            // Stop existing player
            audioPlayer?.stop()
            
            // Create new player
            audioPlayer = try AVAudioPlayer(contentsOf: soundURL)
            audioPlayer?.delegate = self
            audioPlayer?.numberOfLoops = -1 // Endlos Loop
            audioPlayer?.volume = 1.0 // MAXIMUM! System-Volume regelt die Lautstärke
            
            // Prepare and play
            audioPlayer?.prepareToPlay()
            
            // Start playback
            let success = audioPlayer?.play() ?? false
            
            if success {
                Logger.alarm.notice("Sound spielt in ENDLOS LOOP mit Player-Volume 1.0 (MAX)")
                Logger.alarm.debug("System-Lautstärke: \(Int(self.targetVolume * 100), privacy: .public)% (wird ERZWUNGEN)")
            } else {
                Logger.alarm.error("Sound konnte nicht abgespielt werden - Audio Session Status: \(sessionActivated, privacy: .public)")
            }
        } catch {
            Logger.alarm.error("Audio Player Fehler: \(error.localizedDescription, privacy: .public)")
        }
    }
    
    func getCurrentAlarmID() -> UUID? {
        return currentAlarmID
    }
    
    func stopAlarm() {
        // Stoppe Audio
        audioPlayer?.stop()
        audioPlayer = nil
        
        // Stoppe alle Timer
        stopTimer?.invalidate()
        stopTimer = nil
        volumeEnforceTimer?.invalidate()
        volumeEnforceTimer = nil
        notificationTimer?.invalidate()
        notificationTimer = nil
        vibrationTimer?.invalidate()
        vibrationTimer = nil
        
        // Stelle System-Volume wieder her
        if originalSystemVolume > 0 {
            setSystemVolume(originalSystemVolume)
            Logger.alarm.debug("System-Volume wiederhergestellt: \(self.originalSystemVolume, privacy: .public)")
        }
        
        isPlaying = false
        
        // Remove ALL notifications (delivered + pending!)
        if let alarmID = currentAlarmID {
            // Stoppe AlarmKit-Alert; wiederkehrende Alarme bleiben geplant
            if let alarmModel = alarmsToCheck.first(where: { $0.id == alarmID }),
               alarmModel.isEnabled,
               !alarmModel.repeatDays.isEmpty {
                if #available(iOS 26.0, *) {
                    try? systemAlarmManager.stop(id: alarmID)
                }
                persistScheduledAlarmSnapshot(alarmModel)
                scheduleSystemAlarm(for: alarmModel)
            } else {
                cancelSystemAlarm(id: alarmID, stopIfAlerting: true)
                removeScheduledAlarmSnapshot(id: alarmID)
            }

            // Phase 1 — Synchronous removal of all KNOWN identifier patterns
            var knownIdentifiers: [String] = []
            for i in 0...100 {
                // scheduleAlarm — einmaliger Alarm
                knownIdentifiers.append("\(alarmID.uuidString)-\(i)")
                // scheduleAlarm — wiederkehrender Alarm (pro Wochentag)
                for day in 1...7 {
                    knownIdentifiers.append("\(alarmID.uuidString)-\(day)-\(i)")
                }
                // playAlarm — Backup Notifications
                knownIdentifiers.append("backup-alarm-\(alarmID.uuidString)-\(i)")
            }
            // scheduleBackupNotification — einzelne repeating Backup-Notification
            knownIdentifiers.append("backup-alarm-\(alarmID.uuidString)")
            for day in 1...7 {
                knownIdentifiers.append("backup-alarm-\(alarmID.uuidString)-\(day)")
            }

            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: knownIdentifiers)
            center.removeDeliveredNotifications(withIdentifiers: knownIdentifiers)
            Logger.notifications.debug("\(knownIdentifiers.count, privacy: .public) bekannte Notification-IDs synchron entfernt")

            // Phase 2 — Asynchronous catch-all for timestamp-based IDs (sendSingleNotification)
            center.getPendingNotificationRequests { requests in
                let leftover = requests
                    .filter { $0.identifier.contains(alarmID.uuidString) }
                    .map { $0.identifier }
                if !leftover.isEmpty {
                    center.removePendingNotificationRequests(withIdentifiers: leftover)
                    Logger.notifications.debug("\(leftover.count, privacy: .public) weitere pending Notifications entfernt (catch-all via UUID)")
                }
            }
        }
        
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        DispatchQueue.main.async {
            UIApplication.shared.applicationIconBadgeNumber = 0
        }
        
        // Lösche gespeicherten Alarm-Status
        clearActiveAlarmState()
        
        currentAlarmID = nil
        currentSoundURL = nil
        alarmStartTime = nil
        notificationCount = 0
        notificationsPaused = false // Reset Pause-Status
        targetVolume = 1.0 // Reset auf Standard
        
        Logger.alarm.notice("Alarm gestoppt (Audio + Notifications + Volume-Enforcement)")
    }
    
    // Pausiere Notifications wenn App geöffnet wird
    func pauseNotifications() {
        guard isPlaying else { return }
        notificationsPaused = true
        Logger.notifications.debug("Notifications pausiert (App wurde geöffnet)")
    }
    
    // Setze Notifications fort wenn App geschlossen wird
    func resumeNotifications() {
        guard isPlaying else { return }
        notificationsPaused = false
        Logger.notifications.debug("Notifications fortgesetzt (App wurde geschlossen)")
    }

    func shouldShowAppKeepAliveWarning() -> Bool {
        refreshSystemAlarmAuthorization()
        return !hasAuthorizedSystemAlarms
    }

    private func refreshSystemAlarmAuthorization() {
        guard #available(iOS 26.0, *) else {
            hasAuthorizedSystemAlarms = false
            return
        }
        hasAuthorizedSystemAlarms = systemAlarmManager.authorizationState == .authorized
    }

    private func observeSystemAlarmUpdates() {
        guard #available(iOS 26.0, *) else { return }

        alarmUpdatesTask?.cancel()
        alarmUpdatesTask = Task { [weak self] in
            for await systemAlarms in AlarmKit.AlarmManager.shared.alarmUpdates {
                await MainActor.run {
                    self?.handleSystemAlarmUpdates(systemAlarms)
                }
            }
        }
    }

    @available(iOS 26.0, *)
    private func handleSystemAlarmUpdates(_ systemAlarms: [AlarmKit.Alarm]) {
        // #region agent log
        PhantomDebug.log("handleSystemAlarmUpdates", "update batch",
            data: [
                "count": systemAlarms.count,
                "currentAlarmID": currentAlarmID?.uuidString ?? "<nil>",
                "now": Date().description,
                "ids": systemAlarms.map { "\($0.id.uuidString):\(String(describing: $0.state))" }
            ])
        // #endregion
        for systemAlarm in systemAlarms where systemAlarm.state == .alerting {
            guard currentAlarmID != systemAlarm.id else { continue }
            // #region agent log
            let resolved = resolveAlarm(id: systemAlarm.id)
            PhantomDebug.log("handleSystemAlarmUpdates", "alerting detected",
                data: [
                    "alarmKitID": systemAlarm.id.uuidString,
                    "schedule": String(describing: systemAlarm.schedule),
                    "resolved": resolved != nil,
                    "resolvedLabel": resolved?.label ?? "<nil>",
                    "resolvedTime": resolved?.time.description ?? "<nil>",
                    "resolvedRepeatDays": Array(resolved?.repeatDays ?? []).sorted(),
                    "now": Date().description
                ])
            // #endregion
            guard let alarm = resolved else {
                Logger.alarm.error("AlarmKit meldet alerting, aber Alarmdaten fehlen: \(systemAlarm.id.uuidString, privacy: .public)")
                continue
            }

            Logger.alarm.notice("AlarmKit ALERTING erkannt: \(alarm.label, privacy: .public)")
            playAlarm(alarm, shouldNotify: false)
        }
    }

    @available(iOS 26.0, *)
    private func localeWeekday(from appWeekday: Int) -> Locale.Weekday? {
        switch appWeekday {
        case 1: return .sunday
        case 2: return .monday
        case 3: return .tuesday
        case 4: return .wednesday
        case 5: return .thursday
        case 6: return .friday
        case 7: return .saturday
        default: return nil
        }
    }

    private func nextOneTimeAlarmDate(for alarm: Alarm, now: Date = Date()) -> Date? {
        let calendar = Calendar.current
        let targetComponents = calendar.dateComponents([.year, .month, .day], from: now)
        var alarmComponents = targetComponents
        let timeComponents = calendar.dateComponents([.hour, .minute], from: alarm.time)
        alarmComponents.hour = timeComponents.hour
        alarmComponents.minute = timeComponents.minute
        alarmComponents.second = 0

        guard var alarmDate = calendar.date(from: alarmComponents) else {
            return nil
        }

        let firstAttempt = alarmDate
        var didAddDay = false
        if alarmDate <= now {
            alarmDate = calendar.date(byAdding: .day, value: 1, to: alarmDate) ?? alarmDate
            didAddDay = true
        }
        // #region agent log
        PhantomDebug.log("nextOneTimeAlarmDate", "computed",
            data: [
                "alarmID": alarm.id.uuidString,
                "alarmLabel": alarm.label,
                "alarmTimeRaw": alarm.time.description,
                "alarmTimeRawEpoch": alarm.time.timeIntervalSince1970,
                "now": now.description,
                "extractedHour": timeComponents.hour ?? -1,
                "extractedMinute": timeComponents.minute ?? -1,
                "firstAttempt": firstAttempt.description,
                "didAddDay": didAddDay,
                "result": alarmDate.description,
                "resultEpoch": alarmDate.timeIntervalSince1970,
                "timezone": calendar.timeZone.identifier,
                "timezoneOffset": calendar.timeZone.secondsFromGMT()
            ])
        // #endregion
        return alarmDate
    }

    @available(iOS 26.0, *)
    private func systemAlarmSchedule(for alarm: Alarm) -> AlarmKit.Alarm.Schedule? {
        let calendar = Calendar.current
        let timeComponents = calendar.dateComponents([.hour, .minute], from: alarm.time)
        let hour = min(max(timeComponents.hour ?? 0, 0), 23)
        let minute = min(max(timeComponents.minute ?? 0, 0), 59)

        if alarm.repeatDays.isEmpty {
            guard let date = nextOneTimeAlarmDate(for: alarm) else {
                return nil
            }
            return .fixed(date)
        }

        let weekdays = alarm.repeatDays.compactMap { localeWeekday(from: $0) }
        guard !weekdays.isEmpty else {
            return nil
        }

        let relative = AlarmKit.Alarm.Schedule.Relative(
            time: .init(hour: hour, minute: minute),
            repeats: .weekly(weekdays)
        )
        return .relative(relative)
    }

    @available(iOS 26.0, *)
    private func systemAlarmAttributes(for alarm: Alarm) -> AlarmKit.AlarmAttributes<WakeFlowAlarmMetadata> {
        let stopButton = AlarmButton(
            text: LocalizedStringResource(stringLiteral: "Stoppen"),
            textColor: .white,
            systemImageName: "stop.fill"
        )
        let secondaryButton = AlarmButton(
            text: LocalizedStringResource(stringLiteral: "WakeFlow öffnen"),
            textColor: .white,
            systemImageName: "arrow.up.right.square.fill"
        )

        let alert = AlarmPresentation.Alert(
            title: LocalizedStringResource(stringLiteral: alarm.label),
            stopButton: stopButton,
            secondaryButton: secondaryButton,
            secondaryButtonBehavior: .custom
        )

        let presentation = AlarmPresentation(alert: alert)
        let metadata = WakeFlowAlarmMetadata(label: alarm.label, soundName: alarm.soundName)

        return AlarmAttributes(
            presentation: presentation,
            metadata: metadata,
            tintColor: .red
        )
    }

    private func scheduleSystemAlarm(for alarm: Alarm) {
        guard #available(iOS 26.0, *) else {
            usesSystemAlarmByID[alarm.id] = false
            return
        }

        Task { @MainActor [weak self] in
            guard let self = self else { return }

            do {
                var authState = self.systemAlarmManager.authorizationState
                if authState == .notDetermined {
                    authState = try await self.systemAlarmManager.requestAuthorization()
                }
                self.hasAuthorizedSystemAlarms = (authState == .authorized)

                guard self.loadScheduledAlarmSnapshots()[alarm.id]?.isEnabled == true else {
                    Logger.alarm.info("Alarm wurde während der AlarmKit-Anfrage deaktiviert: \(alarm.label, privacy: .public)")
                    return
                }

                guard authState == .authorized else {
                    self.usesSystemAlarmByID[alarm.id] = false
                    Logger.alarm.notice("AlarmKit nicht autorisiert - kein iOS-26-Notification-Fallback: \(alarm.label, privacy: .public)")
                    return
                }

                guard let schedule = self.systemAlarmSchedule(for: alarm) else {
                    self.usesSystemAlarmByID[alarm.id] = false
                    Logger.alarm.notice("AlarmKit Schedule ungültig - kein iOS-26-Notification-Fallback: \(alarm.label, privacy: .public)")
                    return
                }

                let soundFileName = alarm.soundName.replacingOccurrences(of: ".caf", with: "") + ".caf"
                let sound: ActivityKit.AlertConfiguration.AlertSound
                if Bundle.main.url(
                    forResource: alarm.soundName.replacingOccurrences(of: ".caf", with: ""),
                    withExtension: "caf"
                ) != nil {
                    sound = .named(soundFileName)
                } else {
                    sound = .default
                    Logger.alarm.notice("AlarmKit Sound nicht gefunden (\(soundFileName, privacy: .public)), nutze default")
                }

                let configuration = AlarmKit.AlarmManager.AlarmConfiguration<WakeFlowAlarmMetadata>.alarm(
                    schedule: schedule,
                    attributes: self.systemAlarmAttributes(for: alarm),
                    secondaryIntent: OpenWakeFlowFromAlarmIntent(alarmID: alarm.id.uuidString),
                    sound: sound
                )

                // #region agent log
                let alarmsBefore = (try? AlarmKit.AlarmManager.shared.alarms) ?? []
                PhantomDebug.log("scheduleSystemAlarm", "AlarmKit alarms BEFORE schedule",
                    data: [
                        "count": alarmsBefore.count,
                        "ids": alarmsBefore.map { "\($0.id.uuidString):\(String(describing: $0.state)):\(String(describing: $0.schedule))" }
                    ])
                PhantomDebug.log("scheduleSystemAlarm", "submitting to AlarmKit",
                    data: [
                        "alarmID": alarm.id.uuidString,
                        "alarmLabel": alarm.label,
                        "alarmTimeRaw": alarm.time.description,
                        "alarmRepeatDays": Array(alarm.repeatDays).sorted(),
                        "schedule": String(describing: schedule),
                        "now": Date().description,
                        "soundFile": soundFileName
                    ])
                // #endregion
                try? self.systemAlarmManager.cancel(id: alarm.id)
                _ = try await self.systemAlarmManager.schedule(id: alarm.id, configuration: configuration)

                // #region agent log
                let alarmsAfter = (try? AlarmKit.AlarmManager.shared.alarms) ?? []
                PhantomDebug.log("scheduleSystemAlarm", "AlarmKit alarms AFTER schedule",
                    data: [
                        "count": alarmsAfter.count,
                        "ids": alarmsAfter.map { "\($0.id.uuidString):\(String(describing: $0.state)):\(String(describing: $0.schedule))" }
                    ])
                // #endregion
                self.usesSystemAlarmByID[alarm.id] = true
                Logger.alarm.notice("AlarmKit Alarm geplant: \(alarm.label, privacy: .public) [\(alarm.id.uuidString, privacy: .public)]")
            } catch {
                self.usesSystemAlarmByID[alarm.id] = false
                self.refreshSystemAlarmAuthorization()
                Logger.alarm.error("AlarmKit Scheduling Fehler (\(alarm.label, privacy: .public)): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func cancelSystemAlarm(id: UUID, stopIfAlerting: Bool = false) {
        guard #available(iOS 26.0, *) else { return }

        // #region agent log
        var stopErr: String? = nil
        var cancelErr: String? = nil
        // #endregion
        if stopIfAlerting {
            do { try systemAlarmManager.stop(id: id) }
            catch { stopErr = error.localizedDescription }
        }
        do { try systemAlarmManager.cancel(id: id) }
        catch { cancelErr = error.localizedDescription }
        // #region agent log
        PhantomDebug.log("cancelSystemAlarm", "cancel attempt",
            data: [
                "id": id.uuidString,
                "stopIfAlerting": stopIfAlerting,
                "stopError": stopErr ?? "<none>",
                "cancelError": cancelErr ?? "<none>"
            ])
        // #endregion
        usesSystemAlarmByID[id] = nil
    }
    
    // WICHTIG: Plane einen Alarm (wird beim App-Start für alle aktiven Alarme aufgerufen!)
    func scheduleAlarm(_ alarm: Alarm) {
        cancelAlarm(alarm)
        
        guard alarm.isEnabled else {
            removeScheduledAlarmSnapshot(id: alarm.id)
            return
        }

        persistScheduledAlarmSnapshot(alarm)
        resetAppKillWarning()

        // Silent Audio aufrechterhalten, damit AVAudioPlayer.play() im Background nicht fehlschlägt.
        // Ohne aktiven Player verliert die App ihre Background-Audio-Privilegien, und beim
        // AlarmKit-Trigger schlägt play() fehl, bis die App wieder in den Vordergrund kommt.
        startSilentAudio(forceStart: true)

        if #available(iOS 26.0, *) {
            scheduleSystemAlarm(for: alarm)
        } else {
            scheduleNotificationFallbacks(for: alarm)
        }
    }

    private func scheduleNotificationFallbacks(for alarm: Alarm) {
        Logger.notifications.info("Plane Notification-Fallback für: \(alarm.label, privacy: .public)")

        // WICHTIG: Starte Silent Audio um App wach zu halten
        startSilentAudio(forceStart: true)

        let calendar = Calendar.current
        let components = calendar.dateComponents([.hour, .minute], from: alarm.time)
        let notificationCount = 12
        let intervalSeconds: TimeInterval = 5.0
        let center = UNUserNotificationCenter.current()

        center.getPendingNotificationRequests { requests in
            let maxPending = 64
            let currentPending = requests.count
            let availableSlots = max(0, maxPending - currentPending)
            let scheduleCount = min(notificationCount, availableSlots)

            if scheduleCount == 0 {
                Logger.notifications.notice("Keine Slots für Notification-Fallback verfügbar")
            }

            if alarm.repeatDays.isEmpty {
                let now = Date()

                guard let alarmDate = self.nextOneTimeAlarmDate(for: alarm, now: now) else {
                    Logger.notifications.error("Konnte Alarm-Datum nicht erstellen")
                    return
                }

                let timeInterval = alarmDate.timeIntervalSince(now)
                Logger.notifications.info("Alarm geplant für: \(alarmDate.description, privacy: .public)")
                Logger.notifications.info("In: \(timeInterval, privacy: .public)s (\(timeInterval / 60, privacy: .public) min)")

                guard timeInterval >= 1 else {
                    Logger.notifications.error("TimeInterval zu kurz: \(timeInterval, privacy: .public)")
                    return
                }

                if scheduleCount > 0 {
                    for i in 0..<scheduleCount {
                        let finalInterval = timeInterval + intervalSeconds * Double(i)
                        let request = self.notificationRequest(
                            for: alarm,
                            identifier: "\(alarm.id.uuidString)-\(i)",
                            badge: i + 1,
                            timeInterval: finalInterval
                        )

                        UNUserNotificationCenter.current().add(request) { error in
                            if let error = error {
                                Logger.notifications.error("Fehler beim Planen (\(i, privacy: .public)): \(error.localizedDescription, privacy: .public)")
                            } else if i == 0 {
                                Logger.notifications.info("Benachrichtigung \(i, privacy: .public) geplant in \(finalInterval, privacy: .public)s mit Sound")
                            }
                        }
                    }
                }
            } else {
                let now = Date()

                for day in alarm.repeatDays {
                    var dayComponents = components
                    dayComponents.weekday = day
                    dayComponents.second = 0

                    guard let nextAlarmDate = calendar.nextDate(after: now, matching: dayComponents, matchingPolicy: .nextTime) else {
                        Logger.notifications.error("Konnte nächstes Datum für Tag \(day, privacy: .public) nicht finden")
                        continue
                    }

                    let timeInterval = nextAlarmDate.timeIntervalSince(now)
                    Logger.notifications.info("Wiederkehrender Alarm für Tag \(day, privacy: .public): \(nextAlarmDate.description, privacy: .public)")
                    Logger.notifications.info("In: \(timeInterval, privacy: .public)s (\(timeInterval / 60, privacy: .public) min)")

                    guard timeInterval >= 1 else {
                        Logger.notifications.error("TimeInterval zu kurz für Tag \(day, privacy: .public): \(timeInterval, privacy: .public)")
                        continue
                    }

                    if scheduleCount > 0 {
                        for i in 0..<scheduleCount {
                            let finalInterval = timeInterval + intervalSeconds * Double(i)
                            let request = self.notificationRequest(
                                for: alarm,
                                identifier: "\(alarm.id.uuidString)-\(day)-\(i)",
                                badge: i + 1,
                                timeInterval: finalInterval
                            )

                            UNUserNotificationCenter.current().add(request) { error in
                                if let error = error {
                                    Logger.notifications.error("Fehler beim Planen (Tag \(day, privacy: .public), \(i, privacy: .public)): \(error.localizedDescription, privacy: .public)")
                                } else if i == 0 {
                                    Logger.notifications.info("Tag \(day, privacy: .public), Benachrichtigung \(i, privacy: .public) in \(finalInterval, privacy: .public)s mit Sound")
                                }
                            }
                        }
                    }
                }
            }

            // BACKUP: Plane auch eine loopende Notification als Fallback
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.scheduleBackupNotification(for: alarm)
            }
        }
    }
    
    func cancelAlarm(_ alarm: Alarm) {
        cancelSystemAlarm(id: alarm.id)
        removeScheduledAlarmSnapshot(id: alarm.id)

        var identifiers: [String] = []
        
        // All notification indices (0-100)
        for i in 0...100 {
            identifiers.append("\(alarm.id.uuidString)-\(i)")
            
            // All day-specific notifications
            for day in 1...7 {
                identifiers.append("\(alarm.id.uuidString)-\(day)-\(i)")
            }
            identifiers.append("backup-alarm-\(alarm.id.uuidString)-\(i)")
        }
        
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
        Logger.notifications.debug("\(identifiers.count, privacy: .public) Benachrichtigungen für Alarm gelöscht")
        
        // BACKUP: Lösche auch die Backup-Notification
        cancelBackupNotification(for: alarm)
        
        // Wenn keine aktiven Alarme mehr da sind, stoppe Silent Audio
        if !hasActiveAlarms() {
            stopSilentAudio()
        }
    }
    
    // Prüfe ob aktive Wecker vorhanden sind
    func hasActiveAlarms() -> Bool {
        return alarmsToCheck.contains(where: { $0.isEnabled })
    }
    
    // WICHTIG: Wird aufgerufen wenn User auf Notification tippt
    func triggerAlarmFromNotification(alarmID: UUID, userInfo: [AnyHashable: Any] = [:]) {
        Logger.alarm.notice("Alarm-Trigger von Notification: \(alarmID.uuidString, privacy: .public)")
        
        // Finde den Alarm in Memory, gespeicherten Weckern oder direkt aus dem Notification-Payload.
        guard let alarm = resolveAlarm(id: alarmID, userInfo: userInfo) else {
            Logger.alarm.error("Alarm nicht gefunden: \(alarmID.uuidString, privacy: .public)")
            return
        }
        
        // Starte den Alarm (nur wenn er noch nicht läuft)
        if !isPlaying {
            Logger.alarm.notice("Starte Alarm: \(alarm.label, privacy: .public)")
            playAlarm(alarm)
        } else {
            Logger.alarm.debug("Alarm läuft bereits")
        }
    }

    func handleAlarmKitOpenMarkerIfNeeded() {
        let defaults = UserDefaults.standard
        defaults.synchronize()

        guard let alarmIDString = defaults.string(forKey: WakeFlowAlarmKitLaunchMarker.alarmIDKey) else {
            return
        }

        let timestamp = defaults.object(forKey: WakeFlowAlarmKitLaunchMarker.timestampKey) as? TimeInterval
        // #region agent log
        PhantomDebug.log("handleAlarmKitOpenMarkerIfNeeded", "marker found",
            data: [
                "alarmID": alarmIDString,
                "timestamp": timestamp ?? -1,
                "markerAge": timestamp.map { Date().timeIntervalSince1970 - $0 } ?? -1,
                "isPlaying": isPlaying
            ])
        // #endregion
        defaults.removeObject(forKey: WakeFlowAlarmKitLaunchMarker.alarmIDKey)
        defaults.removeObject(forKey: WakeFlowAlarmKitLaunchMarker.timestampKey)
        defaults.synchronize()

        guard let timestamp else {
            Logger.alarm.notice("AlarmKit Open-Marker ohne Timestamp verworfen")
            return
        }

        let markerAge = Date().timeIntervalSince1970 - timestamp
        guard markerAge >= 0 && markerAge < 30 else {
            Logger.alarm.notice("AlarmKit Open-Marker zu alt verworfen: \(markerAge, privacy: .public)s")
            return
        }

        guard let alarmID = UUID(uuidString: alarmIDString) else {
            Logger.alarm.error("AlarmKit Open-Marker mit ungültiger Alarm-ID verworfen: \(alarmIDString, privacy: .public)")
            return
        }

        guard let alarm = resolveAlarm(id: alarmID) else {
            Logger.alarm.error("AlarmKit Open-Marker konnte Alarm nicht auflösen: \(alarmID.uuidString, privacy: .public)")
            return
        }

        if !isPlaying {
            Logger.alarm.notice("AlarmKit Open-Marker startet MoonView für: \(alarm.label, privacy: .public)")
            playAlarm(alarm, shouldNotify: false)
        } else {
            Logger.alarm.info("AlarmKit Open-Marker konsumiert, Alarm läuft bereits")
        }
    }
    
    // Bereite App für Background Alarme vor
    func prepareForBackgroundAlarms() {
        refreshSystemAlarmAuthorization()

        // Prüfe ob es aktive Alarme gibt
        if hasActiveAlarms() {
            Logger.lifecycle.info("App bereit für Background Alarme")
            // Audio Session ist schon in playback Mode configuriert
        }
    }
    
    // Starte stillen Audio-Stream um App im Hintergrund wach zu halten
    private func startSilentAudio(forceStart: Bool = false) {
        // Erstelle einen 1-Sekunden Stille-Sound
        let silenceURL = URL(fileURLWithPath: "/System/Library/Audio/UISounds/silence.caf")
        
        do {
            silentPlayer = try AVAudioPlayer(contentsOf: silenceURL)
            silentPlayer?.numberOfLoops = -1 // Endlos Loop
            silentPlayer?.volume = 0.01 // Fast unhörbar
            silentPlayer?.prepareToPlay()
            
            // Spiele wenn gerade aktiv geplant wird ODER aktive Alarme existieren
            if forceStart || hasActiveAlarms() {
                silentPlayer?.play()
                Logger.lifecycle.info("Silent Audio gestartet - App bleibt im Hintergrund aktiv")
            }
        } catch {
            Logger.lifecycle.error("Konnte Silent Audio nicht starten: \(error.localizedDescription, privacy: .public)")
            // Fallback: Nutze einen der App-Sounds
            if let fallbackURL = Bundle.main.url(forResource: "alarm-clock-1", withExtension: "caf") {
                do {
                    silentPlayer = try AVAudioPlayer(contentsOf: fallbackURL)
                    silentPlayer?.numberOfLoops = -1
                    silentPlayer?.volume = 0.0 // Komplett stumm
                    silentPlayer?.prepareToPlay()
                    if forceStart || hasActiveAlarms() {
                        silentPlayer?.play()
                        Logger.lifecycle.info("Silent Audio (Fallback) gestartet")
                    }
                } catch {
                    Logger.lifecycle.error("Auch Fallback fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
    
    // Stoppe Silent Audio
    func stopSilentAudio() {
        silentPlayer?.stop()
        silentPlayer = nil
        Logger.lifecycle.info("Silent Audio gestoppt")
    }
    
    // Sende Warnung dass App offen bleiben muss
    func scheduleAppKillWarning() {
        // Prüfe ob Warnung bereits gesendet wurde (persistent)
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "appKillWarningSent") {
            Logger.criticalAlerts.debug("App-Kill Warnung wurde bereits gesendet - keine weitere Warnung")
            return
        }
        
        // Entferne erst alte Warnungen
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["app-kill-warning"])
        
        let content = UNMutableNotificationContent()
        content.title = "⚠️ Fallback-Modus aktiv"
        content.body = "Öffne WakeFlow kurz vor dem Schlafen, damit dein Alarm im Fallback zuverlässig startet."
        content.interruptionLevel = .timeSensitive
        content.sound = .default
        content.categoryIdentifier = "WARNING_CATEGORY"
        
        // Trigger: Nach 30 Sekunden (nur bei echtem Kill kommt sie)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 30, repeats: false)
        
        let request = UNNotificationRequest(
            identifier: "app-kill-warning",
            content: content,
            trigger: trigger
        )
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                Logger.criticalAlerts.error("App-Kill Warnung Fehler: \(error.localizedDescription, privacy: .public)")
            } else {
                // Markiere als gesendet
                defaults.set(true, forKey: "appKillWarningSent")
                Logger.criticalAlerts.notice("App-Kill Warnung geplant (kommt in 30s wenn App geschlossen bleibt)")
            }
        }
    }
    
    // Entferne App-Kill Warnung
    func cancelAppKillWarning() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["app-kill-warning"])
        Logger.criticalAlerts.debug("App-Kill Warnung entfernt (App ist wieder offen)")
    }
    
    // Setze Warnung zurück (für neuen Alarm)
    func resetAppKillWarning() {
        UserDefaults.standard.set(false, forKey: "appKillWarningSent")
        Logger.criticalAlerts.debug("App-Kill Warnung zurückgesetzt - kann wieder gesendet werden")
    }
    
    // Speichere aktiven Alarm-Status persistent
    private func saveActiveAlarmState(_ alarm: Alarm) {
        let defaults = UserDefaults.standard
        
        // Speichere Alarm-Daten
        defaults.set(alarm.id.uuidString, forKey: "activeAlarmID")
        defaults.set(alarm.label, forKey: "activeAlarmLabel")
        defaults.set(alarm.soundName, forKey: "activeAlarmSound")
        defaults.set(alarm.volume, forKey: "activeAlarmVolume")
        defaults.set(Date(), forKey: "activeAlarmStartTime")
        
        Logger.alarm.debug("Alarm-Status gespeichert: \(alarm.label, privacy: .public)")
    }
    
    // Lade aktiven Alarm-Status beim App-Start
    func loadActiveAlarmState() -> Alarm? {
        let defaults = UserDefaults.standard
        
        guard let alarmIDString = defaults.string(forKey: "activeAlarmID"),
              let alarmID = UUID(uuidString: alarmIDString),
              let label = defaults.string(forKey: "activeAlarmLabel"),
              let soundName = defaults.string(forKey: "activeAlarmSound") else {
            Logger.alarm.debug("Kein aktiver Alarm gefunden")
            return nil
        }
        
        let volume = (defaults.object(forKey: "activeAlarmVolume") as? NSNumber)?.floatValue ?? 1.0
        
        // Erstelle Alarm-Objekt (mit minimalen Daten)
        let alarm = Alarm(
            id: alarmID,
            time: Date(), // Dummy-Zeit
            isEnabled: true,
            label: label,
            repeatDays: [],
            soundName: soundName,
            volume: volume
        )
        
        Logger.alarm.notice("Aktiver Alarm geladen: \(label, privacy: .public)")
        return alarm
    }
    
    // Lösche gespeicherten Alarm-Status
    private func clearActiveAlarmState() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "activeAlarmID")
        defaults.removeObject(forKey: "activeAlarmLabel")
        defaults.removeObject(forKey: "activeAlarmSound")
        defaults.removeObject(forKey: "activeAlarmVolume")
        defaults.removeObject(forKey: "activeAlarmStartTime")
        
        Logger.alarm.debug("Alarm-Status gelöscht")
    }
    
    // MARK: - Keep-Alive Service
    
    /// Starte Keep-Alive Service um App für 15-30 Minuten wach zu halten
    func startKeepAliveService() {
        Logger.lifecycle.info("Starte Keep-Alive Service (15-30 Min)")
        
        // Speichere dass Keep-Alive aktiv ist
        let defaults = UserDefaults.standard
        defaults.set(Date(), forKey: "keepAliveStartTime")
        
        // Nutze stille Audio um App wach zu halten
        if silentPlayer != nil {
            silentPlayer?.stop()
        }
        
        do {
            silentPlayer = try AVAudioPlayer(contentsOf: Bundle.main.url(forResource: "alarm-clock-1", withExtension: "caf")!)
            silentPlayer?.numberOfLoops = -1
            silentPlayer?.volume = 0.0 // Komplett stumm
            silentPlayer?.prepareToPlay()
            silentPlayer?.play()
            Logger.lifecycle.info("Keep-Alive Audio startet (stumm)")
        } catch {
            Logger.lifecycle.error("Keep-Alive Audio Fehler: \(error.localizedDescription, privacy: .public)")
        }
    }
    
    // MARK: - Reminder Notifications
    
    /// Plane tägliche Reminder-Notification um Schlafenszeit (nur wenn Alarme für morgen)
    func scheduleReminderNotification(at sleepTime: Date) {
        Logger.notifications.info("Plane Reminder-Notification um \(sleepTime.formatted(date: .omitted, time: .shortened), privacy: .public)")
        
        let defaults = UserDefaults.standard
        defaults.set(sleepTime.timeIntervalSince1970, forKey: "sleepTime")
        
        // Entferne alte Reminder
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["daily-reminder"])
        
        // Prüfe ob morgen Alarme existieren
        guard hasAlarmsForTomorrow() else {
            Logger.notifications.debug("Keine Alarme für morgen - Reminder wird nicht geplant")
            return
        }
        
        let content = UNMutableNotificationContent()
        content.title = "🌙 Schlaf schön!"
        content.body = "Öffne WakeFlow kurz um sicherzustellen, dass dein Wecker zuverlässig funktioniert"
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.badge = NSNumber(value: 1)
        
        // Trigger täglich um die Schlafenszeit
        let components = Calendar.current.dateComponents([.hour, .minute], from: sleepTime)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        
        let request = UNNotificationRequest(
            identifier: "daily-reminder",
            content: content,
            trigger: trigger
        )
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                Logger.notifications.error("Reminder Notification Fehler: \(error.localizedDescription, privacy: .public)")
            } else {
                Logger.notifications.info("Tägliche Reminder-Notification geplant um \(components.hour ?? 0, privacy: .public):\(String(format: "%02d", components.minute ?? 0), privacy: .public)")
            }
        }
    }
    
    /// Prüfe ob es morgen Alarme gibt
    private func hasAlarmsForTomorrow() -> Bool {
        let tomorrow = Calendar.current.dateComponents([.weekday], from: Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date())
        let tomorrowWeekday = tomorrow.weekday ?? 0
        
        return !alarmsToCheck.filter { alarm in
            alarm.isEnabled && (alarm.repeatDays.isEmpty || alarm.repeatDays.contains(tomorrowWeekday))
        }.isEmpty
    }
    
    // MARK: - Backup Notifications
    
    // LEGACY — nicht mehr verwendet ab AlarmKit-Migration. Wird in Phase 2 entfernt.
    func scheduleBackupNotification(for alarm: Alarm) {
        Logger.notifications.info("Plane Backup-Notification für: \(alarm.label, privacy: .public)")

        func makeContent() -> UNMutableNotificationContent {
            let content = UNMutableNotificationContent()
            content.title = alarm.label
            content.body = "Tippe um zu stoppen"
            content.badge = NSNumber(value: 1)
            content.sound = notificationSound(for: alarm)
            content.interruptionLevel = .timeSensitive // [CRITICAL MESSAGING DEAKTIVIERT — war .critical]
            content.relevanceScore = 1.0
            content.categoryIdentifier = "ALARM_CATEGORY"
            content.userInfo = notificationPayload(for: alarm)
            return content
        }

        let baseComponents = Calendar.current.dateComponents([.hour, .minute], from: alarm.time)
        let repeatDays: [Int?] = alarm.repeatDays.isEmpty ? [nil] : alarm.repeatDays.map { Optional.some($0) }

        for day in repeatDays {
            var components = baseComponents
            if let day {
                components.weekday = day
            }

            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: day != nil)
            let identifier = day.map { "backup-alarm-\(alarm.id)-\($0)" } ?? "backup-alarm-\(alarm.id)"

            let request = UNNotificationRequest(
                identifier: identifier,
                content: makeContent(),
                trigger: trigger
            )

            UNUserNotificationCenter.current().add(request) { error in
                if let error = error {
                    Logger.notifications.error("Backup-Notification Fehler: \(error.localizedDescription, privacy: .public)")
                } else {
                    Logger.notifications.info("Backup-Notification geplant: \(alarm.label, privacy: .public) um \(components.hour ?? 0, privacy: .public):\(String(format: "%02d", components.minute ?? 0), privacy: .public)")
                }
            }
        }
    }
    
    /// Entferne Backup-Notification
    func cancelBackupNotification(for alarm: Alarm) {
        var identifiers = ["backup-alarm-\(alarm.id)"]
        identifiers.append(contentsOf: (1...7).map { "backup-alarm-\(alarm.id)-\($0)" })
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
        Logger.notifications.debug("Backup-Notification entfernt: \(alarm.label, privacy: .public)")
    }
    
    deinit {
        checkTimer?.invalidate()
        stopTimer?.invalidate()
        volumeEnforceTimer?.invalidate()
        notificationTimer?.invalidate()
        vibrationTimer?.invalidate()
        alarmUpdatesTask?.cancel()
        
        // Remove Volume Observer
        AVAudioSession.sharedInstance().removeObserver(self, forKeyPath: "outputVolume")
    }
}

// MARK: - Notification Manager
class AlarmManager: ObservableObject {
    static let shared = AlarmManager()
    
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            if granted {
                Logger.notifications.info("Benachrichtigungen erlaubt")
            } else if let error = error {
                Logger.notifications.error("Fehler: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
    
}

// MARK: - Main View
struct ContentView: View {
    @State private var selectedTab = 0
    @State private var alarms: [Alarm] = []
    @State private var showingAddAlarm = false
    @StateObject private var backgroundAlarmManager = BackgroundAlarmManager.shared
    
    let iosBlue = Color(red: 0/255, green: 122/255, blue: 255/255)
    
    // MARK: - Persistente Speicherung
    private func saveAlarms() {
        if let encoded = try? JSONEncoder().encode(alarms) {
            UserDefaults.standard.set(encoded, forKey: "savedAlarms")
            Logger.lifecycle.debug("\(alarms.count, privacy: .public) Wecker gespeichert")
        }
    }
    
    private func loadAlarms() {
        if let data = UserDefaults.standard.data(forKey: "savedAlarms"),
           let decoded = try? JSONDecoder().decode([Alarm].self, from: data) {
            alarms = decoded
            Logger.lifecycle.debug("\(decoded.count, privacy: .public) Wecker geladen")
        } else {
            Logger.lifecycle.debug("Keine gespeicherten Wecker gefunden")
        }
    }
    
    var body: some View {
        TabView(selection: $selectedTab) {
            AlarmsView(
                alarms: $alarms,
                showingAddAlarm: $showingAddAlarm,
                iosBlue: iosBlue,
                backgroundAlarmManager: backgroundAlarmManager,
                onAlarmToggle: { index, newValue in
                    if let alarm = alarms[safe: index] {
                        // Direktes Aktivieren/Deaktivieren OHNE NFC!
                        alarms[index].isEnabled = newValue
                        if newValue {
                            Logger.alarm.info("Alarm aktiviert (ohne NFC): \(alarm.label, privacy: .public)")
                            Logger.alarm.debug("Alarm-Zeit: \(alarm.time.description, privacy: .public)")
                            Logger.alarm.debug("Wiederholungstage: \(Array(alarm.repeatDays).sorted(), privacy: .public)")
                            // WICHTIG: Plane Alarm neu!
                            backgroundAlarmManager.scheduleAlarm(alarms[index])
                        } else {
                            Logger.alarm.info("Alarm deaktiviert (ohne NFC): \(alarm.label, privacy: .public)")
                            // WICHTIG: Lösche geplante Notifications!
                            backgroundAlarmManager.cancelAlarm(alarms[index])
                        }
                        // Speichere sofort
                        saveAlarms()
                        // Update BackgroundAlarmManager
                        backgroundAlarmManager.updateAlarms(alarms)
                    }
                }
            )
                .tabItem {
                    Image(systemName: "alarm.fill")
                    Text("Wecker")
                }
                .tag(0)
            
            Text("Pro")
                .font(.largeTitle)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .tabItem {
                    Image(systemName: "trophy.fill")
                    Text("Pro")
                }
                .tag(1)
            
            
            SettingsView()
                .tabItem {
                    Image(systemName: "gearshape.fill")
                    Text("Einstellungen")
                }
                .tag(2)
        }
        .accentColor(iosBlue)
        .sheet(isPresented: $showingAddAlarm) {
            AddAlarmView(
                iosBlue: iosBlue,
                onSave: { newAlarm in
                    // Neuer Alarm direkt hinzufügen OHNE NFC!
                    alarms.append(newAlarm)
                    Logger.alarm.info("Neuer Alarm hinzugefügt (ohne NFC): \(newAlarm.label, privacy: .public)")
                    Logger.alarm.debug("Alarm-Zeit: \(newAlarm.time.description, privacy: .public)")
                    Logger.alarm.debug("Alarm aktiviert: \(newAlarm.isEnabled, privacy: .public)")
                    Logger.alarm.debug("Wiederholungstage: \(Array(newAlarm.repeatDays).sorted(), privacy: .public)")
                    // Speichere und update
                    saveAlarms()
                    backgroundAlarmManager.updateAlarms(alarms)
                    // WICHTIG: Plane Alarm wenn aktiviert!
                    if newAlarm.isEnabled {
                        backgroundAlarmManager.scheduleAlarm(newAlarm)
                    }
                }
            )
        }
        .fullScreenCover(isPresented: .constant(backgroundAlarmManager.isPlaying)) {
            MoonView(
                iosBlue: iosBlue,
                backgroundAlarmManager: backgroundAlarmManager,
                onAlarmStopped: { alarmID in
                    // Prüfe ob der gestoppte Alarm einmalig war
                    DispatchQueue.main.async {
                        guard let alarmID = alarmID else {
                            Logger.alarm.error("Keine Alarm-ID übergeben")
                            return
                        }
                        
                        if let index = alarms.firstIndex(where: { $0.id == alarmID }) {
                            let alarm = alarms[index]
                            Logger.alarm.debug("Alarm gestoppt - ID: \(alarmID.uuidString, privacy: .public)")
                            Logger.alarm.debug("Wiederholungstage: \(Array(alarm.repeatDays).sorted(), privacy: .public)")
                            Logger.alarm.debug("Ist einmalig: \(alarm.repeatDays.isEmpty, privacy: .public)")
                            
                            if alarm.repeatDays.isEmpty {
                                // Einmaliger Alarm → Deaktivieren!
                                Logger.alarm.info("Einmaliger Alarm wird deaktiviert: \(alarm.label, privacy: .public)")
                                alarms[index].isEnabled = false
                                
                                // Trigger manuelles Update der UI
                                let updatedAlarms = alarms
                                alarms = []
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    alarms = updatedAlarms
                                    saveAlarms()
                                    backgroundAlarmManager.updateAlarms(alarms)
                                    Logger.alarm.debug("Toggle Switch ist jetzt: \(alarms[index].isEnabled ? "AN" : "AUS", privacy: .public)")
                                }
                            } else {
                                Logger.alarm.info("Wiederkehrender Alarm bleibt aktiv: \(alarm.label, privacy: .public)")
                            }
                        }
                    }
                }
            )
            .interactiveDismissDisabled(true)  // Kann NICHT weggewischt werden!
        }
        .onAppear {
            // Lade gespeicherte Wecker
            loadAlarms()
            
            // Frage nach Permissions
            requestNotificationPermissions()
            
            // Registriere Notification Category
            registerNotificationCategory()
            
            // WICHTIG: Alle aktiven Alarme neu planen!
            // Das stellt sicher, dass Alarme auch nach App-Neustart oder wenn iOS die Notifications gelöscht hat, funktionieren
            for alarm in alarms where alarm.isEnabled {
                backgroundAlarmManager.scheduleAlarm(alarm)
                Logger.alarm.notice("Alarm neu geplant: \(alarm.label, privacy: .public) um \(alarm.time.description, privacy: .public)")
            }
            
            // Update alarms in background manager
            backgroundAlarmManager.updateAlarms(alarms)

            // Verarbeite defensiv einen frischen AlarmKit-Open-Marker aus dem Secondary Intent.
            backgroundAlarmManager.handleAlarmKitOpenMarkerIfNeeded()
            
            // Pausiere Notifications wenn App geöffnet wird
            backgroundAlarmManager.pauseNotifications()
            
            // WICHTIG: Starte Keep-Alive Service um App für 15-30 Min wach zu halten
            backgroundAlarmManager.startKeepAliveService()
            Logger.lifecycle.info("Keep-Alive Service aktiviert")
            
            // Lade Schlafenszeit und plane Reminder-Notification
            loadAndScheduleReminder()
            
            // Prüfe ob ein Alarm beim letzten App-Kill aktiv war
            checkForActiveAlarmAfterRestart()
        }
        .onDisappear {
            // Setze Notifications fort wenn App geschlossen wird
            backgroundAlarmManager.resumeNotifications()
        }
        .onChange(of: alarms) { newAlarms in
            backgroundAlarmManager.updateAlarms(newAlarms)
            saveAlarms() // Speichere automatisch bei jeder Änderung
            
            // Wenn keine aktiven Alarme mehr vorhanden sind, entferne Warnung
            if !newAlarms.contains(where: { $0.isEnabled }) {
                backgroundAlarmManager.cancelAppKillWarning()
                Logger.lifecycle.debug("Keine aktiven Alarme mehr - Warnung entfernt")
            }
        }
        .onChange(of: backgroundAlarmManager.isPlaying) { isPlaying in
            // FullScreenCover erscheint automatisch durch .constant(backgroundAlarmManager.isPlaying)
            if isPlaying {
                Logger.lifecycle.notice("Mond-Screen erscheint - Alarm klingelt")
            } else {
                Logger.lifecycle.notice("Mond-Screen verschwindet - Alarm gestoppt")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            // App kommt in den Vordergrund
            backgroundAlarmManager.pauseNotifications()
            backgroundAlarmManager.cancelAppKillWarning() // Entferne Warnung
            backgroundAlarmManager.handleAlarmKitOpenMarkerIfNeeded()
            Logger.lifecycle.notice("App in Vordergrund - Notifications pausiert + Warnung entfernt")
            // #region agent log
            Task { @MainActor in
                await PhantomDebug.dumpBootState(reason: "willEnterForeground")
            }
            // #endregion
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            // App geht in den Hintergrund
            backgroundAlarmManager.resumeNotifications()
            
            // Prüfe ob aktive Wecker vorhanden sind (und kein Alarm gerade klingelt)
            if backgroundAlarmManager.hasActiveAlarms() && !backgroundAlarmManager.isPlaying {
                if backgroundAlarmManager.shouldShowAppKeepAliveWarning() {
                    // Nur Fallback-Hinweis, wenn kein zuverlässiger systemischer Alarmpfad aktiv ist
                    backgroundAlarmManager.scheduleAppKillWarning()
                    Logger.lifecycle.notice("App in Hintergrund mit aktivem Wecker - Fallback-Warnung geplant")
                } else {
                    backgroundAlarmManager.cancelAppKillWarning()
                    Logger.lifecycle.info("App in Hintergrund - AlarmKit übernimmt zuverlässig")
                }
            } else {
                Logger.lifecycle.debug("App in Hintergrund - Notifications fortgesetzt")
            }
            // #region agent log
            Task { @MainActor in
                await PhantomDebug.dumpBootState(reason: "didEnterBackground")
            }
            // #endregion
        }
    }
    
    
    private func requestNotificationPermissions() {
        // [CRITICAL MESSAGING DEAKTIVIERT] — Standard-Benachrichtigungen
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            if granted {
                Logger.notifications.info("Notification Permissions gewährt")
            } else if let error = error {
                Logger.notifications.error("Notification Permissions Fehler: \(error.localizedDescription, privacy: .public)")
            } else {
                Logger.notifications.notice("Notification Permissions abgelehnt")
            }
        }
    }
    
    private func registerNotificationCategory() {
        let stopAction = UNNotificationAction(
            identifier: "STOP_ALARM",
            title: "Stoppen",
            options: [.foreground]
        )
        
        let alarmCategory = UNNotificationCategory(
            identifier: "ALARM_CATEGORY",
            actions: [stopAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        
        let openAppAction = UNNotificationAction(
            identifier: "OPEN_APP",
            title: "App öffnen",
            options: [.foreground]
        )
        
        let warningCategory = UNNotificationCategory(
            identifier: "WARNING_CATEGORY",
            actions: [openAppAction],
            intentIdentifiers: [],
            options: []
        )
        
        UNUserNotificationCenter.current().setNotificationCategories([alarmCategory, warningCategory])
        Logger.notifications.info("Notification Categories registriert (Alarm + Warning)")
    }
    
    // Prüfe nach App-Neustart ob ein Alarm aktiv war
    private func checkForActiveAlarmAfterRestart() {
        // Warte kurz damit UI geladen ist
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard !backgroundAlarmManager.isPlaying else {
                Logger.alarm.debug("Aktiver Alarm läuft bereits - kein Neustart nötig")
                return
            }

            if let activeAlarm = backgroundAlarmManager.loadActiveAlarmState() {
                // #region agent log
                let activeStart = UserDefaults.standard.object(forKey: "activeAlarmStartTime") as? Date
                PhantomDebug.log("checkForActiveAlarmAfterRestart", "REPLAY active alarm state",
                    data: [
                        "alarmID": activeAlarm.id.uuidString,
                        "label": activeAlarm.label,
                        "savedStart": activeStart?.description ?? "<nil>",
                        "now": Date().description,
                        "ageSec": activeStart.map { Date().timeIntervalSince($0) } ?? -1
                    ])
                // #endregion
                Logger.alarm.notice("APP NEUSTART - Alarm war aktiv: \(activeAlarm.label, privacy: .public)")
                Logger.alarm.notice("Starte Alarm + Mond-Screen neu")
                
                // Starte Alarm wieder
                backgroundAlarmManager.playAlarm(activeAlarm)
                
                Logger.alarm.notice("Alarm erfolgreich neu gestartet nach App-Kill")
            }
        }
    }
    
    private func loadAndScheduleReminder() {
        let defaults = UserDefaults.standard
        
        // Lade gespeicherte Schlafenszeit
        if let sleepTimeInterval = defaults.object(forKey: "sleepTime") as? TimeInterval {
            let sleepTime = Date(timeIntervalSince1970: sleepTimeInterval)
            
            // Plane täglich Reminder-Notification
            backgroundAlarmManager.scheduleReminderNotification(at: sleepTime)
            Logger.notifications.info("Reminder-Notification geplant um \(sleepTime.formatted(date: .omitted, time: .shortened), privacy: .public)")
        } else {
            Logger.notifications.debug("Keine Schlafenszeit gespeichert - Bitte in Einstellungen einstellen")
        }
    }
}

// MARK: - Alarms View
struct AlarmsView: View {
    @Binding var alarms: [Alarm]
    @Binding var showingAddAlarm: Bool
    @State private var editingAlarmID: UUID?
#if DEBUG
    @State private var showingSpikeLog = false
#endif
    // #region agent log
    @State private var showingPhantomLog = false
    // #endregion
    let iosBlue: Color
    let backgroundAlarmManager: BackgroundAlarmManager
    let onAlarmToggle: (Int, Bool) -> Void // (index, newValue)
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("Wecker")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundColor(.white)
                    
                    Spacer()
                    
                    // #region agent log
                    Button(action: { showingPhantomLog = true }) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.yellow)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(.ultraThinMaterial))
                    }
                    .padding(.trailing, 8)
                    // #endregion

                    Button(action: {
                        showingAddAlarm = true
                    }) {
                        Image(systemName: "plus")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(iosBlue)
                            .frame(width: 36, height: 36)
                            .background(
                                Circle()
                                    .fill(.ultraThinMaterial)
                            )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 20)

#if DEBUG
                if #available(iOS 26.0, *) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            Button("AlarmKit Spike") {
                                Task {
                                    await scheduleAlarmKitSpike()
                                }
                            }
                            .buttonStyle(.borderedProminent)

                            Button("Cancel Spike Alarm") {
                                cancelAlarmKitSpike()
                            }
                            .buttonStyle(.bordered)

                            Button("Plain Notification Spike") {
                                Task {
                                    await schedulePlainNotificationSpike()
                                }
                            }
                            .buttonStyle(.borderedProminent)

                            Button("Cancel Plain Notification") {
                                cancelPlainNotificationSpike()
                            }
                            .buttonStyle(.bordered)

                            Button("Combined Spike") {
                                Task {
                                    await scheduleCombinedSpike()
                                }
                            }
                            .buttonStyle(.borderedProminent)

                            Button("Show Spike Log") {
                                showingSpikeLog = true
                            }
                            .buttonStyle(.bordered)
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 20)
                    }
                    .padding(.bottom, 12)
                }
#endif
                
                // Alarms List
                if alarms.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "alarm")
                            .font(.system(size: 60))
                            .foregroundColor(.gray.opacity(0.3))
                        
                        Text("Keine Wecker")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(.gray)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 12) {
                            ForEach(Array(alarms.enumerated()), id: \.element.id) { index, alarm in
                                SwipeableAlarmRow(
                                    alarm: alarm,
                                    iosBlue: iosBlue,
                                    onToggle: { newValue in
                                        // Toggle → Callback mit neuem Wert
                                        onAlarmToggle(index, newValue)
                                    },
                                    onTap: {
                                        editingAlarmID = alarm.id
                                    },
                                    onDelete: {
                                        // FIX: AlarmKit-Eintrag löschen, sonst feuert er später als Phantom-Wecker
                                        let toDelete = alarms[index]
                                        backgroundAlarmManager.cancelAlarm(toDelete)
                                        alarms.remove(at: index)
                                    }
                                )
                                .id(alarm.id)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: Binding(
            get: { editingAlarmID != nil },
            set: { if !$0 { editingAlarmID = nil } }
        )) {
            if let alarmID = editingAlarmID,
               let index = alarms.firstIndex(where: { $0.id == alarmID }) {
                EditAlarmView(
                    alarm: alarms[index],
                    iosBlue: iosBlue,
                    onSave: { updatedAlarm in
                        // Bearbeiteter Alarm direkt speichern OHNE NFC!
                        editingAlarmID = nil
                        alarms[index] = updatedAlarm
                        Logger.alarm.info("Alarm bearbeitet (ohne NFC): \(updatedAlarm.label, privacy: .public)")
                        // WICHTIG: Plane Alarm neu wenn aktiviert!
                        if updatedAlarm.isEnabled {
                            backgroundAlarmManager.scheduleAlarm(updatedAlarm)
                        } else {
                            backgroundAlarmManager.cancelAlarm(updatedAlarm)
                        }
                    }
                )
            }
        }
#if DEBUG
        .sheet(isPresented: $showingSpikeLog) {
            AlarmKitSpikeLogView()
        }
#endif
        // #region agent log
        .sheet(isPresented: $showingPhantomLog) {
            PhantomLogView()
        }
        // #endregion
    }

#if DEBUG
    private func scheduleAlarmKitSpike() async {
        guard #available(iOS 26.0, *) else { return }

        await scheduleAlarmKitSpike(
            fireDate: Date().addingTimeInterval(60),
            spikeType: "alarmKit",
            logPrefix: "AlarmKit Spike"
        )
    }

    private func schedulePlainNotificationSpike() async {
        guard #available(iOS 26.0, *) else { return }

        await schedulePlainNotificationSpike(
            fireDate: Date().addingTimeInterval(60),
            spikeType: "plain",
            logPrefix: "Plain Notification Spike"
        )
    }

    private func scheduleCombinedSpike() async {
        guard #available(iOS 26.0, *) else { return }

        let fireDate = Date().addingTimeInterval(60)
        AlarmKitSpikeDefaults.appendLog("Combined Spike: schedule button tapped for \(fireDate)")

        await scheduleAlarmKitSpike(
            fireDate: fireDate,
            spikeType: "combined",
            logPrefix: "Combined Spike"
        )
        await schedulePlainNotificationSpike(
            fireDate: fireDate,
            spikeType: "combined",
            logPrefix: "Combined Spike"
        )
    }

    private func scheduleAlarmKitSpike(fireDate: Date, spikeType: String, logPrefix: String) async {
        guard #available(iOS 26.0, *) else { return }

        let defaults = AlarmKitSpikeDefaults.defaults
        defaults.synchronize()

        AlarmKitSpikeDefaults.appendLog("\(logPrefix): AlarmKit schedule requested")

        let alarmManager = AlarmKit.AlarmManager.shared
        let currentState = alarmManager.authorizationState
        AlarmKitSpikeDefaults.appendLog("\(logPrefix): authorization state before scheduling = \(currentState)")

        switch currentState {
        case .notDetermined:
            do {
                let newState = try await alarmManager.requestAuthorization()
                AlarmKitSpikeDefaults.appendLog("\(logPrefix): authorization state after request = \(newState)")
                guard newState == .authorized else {
                    AlarmKitSpikeDefaults.appendLog("\(logPrefix): authorization denied/restricted — open Settings to grant")
                    return
                }
            } catch {
                AlarmKitSpikeDefaults.appendLog("\(logPrefix): authorization request failed: \(error)")
                return
            }
        case .denied:
            AlarmKitSpikeDefaults.appendLog("\(logPrefix): authorization denied/restricted — open Settings to grant")
            return
        case .authorized:
            break
        @unknown default:
            AlarmKitSpikeDefaults.appendLog("\(logPrefix): authorization denied/restricted — open Settings to grant")
            return
        }

        defaults.set(false, forKey: AlarmKitSpikeDefaults.verificationConsumedKey)

        if let pendingAlarmIDString = defaults.string(forKey: AlarmKitSpikeDefaults.pendingAlarmIDKey),
           let pendingAlarmID = UUID(uuidString: pendingAlarmIDString) {
            do {
                let existingAlarms = try alarmManager.alarms
                AlarmKitSpikeDefaults.appendLog("\(logPrefix): raw AlarmKit alarms count before scheduling = \(existingAlarms.count)")
                if let existingAlarm = existingAlarms.first(where: { $0.id == pendingAlarmID }) {
                    AlarmKitSpikeDefaults.appendLog("\(logPrefix): cancelling currently-active spike alarm \(pendingAlarmID) in state \(existingAlarm.state)")
                } else {
                    AlarmKitSpikeDefaults.appendLog("\(logPrefix): persisted pending alarm \(pendingAlarmID) not found before scheduling; attempting defensive cancel")
                }
            } catch {
                AlarmKitSpikeDefaults.appendLog("\(logPrefix): failed to query persisted pending alarm before scheduling: \(error); attempting defensive cancel")
            }

            do {
                // Calling cancel(id:) on an alerting AlarmKit alarm has unknown UI consequences; this spike exposes that behavior for observation.
                try alarmManager.cancel(id: pendingAlarmID)
                AlarmKitSpikeDefaults.appendLog("\(logPrefix): canceled previous pending alarm \(pendingAlarmID)")
            } catch {
                AlarmKitSpikeDefaults.appendLog("\(logPrefix): cancel previous pending alarm \(pendingAlarmID) failed: \(error)")
            }
            defaults.removeObject(forKey: AlarmKitSpikeDefaults.pendingAlarmIDKey)
            defaults.removeObject(forKey: AlarmKitSpikeDefaults.activeAlarmKitSpikeTypeKey)
        }

        let spikeAlarmID = UUID()
        let stopButton = AlarmButton(
            text: LocalizedStringResource(stringLiteral: "Stoppen"),
            textColor: .white,
            systemImageName: "stop.fill"
        )
        let secondaryButton = AlarmButton(
            text: LocalizedStringResource(stringLiteral: "WakeFlow öffnen"),
            textColor: .white,
            systemImageName: "arrow.up.right.square.fill"
        )
        let alert = AlarmPresentation.Alert(
            title: LocalizedStringResource(stringLiteral: "AlarmKit Spike"),
            stopButton: stopButton,
            secondaryButton: secondaryButton,
            secondaryButtonBehavior: .custom
        )
        let presentation = AlarmPresentation(alert: alert)
        let metadata = WakeFlowAlarmMetadata(label: "AlarmKit Spike", soundName: "default")
        let attributes = AlarmAttributes(
            presentation: presentation,
            metadata: metadata,
            tintColor: .orange
        )
        let configuration = AlarmKit.AlarmManager.AlarmConfiguration<WakeFlowAlarmMetadata>.alarm(
            schedule: AlarmKit.Alarm.Schedule.fixed(fireDate),
            attributes: attributes,
            secondaryIntent: OpenWakeFlowFromAlarmSpikeIntent(),
            sound: .default
        )

        do {
            let scheduledAlarm = try await alarmManager.schedule(id: spikeAlarmID, configuration: configuration)
            defaults.set(spikeAlarmID.uuidString, forKey: AlarmKitSpikeDefaults.pendingAlarmIDKey)
            defaults.set(spikeType, forKey: AlarmKitSpikeDefaults.activeAlarmKitSpikeTypeKey)
            defaults.synchronize()
            AlarmKitSpikeDefaults.appendLog("\(logPrefix): scheduled AlarmKit alarm \(spikeAlarmID) for \(fireDate), initial state \(scheduledAlarm.state)")
        } catch {
            AlarmKitSpikeDefaults.appendLog("\(logPrefix): AlarmKit schedule failed for \(spikeAlarmID): \(error)")
        }
    }

    private func schedulePlainNotificationSpike(fireDate: Date, spikeType: String, logPrefix: String) async {
        guard #available(iOS 26.0, *) else { return }

        let defaults = AlarmKitSpikeDefaults.defaults
        defaults.synchronize()

        AlarmKitSpikeDefaults.appendLog("\(logPrefix): plain notification schedule requested")
        clearPendingPlainNotificationSpike(logPrefix: logPrefix, shouldLogMissing: false)

        guard await ensurePlainNotificationAuthorization(logPrefix: logPrefix) else {
            return
        }

        let identifier = "plain-notification-spike-\(UUID().uuidString)"
        let content = UNMutableNotificationContent()
        content.title = "Plain Notification Spike"
        content.body = "Plain Notification Spike Test"
        content.sound = nil
        content.interruptionLevel = .timeSensitive
        content.userInfo = ["spikeType": spikeType]

        let fireComponents = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: fireDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: fireComponents, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

        let addErrorMessage: String? = await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().add(request) { error in
                continuation.resume(returning: error?.localizedDescription)
            }
        }

        if let addErrorMessage {
            AlarmKitSpikeDefaults.appendLog("\(logPrefix): plain notification schedule failed for \(identifier): \(addErrorMessage)")
            return
        }

        defaults.set(identifier, forKey: AlarmKitSpikeDefaults.pendingPlainNotificationIDKey)
        defaults.set(fireDate.timeIntervalSince1970, forKey: AlarmKitSpikeDefaults.pendingPlainNotificationFireDateKey)
        defaults.synchronize()

        AlarmKitSpikeDefaults.appendLog("\(logPrefix): scheduled plain notification \(identifier) for \(fireDate), spikeType=\(spikeType), sound=nil")
    }

    private func cancelAlarmKitSpike() {
        guard #available(iOS 26.0, *) else { return }

        let defaults = AlarmKitSpikeDefaults.defaults
        defaults.synchronize()

        guard let pendingAlarmIDString = defaults.string(forKey: AlarmKitSpikeDefaults.pendingAlarmIDKey),
              let pendingAlarmID = UUID(uuidString: pendingAlarmIDString) else {
            AlarmKitSpikeDefaults.appendLog("AlarmKit Spike: cancel requested but no pending alarm ID was stored")
            return
        }

        do {
            try AlarmKit.AlarmManager.shared.cancel(id: pendingAlarmID)
            AlarmKitSpikeDefaults.appendLog("AlarmKit Spike: Cancel Spike Alarm canceled \(pendingAlarmID)")
        } catch {
            AlarmKitSpikeDefaults.appendLog("AlarmKit Spike: Cancel Spike Alarm failed for \(pendingAlarmID): \(error)")
        }

        defaults.removeObject(forKey: AlarmKitSpikeDefaults.pendingAlarmIDKey)
        defaults.removeObject(forKey: AlarmKitSpikeDefaults.activeAlarmKitSpikeTypeKey)
        defaults.synchronize()
    }

    private func cancelPlainNotificationSpike() {
        guard #available(iOS 26.0, *) else { return }

        clearPendingPlainNotificationSpike(
            logPrefix: "Plain Notification Spike",
            shouldLogMissing: true
        )
    }

    private func clearPendingPlainNotificationSpike(logPrefix: String, shouldLogMissing: Bool) {
        let defaults = AlarmKitSpikeDefaults.defaults
        defaults.synchronize()

        guard let identifier = defaults.string(forKey: AlarmKitSpikeDefaults.pendingPlainNotificationIDKey) else {
            if shouldLogMissing {
                AlarmKitSpikeDefaults.appendLog("\(logPrefix): cancel requested but no pending plain notification ID was stored")
            }
            defaults.removeObject(forKey: AlarmKitSpikeDefaults.pendingPlainNotificationFireDateKey)
            defaults.synchronize()
            return
        }

        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
        defaults.removeObject(forKey: AlarmKitSpikeDefaults.pendingPlainNotificationIDKey)
        defaults.removeObject(forKey: AlarmKitSpikeDefaults.pendingPlainNotificationFireDateKey)
        defaults.synchronize()

        AlarmKitSpikeDefaults.appendLog("\(logPrefix): removed pending/delivered plain notification \(identifier)")
    }

    private func ensurePlainNotificationAuthorization(logPrefix: String) async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings)
            }
        }

        switch settings.authorizationStatus {
        case .notDetermined:
            let result = await withCheckedContinuation { continuation in
                center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
                    continuation.resume(returning: (granted, error?.localizedDescription))
                }
            }
            if let errorMessage = result.1 {
                AlarmKitSpikeDefaults.appendLog("\(logPrefix): notification authorization request failed: \(errorMessage)")
            }
            guard result.0 else {
                AlarmKitSpikeDefaults.appendLog("\(logPrefix): notification authorization denied")
                return false
            }
            AlarmKitSpikeDefaults.appendLog("\(logPrefix): notification authorization granted")
            return true
        case .authorized, .provisional, .ephemeral:
            AlarmKitSpikeDefaults.appendLog("\(logPrefix): notification authorization state before scheduling = \(settings.authorizationStatus)")
            return true
        case .denied:
            AlarmKitSpikeDefaults.appendLog("\(logPrefix): notification authorization denied/restricted — open Settings to grant")
            return false
        @unknown default:
            AlarmKitSpikeDefaults.appendLog("\(logPrefix): notification authorization unknown state \(settings.authorizationStatus)")
            return false
        }
    }
#endif
}

// MARK: - Swipeable Alarm Row
struct SwipeableAlarmRow: View {
    let alarm: Alarm
    let iosBlue: Color
    let onToggle: (Bool) -> Void
    let onTap: () -> Void
    let onDelete: () -> Void
    
    @State private var offset: CGFloat = 0
    @State private var isSwiping = false
    @State private var isDeleting = false
    @State private var localIsEnabled: Bool
    
    private let deleteButtonWidth: CGFloat = 80
    
    init(alarm: Alarm, iosBlue: Color, onToggle: @escaping (Bool) -> Void, onTap: @escaping () -> Void, onDelete: @escaping () -> Void) {
        self.alarm = alarm
        self.iosBlue = iosBlue
        self.onToggle = onToggle
        self.onTap = onTap
        self.onDelete = onDelete
        self._localIsEnabled = State(initialValue: alarm.isEnabled)
    }
    
    var body: some View {
        ZStack(alignment: .trailing) {
            // Delete Button (behind)
            Button(action: {
                guard !isDeleting else { return }
                isDeleting = true
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    offset = -UIScreen.main.bounds.width
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    onDelete()
                }
            }) {
                HStack {
                    Spacer()
                    VStack(spacing: 4) {
                        Image(systemName: "trash.fill")
                            .font(.system(size: 20))
                        Text("Löschen")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(.white)
                    .frame(width: deleteButtonWidth)
                }
            }
            .frame(maxHeight: .infinity)
            .background(Color.red)
            .cornerRadius(13)
            
            // Alarm Card (front)
            AlarmRowView(
                alarm: alarm, 
                iosBlue: iosBlue, 
                isEnabled: $localIsEnabled,
                onToggle: { newValue in
                    // Setze immer die lokale UI-Anzeige
                    localIsEnabled = newValue
                    
                    // Direktes Aktivieren/Deaktivieren OHNE NFC!
                    if newValue {
                        Logger.alarm.debug("Toggle: Aktivierung (ohne NFC)")
                    } else {
                        Logger.alarm.debug("Toggle: Deaktivierung (ohne NFC)")
                    }
                    
                    // Immer Callback aufrufen
                    onToggle(newValue)
                }
            )
                .offset(x: offset)
                .onChange(of: alarm.isEnabled) { newValue in
                    // Synchronisiere lokalIsEnabled mit tatsächlichem Alarm-State
                    localIsEnabled = newValue
                    Logger.alarm.debug("Toggle-State synchronisiert: \(newValue, privacy: .public)")
                }
                .gesture(
                    DragGesture()
                        .onChanged { gesture in
                            guard !isDeleting else { return }
                            isSwiping = true
                            // Only allow left swipe
                            if gesture.translation.width < 0 {
                                let newOffset = gesture.translation.width
                                offset = max(newOffset, -deleteButtonWidth)
                            } else if offset < 0 {
                                // Allow swiping back to close
                                offset = min(0, offset + gesture.translation.width)
                            }
                        }
                        .onEnded { gesture in
                            guard !isDeleting else { return }
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                if gesture.translation.width < -50 || gesture.predictedEndTranslation.width < -100 {
                                    offset = -deleteButtonWidth
                                } else {
                                    offset = 0
                                }
                            }
                            
                            // Delay tap detection after swipe
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                isSwiping = false
                            }
                        }
                )
                .onTapGesture {
                    guard !isDeleting else { return }
                    if !isSwiping && offset == 0 {
                        onTap()
                    } else if offset < 0 {
                        // Close swipe when tapping
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            offset = 0
                        }
                    }
                }
        }
    }
}

// MARK: - Alarm Row View
struct AlarmRowView: View {
    let alarm: Alarm
    let iosBlue: Color
    @Binding var isEnabled: Bool
    let onToggle: (Bool) -> Void
    
    let weekdayMap: [Int: String] = [
        1: "So.",
        2: "Mo.",
        3: "Di.",
        4: "Mi.",
        5: "Do.",
        6: "Fr.",
        7: "Sa."
    ]
    
    var repeatDaysText: String {
        if alarm.repeatDays.isEmpty {
            return "Einmalig"
        }
        
        // Sort days in German order (Monday to Sunday)
        let germanOrder = [2, 3, 4, 5, 6, 7, 1]
        let sortedDays = alarm.repeatDays.sorted { day1, day2 in
            let index1 = germanOrder.firstIndex(of: day1) ?? 0
            let index2 = germanOrder.firstIndex(of: day2) ?? 0
            return index1 < index2
        }
        
        let dayNames = sortedDays.compactMap { weekdayMap[$0] }
        
        if dayNames.count == 7 {
            return "Täglich"
        } else if Set(sortedDays) == Set([2, 3, 4, 5, 6]) {
            return "Wochentags"
        } else if Set(sortedDays) == Set([1, 7]) {
            return "Wochenende"
        } else {
            return "Jeden " + dayNames.joined(separator: " ")
        }
    }
    
    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                // Time
                Text(timeString(from: alarm.time))
                    .font(.system(size: 52, weight: .medium))
                    .foregroundColor(isEnabled ? .white : .gray)
                
                // Label and Repeat Days
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: "bed.double.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.gray)
                        
                        Text(alarm.label)
                            .font(.system(size: 15, weight: .regular))
                            .foregroundColor(.gray)
                    }
                    
                    // Repeat Days
                    Text(repeatDaysText)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(.gray)
                }
            }
            
            Spacer()
            
            // Toggle Switch
            Toggle("", isOn: Binding(
                get: { isEnabled },
                set: { newValue in
                    // Rufe nur den Callback auf, OHNE das Binding direkt zu ändern
                    // Die Änderung kommt dann von außen über onChange(of: alarm.isEnabled)
                    onToggle(newValue)
                }
            ))
                .onChange(of: isEnabled) { _ in
                    // Force UI update when isEnabled changes from parent
                }
            .labelsHidden()
            .toggleStyle(SwitchToggleStyle(tint: iosBlue))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(white: 0.11))
        .cornerRadius(13)
    }
    
    private func timeString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - Add Alarm View
struct AddAlarmView: View {
    @Environment(\.dismiss) var dismiss
    let iosBlue: Color
    let onSave: (Alarm) -> Void
    
    @State private var selectedTime = Date()
    @State private var alarmLabel = "Wecker"
    @State private var selectedDays: Set<Int> = []
    @State private var selectedSound = "alarm-clock-1.caf"
    @State private var selectedVolume: Float = 1.0 // UI: 0-1, Intern: 0.25-0.8
    @State private var isPlayingPreview = false
    @State private var previewPlayer: AVAudioPlayer?
    
    let weekdaySymbols = ["M", "D", "M", "D", "F", "S", "S"] // Mo, Di, Mi, Do, Fr, Sa, So
    let weekdayOrder = [2, 3, 4, 5, 6, 7, 1] // Montag bis Sonntag
    
    // Konvertiere UI-Wert (0-1) zu internem Wert (0.25-0.8)
    private func volumeToInternal(_ uiVolume: Float) -> Float {
        return 0.25 + (uiVolume * 0.55)
    }
    
    // Konvertiere internen Wert (0.25-0.8) zu System-Slider (0-1.0)
    // Damit 0.8 wie "voll aufgedreht" aussieht
    private func internalToSystemVolume(_ internalVolume: Float) -> Float {
        return (internalVolume - 0.25) / 0.55
    }
    
    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                
                VStack(spacing: 0) {
                    // Time Picker
                    DatePicker("", selection: $selectedTime, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.wheel)
                        .labelsHidden()
                        .colorScheme(.dark)
                        .padding(.vertical, 20)
                    
                    // Settings List
                    VStack(spacing: 0) {
                        // Repeat Days
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Wiederholen")
                                    .foregroundColor(.white)
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                            
                            HStack(spacing: 0) {
                                ForEach(0..<7, id: \.self) { index in
                                    let day = weekdayOrder[index]
                                    Button(action: {
                                        if selectedDays.contains(day) {
                                            selectedDays.remove(day)
                                        } else {
                                            selectedDays.insert(day)
                                        }
                                    }) {
                                        Text(weekdaySymbols[index])
                                            .font(.system(size: 15, weight: .medium))
                                            .foregroundColor(selectedDays.contains(day) ? .white : .gray)
                                            .frame(maxWidth: .infinity)
                                            .frame(height: 42)
                                            .background(
                                                Circle()
                                                    .fill(selectedDays.contains(day) ? iosBlue : Color(white: 0.2))
                                                    .frame(width: 42, height: 42)
                                            )
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)
                        }
                        
                        Divider()
                            .background(Color(white: 0.2))
                        
                        // Label
                        HStack {
                            Text("Bezeichnung")
                                .foregroundColor(.white)
                            
                            Spacer()
                            
                            TextField("Wecker", text: $alarmLabel)
                                .foregroundColor(.gray)
                                .multilineTextAlignment(.trailing)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        
                        Divider()
                            .background(Color(white: 0.2))
                        
                        // Sound Selection
                        NavigationLink(destination: SoundPickerView(selectedSound: $selectedSound, iosBlue: iosBlue)) {
                            HStack {
                                Text("Sound")
                                    .foregroundColor(.white)
                                
                                Spacer()
                                
                                Text(availableSounds.first(where: { $0.file == selectedSound })?.name ?? "Wecker 1")
                                    .foregroundColor(.gray)
                                
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.gray)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        }
                        
                        Divider()
                            .background(Color(white: 0.2))
                        
                        // Volume Slider
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Lautstärke")
                                    .foregroundColor(.white)
                                
                                Spacer()
                                
                                if isPlayingPreview {
                                    Button(action: {
                                        stopPreview()
                                    }) {
                                        Image(systemName: "pause.circle.fill")
                                            .font(.system(size: 24))
                                            .foregroundColor(iosBlue)
                                    }
                                }
                            }
                            
                            HStack(spacing: 12) {
                                Image(systemName: "speaker.fill")
                                    .font(.system(size: 14))
                                    .foregroundColor(.gray)
                                
                                Slider(value: $selectedVolume, in: 0.0...1.0, step: 0.01)
                                .accentColor(iosBlue)
                                .onChange(of: selectedVolume) { _ in
                                    // Slider bewegt → Starte Vorschau (falls nicht läuft)
                                    if !isPlayingPreview {
                                        playPreview()
                                    } else {
                                        updatePreviewVolume()
                                    }
                                }
                                
                                Image(systemName: "speaker.wave.3.fill")
                                    .font(.system(size: 14))
                                    .foregroundColor(.gray)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                    .background(Color(white: 0.11))
                    .cornerRadius(13)
                    .padding(.horizontal, 16)
                    
                    Spacer()
                }
            }
            .navigationTitle("Wecker hinzufügen")
            .onDisappear {
                stopPreview()
            }
            .onChange(of: selectedSound) { _ in
                // Sound gewechselt → Stoppe alte Vorschau
                stopPreview()
                Logger.lifecycle.debug("Sound gewechselt → Vorschau gestoppt")
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Abbrechen") {
                        dismiss()
                    }
                    .foregroundColor(iosBlue)
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Sichern") {
                        Logger.alarm.debug("Speichere Alarm mit Sound: \(selectedSound, privacy: .public)")
                        
                        let newAlarm = Alarm(
                            time: selectedTime,
                            isEnabled: true,
                            label: alarmLabel.isEmpty ? "Wecker" : alarmLabel,
                            repeatDays: selectedDays,
                            soundName: selectedSound,
                            volume: volumeToInternal(selectedVolume) // UI 0-100% → Intern 0.5-1.0
                        )
                        
                        Logger.alarm.info("Alarm erstellt - Sound: \(newAlarm.soundName, privacy: .public)")
                        Logger.alarm.debug("Lautstärke: \(volumeToInternal(selectedVolume), privacy: .public) (0.25-0.8)")
                        Logger.nfc.debug("NFC-Scan erforderlich zum Aktivieren")
                        
                        dismiss()
                        onSave(newAlarm)
                    }
                    .foregroundColor(iosBlue)
                    .fontWeight(.semibold)
                }
            }
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }
    
    private func playPreview() {
        // Stoppe erst den alten Player (falls vorhanden)
        previewPlayer?.stop()
        
        guard let soundURL = Bundle.main.url(
            forResource: selectedSound.replacingOccurrences(of: ".caf", with: ""),
            withExtension: "caf"
        ) else {
            Logger.alarm.error("Vorschau Sound nicht gefunden: \(selectedSound, privacy: .public)")
            return
        }
        
        do {
            // Konvertiere zu interner Lautstärke (0.25-0.8)
            let internalVolume = volumeToInternal(selectedVolume)
            // Skaliere für System-Slider (0-1.0), damit 0.8 wie 100% aussieht
            let scaledVolume = internalToSystemVolume(internalVolume)
            setSystemVolume(scaledVolume)
            
            previewPlayer = try AVAudioPlayer(contentsOf: soundURL)
            previewPlayer?.numberOfLoops = -1 // Endlos Loop
            previewPlayer?.volume = 1.0 // Maximum (System-Volume regelt die Lautstärke)
            previewPlayer?.play()
            isPlayingPreview = true
            Logger.alarm.debug("Vorschau: Sound \(selectedSound, privacy: .public), Intern \(Int(internalVolume * 100), privacy: .public)%, System-Slider \(Int(scaledVolume * 100), privacy: .public)%")
        } catch {
            Logger.alarm.error("Vorschau Fehler: \(error.localizedDescription, privacy: .public)")
        }
    }
    
    private func stopPreview() {
        previewPlayer?.stop()
        previewPlayer = nil
        isPlayingPreview = false
        Logger.alarm.debug("Vorschau gestoppt")
    }
    
    private func updatePreviewVolume() {
        let internalVolume = volumeToInternal(selectedVolume)
        let scaledVolume = internalToSystemVolume(internalVolume)
        setSystemVolume(scaledVolume)
        Logger.alarm.debug("Lautstärke: Intern \(Int(internalVolume * 100), privacy: .public)%, System \(Int(scaledVolume * 100), privacy: .public)%")
    }
    
    private func setSystemVolume(_ volume: Float) {
        // Nutze MPVolumeView um System-Volume zu setzen
        let volumeView = MPVolumeView(frame: .zero)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            if let slider = volumeView.subviews.first(where: { $0 is UISlider }) as? UISlider {
                slider.value = volume
            }
        }
    }
}

// MARK: - Edit Alarm View
struct EditAlarmView: View {
    @Environment(\.dismiss) var dismiss
    let alarm: Alarm
    let iosBlue: Color
    let onSave: (Alarm) -> Void
    
    @State private var selectedTime: Date
    @State private var alarmLabel: String
    @State private var selectedDays: Set<Int>
    @State private var selectedSound: String
    @State private var selectedVolume: Float
    @State private var isPlayingPreview = false
    @State private var previewPlayer: AVAudioPlayer?
    
    let weekdaySymbols = ["M", "D", "M", "D", "F", "S", "S"] // Mo, Di, Mi, Do, Fr, Sa, So
    let weekdayOrder = [2, 3, 4, 5, 6, 7, 1] // Montag bis Sonntag
    
    init(alarm: Alarm, iosBlue: Color, onSave: @escaping (Alarm) -> Void) {
        self.alarm = alarm
        self.iosBlue = iosBlue
        self.onSave = onSave
        self._selectedTime = State(initialValue: alarm.time)
        self._alarmLabel = State(initialValue: alarm.label)
        self._selectedDays = State(initialValue: alarm.repeatDays)
        self._selectedSound = State(initialValue: alarm.soundName)
        // Konvertiere internen Wert (0.25-0.8) zu UI-Wert (0-1)
        self._selectedVolume = State(initialValue: (alarm.volume - 0.25) / 0.55)
    }
    
    // Konvertiere UI-Wert (0-1) zu internem Wert (0.25-0.8)
    private func volumeToInternal(_ uiVolume: Float) -> Float {
        return 0.25 + (uiVolume * 0.55)
    }
    
    // Konvertiere internen Wert (0.25-0.8) zu System-Slider (0-1.0)
    // Damit 0.8 wie "voll aufgedreht" aussieht
    private func internalToSystemVolume(_ internalVolume: Float) -> Float {
        return (internalVolume - 0.25) / 0.55
    }
    
    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                
                VStack(spacing: 0) {
                    // Time Picker
                    DatePicker("", selection: $selectedTime, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.wheel)
                        .labelsHidden()
                        .colorScheme(.dark)
                        .padding(.vertical, 20)
                    
                    // Settings List
                    VStack(spacing: 0) {
                        // Repeat Days
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Wiederholen")
                                    .foregroundColor(.white)
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                            
                            HStack(spacing: 0) {
                                ForEach(0..<7, id: \.self) { index in
                                    let day = weekdayOrder[index]
                                    Button(action: {
                                        if selectedDays.contains(day) {
                                            selectedDays.remove(day)
                                        } else {
                                            selectedDays.insert(day)
                                        }
                                    }) {
                                        Text(weekdaySymbols[index])
                                            .font(.system(size: 15, weight: .medium))
                                            .foregroundColor(selectedDays.contains(day) ? .white : .gray)
                                            .frame(maxWidth: .infinity)
                                            .frame(height: 42)
                                            .background(
                                                Circle()
                                                    .fill(selectedDays.contains(day) ? iosBlue : Color(white: 0.2))
                                                    .frame(width: 42, height: 42)
                                            )
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)
                        }
                        
                        Divider()
                            .background(Color(white: 0.2))
                        
                        // Label
                        HStack {
                            Text("Bezeichnung")
                                .foregroundColor(.white)
                            
                            Spacer()
                            
                            TextField("Wecker", text: $alarmLabel)
                                .foregroundColor(.gray)
                                .multilineTextAlignment(.trailing)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        
                        Divider()
                            .background(Color(white: 0.2))
                        
                        // Sound Selection
                        NavigationLink(destination: SoundPickerView(selectedSound: $selectedSound, iosBlue: iosBlue)) {
                            HStack {
                                Text("Sound")
                                    .foregroundColor(.white)
                                
                                Spacer()
                                
                                Text(availableSounds.first(where: { $0.file == selectedSound })?.name ?? "Wecker 1")
                                    .foregroundColor(.gray)
                                
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.gray)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        }
                        
                        Divider()
                            .background(Color(white: 0.2))
                        
                        // Volume Slider
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Lautstärke")
                                    .foregroundColor(.white)
                                
                                Spacer()
                                
                                if isPlayingPreview {
                                    Button(action: {
                                        stopPreview()
                                    }) {
                                        Image(systemName: "pause.circle.fill")
                                            .font(.system(size: 24))
                                            .foregroundColor(iosBlue)
                                    }
                                }
                            }
                            
                            HStack(spacing: 12) {
                                Image(systemName: "speaker.fill")
                                    .font(.system(size: 14))
                                    .foregroundColor(.gray)
                                
                                Slider(value: $selectedVolume, in: 0.0...1.0, step: 0.01)
                                .accentColor(iosBlue)
                                .onChange(of: selectedVolume) { _ in
                                    // Slider bewegt → Starte Vorschau (falls nicht läuft)
                                    if !isPlayingPreview {
                                        playPreview()
                                    } else {
                                        updatePreviewVolume()
                                    }
                                }
                                
                                Image(systemName: "speaker.wave.3.fill")
                                    .font(.system(size: 14))
                                    .foregroundColor(.gray)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                    .background(Color(white: 0.11))
                    .cornerRadius(13)
                    .padding(.horizontal, 16)
                    
                    Spacer()
                }
            }
            .navigationTitle("Wecker bearbeiten")
            .onDisappear {
                stopPreview()
            }
            .onChange(of: selectedSound) { _ in
                // Sound gewechselt → Stoppe alte Vorschau
                stopPreview()
                Logger.lifecycle.debug("Sound gewechselt → Vorschau gestoppt")
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Abbrechen") {
                        dismiss()
                    }
                    .foregroundColor(iosBlue)
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Sichern") {
                        Logger.alarm.debug("Bearbeite Alarm - Alter Sound: \(alarm.soundName, privacy: .public)")
                        Logger.alarm.debug("Bearbeite Alarm - Neuer Sound: \(selectedSound, privacy: .public)")
                        
                        var updatedAlarm = alarm
                        updatedAlarm.time = selectedTime
                        updatedAlarm.label = alarmLabel.isEmpty ? "Wecker" : alarmLabel
                        updatedAlarm.repeatDays = selectedDays
                        updatedAlarm.soundName = selectedSound
                        updatedAlarm.volume = volumeToInternal(selectedVolume) // UI 0-100% → Intern 0.5-1.0
                        
                        Logger.alarm.info("Alarm gespeichert - Sound jetzt: \(updatedAlarm.soundName, privacy: .public)")
                        Logger.alarm.debug("Lautstärke: \(volumeToInternal(selectedVolume), privacy: .public) (0.25-0.8)")
                        Logger.nfc.debug("NFC-Scan erforderlich zum Aktivieren")
                        
                        dismiss()
                        onSave(updatedAlarm)
                    }
                    .foregroundColor(iosBlue)
                    .fontWeight(.semibold)
                }
            }
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }
    
    private func playPreview() {
        // Stoppe erst den alten Player (falls vorhanden)
        previewPlayer?.stop()
        
        guard let soundURL = Bundle.main.url(
            forResource: selectedSound.replacingOccurrences(of: ".caf", with: ""),
            withExtension: "caf"
        ) else {
            Logger.alarm.error("Vorschau Sound nicht gefunden: \(selectedSound, privacy: .public)")
            return
        }
        
        do {
            // Konvertiere zu interner Lautstärke (0.25-0.8)
            let internalVolume = volumeToInternal(selectedVolume)
            // Skaliere für System-Slider (0-1.0), damit 0.8 wie 100% aussieht
            let scaledVolume = internalToSystemVolume(internalVolume)
            setSystemVolume(scaledVolume)
            
            previewPlayer = try AVAudioPlayer(contentsOf: soundURL)
            previewPlayer?.numberOfLoops = -1 // Endlos Loop
            previewPlayer?.volume = 1.0 // Maximum (System-Volume regelt die Lautstärke)
            previewPlayer?.play()
            isPlayingPreview = true
            Logger.alarm.debug("Vorschau: Sound \(selectedSound, privacy: .public), Intern \(Int(internalVolume * 100), privacy: .public)%, System-Slider \(Int(scaledVolume * 100), privacy: .public)%")
        } catch {
            Logger.alarm.error("Vorschau Fehler: \(error.localizedDescription, privacy: .public)")
        }
    }
    
    private func stopPreview() {
        previewPlayer?.stop()
        previewPlayer = nil
        isPlayingPreview = false
        Logger.alarm.debug("Vorschau gestoppt")
    }
    
    private func updatePreviewVolume() {
        let internalVolume = volumeToInternal(selectedVolume)
        let scaledVolume = internalToSystemVolume(internalVolume)
        setSystemVolume(scaledVolume)
        Logger.alarm.debug("Lautstärke: Intern \(Int(internalVolume * 100), privacy: .public)%, System \(Int(scaledVolume * 100), privacy: .public)%")
    }
    
    private func setSystemVolume(_ volume: Float) {
        // Nutze MPVolumeView um System-Volume zu setzen
        let volumeView = MPVolumeView(frame: .zero)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            if let slider = volumeView.subviews.first(where: { $0 is UISlider }) as? UISlider {
                slider.value = volume
            }
        }
    }
}

// MARK: - NFC Activation View [DEAKTIVIERT]
#if ENABLE_NFC
// [NFC DEAKTIVIERT] — NFCActivationView
struct NFCActivationView: View {
    @Binding var isPresented: Bool
    let iosBlue: Color
    let alarmLabel: String
    let onSuccess: () -> Void
    
    @StateObject private var nfcReader = NFCAlarmReader()
    @State private var showError = false
    @State private var errorMessage = ""
    
    var body: some View {
        NavigationView {
            ZStack {
                Color.black
                    .ignoresSafeArea()
                
                VStack(spacing: 40) {
                    Spacer()
                    
                    // NFC Icon (groß)
                    ZStack {
                        Circle()
                            .fill(iosBlue.opacity(0.2))
                            .frame(width: 150, height: 150)
                        
                        Image(systemName: "sensor.tag.radiowaves.forward.fill")
                            .font(.system(size: 70))
                            .foregroundColor(iosBlue)
                    }
                    
                    // Titel
                    Text("Alarm aktivieren")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundColor(.white)
                    
                    // Alarm Info
                    VStack(spacing: 8) {
                        Text(alarmLabel)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(.white)
                        
                        Text("Halte dein Handy an deinen WakeFlow um den Alarm zu aktivieren")
                            .font(.system(size: 14))
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 40)
                    
                    // Error Message
                    if showError {
                        Text(errorMessage)
                            .font(.system(size: 14))
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                    
                    Spacer()
                    
                    // NFC SCAN Button (nur anzeigen wenn NFC fehlgeschlagen ist)
                    if showError {
                        Button(action: {
                            Logger.nfc.debug("NFC Button gedrückt (erneuter Versuch)")
                            
                            if NFCNDEFReaderSession.readingAvailable {
                                showError = false
                                nfcReader.startScanning(actionType: .activate)
                            } else {
                                errorMessage = "NFC wird auf diesem Gerät nicht unterstützt."
                            }
                        }) {
                            HStack(spacing: 15) {
                                Image(systemName: "sensor.tag.radiowaves.forward.fill")
                                    .font(.system(size: 24))
                                
                                Text("ERNEUT VERSUCHEN")
                                    .font(.system(size: 20, weight: .bold))
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 70)
                            .background(
                                RoundedRectangle(cornerRadius: 20)
                                    .fill(iosBlue)
                            )
                            .padding(.horizontal, 40)
                        }
                    }
                    
                    Spacer()
                        .frame(height: 60)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Abbrechen") {
                        isPresented = false
                    }
                    .foregroundColor(iosBlue)
                }
            }
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .onChange(of: nfcReader.isScanned) { isScanned in
            if isScanned {
                Logger.nfc.notice("NFC gescannt - Alarm wird aktiviert")
                isPresented = false
                onSuccess()
            }
        }
        .onAppear {
            Logger.nfc.debug("NFCActivationView geladen für: \(alarmLabel, privacy: .public)")
            
            // Starte NFC-Scan AUTOMATISCH beim Erscheinen
            if NFCNDEFReaderSession.readingAvailable {
                Logger.nfc.info("NFC-Scan startet automatisch")
                // Kleine Verzögerung für bessere UX
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    nfcReader.startScanning(actionType: .activate)
                }
            } else {
                showError = true
                errorMessage = "NFC wird auf diesem Gerät nicht unterstützt."
                Logger.nfc.error("NFC nicht verfügbar auf diesem Gerät")
            }
        }
    }
}
#endif

// MARK: - Alarm Stop View [DEAKTIVIERT]
#if ENABLE_NFC
// [NFC DEAKTIVIERT] — AlarmStopView
struct AlarmStopView: View {
    @Binding var isPresented: Bool
    @ObservedObject var backgroundAlarmManager: BackgroundAlarmManager
    let iosBlue: Color
    let onAlarmStopped: (UUID?) -> Void
    
    @StateObject private var nfcReader = NFCAlarmReader()
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var alarmIDBeforeStop: UUID?
    
    var body: some View {
        ZStack {
            // Background
            Color.black
                .ignoresSafeArea()
            
            VStack(spacing: 40) {
                Spacer()
                
                // Alarm Icon (animated)
                ZStack {
                    Circle()
                        .fill(iosBlue.opacity(0.2))
                        .frame(width: 150, height: 150)
                    
                    Image(systemName: "alarm.fill")
                        .font(.system(size: 70))
                        .foregroundColor(iosBlue)
                }
                .scaleEffect(backgroundAlarmManager.isPlaying ? 1.1 : 1.0)
                .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: backgroundAlarmManager.isPlaying)
                
                // Titel
                Text("Wecker klingelt")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundColor(.white)
                
                // NFC Icon
                Image(systemName: "wave.3.right")
                    .font(.system(size: 60))
                    .foregroundColor(iosBlue)
                    .padding(.top, 20)
                
                // Error Message
                if showError {
                    Text(errorMessage)
                        .font(.system(size: 14))
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
                
                Spacer()
                
                // NFC SCAN Button (nur anzeigen wenn NFC fehlgeschlagen ist)
                if showError {
                    Button(action: {
                        Logger.nfc.debug("NFC Button gedrückt (erneuter Versuch)")
                        Logger.nfc.debug("NFC verfügbar: \(NFCNDEFReaderSession.readingAvailable, privacy: .public)")
                        
                        if NFCNDEFReaderSession.readingAvailable {
                            showError = false
                            nfcReader.startScanning(actionType: .deactivate)
                        } else {
                            errorMessage = "NFC wird auf diesem Gerät nicht unterstützt.\nBenötigt iPhone 7 oder neuer."
                            Logger.nfc.error("NFC nicht verfügbar")
                        }
                    }) {
                        HStack(spacing: 15) {
                            Image(systemName: "sensor.tag.radiowaves.forward.fill")
                                .font(.system(size: 24))
                            
                            Text("ERNEUT VERSUCHEN")
                                .font(.system(size: 20, weight: .bold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 70)
                        .background(
                            RoundedRectangle(cornerRadius: 20)
                                .fill(iosBlue)
                        )
                        .padding(.horizontal, 40)
                    }
                }
                
                // DEBUG: Skip Button (nur für Tests)
                #if DEBUG
                Button(action: {
                    Logger.alarm.notice("DEBUG: Alarm wird ohne NFC gestoppt")
                    onAlarmStopped(alarmIDBeforeStop)
                    backgroundAlarmManager.stopAlarm()
                    isPresented = false
                }) {
                    Text("DEBUG: Ohne NFC stoppen")
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                }
                .padding(.top, 10)
                #endif
                
                Spacer()
                    .frame(height: 60)
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: nfcReader.isScanned) { isScanned in
            if isScanned {
                // NFC erkannt → Alarm stoppen!
                Logger.nfc.notice("NFC gescannt - Alarm wird gestoppt")
                
                // Callback ZUERST aufrufen (bevor stopAlarm() die ID löscht)
                onAlarmStopped(alarmIDBeforeStop)
                
                backgroundAlarmManager.stopAlarm()
                isPresented = false
            }
        }
        .onAppear {
            // Speichere die Alarm-ID BEVOR sie durch stopAlarm() gelöscht wird
            alarmIDBeforeStop = backgroundAlarmManager.getCurrentAlarmID()
            Logger.nfc.debug("AlarmStopView geladen - Alarm ID: \(alarmIDBeforeStop?.uuidString ?? "nil", privacy: .public)")
            Logger.nfc.debug("NFC verfügbar: \(NFCNDEFReaderSession.readingAvailable, privacy: .public)")
            
            // Starte NFC-Scan AUTOMATISCH beim Erscheinen
            if NFCNDEFReaderSession.readingAvailable {
                Logger.nfc.info("NFC-Scan startet automatisch (Alarm stoppen)")
                // Kleine Verzögerung für bessere UX
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    nfcReader.startScanning(actionType: .deactivate)
                }
            } else {
                showError = true
                errorMessage = "NFC wird auf diesem Gerät nicht unterstützt.\nBenötigt iPhone 7 oder neuer."
                Logger.nfc.error("NFC nicht verfügbar auf diesem Gerät")
            }
        }
    }
}
#endif

// MARK: - Sound Picker View
struct SoundPickerView: View {
    @Environment(\.dismiss) var dismiss
    @Binding var selectedSound: String
    let iosBlue: Color
    
    @StateObject private var previewPlayer = SoundPreviewPlayer()
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            List {
                ForEach(availableSounds, id: \.file) { sound in
                    Button(action: {
                        Logger.alarm.debug("Sound ausgewählt: \(sound.file, privacy: .public) (\(sound.name, privacy: .public))")
                        selectedSound = sound.file
                        // Spiele den Sound in Endlosschleife ab
                        previewPlayer.playSound(sound.file)
                    }) {
                        HStack {
                            Text(sound.name)
                                .foregroundColor(.white)
                            
                            Spacer()
                            
                            if selectedSound == sound.file {
                                Image(systemName: "checkmark")
                                    .foregroundColor(iosBlue)
                                    .font(.system(size: 16, weight: .semibold))
                            }
                        }
                    }
                    .listRowBackground(Color(white: 0.11))
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Sound")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
        .toolbarBackground(.black, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onDisappear {
            // Stoppe den Sound wenn man zurück navigiert
            previewPlayer.stop()
            Logger.alarm.debug("Sound-Vorschau gestoppt")
        }
    }
}

// MARK: - Sound Preview Player
class SoundPreviewPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    private var audioPlayer: AVAudioPlayer?
    private var originalVolume: Float = 0.5
    private var volumeView: MPVolumeView?
    private var volumeSlider: UISlider?
    
    override init() {
        super.init()
        setupVolumeControl()
    }
    
    private func setupVolumeControl() {
        volumeView = MPVolumeView(frame: .zero)
        if let view = volumeView {
            for subview in view.subviews {
                if let slider = subview as? UISlider {
                    volumeSlider = slider
                    break
                }
            }
        }
    }
    
    private func setSystemVolume(_ volume: Float) {
        volumeSlider?.value = volume
        Logger.alarm.debug("Systemlautstärke gesetzt auf: \(volume, privacy: .public)")
    }
    
    func playSound(_ soundFile: String) {
        // Stoppe den aktuellen Sound falls einer läuft
        stop()
        
        guard let url = Bundle.main.url(forResource: soundFile, withExtension: nil) else {
            Logger.alarm.error("Sound-Datei nicht gefunden: \(soundFile, privacy: .public)")
            return
        }
        
        do {
            // Speichere aktuelle Lautstärke
            originalVolume = AVAudioSession.sharedInstance().outputVolume
            Logger.alarm.debug("Original-Lautstärke gespeichert: \(self.originalVolume, privacy: .public)")
            
            // Konfiguriere Audio Session für Vorschau
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
            
            // Setze Systemlautstärke auf 0.4
            setSystemVolume(0.4)
            
            // Erstelle neuen Player
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.delegate = self
            audioPlayer?.numberOfLoops = -1 // Endlosschleife
            audioPlayer?.volume = 1.0 // Volle Player-Lautstärke, da wir System-Lautstärke kontrollieren
            audioPlayer?.prepareToPlay()
            audioPlayer?.play()
            
            Logger.alarm.debug("Sound-Vorschau gestartet: \(soundFile, privacy: .public) bei 0.4 Systemlautstärke")
        } catch {
            Logger.alarm.error("Fehler beim Abspielen der Vorschau: \(error.localizedDescription, privacy: .public)")
        }
    }
    
    func stop() {
        audioPlayer?.stop()
        audioPlayer = nil
        
        // Stelle ursprüngliche Lautstärke wieder her
        setSystemVolume(originalVolume)
        Logger.alarm.debug("Original-Lautstärke wiederhergestellt: \(self.originalVolume, privacy: .public)")
    }
}

// MARK: - Moon View
struct MoonView: View {
    let iosBlue: Color
    @ObservedObject var backgroundAlarmManager: BackgroundAlarmManager
    #if ENABLE_NFC
    @StateObject private var nfcReader = NFCAlarmReader()
    #endif
    @State private var isPressed = false
    @State private var showSuccess = false
    @State private var pulseScale: CGFloat = 1.0
    // Speichere Alarm-ID BEVOR sie durch stopAlarm() gelöscht wird
    // (1:1 Übernahme aus AlarmStopView-NFC-Flow)
    @State private var alarmIDBeforeStop: UUID?
    let onAlarmStopped: (UUID?) -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 40) {
                Spacer()

                // Interaktiver Mond - Neues Design
                Button(action: {
                    #if ENABLE_NFC
                    stopAlarmWithNFC()
                    #else
                    stopAlarmDirectly()
                    #endif
                }) {
                    Image("CrescentMoon")
                        .resizable()
                        .renderingMode(.original)
                        .interpolation(.high)
                        .antialiased(true)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 380, height: 380)
                        // Leichte Optimierung für dein neues 3D-Design
                        .contrast(1.1)
                        .brightness(0.02)
                        // Subtiler Schatten für zusätzliche Tiefe
                        .shadow(color: Color.black.opacity(0.3), radius: 20, x: 0, y: 10)
                        // Animations-Effekte beim Drücken
                        .scaleEffect(isPressed ? 0.95 : 1.0)
                        .opacity(isPressed ? 0.8 : 1.0)
                        .animation(.spring(response: 0.3), value: isPressed)
                        // Pulsierender Effekt
                        .scaleEffect(pulseScale)
                }
                .buttonStyle(PlainButtonStyle())
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            isPressed = true
                        }
                        .onEnded { _ in
                            isPressed = false
                        }
                )

                // Status Text
                if showSuccess {
                    Text("✅ Alarm gestoppt!")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.green)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    VStack(spacing: 12) {
                        Text("🔔 Wecker klingelt")
                            .font(.system(size: 34, weight: .bold))
                            .foregroundColor(.white)

                        Text("Tippe auf den Mond um den Alarm zu stoppen")
                            .font(.system(size: 16))
                            .foregroundColor(iosBlue)
                            .multilineTextAlignment(.center)
                    }
                }


                Spacer()
            }
            .padding(.horizontal, 40)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            // WICHTIG: Speichere Alarm-ID SOFORT beim Erscheinen,
            // BEVOR irgendwas anderes passiert. Genau wie im NFC-Flow
            // (AlarmStopView.onAppear). Sonst ist sie nach stopAlarm() nil.
            alarmIDBeforeStop = backgroundAlarmManager.getCurrentAlarmID()
            Logger.lifecycle.debug("MoonView geladen - Alarm ID: \(alarmIDBeforeStop?.uuidString ?? "nil", privacy: .public)")

            // Starte pulsierende Animation - subtiler
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                pulseScale = 1.05
            }
        }
        #if ENABLE_NFC
        .onChange(of: nfcReader.isScanned) { isScanned in
            if isScanned {
                // 1. Callback ZUERST aufrufen (bevor stopAlarm() die ID löscht)
                onAlarmStopped(alarmIDBeforeStop)

                // 2. DANACH Alarm stoppen
                backgroundAlarmManager.stopAlarm()

                withAnimation {
                    showSuccess = true
                }

                // Erfolgs-Feedback
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.success)

                // Screen verschwindet automatisch wenn isPlaying false wird
                nfcReader.isScanned = false
            }
        }
        #endif
    }

    #if ENABLE_NFC
    private func stopAlarmWithNFC() {
        Logger.alarm.notice("Mond gedrückt - Stoppe Alarm mit NFC")

        // Haptic Feedback
        let generator = UIImpactFeedbackGenerator(style: .heavy)
        generator.impactOccurred()

        if NFCNDEFReaderSession.readingAvailable {
            nfcReader.startScanning(actionType: .deactivate)
        } else {
            Logger.nfc.error("NFC nicht verfügbar auf diesem Gerät")
        }
    }
    #endif

    private func stopAlarmDirectly() {
        // 1:1 Nachbau des NFC-Stop-Flows (AlarmStopView.onChange).
        // Reihenfolge ist KRITISCH und muss exakt mit dem Original übereinstimmen.

        Logger.alarm.notice("Stop-Button gedrückt - Alarm wird gestoppt")

        // Pre-Stop Haptic (wie stopAlarmWithNFC vor dem Scan)
        let impactGenerator = UIImpactFeedbackGenerator(style: .heavy)
        impactGenerator.impactOccurred()

        // 1. Callback ZUERST aufrufen (bevor stopAlarm() die ID löscht).
        //    Wir nutzen die in onAppear zwischengespeicherte ID,
        //    exakt wie AlarmStopView es gemacht hat.
        onAlarmStopped(alarmIDBeforeStop)

        // 2. DANACH Alarm stoppen (setzt isPlaying=false,
        //    entfernt Notifications, schließt MoonView via fullScreenCover)
        backgroundAlarmManager.stopAlarm()

        // 3. Erfolgs-Animation + Haptic (wie in MoonView.onChange-NFC-Flow)
        withAnimation {
            showSuccess = true
        }
        let successGenerator = UINotificationFeedbackGenerator()
        successGenerator.notificationOccurred(.success)
    }
}

// MARK: - Settings View
struct SettingsView: View {
    @State private var sleepTime = Calendar.current.date(bySettingHour: 22, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var showSaveAlert = false
    
    let iosBlue = Color(red: 0/255, green: 122/255, blue: 255/255)
    
    var body: some View {
        NavigationStack {
            List {
                Section("🌙 Schlafenszeit") {
                    HStack {
                        Image(systemName: "moon.stars.fill")
                            .foregroundColor(.orange)
                        
                        DatePicker(
                            "Wann gehst du schlafen?",
                            selection: $sleepTime,
                            displayedComponents: .hourAndMinute
                        )
                        .onChange(of: sleepTime) { _ in
                            showSaveAlert = true
                        }
                    }
                    
                    Text("Du wirst täglich um diese Zeit erinnert, die WakeFlow App zu öffnen")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
                
                Section("💡 Infobox") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.headline)
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Wie es funktioniert:").font(.headline)
                                Text("1. Stelle deine Schlafenszeit ein").font(.caption)
                                Text("2. Um diese Zeit bekommst du eine Erinnerung").font(.caption)
                                Text("3. Öffne WakeFlow wenn die Erinnerung kommt").font(.caption)
                                Text("4. Die App wird dann für 15-30 Min im Hintergrund aktiv").font(.caption)
                                Text("5. Dein Wecker klingelt zuverlässig am nächsten Morgen 🎯").font(.caption)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
                
                Section("🔊 Backup-System") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "bell.badge.fill")
                                .foregroundColor(.blue)
                            Text("Fallback-Notifications").font(.headline)
                        }
                        
                        Text("Wenn die App trotz Keep-Alive gekillt wird, spielt die Backup-Notification den Alarm-Sound ab. Das funktioniert auch ohne dass die App läuft!")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    .padding(.vertical, 8)
                }
            }
            .navigationTitle("Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .alert("Schlafenszeit gespeichert", isPresented: $showSaveAlert) {
                Button("OK") {
                    saveSleepTime()
                    showSaveAlert = false
                }
            } message: {
                Text("Deine Schlafenszeit wurde aktualisiert. Du bekommst täglich um \(sleepTime.formatted(date: .omitted, time: .shortened)) eine Erinnerung.")
            }
        }
        .onAppear {
            loadSleepTime()
        }
    }
    
    private func saveSleepTime() {
        let defaults = UserDefaults.standard
        defaults.set(sleepTime.timeIntervalSince1970, forKey: "sleepTime")
        
        // Plane Reminder-Notification neu
        if let backgroundManager = BackgroundAlarmManager.shared as? BackgroundAlarmManager {
            backgroundManager.scheduleReminderNotification(at: sleepTime)
        }
        
        Logger.lifecycle.debug("Schlafenszeit gespeichert: \(sleepTime.formatted(date: .omitted, time: .shortened), privacy: .public)")
    }
    
    private func loadSleepTime() {
        let defaults = UserDefaults.standard
        if let sleepTimeInterval = defaults.object(forKey: "sleepTime") as? TimeInterval {
            sleepTime = Date(timeIntervalSince1970: sleepTimeInterval)
        }
    }
}

#Preview {
    ContentView()
}
