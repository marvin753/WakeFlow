//
//  WakeFlowFinalUITests.swift
//  WakeFlowFinalUITests
//
//  Research-only simulator probes for AlarmKit rendering.
//

import XCTest

final class WakeFlowFinalUITests: XCTestCase {
    private let screenshotDirectory = URL(fileURLWithPath: "/Users/marvinbarsal/Desktop/Gaming/WakeFlow/ResearchScreenshots", isDirectory: true)

    override func setUpWithError() throws {
        continueAfterFailure = false
        try FileManager.default.createDirectory(at: screenshotDirectory, withIntermediateDirectories: true)
    }

    @MainActor
    func testAlarmKitSpikeHomeScreenAndNotificationCenter() throws {
        let app = launchWakeFlow()
        try scheduleAlarmKitSpike(in: app)

        XCUIDevice.shared.press(.home)
        waitForAlarmToFire()

        try saveScreenshot(named: "alarmkit-sim-homescreen")

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let start = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.01))
        let end = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.82))
        start.press(forDuration: 0.2, thenDragTo: end)
        sleep(2)

        try saveScreenshot(named: "alarmkit-sim-notification-center")
    }

    @MainActor
    func testAlarmKitSpikeForeignApp() throws {
        let app = launchWakeFlow()
        try scheduleAlarmKitSpike(in: app)

        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.launch()
        handleSystemAlerts(focusedApp: safari)
        waitForAlarmToFire()

        try saveScreenshot(named: "alarmkit-sim-foreign-app")
    }

    @MainActor
    func testAlarmKitSpikeSecondaryButtonTapFromHomeScreen() throws {
        let app = launchWakeFlow()
        try scheduleAlarmKitSpike(in: app)

        XCUIDevice.shared.press(.home)
        waitForAlarmToFire()

        tapAlarmKitSecondaryButton()
        sleep(4)

        try saveScreenshot(named: "alarmkit-sim-secondary-tap-result")
    }

    @MainActor
    func testAlarmKitSpikeCloseButtonTapFromHomeScreen() throws {
        let app = launchWakeFlow()
        try scheduleAlarmKitSpike(in: app)

        XCUIDevice.shared.press(.home)
        waitForAlarmToFire()

        tapAlarmKitCloseButton()
        sleep(3)

        try saveScreenshot(named: "alarmkit-sim-close-tap-result")
    }

    @MainActor
    private func launchWakeFlow() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        handleSystemAlerts(focusedApp: app)
        return app
    }

    @MainActor
    private func scheduleAlarmKitSpike(in app: XCUIApplication) throws {
        handleSystemAlerts(focusedApp: app)

        let spikeButton = app.buttons["AlarmKit Spike"]
        XCTAssertTrue(spikeButton.waitForExistence(timeout: 15), "AlarmKit Spike button did not appear")
        spikeButton.tap()

        handleSystemAlerts(focusedApp: app)
        sleep(2)
        handleSystemAlerts(focusedApp: app)
    }

    @MainActor
    private func handleSystemAlerts(focusedApp: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let positiveButtons = [
            "Allow",
            "OK",
            "Continue",
            "Erlauben",
            "Zulassen",
            "Fortfahren",
            "OK"
        ]

        for _ in 0..<8 {
            let alert = springboard.alerts.firstMatch
            if alert.exists {
                var tapped = false
                for title in positiveButtons {
                    let button = alert.buttons[title]
                    if button.exists {
                        button.tap()
                        tapped = true
                        break
                    }
                }

                if !tapped {
                    alert.buttons.element(boundBy: alert.buttons.count - 1).tap()
                }
                sleep(1)
            } else {
                focusedApp.tap()
                usleep(250_000)
            }
        }
    }

    private func waitForAlarmToFire() {
        sleep(75)
    }

    private func tapAlarmKitSecondaryButton() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.716, dy: 0.067)).tap()
    }

    private func tapAlarmKitCloseButton() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.862, dy: 0.067)).tap()
    }

    private func saveScreenshot(named name: String) throws {
        let screenshot = XCUIScreen.main.screenshot()
        let url = screenshotDirectory.appendingPathComponent("\(name).png")
        try screenshot.pngRepresentation.write(to: url, options: .atomic)

        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
