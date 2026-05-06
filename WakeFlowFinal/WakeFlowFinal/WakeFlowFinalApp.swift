//
//  WakeFlowFinalApp.swift
//  WakeFlowFinal
//
//  Created by Viktor Rotgang on 03.02.26.
//

import SwiftUI
import UserNotifications
import AVFoundation
import AlarmKit
import OSLog

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self

        // #region agent log
        Task { @MainActor in
            await PhantomDebug.dumpBootState(reason: "didFinishLaunchingWithOptions")
        }
        // #endregion

        // Clear all delivered notifications when app launches
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        
        // WICHTIG: Setup Audio Session für Background Playback
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try audioSession.setActive(true)
            Logger.lifecycle.info("Audio Session für Background aktiv")
        } catch {
            Logger.lifecycle.error("Audio Session Fehler: \(error.localizedDescription, privacy: .public)")
        }
        
        // WICHTIG: AlarmKit Permission anfragen
        Task {
            await requestAlarmPermission()
        }
        
        // Prüfe ob es geplante Alarme gibt und starte Background Audio wenn nötig
        BackgroundAlarmManager.shared.prepareForBackgroundAlarms()

#if DEBUG
        Task { @MainActor in
            AlarmKitSpikeForegroundVerifier.shared.register()
        }
#endif
        
        return true
    }
    
    // AlarmKit Permission anfragen
    func requestAlarmPermission() async {
        do {
            let alarmManager = AlarmKit.AlarmManager.shared
            let state = alarmManager.authorizationState

            if state == .authorized {
                Logger.alarm.info("AlarmKit Zugriff bereits erlaubt")
                return
            }

            let newState = try await alarmManager.requestAuthorization()
            if newState == .authorized {
                Logger.alarm.info("AlarmKit Zugriff erlaubt")
            } else {
                Logger.alarm.notice("AlarmKit Zugriff nicht erlaubt: \(String(describing: newState), privacy: .public)")
            }
        } catch {
            Logger.alarm.error("Fehler bei AlarmKit Anfrage: \(error.localizedDescription, privacy: .public)")
        }
    }
    
    // Wird nur aufgerufen, wenn eine Notification im Vordergrund präsentiert wird.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        
        let userInfo = notification.request.content.userInfo
        
        // Extrahiere Alarm-ID aus userInfo (zuverlässig) statt aus dem Identifier
        if let alarmIDString = userInfo["alarmID"] as? String,
           let alarmID = UUID(uuidString: alarmIDString) {
            
            Logger.notifications.notice("Notification wird gezeigt für Alarm: \(alarmID.uuidString, privacy: .public)")
            
            DispatchQueue.main.async {
                if !BackgroundAlarmManager.shared.isPlaying {
                    BackgroundAlarmManager.shared.triggerAlarmFromNotification(alarmID: alarmID, userInfo: userInfo)
                }
            }
        }
        
        // Zeige Notification mit Sound und Banner
        completionHandler([.banner, .sound, .badge])
    }
    
    // Handle notification responses (user taps on notification)
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        // Clear delivered notifications
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        
        let userInfo = response.notification.request.content.userInfo
        
        // Extrahiere Alarm-ID aus userInfo (zuverlässig)
        if let alarmIDString = userInfo["alarmID"] as? String,
           let alarmID = UUID(uuidString: alarmIDString) {
            
            Logger.notifications.notice("Notification erhalten für Alarm: \(alarmID.uuidString, privacy: .public)")
            
            DispatchQueue.main.async {
                BackgroundAlarmManager.shared.triggerAlarmFromNotification(alarmID: alarmID, userInfo: userInfo)
            }
        }
        
        if response.actionIdentifier == "STOP_ALARM" || response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            Logger.lifecycle.notice("App geöffnet per Notification → Mond-Screen erscheint (Audio läuft weiter)")
        }
        
        completionHandler()
    }
    
    // When app becomes active (comes to foreground)
    func applicationDidBecomeActive(_ application: UIApplication) {
        // Clear all delivered notifications from lock screen
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        application.applicationIconBadgeNumber = 0
        
        // WICHTIG: Alarm läuft weiter! Nur Notifications clearen
        // Der User muss in der App den Stop-Button drücken
        
        if BackgroundAlarmManager.shared.isPlaying {
            Logger.lifecycle.notice("App im Vordergrund - Alarm läuft weiter (wie Alarmy!)")
        } else {
            Logger.lifecycle.info("App im Vordergrund - kein aktiver Alarm")
        }
    }
}

@main
struct WakeFlowFinalApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
