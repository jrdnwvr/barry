//  RadarUITests.swift
//  BarryUITests
//
//  One walk through the radar: open it full screen, turn every layer on,
//  pan, zoom out to a continent and back in, turn the layers off again,
//  come back. It asserts nothing about pixels; it asserts the app is still
//  standing and the wind layer is still on when it leaves.

import XCTest

final class RadarUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func chip(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.buttons["radar.chip.\(name)"]
    }

    /// The chip bar scrolls sideways. A swipe carries with momentum and
    /// overshoots, so this drags, slowly, by the distance the chip is from
    /// the bar's centre, a step at a time, until the chip can be tapped.
    private func tapChip(_ app: XCUIApplication, _ name: String) {
        let c = chip(app, name)
        XCTAssertTrue(c.waitForExistence(timeout: 10), "no \(name) chip")
        let bar = app.scrollViews["radar.chips"]
        var steps = 0
        while !c.isHittable && bar.exists && steps < 8 {
            let dx = max(-150, min(150, c.frame.midX - bar.frame.midX))
            let start = bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: -dx, dy: 0)))
            usleep(400_000)
            steps += 1
        }
        XCTAssertTrue(c.isHittable, "\(name) chip is not reachable\n\(app.debugDescription)")
        c.tap()
    }

    func testRadarSurvivesEveryLayerAPanAndAZoom() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uitest"]
        addUIInterruptionMonitor(withDescription: "system prompt") { alert in
            for label in ["Allow While Using App", "Allow", "Don't Allow", "OK"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        app.launch()

        // Scroll the dashboard until the radar card's expand button is in
        // reach, tap it, and confirm the full screen actually came up (the
        // map key button only exists there).
        let expand = app.buttons["radar.expand"]
        let key = app.buttons["Map key"]
        for attempt in 0..<3 {
            var swipes = 0
            while !(expand.exists && expand.isHittable) && swipes < 8 {
                app.swipeUp()
                swipes += 1
                _ = expand.waitForExistence(timeout: 2)
            }
            XCTAssertTrue(expand.waitForExistence(timeout: 30), "the radar card never came on screen\n\(app.debugDescription)")
            expand.tap()
            if key.waitForExistence(timeout: 8) { break }
            XCTAssertLessThan(attempt, 2, "expand never opened the radar\n\(app.debugDescription)")
        }

        let layers = ["Pressure", "Change", "Isobars", "Wind", "Fronts", "Troughs", "Stations", "Lightning"]
        for name in layers {
            tapChip(app, name)
            sleep(1)
        }

        let map = app.otherElements["radar.map"].exists ? app.otherElements["radar.map"] : app.maps.firstMatch
        XCTAssertTrue(map.waitForExistence(timeout: 10), "no map on the radar screen\n\(app.debugDescription)")
        map.swipeLeft()
        map.swipeDown()
        map.pinch(withScale: 0.2, velocity: -2)      // out to a continent
        sleep(4)
        map.pinch(withScale: 4.0, velocity: 2)       // and back in
        sleep(2)

        for name in layers where name != "Wind" {
            tapChip(app, name)
        }
        XCTAssertTrue(chip(app, "Wind").isSelected, "the wind layer should still be on")

        // The timeline: Now parks on the latest frame, a scrub pauses where
        // it lands, the loop button starts the last hour again.
        let now = app.buttons["radar.now"], loop = app.buttons["radar.loop"]
        let frameTime = app.staticTexts["radar.frameTime"]
        XCTAssertTrue(now.waitForExistence(timeout: 5) && loop.exists)
        now.tap()
        XCTAssertTrue(now.isSelected && !loop.isSelected)
        XCTAssertTrue(frameTime.label.contains("latest"), frameTime.label)
        app.sliders.firstMatch.adjust(toNormalizedSliderPosition: 0.2)
        XCTAssertTrue(!now.isSelected && !loop.isSelected, "a scrub should pause where it lands")
        XCTAssertFalse(frameTime.label.contains("latest"), frameTime.label)
        loop.tap()
        XCTAssertTrue(loop.isSelected && !now.isSelected)

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(expand.waitForExistence(timeout: 10), "did not come back to the dashboard")
        XCTAssertEqual(app.state, .runningForeground)
    }
}
