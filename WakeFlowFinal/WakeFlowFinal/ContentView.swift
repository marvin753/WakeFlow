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
import CoreNFC


// MARK: - Collection Extension (Safe Array Access)
extension Collection {
    subscript(safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}

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

// MARK: - NFC Alarm Reader
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
        print("🔵 startScanning() aufgerufen")
        print("📡 NFCNDEFReaderSession.readingAvailable: \(NFCNDEFReaderSession.readingAvailable)")

        guard NFCNDEFReaderSession.readingAvailable else {
            DispatchQueue.main.async {
                self.statusMessage = "NFC wird auf diesem\nGerät nicht unterstützt"
            }
            print("❌ NFC nicht verfügbar auf diesem Gerät")
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

        print("📡 ✅ NFC Scanner gestartet!")
    }

    func readerSession(_ session: NFCNDEFReaderSession, didDetectNDEFs messages: [NFCNDEFMessage]) {
        // NFC-Tag erkannt!
        DispatchQueue.main.async {
            self.isScanned = true
            self.statusMessage = "✅ NFC-Chip erkannt!"

            if self.actionType == .activate {
                print("✅ NFC-Tag erkannt - Alarm wird aktiviert!")
            } else {
                print("✅ NFC-Tag erkannt - Alarm wird gestoppt!")
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
                print("⚠️ NFC Scan abgebrochen")
                DispatchQueue.main.async {
                    self.statusMessage = "Scan abgebrochen"
                }
            case .readerSessionInvalidationErrorFirstNDEFTagRead:
                // Tag wurde gelesen - das ist Erfolg!
                print("✅ NFC-Tag erfolgreich gelesen")
            default:
                print("❌ NFC Fehler: \(error.localizedDescription)")
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
                    print("✅ NFC-Tag gescannt - Alarm wird gestoppt!")
                }

                session.alertMessage = "✅ Erkannt! Alarm wird gestoppt..."
                session.invalidate()
            }
        }
    }
}

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
    
    override init() {
        super.init()
        setupAudioSession()
        startMonitoring()
        observeVolumeChanges()
        startSilentAudio() // Starte stillen Audio-Stream
    }
    
    // Konvertiere internen Wert (0.25-0.8) zu System-Slider (0-1.0)
    // Damit 0.8 wie "voll aufgedreht" aussieht
    private func internalToSystemVolume(_ internalVolume: Float) -> Float {
        return (internalVolume - 0.25) / 0.55
    }
    
    func setupAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            // WICHTIG: playback ohne Options = VOLLE LAUTSTÄRKE!
            try audioSession.setCategory(.playback, mode: .default, options: [])
            try audioSession.setActive(true, options: [])
            print("✅ Audio Session konfiguriert (VOLLE POWER)")
        } catch {
            print("❌ Audio Session Fehler: \(error)")
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
        
        print("✅ Volume Observer aktiviert")
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
        print("🔊 Lautstärke auf MAXIMUM erzwungen!")
    }
    
    func startMonitoring() {
        checkTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkAlarms()
        }
        RunLoop.current.add(checkTimer!, forMode: .common)
        print("✅ Alarm-Überwachung gestartet")
    }
    
    var alarmsToCheck: [Alarm] = []
    
    func updateAlarms(_ alarms: [Alarm]) {
        alarmsToCheck = alarms
    }
    
    private func checkAlarms() {
        let now = Date()
        let calendar = Calendar.current
        let currentComponents = calendar.dateComponents([.hour, .minute, .second, .weekday], from: now)
        
        // Debug: Zeige aktuelle Zeit
        if currentComponents.second == 0 {
            print("⏰ Checking alarms at \(currentComponents.hour ?? 0):\(currentComponents.minute ?? 0) Weekday: \(currentComponents.weekday ?? 0)")
            print("⏰ Active alarms count: \(alarmsToCheck.filter { $0.isEnabled }.count)")
        }
        
        for alarm in alarmsToCheck where alarm.isEnabled {
            let alarmComponents = calendar.dateComponents([.hour, .minute], from: alarm.time)
            
            if currentComponents.hour == alarmComponents.hour &&
               currentComponents.minute == alarmComponents.minute &&
               currentComponents.second == 0 {
                
                if alarm.repeatDays.isEmpty || alarm.repeatDays.contains(currentComponents.weekday ?? 0) {
                    if currentAlarmID != alarm.id {
                        print("🔔 ALARM TRIGGERED: \(alarm.label)")
                        playAlarm(alarm)
                        currentAlarmID = alarm.id
                    }
                }
            }
        }
    }
    
    func playAlarm(_ alarm: Alarm) {
        print("🎵 Versuche Sound zu laden: \(alarm.soundName)")
        
        guard let soundURL = Bundle.main.url(
            forResource: alarm.soundName.replacingOccurrences(of: ".caf", with: ""),
            withExtension: "caf"
        ) else {
            print("❌ Sound nicht gefunden: \(alarm.soundName)")
            print("❌ Gesuchter Dateiname: \(alarm.soundName.replacingOccurrences(of: ".caf", with: ""))")
            return
        }
        
        currentSoundURL = soundURL
        currentAlarmID = alarm.id
        alarmStartTime = Date()
        targetVolume = alarm.volume // Setze Ziel-Lautstärke
        isPlaying = true
        
        // Speichere Alarm-Status persistent (für App-Neustart nach Kill)
        saveActiveAlarmState(alarm)
        
        print("🔊 Alarm startet: \(alarm.label)")
        print("✅ Sound geladen: \(soundURL.lastPathComponent)")
        print("🔊 Ziel-Lautstärke: \(Int(targetVolume * 100))% (wird erzwungen!)")
        
        // 1. Starte Audio ZUERST (das ist dein Sound!)
        playSoundLoop()
        
        // 2. Starte Volume-Enforce Timer (prüft alle 0.1 Sekunden!)
        startVolumeEnforcement()
        
        // 3. Starte kontinuierliche Vibration
        startVibration()
        
        // 4. Sende HIGH PRIORITY Notification (triggert iOS Wecker-ähnliche UI)
        sendSystemAlarmNotification(for: alarm)
        
        // Stoppe nach 10 Minuten automatisch
        stopTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: false) { [weak self] _ in
            print("⏱️ 10 Minuten vorbei - Alarm stoppt automatisch")
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
            print("📳 Vibration ausgelöst")
        }
        
        RunLoop.current.add(vibrationTimer!, forMode: .common)
        print("✅ Kontinuierliche Vibration gestartet (alle 2s)")
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
                print("🔊 System-Volume geändert: \(Int(currentSystemVolume * 100))% → Setze zurück auf \(Int(scaledTargetVolume * 100))%!")
                print("   (Intern: \(Int(self.targetVolume * 100))%)")
                self.setSystemVolume(scaledTargetVolume)
            }
            
            // 2. Prüfe ob Player noch spielt und auf Maximum steht
            if let player = self.audioPlayer {
                // Stelle sicher dass Player-Volume IMMER auf 1.0 bleibt
                if player.volume < 1.0 {
                    player.volume = 1.0
                    print("🔊 Player-Volume zurückgesetzt auf MAXIMUM (1.0)!")
                }
                
                // 3. Prüfe ob Player noch spielt
                if !player.isPlaying {
                    print("⚠️ Player gestoppt - starte neu!")
                    player.play()
                }
            }
            
            // 4. Halte Audio Session aktiv
            do {
                try AVAudioSession.sharedInstance().setActive(true, options: [])
            } catch {
                // Silent fail
            }
        }
        
        RunLoop.current.add(volumeEnforceTimer!, forMode: .common)
        print("✅ Volume-Enforcement Timer gestartet (alle 0.05s)")
        print("🔒 Interne Lautstärke: \(Int(targetVolume * 100))% (0.25-0.8)")
        print("🔒 System-Volume erscheint als: \(Int(scaledVolume * 100))% (skaliert auf 0-1.0)")
    }
    
    private func setSystemVolume(_ volume: Float) {
        // Nutze MPVolumeView um System-Volume zu setzen
        let volumeView = MPVolumeView(frame: .zero)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            if let slider = volumeView.subviews.first(where: { $0 is UISlider }) as? UISlider {
                slider.value = volume
                print("🔊 System-Volume gesetzt auf: \(volume)")
            }
        }
    }
    
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
            
            print("📳 Notification #\(self.notificationCount) gesendet")
            
            // Stoppe nach 100 Notifications (5 Minuten)
            if self.notificationCount >= 100 {
                self.notificationTimer?.invalidate()
                self.notificationTimer = nil
                print("⏹️ Notification Timer gestoppt (100 erreicht)")
            }
        }
        
        RunLoop.current.add(notificationTimer!, forMode: .common)
        print("✅ Notification Timer gestartet (alle 3s)")
        print("📱 Erste Notification SOFORT gesendet!")
    }
    
    // Scheduled Notifications als Backup (funktionieren auch wenn App gekillt wird)
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
                print("⚠️ Keine verfügbaren Slots für Backup-Notifications (Limit erreicht)")
                return
            }

            // Erstelle scheduled notifications (alle 3 Sekunden)
            for i in 1...scheduleCount {
                let content = UNMutableNotificationContent()
                content.title = "⏰ \(alarm.label)"
                content.body = "Wecker klingelt - Öffne die App zum Stoppen"
                content.interruptionLevel = .timeSensitive // [CRITICAL MESSAGING DEAKTIVIERT — war .critical]
                content.sound = .default // [CRITICAL MESSAGING DEAKTIVIERT — war .defaultCritical]
                content.badge = NSNumber(value: i)
                content.categoryIdentifier = "ALARM_CATEGORY"
                content.userInfo = ["alarmID": alarm.id.uuidString]

                let timeInterval = TimeInterval(i * 3)
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: timeInterval, repeats: false)

                let request = UNNotificationRequest(
                    identifier: "backup-alarm-\(alarm.id.uuidString)-\(i)",
                    content: content,
                    trigger: trigger
                )

                center.add(request) { error in
                    if let error = error {
                        print("❌ Backup Notification \(i) Fehler: \(error)")
                    } else if i == 1 || i == scheduleCount {
                        print("✅ Backup Notification \(i) geplant für +\(timeInterval)s")
                    }
                }
            }

            print("✅ \(scheduleCount) Backup Notifications geplant (Sound + Vibration)")
        }
    }
    
    private func sendSingleNotification(for alarm: Alarm, count: Int) {
        // Wenn pausiert, sende keine Notification
        guard !notificationsPaused else {
            print("⏸️ Notifications sind pausiert (App ist offen)")
            return
        }
        
        let content = UNMutableNotificationContent()
        content.title = "⏰ \(alarm.label)"
        content.body = "Wecker klingelt - Öffne die App zum Stoppen"
        
        // [CRITICAL MESSAGING DEAKTIVIERT] — Standard interruption
        content.interruptionLevel = .timeSensitive // [CRITICAL MESSAGING DEAKTIVIERT — war .critical]

        // [CRITICAL MESSAGING DEAKTIVIERT] — Standard sound
        content.sound = .default // [CRITICAL MESSAGING DEAKTIVIERT — war .defaultCritical]
        
        // Badge
        content.badge = NSNumber(value: count + 1)
        
        // Category mit Action
        content.categoryIdentifier = "ALARM_CATEGORY"
        content.userInfo = ["alarmID": alarm.id.uuidString]
        
        // Unique identifier für jede Notification
        let request = UNNotificationRequest(
            identifier: "wakeflow-alarm-\(alarm.id.uuidString)-\(count)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil // Sofort senden!
        )
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("❌ Notification \(count) Fehler: \(error)")
            }
        }
    }
    
    private func playSoundLoop() {
        guard let soundURL = currentSoundURL else { return }
        
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
                print("▶️ Sound spielt in ENDLOS LOOP mit Player-Volume: 1.0 (MAX)")
                print("🔒 System-Lautstärke: \(Int(targetVolume * 100))% (wird ERZWUNGEN!)")
            } else {
                print("❌ Sound konnte nicht abgespielt werden")
            }
        } catch {
            print("❌ Audio Player Fehler: \(error.localizedDescription)")
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
            print("🔊 System-Volume wiederhergestellt: \(originalSystemVolume)")
        }
        
        isPlaying = false
        
        // Remove ALL notifications (delivered + pending!)
        if let alarmID = currentAlarmID {
            // Phase 1 — Synchronous removal of all KNOWN identifier patterns
            var knownIdentifiers: [String] = []
            for i in 0..<60 {
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

            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: knownIdentifiers)
            center.removeDeliveredNotifications(withIdentifiers: knownIdentifiers)
            print("🗑️ \(knownIdentifiers.count) bekannte Notification-IDs synchron entfernt")

            // Phase 2 — Asynchronous catch-all for timestamp-based IDs (sendSingleNotification)
            center.getPendingNotificationRequests { requests in
                let leftover = requests
                    .filter { $0.identifier.contains(alarmID.uuidString) }
                    .map { $0.identifier }
                if !leftover.isEmpty {
                    center.removePendingNotificationRequests(withIdentifiers: leftover)
                    print("🗑️ \(leftover.count) weitere pending Notifications entfernt (catch-all via UUID)")
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
        
        print("🛑 Alarm gestoppt (Audio + Notifications + Volume-Enforcement)")
    }
    
    // Pausiere Notifications wenn App geöffnet wird
    func pauseNotifications() {
        guard isPlaying else { return }
        notificationsPaused = true
        print("⏸️ Notifications pausiert (App wurde geöffnet)")
    }
    
    // Setze Notifications fort wenn App geschlossen wird
    func resumeNotifications() {
        guard isPlaying else { return }
        notificationsPaused = false
        print("▶️ Notifications fortgesetzt (App wurde geschlossen)")
    }
    
    // WICHTIG: Plane einen Alarm (wird beim App-Start für alle aktiven Alarme aufgerufen!)
    func scheduleAlarm(_ alarm: Alarm) {
        // Remove old notifications for this alarm
        cancelAlarm(alarm)
        
        guard alarm.isEnabled else { return }
        
        // WICHTIG: Starte Silent Audio um App wach zu halten
        startSilentAudio()
        
        let calendar = Calendar.current
        let components = calendar.dateComponents([.hour, .minute], from: alarm.time)
        
        // Schedule 60 notifications over 2 minutes (one every 2 seconds)
        // This creates a persistent alarm that rings for 2 minutes
        let notificationCount = 60
        let intervalSeconds: TimeInterval = 2.0

        // Prüfe verfügbare Pending-Notification-Slots (iOS Limit: 64)
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            let maxPending = 64
            let currentPending = requests.count
            let availableSlots = max(0, maxPending - currentPending)
            let scheduleCount = min(notificationCount, availableSlots)

            if scheduleCount == 0 {
                print("⚠️ Keine verfügbaren Slots um Alarm-Notifications zu planen (Limit erreicht)")
                return
            }

            if alarm.repeatDays.isEmpty {
            // Einmaliger Alarm
            let now = Date()
            
            // Zielzeit erstellen
            let targetComponents = calendar.dateComponents([.year, .month, .day], from: now)
            var alarmComponents = targetComponents
            let timeComponents = calendar.dateComponents([.hour, .minute], from: alarm.time)
            alarmComponents.hour = timeComponents.hour
            alarmComponents.minute = timeComponents.minute
            alarmComponents.second = 0
            
            guard var alarmDate = calendar.date(from: alarmComponents) else {
                print("❌ Konnte Alarm-Datum nicht erstellen")
                return
            }
            
            // Wenn die Zeit heute schon vorbei ist, auf morgen verschieben
            if alarmDate <= now {
                alarmDate = calendar.date(byAdding: .day, value: 1, to: alarmDate) ?? alarmDate
            }
            
            let timeInterval = alarmDate.timeIntervalSince(now)
            
            print("📅 Alarm geplant für: \(alarmDate)")
            print("⏱️ In: \(timeInterval) Sekunden (\(timeInterval / 60) Minuten)")
            
            // Sicherstellen dass timeInterval positiv und mindestens 1 Sekunde ist
            guard timeInterval >= 1 else {
                print("❌ TimeInterval zu kurz: \(timeInterval)")
                return
            }
            
            // Schedule multiple notifications (begrenze auf scheduleCount)
            for i in 0..<scheduleCount {
                let content = UNMutableNotificationContent()
                content.title = "⏰ WakeFlow Wecker"
                content.body = alarm.label
                
                // WICHTIG: Custom Sound für Notifications
                // Der Sound muss im Bundle sein und als .caf Format vorliegen
                let soundFileName = alarm.soundName.replacingOccurrences(of: ".caf", with: "") + ".caf"
                if Bundle.main.url(forResource: alarm.soundName.replacingOccurrences(of: ".caf", with: ""), withExtension: "caf") != nil {
                    content.sound = UNNotificationSound(named: UNNotificationSoundName(rawValue: soundFileName))
                    if i == 0 {
                        print("🔊 Notification Sound: \(soundFileName)")
                    }
                } else {
                    // Fallback auf Standard-Alarm Sound
                    content.sound = UNNotificationSound.default // [CRITICAL MESSAGING DEAKTIVIERT]
                    if i == 0 {
                        print("⚠️ Sound nicht gefunden (\(soundFileName)), benutze default")
                    }
                }

                content.categoryIdentifier = "ALARM"
                content.badge = NSNumber(value: i + 1)
                content.interruptionLevel = .timeSensitive // Wichtige Benachrichtigung
                
                // WICHTIG: Speichere Alarm-ID in der Notification
                content.userInfo = ["alarmID": alarm.id.uuidString, "alarmTime": alarm.time.timeIntervalSince1970]
                
                let offset = intervalSeconds * Double(i)
                let finalInterval = timeInterval + offset
                
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: finalInterval, repeats: false)
                let request = UNNotificationRequest(
                    identifier: "\(alarm.id.uuidString)-\(i)",
                    content: content,
                    trigger: trigger
                )
                
                UNUserNotificationCenter.current().add(request) { error in
                    if let error = error {
                        print("❌ Fehler beim Planen (\(i)): \(error)")
                    } else if i == 0 {
                        print("✅ Benachrichtigung \(i) geplant in \(finalInterval)s mit Sound")
                    }
                }
            }
        } else {
            // Wiederkehrender Alarm - für jeden ausgewählten Tag
            let now = Date()
            
            for day in alarm.repeatDays {
                var dayComponents = components
                dayComponents.weekday = day
                dayComponents.second = 0
                
                guard let nextAlarmDate = calendar.nextDate(after: now, matching: dayComponents, matchingPolicy: .nextTime) else {
                    print("❌ Konnte nächstes Datum für Tag \(day) nicht finden")
                    continue
                }
                
                let timeInterval = nextAlarmDate.timeIntervalSince(now)
                
                print("📅 Wiederkehrender Alarm für Tag \(day): \(nextAlarmDate)")
                print("⏱️ In: \(timeInterval) Sekunden (\(timeInterval / 60) Minuten)")
                
                // Sicherstellen dass timeInterval positiv und mindestens 1 Sekunde ist
                guard timeInterval >= 1 else {
                    print("❌ TimeInterval zu kurz für Tag \(day): \(timeInterval)")
                    continue
                }
                
                // Schedule multiple notifications for this day (begrenze auf scheduleCount)
                for i in 0..<scheduleCount {
                    let content = UNMutableNotificationContent()
                    content.title = "⏰ WakeFlow Wecker"
                    content.body = alarm.label
                    
                    // WICHTIG: Custom Sound für Notifications
                    let soundFileName = alarm.soundName.replacingOccurrences(of: ".caf", with: "") + ".caf"
                    if Bundle.main.url(forResource: alarm.soundName.replacingOccurrences(of: ".caf", with: ""), withExtension: "caf") != nil {
                        content.sound = UNNotificationSound(named: UNNotificationSoundName(rawValue: soundFileName))
                        if i == 0 {
                            print("🔊 Notification Sound: \(soundFileName)")
                        }
                    } else {
                        content.sound = UNNotificationSound.default // [CRITICAL MESSAGING DEAKTIVIERT]
                        if i == 0 {
                            print("⚠️ Sound nicht gefunden (\(soundFileName)), benutze default")
                        }
                    }

                    content.categoryIdentifier = "ALARM"
                    content.badge = NSNumber(value: i + 1)
                    content.interruptionLevel = .timeSensitive
                    
                    // WICHTIG: Speichere Alarm-ID in der Notification
                    content.userInfo = ["alarmID": alarm.id.uuidString, "alarmTime": alarm.time.timeIntervalSince1970]
                    
                    let offset = intervalSeconds * Double(i)
                    let finalInterval = timeInterval + offset
                    
                    let trigger = UNTimeIntervalNotificationTrigger(timeInterval: finalInterval, repeats: false)
                    let request = UNNotificationRequest(
                        identifier: "\(alarm.id.uuidString)-\(day)-\(i)",
                        content: content,
                        trigger: trigger
                    )
                    
                    UNUserNotificationCenter.current().add(request) { error in
                        if let error = error {
                            print("❌ Fehler beim Planen (Tag \(day), \(i)): \(error)")
                        } else if i == 0 {
                            print("✅ Tag \(day), Benachrichtigung \(i) in \(finalInterval)s mit Sound")
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
        var identifiers: [String] = []
        
        // All notification indices (0-59)
        for i in 0..<60 {
            identifiers.append("\(alarm.id.uuidString)-\(i)")
            
            // All day-specific notifications
            for day in 1...7 {
                identifiers.append("\(alarm.id.uuidString)-\(day)-\(i)")
            }
        }
        
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
        print("🗑️ \(identifiers.count) Benachrichtigungen für Alarm gelöscht")
        
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
    func triggerAlarmFromNotification(alarmID: UUID) {
        print("🔔 Alarm-Trigger von Notification: \(alarmID)")
        
        // Finde den Alarm in der Liste
        guard let alarm = alarmsToCheck.first(where: { $0.id == alarmID }) else {
            print("❌ Alarm nicht gefunden: \(alarmID)")
            return
        }
        
        // Starte den Alarm (nur wenn er noch nicht läuft)
        if !isPlaying {
            print("▶️ Starte Alarm: \(alarm.label)")
            playAlarm(alarm)
        } else {
            print("⏸️ Alarm läuft bereits")
        }
    }
    
    // Bereite App für Background Alarme vor
    func prepareForBackgroundAlarms() {
        // Prüfe ob es aktive Alarme gibt
        if hasActiveAlarms() {
            print("🔄 App bereit für Background Alarme")
            // Audio Session ist schon in playback Mode configuriert
        }
    }
    
    // Starte stillen Audio-Stream um App im Hintergrund wach zu halten
    private func startSilentAudio() {
        // Erstelle einen 1-Sekunden Stille-Sound
        let silenceURL = URL(fileURLWithPath: "/System/Library/Audio/UISounds/silence.caf")
        
        do {
            silentPlayer = try AVAudioPlayer(contentsOf: silenceURL)
            silentPlayer?.numberOfLoops = -1 // Endlos Loop
            silentPlayer?.volume = 0.01 // Fast unhörbar
            silentPlayer?.prepareToPlay()
            
            // Spiele NUR wenn es aktive Alarme gibt
            if hasActiveAlarms() {
                silentPlayer?.play()
                print("🔇 Silent Audio gestartet - App bleibt im Hintergrund aktiv")
            }
        } catch {
            print("❌ Konnte Silent Audio nicht starten: \(error)")
            // Fallback: Nutze einen der App-Sounds
            if let fallbackURL = Bundle.main.url(forResource: "alarm-clock-1", withExtension: "caf") {
                do {
                    silentPlayer = try AVAudioPlayer(contentsOf: fallbackURL)
                    silentPlayer?.numberOfLoops = -1
                    silentPlayer?.volume = 0.0 // Komplett stumm
                    silentPlayer?.prepareToPlay()
                    if hasActiveAlarms() {
                        silentPlayer?.play()
                        print("🔇 Silent Audio (Fallback) gestartet")
                    }
                } catch {
                    print("❌ Auch Fallback fehlgeschlagen: \(error)")
                }
            }
        }
    }
    
    // Stoppe Silent Audio
    func stopSilentAudio() {
        silentPlayer?.stop()
        silentPlayer = nil
        print("🔇 Silent Audio gestoppt")
    }
    
    // Sende Warnung dass App offen bleiben muss
    func scheduleAppKillWarning() {
        // Prüfe ob Warnung bereits gesendet wurde (persistent)
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "appKillWarningSent") {
            print("⏭️ App-Kill Warnung wurde bereits gesendet - keine weitere Warnung")
            return
        }
        
        // Entferne erst alte Warnungen
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["app-kill-warning"])
        
        let content = UNMutableNotificationContent()
        content.title = "⚠️ WakeFlow muss geöffnet bleiben"
        content.body = "Die App darf nicht komplett geschlossen sein damit dein Wecker zuverlässig klingelt!"
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
                print("❌ App-Kill Warnung Fehler: \(error)")
            } else {
                // Markiere als gesendet
                defaults.set(true, forKey: "appKillWarningSent")
                print("⚠️ App-Kill Warnung geplant (kommt in 30s wenn App geschlossen bleibt)")
            }
        }
    }
    
    // Entferne App-Kill Warnung
    func cancelAppKillWarning() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["app-kill-warning"])
        print("✅ App-Kill Warnung entfernt (App ist wieder offen)")
    }
    
    // Setze Warnung zurück (für neuen Alarm)
    func resetAppKillWarning() {
        UserDefaults.standard.set(false, forKey: "appKillWarningSent")
        print("🔄 App-Kill Warnung zurückgesetzt - kann wieder gesendet werden")
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
        
        print("💾 Alarm-Status gespeichert: \(alarm.label)")
    }
    
    // Lade aktiven Alarm-Status beim App-Start
    func loadActiveAlarmState() -> Alarm? {
        let defaults = UserDefaults.standard
        
        guard let alarmIDString = defaults.string(forKey: "activeAlarmID"),
              let alarmID = UUID(uuidString: alarmIDString),
              let label = defaults.string(forKey: "activeAlarmLabel"),
              let soundName = defaults.string(forKey: "activeAlarmSound") else {
            print("ℹ️ Kein aktiver Alarm gefunden")
            return nil
        }
        
        let volume = defaults.float(forKey: "activeAlarmVolume")
        
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
        
        print("🔄 Aktiver Alarm geladen: \(label)")
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
        
        print("🗑️ Alarm-Status gelöscht")
    }
    
    // MARK: - Keep-Alive Service
    
    /// Starte Keep-Alive Service um App für 15-30 Minuten wach zu halten
    func startKeepAliveService() {
        print("🔋 Starte Keep-Alive Service (15-30 Min)")
        
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
            print("🔇 Keep-Alive Audio startet (stumm)")
        } catch {
            print("❌ Keep-Alive Audio Fehler: \(error)")
        }
    }
    
    // MARK: - Reminder Notifications
    
    /// Plane tägliche Reminder-Notification um Schlafenszeit (nur wenn Alarme für morgen)
    func scheduleReminderNotification(at sleepTime: Date) {
        print("📝 Plane Reminder-Notification um \(sleepTime.formatted(date: .omitted, time: .shortened))")
        
        let defaults = UserDefaults.standard
        defaults.set(sleepTime.timeIntervalSince1970, forKey: "sleepTime")
        
        // Entferne alte Reminder
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["daily-reminder"])
        
        // Prüfe ob morgen Alarme existieren
        guard hasAlarmsForTomorrow() else {
            print("ℹ️ Keine Alarme für morgen - Reminder wird nicht geplant")
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
                print("❌ Reminder Notification Fehler: \(error)")
            } else {
                print("✅ Tägliche Reminder-Notification geplant um \(components.hour ?? 0):\(String(format: "%02d", components.minute ?? 0))")
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
    
    /// Plane loopende Backup-Notification für Alarm
    func scheduleBackupNotification(for alarm: Alarm) {
        print("📢 Plane Backup-Notification für: \(alarm.label)")
        
        let content = UNMutableNotificationContent()
        content.title = alarm.label
        content.body = "Tippe um zu stoppen"
        content.badge = NSNumber(value: 1)
        
        // Nutze den Custom-Sound des Alarms (als .caf)
        let backupSoundFile = alarm.soundName.replacingOccurrences(of: ".caf", with: "") + ".caf"
        if Bundle.main.url(forResource: alarm.soundName.replacingOccurrences(of: ".caf", with: ""), withExtension: "caf") != nil {
            content.sound = UNNotificationSound(named: UNNotificationSoundName(rawValue: backupSoundFile))
        } else {
            content.sound = UNNotificationSound(named: UNNotificationSoundName("dreamscape-alarm-clock.caf"))
        }
        
        // [CRITICAL MESSAGING DEAKTIVIERT]
        content.interruptionLevel = .timeSensitive // [CRITICAL MESSAGING DEAKTIVIERT — war .critical]
        content.relevanceScore = 1.0
        content.categoryIdentifier = "ALARM_CATEGORY"
        content.userInfo = ["alarmID": alarm.id.uuidString]
        
        // Triggere zur Alarm-Zeit (täglich wenn Wiederholung)
        let components = Calendar.current.dateComponents([.hour, .minute], from: alarm.time)
        let shouldRepeat = !alarm.repeatDays.isEmpty
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: shouldRepeat)
        
        let request = UNNotificationRequest(
            identifier: "backup-alarm-\(alarm.id)",
            content: content,
            trigger: trigger
        )
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("❌ Backup-Notification Fehler: \(error)")
            } else {
                print("✅ Backup-Notification geplant: \(alarm.label) um \(components.hour ?? 0):\(String(format: "%02d", components.minute ?? 0))")
            }
        }
    }
    
    /// Entferne Backup-Notification
    func cancelBackupNotification(for alarm: Alarm) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["backup-alarm-\(alarm.id)"])
        print("🗑️ Backup-Notification entfernt: \(alarm.label)")
    }
    
    deinit {
        checkTimer?.invalidate()
        stopTimer?.invalidate()
        volumeEnforceTimer?.invalidate()
        notificationTimer?.invalidate()
        vibrationTimer?.invalidate()
        
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
                print("✅ Benachrichtigungen erlaubt")
            } else if let error = error {
                print("❌ Fehler: \(error.localizedDescription)")
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
            print("💾 \(alarms.count) Wecker gespeichert")
        }
    }
    
    private func loadAlarms() {
        if let data = UserDefaults.standard.data(forKey: "savedAlarms"),
           let decoded = try? JSONDecoder().decode([Alarm].self, from: data) {
            alarms = decoded
            print("📂 \(decoded.count) Wecker geladen")
        } else {
            print("📂 Keine gespeicherten Wecker gefunden")
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
                            print("🔵 Alarm aktiviert (ohne NFC): \(alarm.label)")
                            print("🔵 Alarm-Zeit: \(alarm.time)")
                            print("🔵 Wiederholungstage: \(alarm.repeatDays)")
                            // WICHTIG: Plane Alarm neu!
                            backgroundAlarmManager.scheduleAlarm(alarms[index])
                        } else {
                            print("⚪️ Alarm deaktiviert (ohne NFC): \(alarm.label)")
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
                    print("✅ Neuer Alarm hinzugefügt (ohne NFC): \(newAlarm.label)")
                    print("✅ Alarm-Zeit: \(newAlarm.time)")
                    print("✅ Alarm aktiviert: \(newAlarm.isEnabled)")
                    print("✅ Wiederholungstage: \(newAlarm.repeatDays)")
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
                            print("❌ Keine Alarm-ID übergeben")
                            return
                        }
                        
                        if let index = alarms.firstIndex(where: { $0.id == alarmID }) {
                            let alarm = alarms[index]
                            print("🔍 Alarm gestoppt - ID: \(alarmID)")
                            print("🔍 Wiederholungstage: \(alarm.repeatDays)")
                            print("🔍 Ist einmalig: \(alarm.repeatDays.isEmpty)")
                            
                            if alarm.repeatDays.isEmpty {
                                // Einmaliger Alarm → Deaktivieren!
                                print("⚪️ Einmaliger Alarm wird deaktiviert: \(alarm.label)")
                                alarms[index].isEnabled = false
                                
                                // Trigger manuelles Update der UI
                                let updatedAlarms = alarms
                                alarms = []
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    alarms = updatedAlarms
                                    saveAlarms()
                                    backgroundAlarmManager.updateAlarms(alarms)
                                    print("✅ Toggle Switch ist jetzt: \(alarms[index].isEnabled ? "AN" : "AUS")")
                                }
                            } else {
                                print("🔄 Wiederkehrender Alarm bleibt aktiv: \(alarm.label)")
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
                print("🔄 Alarm neu geplant: \(alarm.label) um \(alarm.time)")
            }
            
            // Update alarms in background manager
            backgroundAlarmManager.updateAlarms(alarms)
            
            // Pausiere Notifications wenn App geöffnet wird
            backgroundAlarmManager.pauseNotifications()
            
            // WICHTIG: Starte Keep-Alive Service um App für 15-30 Min wach zu halten
            backgroundAlarmManager.startKeepAliveService()
            print("🔋 Keep-Alive Service aktiviert")
            
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
                print("✅ Keine aktiven Alarme mehr - Warnung entfernt")
            }
        }
        .onChange(of: backgroundAlarmManager.isPlaying) { isPlaying in
            // FullScreenCover erscheint automatisch durch .constant(backgroundAlarmManager.isPlaying)
            if isPlaying {
                print("🌙 Mond-Screen erscheint - Alarm klingelt")
            } else {
                print("🌙 Mond-Screen verschwindet - Alarm gestoppt")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            // App kommt in den Vordergrund
            backgroundAlarmManager.pauseNotifications()
            backgroundAlarmManager.cancelAppKillWarning() // Entferne Warnung
            print("📱 App in Vordergrund - Notifications pausiert + Warnung entfernt")
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            // App geht in den Hintergrund
            backgroundAlarmManager.resumeNotifications()
            
            // Prüfe ob aktive Wecker vorhanden sind (und kein Alarm gerade klingelt)
            if backgroundAlarmManager.hasActiveAlarms() && !backgroundAlarmManager.isPlaying {
                // Plane Warnung dass App offen bleiben muss
                backgroundAlarmManager.scheduleAppKillWarning()
                print("⚠️ App in Hintergrund mit aktivem Wecker - Warnung geplant")
            } else {
                print("📱 App in Hintergrund - Notifications fortgesetzt")
            }
        }
    }
    
    
    private func requestNotificationPermissions() {
        // [CRITICAL MESSAGING DEAKTIVIERT] — Standard-Benachrichtigungen
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            if granted {
                print("✅ Notification Permissions gewährt")
            } else if let error = error {
                print("❌ Notification Permissions Fehler: \(error.localizedDescription)")
            } else {
                print("⚠️ Notification Permissions abgelehnt")
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
        print("✅ Notification Categories registriert (Alarm + Warning)")
    }
    
    // Prüfe nach App-Neustart ob ein Alarm aktiv war
    private func checkForActiveAlarmAfterRestart() {
        // Warte kurz damit UI geladen ist
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let activeAlarm = backgroundAlarmManager.loadActiveAlarmState() {
                print("🔄 APP NEUSTART - Alarm war aktiv: \(activeAlarm.label)")
                print("🔄 Starte Alarm + Mond-Screen neu...")
                
                // Starte Alarm wieder
                backgroundAlarmManager.playAlarm(activeAlarm)
                
                print("✅ Alarm erfolgreich neu gestartet nach App-Kill!")
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
            print("📝 Reminder-Notification geplant um \(sleepTime.formatted(date: .omitted, time: .shortened))")
        } else {
            print("ℹ️ Keine Schlafenszeit gespeichert - Bitte in Einstellungen einstellen")
        }
    }
}

// MARK: - Alarms View
struct AlarmsView: View {
    @Binding var alarms: [Alarm]
    @Binding var showingAddAlarm: Bool
    @State private var editingAlarmID: UUID?
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
                        print("✅ Alarm bearbeitet (ohne NFC): \(updatedAlarm.label)")
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
    }
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
                        print("🔵 Toggle: Aktivierung (ohne NFC)")
                    } else {
                        print("⚪️ Toggle: Deaktivierung (ohne NFC)")
                    }
                    
                    // Immer Callback aufrufen
                    onToggle(newValue)
                }
            )
                .offset(x: offset)
                .onChange(of: alarm.isEnabled) { newValue in
                    // Synchronisiere lokalIsEnabled mit tatsächlichem Alarm-State
                    localIsEnabled = newValue
                    print("🔄 Toggle-State synchronisiert: \(newValue)")
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
                print("🔄 Sound gewechselt → Vorschau gestoppt")
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
                        print("💾 Speichere Alarm mit Sound: \(selectedSound)")
                        
                        let newAlarm = Alarm(
                            time: selectedTime,
                            isEnabled: true,
                            label: alarmLabel.isEmpty ? "Wecker" : alarmLabel,
                            repeatDays: selectedDays,
                            soundName: selectedSound,
                            volume: volumeToInternal(selectedVolume) // UI 0-100% → Intern 0.5-1.0
                        )
                        
                        print("💾 Alarm erstellt - Sound: \(newAlarm.soundName)")
                        print("🔊 Lautstärke: \(volumeToInternal(selectedVolume)) (0.25-0.8)")
                        print("📡 NFC-Scan erforderlich zum Aktivieren")
                        
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
            print("❌ Vorschau Sound nicht gefunden: \(selectedSound)")
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
            print("▶️ Vorschau: Sound \(selectedSound), Intern \(Int(internalVolume * 100))%, System-Slider \(Int(scaledVolume * 100))%")
        } catch {
            print("❌ Vorschau Fehler: \(error)")
        }
    }
    
    private func stopPreview() {
        previewPlayer?.stop()
        previewPlayer = nil
        isPlayingPreview = false
        print("⏹️ Vorschau gestoppt")
    }
    
    private func updatePreviewVolume() {
        let internalVolume = volumeToInternal(selectedVolume)
        let scaledVolume = internalToSystemVolume(internalVolume)
        setSystemVolume(scaledVolume)
        print("🔊 Lautstärke: Intern \(Int(internalVolume * 100))%, System \(Int(scaledVolume * 100))%")
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
                print("🔄 Sound gewechselt → Vorschau gestoppt")
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
                        print("✏️ Bearbeite Alarm - Alter Sound: \(alarm.soundName)")
                        print("✏️ Bearbeite Alarm - Neuer Sound: \(selectedSound)")
                        
                        var updatedAlarm = alarm
                        updatedAlarm.time = selectedTime
                        updatedAlarm.label = alarmLabel.isEmpty ? "Wecker" : alarmLabel
                        updatedAlarm.repeatDays = selectedDays
                        updatedAlarm.soundName = selectedSound
                        updatedAlarm.volume = volumeToInternal(selectedVolume) // UI 0-100% → Intern 0.5-1.0
                        
                        print("✏️ Alarm gespeichert - Sound jetzt: \(updatedAlarm.soundName)")
                        print("🔊 Lautstärke: \(volumeToInternal(selectedVolume)) (0.25-0.8)")
                        print("📡 NFC-Scan erforderlich zum Aktivieren")
                        
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
            print("❌ Vorschau Sound nicht gefunden: \(selectedSound)")
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
            print("▶️ Vorschau: Sound \(selectedSound), Intern \(Int(internalVolume * 100))%, System-Slider \(Int(scaledVolume * 100))%")
        } catch {
            print("❌ Vorschau Fehler: \(error)")
        }
    }
    
    private func stopPreview() {
        previewPlayer?.stop()
        previewPlayer = nil
        isPlayingPreview = false
        print("⏹️ Vorschau gestoppt")
    }
    
    private func updatePreviewVolume() {
        let internalVolume = volumeToInternal(selectedVolume)
        let scaledVolume = internalToSystemVolume(internalVolume)
        setSystemVolume(scaledVolume)
        print("🔊 Lautstärke: Intern \(Int(internalVolume * 100))%, System \(Int(scaledVolume * 100))%")
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
#if false
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
                            print("🔵 NFC Button gedrückt (erneuter Versuch)")
                            
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
                print("✅ NFC gescannt - Alarm wird aktiviert")
                isPresented = false
                onSuccess()
            }
        }
        .onAppear {
            print("📡 NFCActivationView geladen für: \(alarmLabel)")
            
            // Starte NFC-Scan AUTOMATISCH beim Erscheinen
            if NFCNDEFReaderSession.readingAvailable {
                print("🚀 NFC-Scan startet automatisch...")
                // Kleine Verzögerung für bessere UX
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    nfcReader.startScanning(actionType: .activate)
                }
            } else {
                showError = true
                errorMessage = "NFC wird auf diesem Gerät nicht unterstützt."
                print("❌ NFC nicht verfügbar auf diesem Gerät")
            }
        }
    }
}
#endif

// MARK: - Alarm Stop View [DEAKTIVIERT]
#if false
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
                        print("🔵 NFC Button gedrückt (erneuter Versuch)")
                        print("🔍 NFC verfügbar: \(NFCNDEFReaderSession.readingAvailable)")
                        
                        if NFCNDEFReaderSession.readingAvailable {
                            showError = false
                            nfcReader.startScanning(actionType: .deactivate)
                        } else {
                            errorMessage = "NFC wird auf diesem Gerät nicht unterstützt.\nBenötigt iPhone 7 oder neuer."
                            print("❌ NFC nicht verfügbar")
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
                    print("⚠️ DEBUG: Alarm wird ohne NFC gestoppt")
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
                print("✅ NFC gescannt - Alarm wird gestoppt")
                
                // Callback ZUERST aufrufen (bevor stopAlarm() die ID löscht)
                onAlarmStopped(alarmIDBeforeStop)
                
                backgroundAlarmManager.stopAlarm()
                isPresented = false
            }
        }
        .onAppear {
            // Speichere die Alarm-ID BEVOR sie durch stopAlarm() gelöscht wird
            alarmIDBeforeStop = backgroundAlarmManager.getCurrentAlarmID()
            print("📱 AlarmStopView geladen - Alarm ID: \(alarmIDBeforeStop?.uuidString ?? "nil")")
            print("📡 NFC verfügbar: \(NFCNDEFReaderSession.readingAvailable)")
            
            // Starte NFC-Scan AUTOMATISCH beim Erscheinen
            if NFCNDEFReaderSession.readingAvailable {
                print("🚀 NFC-Scan startet automatisch (Alarm stoppen)...")
                // Kleine Verzögerung für bessere UX
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    nfcReader.startScanning(actionType: .deactivate)
                }
            } else {
                showError = true
                errorMessage = "NFC wird auf diesem Gerät nicht unterstützt.\nBenötigt iPhone 7 oder neuer."
                print("❌ NFC nicht verfügbar auf diesem Gerät")
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
                        print("🎵 Sound ausgewählt: \(sound.file) (\(sound.name))")
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
            print("🛑 Sound-Vorschau gestoppt")
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
        print("🔊 Systemlautstärke gesetzt auf: \(volume)")
    }
    
    func playSound(_ soundFile: String) {
        // Stoppe den aktuellen Sound falls einer läuft
        stop()
        
        guard let url = Bundle.main.url(forResource: soundFile, withExtension: nil) else {
            print("❌ Sound-Datei nicht gefunden: \(soundFile)")
            return
        }
        
        do {
            // Speichere aktuelle Lautstärke
            originalVolume = AVAudioSession.sharedInstance().outputVolume
            print("💾 Original-Lautstärke gespeichert: \(originalVolume)")
            
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
            
            print("▶️ Sound-Vorschau gestartet: \(soundFile) bei 0.4 Systemlautstärke")
        } catch {
            print("❌ Fehler beim Abspielen der Vorschau: \(error.localizedDescription)")
        }
    }
    
    func stop() {
        audioPlayer?.stop()
        audioPlayer = nil
        
        // Stelle ursprüngliche Lautstärke wieder her
        setSystemVolume(originalVolume)
        print("🔄 Original-Lautstärke wiederhergestellt: \(originalVolume)")
    }
}

// MARK: - Moon View
struct MoonView: View {
    let iosBlue: Color
    @ObservedObject var backgroundAlarmManager: BackgroundAlarmManager
    @StateObject private var nfcReader = NFCAlarmReader()
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
                    stopAlarmWithNFC()
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

                        Text("Tippe auf den Mond und scanne\ndeinen NFC-Chip um den Alarm zu stoppen")
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
            print("📱 MoonView geladen - Alarm ID: \(alarmIDBeforeStop?.uuidString ?? "nil")")

            // Starte pulsierende Animation - subtiler
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                pulseScale = 1.05
            }
        }
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
    }

    private func stopAlarmWithNFC() {
        print("🌙 Mond gedrückt - Stoppe Alarm mit NFC...")

        // Haptic Feedback
        let generator = UIImpactFeedbackGenerator(style: .heavy)
        generator.impactOccurred()

        if NFCNDEFReaderSession.readingAvailable {
            nfcReader.startScanning(actionType: .deactivate)
        } else {
            print("❌ NFC nicht verfügbar auf diesem Gerät")
        }
    }

    private func stopAlarmDirectly() {
        // 1:1 Nachbau des NFC-Stop-Flows (AlarmStopView.onChange).
        // Reihenfolge ist KRITISCH und muss exakt mit dem Original übereinstimmen.

        print("✅ Stop-Button gedrückt - Alarm wird gestoppt")

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
        
        print("💾 Schlafenszeit gespeichert: \(sleepTime.formatted(date: .omitted, time: .shortened))")
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
