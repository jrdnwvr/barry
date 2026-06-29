//  PressureHistory.swift
//  Barry — Shared
//
//  A persisted, downsampled rolling log of calibrated phone SLP readings (brief Task 2).
//
//  BarometerManager's in-memory SampleBuffer only spans ~60 min and resets on relaunch.
//  PressureHistory is the long-horizon companion: one point every few minutes, retained
//  for ~48 h, persisted to the App Group so the "sensor vs station" overlay (Task 3) can
//  show the phone's continuous trace across hours and survive relaunches.
//
//  Pure + Codable + Equatable like CalibrationModel — all logic lives here and is unit
//  tested without Core Motion hardware. BarometerManager only feeds it trusted samples.

import Foundation

// MARK: - PressureLogEntry

/// One stored calibrated reading: the SLP-equivalent the app believed at `date`.
struct PressureLogEntry: Equatable, Codable {
    let date: Date
    let slp: Double  // calibrated SLP-equivalent (hPa)
}

// MARK: - PressureHistory

struct PressureHistory: Equatable, Codable {
    /// Minimum spacing between stored points. Trusted samples arrive far more often
    /// than this; we downsample so 48 h of history stays small and chartable.
    static let minSampleInterval: TimeInterval = 150     // ~2.5 min

    /// How far back to retain. Older points are pruned on each write.
    static let maxAgeSeconds: TimeInterval = 48 * 3600   // ~48 h

    /// Hard safety cap so a clock anomaly can't grow the log without bound
    /// (48 h / 2.5 min ≈ 1152 points; this leaves generous headroom).
    static let maxPoints = 2000

    var entries: [PressureLogEntry] = []

    /// Append a calibrated reading, throttled to `minSampleInterval` since the last
    /// stored point (downsampling), then prune anything older than `maxAgeSeconds`.
    /// Returns true when the reading was actually stored — the caller should persist
    /// only then, so writes are throttled too. Out-of-order / duplicate timestamps
    /// (Δt < interval, including non-positive) are ignored.
    @discardableResult
    mutating func record(slp: Double, at date: Date) -> Bool {
        if let last = entries.last,
           date.timeIntervalSince(last.date) < Self.minSampleInterval {
            return false
        }
        entries.append(PressureLogEntry(date: date, slp: slp))
        prune(now: date)
        return true
    }

    /// Drop points older than the retention window and enforce the hard cap.
    mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.maxAgeSeconds)
        entries.removeAll { $0.date < cutoff }
        if entries.count > Self.maxPoints {
            entries.removeFirst(entries.count - Self.maxPoints)
        }
    }

    /// Charting trace, oldest → newest, as (Date, SLP) pairs.
    func trace() -> [(Date, Double)] {
        entries.map { ($0.date, $0.slp) }
    }
}
