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

    /// The copy of an element that is on screen. On iOS 17 the dashboard's
    /// radar card stays in the accessibility tree under the full-screen
    /// radar, with the same identifiers, and a plain query tapped the card's
    /// Layers button at the bottom of the screen (found 2026-09-26 on an
    /// iOS 17.0 simulator; iOS 26 hides the covered card).
    private func onScreen(_ query: XCUIElementQuery, _ id: String, timeout: TimeInterval = 5) -> XCUIElement {
        let first = query[id]
        _ = first.waitForExistence(timeout: timeout)
        return query.matching(identifier: id).allElementsBoundByIndex.first(where: { $0.isHittable }) ?? first
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
        // reach, tap it, and confirm the full screen actually came up: its
        // "Radar" navigation bar (the card has a map key button of its own,
        // so that proved nothing).
        let expand = app.buttons["radar.expand"]
        let key = app.navigationBars["Radar"]
        for attempt in 0..<3 {
            var swipes = 0
            while !(expand.exists && expand.isHittable) && swipes < 8 {
                app.swipeUp()
                swipes += 1
                _ = expand.waitForExistence(timeout: 2)
            }
            XCTAssertTrue(expand.waitForExistence(timeout: 30), "the radar card never came on screen\n\(app.debugDescription)")
            // Hittable is not enough at the very bottom of the screen: a
            // tap under the home indicator goes nowhere (the iPhone 15).
            // Nudge the content up until the button is well clear of it.
            var nudges = 0
            while expand.frame.maxY > app.frame.maxY - 60 && nudges < 4 {
                let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
                from.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)))
                nudges += 1
            }
            expand.tap()
            if key.waitForExistence(timeout: 8) { break }
            XCTAssertLessThan(attempt, 2, "expand never opened the radar\n\(app.debugDescription)")
        }

        // The chips sit behind the Layers button; open the bar first.
        let layersButton = onScreen(app.buttons, "radar.layers")
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
        let now = onScreen(app.buttons, "radar.now"), loop = onScreen(app.buttons, "radar.loop")
        let frameTime = onScreen(app.staticTexts, "radar.frameTime")
        XCTAssertTrue(now.waitForExistence(timeout: 5) && loop.exists)
        now.tap()
        XCTAssertTrue(now.isSelected && !loop.isSelected)
        XCTAssertTrue(frameTime.label.contains("latest"), frameTime.label)
        (app.sliders.allElementsBoundByIndex.first(where: { $0.isHittable }) ?? app.sliders.firstMatch)
            .adjust(toNormalizedSliderPosition: 0.2)
        XCTAssertTrue(!now.isSelected && !loop.isSelected, "a scrub should pause where it lands")
        XCTAssertFalse(frameTime.label.contains("latest"), frameTime.label)
        loop.tap()
        XCTAssertTrue(loop.isSelected && !now.isSelected)

        // The six-hour replay: its chip takes the loop from the hour's, the
        // frames go back hours, and a scrub to the far end lands on a
        // forecast frame. Then back to the hour.
        let loop6 = onScreen(app.buttons, "radar.loop6h")
        XCTAssertTrue(loop6.exists, "no six-hour replay chip")
        loop6.tap()
        let playing = NSPredicate(format: "isSelected == true")
        expectation(for: playing, evaluatedWith: loop6)
        waitForExpectations(timeout: 15)
        XCTAssertFalse(loop.isSelected, "both replay chips read as playing")
        // While a loop plays the radar is the GPU's picture; a scrub hands
        // it back to the tile layers.
        // The chip reads as on while the loop buffers, which can take a
        // while on cold caches; the picture comes once it plays.
        let glide = app.descendants(matching: .any)["radar.glide"].firstMatch
        XCTAssertTrue(glide.waitForExistence(timeout: 25), "the loop should be drawn by the GPU")
        let slider = app.sliders.allElementsBoundByIndex.first(where: { $0.isHittable }) ?? app.sliders.firstMatch
        slider.adjust(toNormalizedSliderPosition: 0.0)
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: glide)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(frameTime.label.contains("h ago"), "the day span should reach back hours: \(frameTime.label)")
        slider.adjust(toNormalizedSliderPosition: 1.0)
        XCTAssertTrue(frameTime.label.contains("model") || frameTime.label.contains("nowcast"),
                      "the day span should end in the forecast: \(frameTime.label)")
        XCTAssertTrue(!loop6.isSelected && !loop.isSelected, "a scrub should pause where it lands")
        loop.tap()
        expectation(for: playing, evaluatedWith: loop)
        waitForExpectations(timeout: 15)
        XCTAssertFalse(loop6.isSelected)

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
