//  Locked.swift
//  Barry — iOS
//
//  A value the main thread writes and another thread reads.

import Foundation

/// MapKit draws overlays on its own queue while the main thread goes on
/// changing what they should show. A struct with references in it, read on
/// one thread while it is being replaced on another, loses count of those
/// references and the app dies in `swift_deallocClassInstance`: that
/// happened on 2026-10-02 the first time an overlay's state was replaced
/// thirty times a second instead of once a radar frame. Every overlay's
/// state goes through one of these.
final class Locked<Value>: @unchecked Sendable {
    private var stored: Value
    private let lock = NSLock()

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }

    /// Read and change the value in one step.
    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(&stored)
    }
}
