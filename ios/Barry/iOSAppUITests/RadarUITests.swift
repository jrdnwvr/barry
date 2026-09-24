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

        // The chips sit behind the Layers button; open the bar first.
        let layersButton = app.buttons["radar.layers"]
        XCTAssertTrue(layersButton.waitForExistence(timeout: 5), "no Layers button\n\(app.debugDescription)")
        layersButton.tap()
        XCTAssertTrue(app.scrollViews["radar.chips"].waitForExistence(timeout: 5), "the chip bar did not open")

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

        // The altitude rail: up to the top stop and the note says so, back to the surface.
        let rail = app.otherElements["radar.altitude"].firstMatch
        XCTAssertTrue(rail.waitForExistence(timeout: 5), "no altitude rail with wind on\n\(app.debugDescription)")
        rail.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        XCTAssertTrue(app.staticTexts["radar.altitudeNote"].firstMatch.waitForExistence(timeout: 5), "no note above the surface")
        XCTAssertNotEqual(rail.value as? String, "Surface")
        rail.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)).tap()
        XCTAssertEqual(rail.value as? String, "Surface")

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

    /// The column: opens from the conditions card, its chips toggle, the
    /// scrubber moves the hour, the ceiling menu rescales, back returns.
    func testAloftOpensTogglesScrubsAndComesBack() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uitest"]
        app.launch()

        let cta = app.descendants(matching: .any)["conditions.clouds"].firstMatch
        var swipes = 0
        while !(cta.exists && cta.isHittable) && swipes < 10 {
            app.swipeUp()
            swipes += 1
            _ = cta.waitForExistence(timeout: 2)
        }
        XCTAssertTrue(cta.waitForExistence(timeout: 30), "no way into Aloft on the dashboard\n\(app.debugDescription)")
        cta.tap()

        let ceiling = app.buttons["aloft.ceiling"].firstMatch
        XCTAssertTrue(ceiling.waitForExistence(timeout: 15), "Aloft did not open")
        let time = app.staticTexts["aloft.time"].firstMatch
        XCTAssertTrue(time.waitForExistence(timeout: 20))
        // The column has loaded once the label carries a clock time.
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS 'M'"), object: time)
        XCTAssertEqual(XCTWaiter().wait(for: [loaded], timeout: 30), .completed, "the column never loaded: \(time.label)")
        XCTAssertTrue(time.label.hasPrefix("Now"), time.label)

        // The layer chips sit behind the Layers button. A tap that lands
        // while the push is still settling can be eaten; one more try.
        let layersButton = app.buttons["aloft.layers"].firstMatch
        XCTAssertTrue(layersButton.waitForExistence(timeout: 5), "no Layers button")
        layersButton.tap()
        if !app.buttons["aloft.layer.clouds"].firstMatch.waitForExistence(timeout: 3) { layersButton.tap() }
        for name in ["clouds", "wind", "temp", "icing", "layer"] {
            let chip = app.buttons["aloft.layer.\(name)"].firstMatch
            XCTAssertTrue(chip.waitForExistence(timeout: 5), "\(name)\n\(app.debugDescription)")
            let was = chip.isSelected
            chip.tap()
            XCTAssertNotEqual(chip.isSelected, was, "\(name) did not toggle")
            chip.tap()
        }

        app.sliders.firstMatch.adjust(toNormalizedSliderPosition: 0.5)
        XCTAssertTrue(time.label.hasPrefix("+"), time.label)

        ceiling.tap()
        let twelve = app.buttons["12,000 ft"].firstMatch
        XCTAssertTrue(twelve.waitForExistence(timeout: 5), app.debugDescription)
        twelve.tap()
        XCTAssertTrue(app.buttons["aloft.ceiling"].firstMatch.label.contains("12,000"))

        app.buttons["Back"].firstMatch.tap()
        XCTAssertTrue(cta.waitForExistence(timeout: 10), "did not come back")
        XCTAssertEqual(app.state, .runningForeground)
    }
}
