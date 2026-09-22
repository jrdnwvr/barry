//  Diagnostics.swift
//  Barry — iOS
//
//  MetricKit hands every app a daily report: launch times, hang and crash
//  diagnostics, battery and network totals. Barry sends its own to its own
//  server (backend/app/diagnostics.py), where they sit as files until a
//  person reads them. Nothing in a payload locates or identifies the phone,
//  and nothing else is collected; the privacy page says the same.

import Foundation
import MetricKit

final class DiagnosticsReporter: NSObject, MXMetricManagerSubscriber {
    static let shared = DiagnosticsReporter()
    private let api = BarryAPI()
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for p in payloads { send(p.jsonRepresentation(), kind: "metric") }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for p in payloads { send(p.jsonRepresentation(), kind: "diagnostic") }
    }

    private func send(_ body: Data, kind: String) {
        // The server refuses anything over a megabyte; do not bother it.
        guard !body.isEmpty, body.count <= 1 << 20 else { return }
        Task.detached(priority: .utility) { [api] in
            try? await api.postDiagnostics(body, kind: kind)
        }
    }
}
