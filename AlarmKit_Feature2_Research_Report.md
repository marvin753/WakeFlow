# AlarmKit / Feature 2 Research Report

Datum: 2026-04-28

Scope-Status: Es wurden keine Production-App-Code-Dateien fuer Feature 2 geaendert. Dieser Bericht basiert auf WakeFlow-Code-Lektuere, lokalen Xcode-26.4.1-SDK-Interfaces, Apple-/Alarmy-Dokumentation und Simulator-Spike-Tests auf `iPhone 17 (iOS 26.4.1)`. Ein physischer On-Device-Test konnte nicht ausgefuehrt werden, weil `xcrun xctrace list devices` das iPhone `Marvin (2) (26.3.1)` als `Devices Offline` meldet. Audio-, Lock-Screen-Standby- und echte Hardware-Verhalten bleiben deshalb `unknown`, sofern sie nicht direkt dokumentiert sind. Abweichend vom gewuenschten Confidence-Set markiert `verified-on-simulator` reine Simulatorbelege, nicht Hardwarebelege.

Simulator-Artefakte:

- `/Users/marvinbarsal/Desktop/Gaming/WakeFlow/ResearchScreenshots/alarmkit-sim-homescreen.png`
- `/Users/marvinbarsal/Desktop/Gaming/WakeFlow/ResearchScreenshots/alarmkit-sim-foreign-app.png`
- `/Users/marvinbarsal/Desktop/Gaming/WakeFlow/ResearchScreenshots/alarmkit-sim-notification-center.png`
- `/Users/marvinbarsal/Desktop/Gaming/WakeFlow/ResearchScreenshots/alarmkit-sim-secondary-tap-result.png`

## Block A - AlarmKit-Verhalten in vier Phone-Zustaenden

### A1. Phone gesperrt, Standby/Schwarz

**Antwort:** WakeFlow-spezifisch nicht auf Geraet verifiziert. Dokumentiert ist: AlarmKit-Alarme sind prominente Alerts, erscheinen auf Lock Screen, Dynamic Island, StandBy und Apple Watch; beim Feuern wird Alert-UI angezeigt und Silent Mode / Focus koennen durchbrochen werden. Alarmy dokumentiert fuer iOS 26 eine Vollbildanzeige ueber dem Lock Screen mit Tap/Swipe in den Mission Screen.

**Beleg:** WWDC25 "Wake up to the AlarmKit API" beschreibt Lock Screen/Dynamic Island/StandBy und Alert mit App-Name/Titel/Stop-Snooze/Custom-Button ([Apple WWDC25](https://developer.apple.com/videos/play/wwdc2025/230/), Transcript lines 198-205, 320-327). Alarmy Help beschreibt Vollbild ueber Lock Screen ([Alarmy iOS 26](https://alarmy-ios.zendesk.com/hc/en-us/articles/53760654821785--New-on-iOS-26-Alarmy-alarm-now-shows-on-your-Lock-Screen), lines 9-16). WakeFlow-Spike konfiguriert `secondaryButton` "WakeFlow oeffnen" und `sound: .default` in `ContentView.swift` lines 2125-2155.

**Confidence:** `verified-in-docs` fuer generelles AlarmKit/Alarmy-Verhalten; `unknown` fuer den konkreten WakeFlow-Spike-Screenshot.

**Konsequenz fuer Feature-2-Plan:** Lock-Screen-AlarmKit darf als separater Systempfad behandelt werden; exakte WakeFlow-Optik und Button-Rendering muessen nach Geraeteverfuegbarkeit nachgetestet werden.

### A2. Phone entsperrt, fremde App

**Antwort:** Auf dem iPhone-17-Simulator erscheint ueber Safari ein breites schwarzes AlarmKit-Systemoverlay am oberen Bildschirmrand. Es ist kein Standard-UNNotification-Banner. Sichtbar sind links ein orangefarbenes Alarm-Icon, der App-Name `WakeFlowFinal` und der Titel `AlarmKit Spike`; rechts ein orangefarbener Secondary-Button mit `arrow.up.right.square`-Icon und ein grauer X-Button. Der im Code gesetzte `stopButton`-Text `Stoppen` wird nicht als Text/Button gerendert. Secondary-Tap oeffnet WakeFlow; der bestehende MoonView-/`playAlarm`-Pfad startet dabei im Spike nicht automatisch, und das AlarmKit-Overlay bleibt sichtbar. X-Tap konnte wegen Simulator-Runner-`Busy` nicht final getestet werden.

**Beleg:** Screenshot `/Users/marvinbarsal/Desktop/Gaming/WakeFlow/ResearchScreenshots/alarmkit-sim-foreign-app.png`. Secondary-Tap-Screenshot `/Users/marvinbarsal/Desktop/Gaming/WakeFlow/ResearchScreenshots/alarmkit-sim-secondary-tap-result.png`. UI-Test `testAlarmKitSpikeForeignApp` und `testAlarmKitSpikeSecondaryButtonTapFromHomeScreen` liefen erfolgreich. SDK bestaetigt, dass `stopButton` deprecated / "not used anymore" ist (`AlarmKit.swiftinterface` lines 54-65).

**Confidence:** `verified-on-simulator` fuer visuelles Rendering und Secondary-Tap; `unknown` fuer X-Tap, Audio und Hardware.

**Konsequenz fuer Feature-2-Plan:** AlarmKit liefert im unlocked-Fremd-App-Zustand bereits ein eigenes Systemoverlay. Ein zusaetzlicher Standard-Banner waere daher ein zweiter UI-Kanal und muss bewusst gegen dieses Overlay abgegrenzt werden.

### A3. Phone entsperrt, Homescreen

**Antwort:** Auf dem iPhone-17-Simulator erscheint auf dem Homescreen dasselbe breite schwarze AlarmKit-Systemoverlay wie in Safari: App-Name `WakeFlowFinal`, Titel `AlarmKit Spike`, orangefarbenes Alarm-Icon, orangefarbener Secondary-Button und grauer X-Button. Kein Vollbild-Takeover und kein klassischer Notification-Banner.

**Beleg:** Screenshot `/Users/marvinbarsal/Desktop/Gaming/WakeFlow/ResearchScreenshots/alarmkit-sim-homescreen.png`. UI-Test `testAlarmKitSpikeHomeScreenAndNotificationCenter` lief erfolgreich.

**Confidence:** `verified-on-simulator` fuer visuelles Rendering; `unknown` fuer Audio und Hardware.

**Konsequenz fuer Feature-2-Plan:** Homescreen und Fremd-App zeigen im Simulator dasselbe AlarmKit-Overlay; Feature 2 muss nicht nur "kein UI" kompensieren, sondern moegliche Doppel-UI vermeiden.

### A4. Notification Center pulled down

**Antwort:** Auf dem iPhone-17-Simulator war nach Pull-down der Mitteilungszentrale kein AlarmKit-Eintrag sichtbar. Das Screenshot zeigt die Notification-Center/Lock-Screen-Ansicht ohne AlarmKit-Karte und ohne Buttons. Das belegt nur den Simulatorpfad nach einem laufenden AlarmKit-Overlay; eine separate Standard-`UNNotification` wurde damit nicht getestet.

**Beleg:** Screenshot `/Users/marvinbarsal/Desktop/Gaming/WakeFlow/ResearchScreenshots/alarmkit-sim-notification-center.png`. Apple Support: Notification Center von entsperrtem iPhone via Swipe down, zeigt Notification History ([Apple Support](https://support.apple.com/en-us/108781)).

**Confidence:** `verified-on-simulator` fuer "kein sichtbarer AlarmKit-Eintrag in diesem Screenshot"; `unknown` fuer Hardware und fuer Standard-Notification-Vergleich.

**Konsequenz fuer Feature-2-Plan:** AlarmKit scheint im Simulator nicht als Notification-Center-History-Eintrag aufzutauchen; Image-2-artige Eintraege muessen weiterhin ueber Standard-`UNNotification` verifiziert werden.

## Block B - Sound-Verhalten

### B1. Wer spielt AlarmKit-Sound?

**Antwort:** AlarmKit/System spielt den konfigurierten Sound. Die AlarmKit-Konfiguration hat einen `sound`-Parameter; Apple beschreibt ihn als Sound, der beim Feuern des Alarms abgespielt wird. Wenn kein Sound angegeben ist, wird ein Default-Systemsound verwendet; custom Sound erfolgt ueber `ActivityKit.AlertConfiguration.AlertSound`.

**Beleg:** AlarmKit SDK `AlarmConfiguration.alarm(... sound: AlertConfiguration.AlertSound = .default)` in `/Applications/Xcode.app/.../AlarmKit.swiftinterface` lines 256-259. ActivityKit `AlertSound.default` und `.named` in `/Applications/Xcode.app/.../ActivityKit.swiftinterface` lines 434-443. WWDC25 Transcript lines 320-323. WakeFlow nutzt `sound: .default` im Spike und `.named(soundFileName)` im Production-Schedule (`ContentView.swift` lines 1074-1090, 2150-2155).

**Confidence:** `verified-in-docs`

**Konsequenz fuer Feature-2-Plan:** App-eigener AVAudioPlayer ist fuer AlarmKit-Sound nicht technisch erforderlich; er ist ein separater paralleler Audio-Pfad.

### B2. WakeFlow-AVAudioPlayer parallel zu AlarmKit

**Antwort:** Nicht gehoert/getestet. Aus Code-Sicht startet WakeFlow beim AlarmKit-Update `.alerting` trotzdem `playAlarm(alarm, shouldNotify: false)`, also AVAudioPlayer, Vibration und Volume-Enforcement. Ob iOS dann Doppel-Audio mischt, unterdrueckt oder duckt, ist ohne Geraetetest offen.

**Beleg:** `handleSystemAlarmUpdates` reagiert auf `systemAlarm.state == .alerting` und ruft `playAlarm(alarm, shouldNotify: false)` (`ContentView.swift` lines 943-954). `playAlarm` startet `playSoundLoop()` (`ContentView.swift` lines 509-545); Audio Session nutzt `.playback` mit `.duckOthers` (`ContentView.swift` lines 249-254, 615-619).

**Confidence:** `inferred` fuer parallelen Startversuch; `unknown` fuer hoerbares Ergebnis.

**Konsequenz fuer Feature-2-Plan:** Audio-Deduplizierung darf nicht angenommen werden.

### B3. AlarmKit + AVAudioPlayer + UNNotification default sound

**Antwort:** Nicht verifiziert. Apple dokumentiert, dass UNNotification `sound` beim Delivering gespielt werden kann und AlarmKit seinen eigenen Sound hat; es wurde keine Deduplizierungs-Garantie gefunden.

**Beleg:** `UNNotificationContent.sound` ist nullable und "sound that will be played" (`UNNotificationContent.h` lines 53-55, 115-116). `UNNotificationPresentationOptionSound` existiert (`UNUserNotificationCenter.h` lines 81-87).

**Confidence:** `unknown`

**Konsequenz fuer Feature-2-Plan:** Ein paralleler Banner sollte in der Testmatrix explizit mit `sound = nil` und `sound = .default` verglichen werden.

### B4. AlarmKit-Sound im Foreground

**Antwort:** Nicht verifiziert. Apple sagt allgemein, dass der Alarm beim Feuern Sound nutzt und Focus/Silent durchbrechen kann; Foreground-App-Zustand ist nicht separat belegt.

**Beleg:** WWDC25 Transcript lines 198-205 und 320-323.

**Confidence:** `unknown`

**Konsequenz fuer Feature-2-Plan:** Foreground-in-WakeFlow und unlocked-in-other-app sind getrennte Audiofaelle.

## Block C - Standard-UNNotification Banner/Notification Center

### C1. Locked zur Fire-Zeit

**Antwort:** Doku: Standard-Notifications koennen auf dem Lock Screen erscheinen; genaue WakeFlow-Testnotification und Kollision mit AlarmKit nicht auf Geraet verifiziert.

**Beleg:** Apple Support: aktuelle Notifications sind auf dem Lock Screen sichtbar und koennen angetippt/verwaltet werden ([Apple Support](https://support.apple.com/en-us/108781)). `UNNotificationInterruptionLevelTimeSensitive` wird unmittelbar praesentiert, kann Screen aufleuchten und Sound spielen (`UNNotificationContent.h` lines 20-31).

**Confidence:** `verified-in-docs` fuer Standardverhalten; `unknown` fuer AlarmKit-Kollision.

**Konsequenz fuer Feature-2-Plan:** Standard-Notification ist ein eigenstaendiger UI-Kanal neben AlarmKit, aber Gleichzeitigkeit braucht Geraetebeleg.

### C2. Entsperrt, fremde App

**Antwort:** Doku: Ein Banner ist der normale Presentation-Typ fuer Notifications, wenn Banners fuer die App erlaubt sind. App ist nicht im Vordergrund, daher entscheidet das System anhand Settings/Focus.

**Beleg:** Apple HIG: Notifications koennen als Banner, Lock-Screen/Home-Screen-View, Badge oder Notification-Center-Item erscheinen ([HIG Notifications](https://developer.apple.com/design/human-interface-guidelines/notifications/)). Apple Support beschreibt Banner-/Alert-Styles in Notification Settings ([Apple Support](https://support.apple.com/en-us/108781)).

**Confidence:** `verified-in-docs`

**Konsequenz fuer Feature-2-Plan:** Ein time-sensitive Standard-Banner ist der dokumentierte iOS-Mechanismus fuer Image-1-artiges Verhalten.

### C3. Entsperrt, Homescreen

**Antwort:** Wie C2: Standard-Banner ist dokumentierter Presentation-Typ, wenn Banners erlaubt sind. Nicht als WakeFlow-Test verifiziert.

**Beleg:** Apple HIG und Apple Support wie C2.

**Confidence:** `verified-in-docs`

**Konsequenz fuer Feature-2-Plan:** Homescreen-Banner sollte mit derselben UNNotification funktionieren, aber Settings/Focus koennen Darstellung veraendern.

### C4. Notification Center pulled down

**Antwort:** Doku: Notification Center zeigt Notification-History; Standard-Notifications koennen dort als Eintraege erscheinen.

**Beleg:** Apple Support: Von entsperrtem iPhone Notification Center per Swipe down oeffnen; dort sieht man verpasste Alerts / History ([Apple Support](https://support.apple.com/en-us/108781)).

**Confidence:** `verified-in-docs`

**Konsequenz fuer Feature-2-Plan:** Image-2-artige Darstellung ist fuer Standard-Notifications kein eigenes Custom-Feature.

### C5. Tap auf Banner

**Antwort:** Ja, fuer Standard-UNNotification-Tap wird `userNotificationCenter(_:didReceive:withCompletionHandler:)` aufgerufen, sofern Delegate rechtzeitig gesetzt ist. WakeFlow setzt den Delegate in `didFinishLaunching` und liest `alarmID` aus `userInfo`.

**Beleg:** SDK: `didReceiveNotificationResponse` wird aufgerufen, wenn User Notification oeffnet/dismissed/Action waehlt; Delegate muss vor Rueckkehr aus `application:didFinishLaunchingWithOptions:` gesetzt sein (`UNUserNotificationCenter.h` lines 96-100). WakeFlow setzt Delegate in `WakeFlowFinalApp.swift` lines 14-16 und verarbeitet Tap in lines 92-113.

**Confidence:** `verified-in-docs` und `verified-in-code`

**Konsequenz fuer Feature-2-Plan:** Banner-Tap kann den bestehenden Notification-Pfad nutzen, wenn `userInfo["alarmID"]` gesetzt ist.

### C6. `sound = nil`

**Antwort:** Ja, technisch ist `sound` nullable; eine Notification ohne Sound ist erlaubt. Sichtbarer UI-Defekt ist nicht dokumentiert und nicht getestet.

**Beleg:** `UNNotificationContent.sound` und `UNMutableNotificationContent.sound` sind nullable (`UNNotificationContent.h` lines 53-55, 115-116).

**Confidence:** `verified-in-docs` fuer Stumm-Konfiguration; `unknown` fuer konkrete WakeFlow-Optik.

**Konsequenz fuer Feature-2-Plan:** Ein stummer Banner ist API-seitig moeglich.

## Block D - Image 2: Notification Center vs. Custom UI

### D1. Alarmy Custom-Live-Activity oder Standard-Notification?

**Antwort:** Keine Quelle bestaetigt, dass Alarmy fuer Image 2 eine Custom-Live-Activity nutzt. Alarmy dokumentiert fuer iOS 26 separat ein Lock-Screen-Vollbild via "Alarm" permission, und fuer Wake Up Check eine "quiet notification", deren Methode je nach locked/unlocked variiert. Apple beschreibt Notification Center als Standard-Systemliste. Ohne das konkrete Image und ohne Geraetetest bleibt die Zuordnung `inferred`.

**Beleg:** Alarmy iOS 26 Lock-Screen-Artikel lines 9-16, 21-33. Alarmy WakeUpCheck beschreibt eine stille Notification, locked vs unlocked outside app ([Alarmy WakeUpCheck](https://alarmy-ios.zendesk.com/hc/en-us/articles/900000085346--WakeUpCheck-I-don-t-understand-how-Wake-up-check-works-Give-me-an-explanation), lines 29-35). Apple Support Notification Center wie oben.

**Confidence:** `inferred`

**Konsequenz fuer Feature-2-Plan:** Image 2 sollte vorerst als Standard-Notification-Center-Rendering behandelt werden, aber final erst nach Vergleichsscreenshot.

### D2. WakeFlow-Testnotification im Notification Center identisch?

**Antwort:** Eine separate WakeFlow-Standard-`UNNotification` wurde nicht getestet. Der AlarmKit-Spike selbst erschien im Simulator-Notification-Center-Screenshot nicht als Eintrag.

**Beleg:** AlarmKit-Notification-Center-Screenshot `/Users/marvinbarsal/Desktop/Gaming/WakeFlow/ResearchScreenshots/alarmkit-sim-notification-center.png`. Physisches iPhone offline in Xcode-Geraeteliste.

**Confidence:** `verified-on-simulator` fuer AlarmKit-nicht-sichtbar; `unknown` fuer separate Standard-Notification.

**Konsequenz fuer Feature-2-Plan:** Muss in Geraetephase nachgeholt werden.

### D3. Ergebnis

**Antwort:** Nicht final bestaetigt. Doku spricht fuer Standard-Notification-Center-Artefakt; der Simulator-Spike zeigt zusaetzlich, dass AlarmKit selbst nicht als normaler Notification-Center-Eintrag sichtbar wurde. Der direkte Vergleich mit einer separaten Standard-`UNNotification` fehlt noch.

**Beleg:** Siehe D1/D2.

**Confidence:** `inferred`

**Konsequenz fuer Feature-2-Plan:** Kein Custom-UI-Scope ableiten, bis Screenshotvergleich gemacht ist.

## Block E - Konflikte mit bestehendem WakeFlow-Code

### E1. `handleSystemAlarmUpdates` -> `playAlarm(alarm, shouldNotify: false)`

**Antwort:** `shouldNotify: false` unterdrueckt nur den Aufruf `sendSystemAlarmNotification(for:)` innerhalb von `playAlarm`. Dadurch werden nicht erzeugt: die sofortigen `wakeflow-alarm-{uuid}-{count}-{timestamp}`-Notifications, die 3-Sekunden-Timer-Schleife bis 100, und die durch `sendSystemAlarmNotification` gestarteten `scheduleBackupNotifications` mit `backup-alarm-{uuid}-{i}`. Trotzdem laufen AVAudioPlayer, Vibration, Volume-Enforcement, 10-Minuten-Autostop und `saveActiveAlarmState`. AlarmKit-System-UI/-Sound selbst ist kein `UNNotification` und laeuft weiter.

**Beleg:** `playAlarm` setzt State, speichert aktiven Alarm, startet Audio/Vibration/Volume, und ruft `sendSystemAlarmNotification` nur bei `shouldNotify` auf (`ContentView.swift` lines 509-553). `handleSystemAlarmUpdates` setzt `shouldNotify: false` (`ContentView.swift` lines 943-954). `sendSystemAlarmNotification` startet sofortige Notification, Backup-Notifications und 3-Sekunden-Timer (`ContentView.swift` lines 642-672).

**Confidence:** `verified-in-code`

**Konsequenz fuer Feature-2-Plan:** Ein unlocked Banner waere im AlarmKit-Pfad neu und wuerde nicht automatisch durch die vorhandene `shouldNotify: false`-Logik entstehen.

### E2. Identifier-Patterns und Cleanup-Kollision

**Antwort:** Bestehende Cleanup-Patterns:

- `"{alarmUUID}-{i}"` fuer einmalige Fallback-Notifications (`i` 0...100 im Cleanup; Scheduling 0..<12)
- `"{alarmUUID}-{day}-{i}"` fuer wiederkehrende Fallback-Notifications (`day` 1...7, `i` 0...100 im Cleanup)
- `"backup-alarm-{alarmUUID}-{i}"` fuer `scheduleBackupNotifications` / PlayAlarm-Backups (`i` 0...100 im Cleanup; Scheduling 1...scheduleCount)
- `"backup-alarm-{alarmUUID}"` fuer einzelne Calendar-Backup-Notification
- `"backup-alarm-{alarmUUID}-{day}"` fuer wiederkehrende Calendar-Backup-Notification je Wochentag
- `"wakeflow-alarm-{alarmUUID}-{count}-{timestamp}"` fuer sofortige `sendSingleNotification`; diese wird in `stopAlarm` nicht synchron gelistet, aber pending per UUID-Catch-all entfernt und delivered durch `removeAllDeliveredNotifications()`.

Ein zusaetzlicher Banner-Identifier kollidiert faktisch mit `stopAlarm`, wenn er die Alarm-UUID enthaelt: pending Requests werden in Phase 2 per `identifier.contains(alarmID.uuidString)` entfernt. `cancelAlarm` hat diesen Catch-all nicht, entfernt also nur bekannte Patterns und `backup-alarm-{uuid}` / per-day Backup.

**Beleg:** `sendSingleNotification` identifier lines 757-760. Backup IDs lines 714-716 und 1567-1569. `stopAlarm` Cleanup lines 850-885. `cancelAlarm` Cleanup lines 1244-1267.

**Confidence:** `verified-in-code`

**Konsequenz fuer Feature-2-Plan:** Identifier-Namensschema entscheidet, ob Stop/Cancel den Banner automatisch mitraeumt oder nicht.

### E3. AlarmKit-Fehlschlag und Fallback-Spam

**Antwort:** Wenn AlarmKit nicht autorisiert ist, ein Schedule ungueltig ist oder Scheduling wirft, ruft WakeFlow `scheduleNotificationFallbacks(for:)` auf. Dieser Fallback plant bis zu 12 Notifications im 5-Sekunden-Abstand plus eine Calendar-Backup-Notification. Wenn die App zur Alarmzeit selbst `playAlarm()` mit Default `shouldNotify: true` ausloest (z.B. lokaler Timer / Foreground-willPresent), startet zusaetzlich die 3-Sekunden-Schleife bis 100 plus `scheduleBackupNotifications`. In diesem dokumentierten Fehlerpfad gibt es kein erfolgreich geplantes AlarmKit-Lockscreen-UI; "100 Spam + neuer Banner + AlarmKit-UI" waere nur bei einem unbewiesenen Partial-Success-Szenario denkbar.

**Beleg:** AlarmKit-Fallback-Aufrufe `scheduleNotificationFallbacks` in `scheduleSystemAlarm` lines 1060-1071, 1097-1102. `scheduleNotificationFallbacks` Count/Interval lines 1141-1179, recurrence lines 1193-1233, Calendar-Backup line 1237-1240. `checkAlarms` ruft `playAlarm(alarm)` default true lines 489-505.

**Confidence:** `verified-in-code` fuer Fallback-Verhalten; `unknown` fuer Partial-Success mit gleichzeitiger AlarmKit-UI.

**Konsequenz fuer Feature-2-Plan:** Der neue Banner muss im Fallback-Pfad gegen bestehende Notification-Flut abgegrenzt werden.

### E4. `notificationsPaused`

**Antwort:** Das Flag wird nur bei laufendem Alarm gesetzt/entfernt: `pauseNotifications()` setzt true, `resumeNotifications()` setzt false, beide haben `guard isPlaying`. `stopAlarm()` setzt es false. Wirksam ist es nur in `sendSingleNotification`; geplante `scheduleBackupNotifications`, `scheduleNotificationFallbacks`, Calendar-Backups oder ein neuer direkt geplanter Banner wuerden dadurch nicht automatisch unterdrueckt.

**Beleg:** Property line 222. Guard in `sendSingleNotification` lines 733-738. `pauseNotifications` / `resumeNotifications` lines 903-915. Aufrufe in `ContentView` onAppear/willEnterForeground/didEnterBackground lines 1785-1786, 1820-1829. Reset in `stopAlarm` line 897.

**Confidence:** `verified-in-code`

**Konsequenz fuer Feature-2-Plan:** Das Flag ist kein generischer Notification-Gatekeeper.

### E5. Foreground `willPresent` und unlocked Banner

**Antwort:** Ja. Wenn eine Notification mit `alarmID` ankommt, waehrend WakeFlow im Vordergrund ist, ruft `willPresent` sofort `triggerAlarmFromNotification` auf, sofern `isPlaying == false`; danach praesentiert es trotzdem `.banner`, `.sound`, `.badge`. UX-Folge: Bei geoeffneter App wuerde ein neuer Banner mit `alarmID` den `playAlarm`-Pfad sofort starten und durch `isPlaying` die `MoonView`-FullScreenCover anzeigen.

**Beleg:** `WakeFlowFinalApp.swift` lines 69-89. `triggerAlarmFromNotification` startet `playAlarm(alarm)` wenn nicht playing (`ContentView.swift` lines 1279-1295). `fullScreenCover` haengt direkt an `backgroundAlarmManager.isPlaying` (`ContentView.swift` lines 1724-1728).

**Confidence:** `verified-in-code`

**Konsequenz fuer Feature-2-Plan:** Foreground-in-WakeFlow braucht eine bewusste Abgrenzung von unlocked-in-other-app/HomeScreen.

## Block F - Tap- und Stop-Verhalten

### F1. Banner-Tap und MoonView

**Antwort:** Standard-UNNotification: Ja, Tap fuehrt zu `didReceive`, WakeFlow liest `alarmID`, ruft `triggerAlarmFromNotification`, startet bei Bedarf `playAlarm`, und `MoonView` erscheint ueber `isPlaying`. AlarmKit-Alert/Custom-Button: Nein, das ist kein UNNotification-Delegate-Pfad; ein AlarmKit-Button laeuft ueber `LiveActivityIntent` (`secondaryIntent` / `stopIntent`) oder systemische AlarmManager-Logik.

**Beleg:** UNUserNotificationCenterDelegate didReceive-Doku in Header lines 96-100; WakeFlow `didReceive` lines 92-113; `OpenWakeFlowFromAlarmSpikeIntent.perform()` schreibt nur Marker lines 64-75; Spike gibt `secondaryIntent` an lines 2150-2155.

**Confidence:** `verified-in-code` und `verified-in-docs`; AlarmKit-Tap-Details `unknown` ohne Geraetetest.

**Konsequenz fuer Feature-2-Plan:** Standard-Banner und AlarmKit-Button muessen als zwei verschiedene Entry-Points behandelt werden.

### F2. "Verwerfen"-Action, die nur Banner schliesst

**Antwort:** API-seitig kann ein UNNotificationAction ohne `.foreground` definiert werden; dann bringt die Action die App nicht in den Vordergrund. Wenn der Handler fuer diese Action `stopAlarm()` nicht aufruft, stoppt er den Alarm nicht. Das System wird die Notification-UI nach der Response schliessen; ob App-Audio im Hintergrund weiterlaeuft, haengt vom laufenden App-/Audio-Zustand ab und ist nicht auf Geraet verifiziert.

**Beleg:** `UNNotificationActionOptionForeground` ist nur eine Option und bewirkt Foreground-Launch (`UNNotificationAction.h` lines 14-24). Apple Handling Notifications: Actionable Notification Buttons koennen direkt aus Notification-Interface Aktionen an App weitergeben ([Apple Docs](https://developer.apple.com/documentation/UserNotifications/handling-notifications-and-notification-related-actions)). Current WakeFlow `STOP_ALARM` hat `.foreground`, stoppt aber im `didReceive` nicht direkt (`WakeFlowFinalApp.swift` lines 109-110; Category lines 1861-1872).

**Confidence:** `verified-in-docs` fuer Konfigurierbarkeit; `unknown` fuer konkrete Audio-Fortsetzung in allen App-Zustaenden.

**Konsequenz fuer Feature-2-Plan:** Ein Dismiss-Button muss nicht automatisch Stop bedeuten, aber Handler-Semantik und Audiozustand sind testpflichtig.

### F3. HIG: Banner ohne Stop-Moeglichkeit

**Antwort:** Keine gefundene HIG-Regel erzwingt eine Stop-Action in jeder Standard-Notification. iOS bietet immer systemische Dismiss/Clear-Mechaniken. HIG sagt aber: Notifications sollen wertvoll/knapp sein, nicht mehrfach fuer dasselbe Thema gesendet werden, Actions sollen sinnvoll sein, und Foreground-Notifications sollen nicht invasiv sein. Fuer AlarmKit-Alerts selbst betont Apple klare Alert-Presentation und Aktionen; `stopButton`-Customizing ist im iOS-26.4-SDK allerdings deprecated/nicht mehr genutzt.

**Beleg:** HIG Notifications Best Practices und Notification Actions ([Apple HIG](https://developer.apple.com/design/human-interface-guidelines/notifications/)). WWDC25 Best Practice: klare Alert Presentation und erkennbare Actions lines 327-329. SDK: `stopButton` "not used anymore" und deprecated init (`AlarmKit.swiftinterface` lines 54-65).

**Confidence:** `verified-in-docs` fuer HIG/API; `inferred` fuer "zulaessig ohne Stop-Action".

**Konsequenz fuer Feature-2-Plan:** Standard-Banner ohne Stop-Action ist API-seitig moeglich; Produkt-/Review-Risiko muss anhand finaler UX bewertet werden.

## Block G - Wiederkehrende Alarme

### G1. Begleitende UNNotification fuer naechsten Trigger

**Antwort:** Zwei API-Muster sind moeglich: eine einmalige Notification fuer den naechsten konkreten Termin via `UNCalendarNotificationTrigger(... repeats: false)` oder pro Repeat-Day eine wiederkehrende `UNCalendarNotificationTrigger(dateMatching: weekday/hour/minute, repeats: true)`. Bestehender WakeFlow-Code nutzt beide Muster an unterschiedlichen Stellen: `scheduleNotificationFallbacks` plant mehrere one-shots fuer den naechsten Tag je Repeat-Day; `scheduleBackupNotification` plant wiederkehrende Calendar-Backups.

**Beleg:** Apple `UNCalendarNotificationTrigger` kann date components optional wiederholen (`UNNotificationTrigger.h` lines 41-48). Apple Scheduling Local Notification zeigt recurring date-based trigger mit `repeats: true` ([Apple Docs](https://developer.apple.com/documentation/usernotifications/scheduling-a-notification-locally-from-your-app)). WakeFlow one-shot recurrence lines 1193-1233; repeating backup lines 1558-1569.

**Confidence:** `verified-in-docs` und `verified-in-code`

**Konsequenz fuer Feature-2-Plan:** Same-day-Cancel und Future-Persistence unterscheiden sich je nach Trigger-Modell.

### G2. AlarmKit weekly + begleitende UNNotification

**Antwort:** AlarmKit kann weekly relative schedules. `AlarmManager.stop(id:)` stoppt bei repeating alarm nur die aktuelle Alerting-Instanz und rescheduled den Alarm fuer den naechsten Termin; one-shot wird geloescht. Eine separate repeating UNNotification bleibt API-seitig bestehen, bis sie entfernt wird. Current WakeFlow `stopAlarm` entfernt aber bekannte Notification-Identifier fuer den Alarm und wuerde eine companion Notification entfernen, wenn sie in diese Patterns faellt oder in pending Catch-all die Alarm-UUID enthaelt.

**Beleg:** AlarmKit Schedule.Relative.Recurrence.weekly im SDK lines 170-183; Apple docs zu `stop(id:)`: one-shot deleted, repeats rescheduled ([Apple stop(id:)](https://developer.apple.com/documentation/alarmkit/alarmmanager/stop%28id%3A%29)). WakeFlow `stopAlarm` cleanup lines 835-885.

**Confidence:** `verified-in-docs` und `verified-in-code`

**Konsequenz fuer Feature-2-Plan:** AlarmKit-Wiederholung bleibt systemisch erhalten; companion UNNotification-Persistenz haengt am Identifier/Cleanup-Modell.

### G3. NFC-Stop nachts: gleicher Tag canceln, naechste Woche behalten

**Antwort:** Wenn der Banner als one-shot fuer den gleichen Tag geplant ist, kann genau dieser Request entfernt werden. Wenn er als einzelne repeating Calendar-Notification geplant ist, entfernt `removePendingNotificationRequests(withIdentifiers:)` die ganze Serie; es gibt keine dokumentierte API, nur die naechste Occurrence eines repeating Request zu entfernen.

**Beleg:** Apple Scheduling Local Notifications: Requests bleiben aktiv bis Trigger erfuellt oder explizit gecancelt; repeating Requests muessen explizit entfernt werden ([Apple Docs](https://developer.apple.com/documentation/usernotifications/scheduling-a-notification-locally-from-your-app)). `UNNotificationTrigger.repeats` property (`UNNotificationTrigger.h` lines 14-18).

**Confidence:** `verified-in-docs`

**Konsequenz fuer Feature-2-Plan:** Same-day-only-cancel spricht faktisch fuer einzeln identifizierbare Occurrences oder explizites Rescheduling.

## Block H - Cold-Start nach App-Kill

### H1. App gekillt, AlarmKit + parallele Banner-UNNotification, User tippt Banner

**Antwort:** Standard-Notification-Tap sollte ueber `didReceive` laufen, weil WakeFlow den Delegate in `didFinishLaunching` setzt. Der Trigger kann aus `notification.userInfo["alarmID"]` und Payload rekonstruiert werden: `resolveAlarm` sucht in Memory, `savedAlarms`, `scheduledAlarmSnapshots`, Notification-Payload und active alarm state. `didFinishLaunchingWithOptions` selbst wertet allerdings keine LaunchOptions aus. Falls `didReceive` nach Launch geliefert wird, ist der Pfad robust genug, um `playAlarm` und spaeter `MoonView` auszuloesen; finaler Cold-Start-Test fehlt.

**Beleg:** Delegate-Set in `WakeFlowFinalApp.swift` lines 14-16; didReceive lines 92-113. `resolveAlarm` Reihenfolge lines 414-431; Notification-Payload-Rekonstruktion lines 377-411. `checkForActiveAlarmAfterRestart` basiert nur auf `activeAlarmState` lines 1891-1904.

**Confidence:** `inferred` aus Code/Doku; `unknown` fuer echten Cold-Start.

**Konsequenz fuer Feature-2-Plan:** Banner-Payload muss vollstaendige Alarmdaten enthalten, weil `activeAlarmState` beim Kill vor Alert eventuell noch nicht existiert.

### H2. App gekillt, AlarmKit-Lockscreen-Slider/Custom-Intent oeffnet App kalt

**Antwort:** Der aktuelle Production-AlarmKit-Pfad uebergibt keinen `secondaryIntent` und keinen `stopIntent`; nur der DEBUG-Spike hat `secondaryIntent`. Der Spike-Intent schreibt Marker/UserDefaults, aber startet keinen MoonView-Pfad. Standard-Notification-Tap ist ueber `UNNotificationResponse` unterscheidbar; AlarmKit-Intent waere ueber AppIntent/Marker/Parameter unterscheidbar. Ob beide aktuell sauber in MoonView muenden, ist fuer AlarmKit-Cold-Start nicht belegt.

**Beleg:** Production `AlarmConfiguration.alarm(schedule:attributes:sound:)` ohne intents (`ContentView.swift` lines 1086-1090). Spike mit `secondaryIntent` lines 2150-2155. `OpenWakeFlowFromAlarmSpikeIntent.perform()` schreibt nur Marker lines 64-75; Verifier liest Marker lines 103-171.

**Confidence:** `verified-in-code` fuer aktuellen Zustand; `unknown` fuer Runtime.

**Konsequenz fuer Feature-2-Plan:** Banner-Tap und AlarmKit-Intent sind getrennte Startquellen; der robuste gemeinsame MoonView-Trigger ist noch nicht implementiert.

## Offene Fragen / Nachzuholende Geraetetests

- A1: AlarmKit-Spike locked/Standby/Schwarz auf echter Hardware mit Screenshot/Video.
- A2-A4: Hardware-Verifikation der Simulatorbelege, inklusive X-Button-Tap und Audio.
- B2-B4: Audio-Matrix AlarmKit Default, WakeFlow AVAudioPlayer, zusaetzliche UNNotification `.default`/`nil`.
- C1-C6: Separate time-sensitive UNNotification 60s mit/ohne Sound, locked/unlocked/HomeScreen/Notification Center und Tap-Callbacks.
- D2: Image-2-Vergleich mit Notification Center auf Testgeraet.
- F2: Dismiss-Action ohne Stop und Hintergrund-Audio-Fortsetzung.
- H1-H2: Cold-Start per Banner-Tap vs AlarmKit-Intent.

## Drei wichtigste Findings

1. AlarmKit rendert im iPhone-17-Simulator unlocked auf Homescreen und in Safari bereits ein eigenes breites Systemoverlay mit Secondary-Button und X. Das ist kein Standard-UNNotification-Banner und wuerde mit einem zusaetzlichen Feature-2-Banner parallel existieren.

2. `shouldNotify: false` verhindert im AlarmKit-Pfad nur WakeFlows UNNotification-Spam, nicht den lokalen AVAudioPlayer. Dadurch ist paralleles Audio im aktuellen Code moeglich, aber akustisch nicht verifiziert.

3. `stopAlarm` und `cancelAlarm` sind stark identifier-getrieben. Ein neuer Banner wird je nach Identifier entweder automatisch geloescht, versehentlich mitgeloescht oder gar nicht gecleant.
