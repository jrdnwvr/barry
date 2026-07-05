//  RadarView.swift
//  Barry — iOS
//
//  Lowest-angle radar sheet, Dark Sky style: a muted basemap where the rain is
//  the only saturated thing on screen, a single restrained color ramp (RainViewer's
//  "Dark Sky" scheme), the last hour of frames plus a short nowcast, and a scrubber.
//  Corroboration for the pressure trend — "here's the rain, physically, right now."
//
//  Tiles come straight from RainViewer (device → tile CDN; the Barry backend stays
//  out of the image business). Attribution required and shown in the footer.

import SwiftUI
import MapKit

// MARK: - Frames

struct RadarFrame: Equatable, Identifiable {
    let time: Int      // unix epoch
    let path: String   // e.g. /v2/radar/1720100000
    let nowcast: Bool
    var id: Int { time }
}

@MainActor
final class RadarModel: ObservableObject {
    @Published var frames: [RadarFrame] = []
    @Published var host = "https://tilecache.rainviewer.com"
    @Published var index = 0
    @Published var playing = true
    @Published var failed = false

    /// Index of the most recent observed (non-forecast) frame.
    var nowIndex: Int {
        frames.lastIndex(where: { !$0.nowcast }) ?? 0
    }

    func load() async {
        failed = false
        struct Maps: Decodable {
            struct Entry: Decodable { let time: Int; let path: String }
            struct Radar: Decodable { let past: [Entry]; let nowcast: [Entry] }
            let host: String
            let radar: Radar
        }
        do {
            let url = URL(string: "https://api.rainviewer.com/public/weather-maps.json")!
            let (data, _) = try await URLSession.shared.data(from: url)
            let maps = try JSONDecoder().decode(Maps.self, from: data)
            host = maps.host
            let past = maps.radar.past.suffix(7)
                .map { RadarFrame(time: $0.time, path: $0.path, nowcast: false) }
            let cast = maps.radar.nowcast.prefix(3)
                .map { RadarFrame(time: $0.time, path: $0.path, nowcast: true) }
            frames = Array(past) + Array(cast)
            index = nowIndex
        } catch {
            failed = true
        }
    }
}

// MARK: - Map (UIKit bridge)

/// MKMapView with one tile overlay per radar frame; scrubbing just flips renderer
/// alphas, so already-loaded frames replay instantly.
struct RadarMapView: UIViewRepresentable {
    let host: String
    let frames: [RadarFrame]
    let index: Int
    let center: CLLocationCoordinate2D

    final class RadarTileOverlay: MKTileOverlay {
        var frameTime = 0
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var overlays: [Int: RadarTileOverlay] = [:]
        var renderers: [Int: MKTileOverlayRenderer] = [:]

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tile = overlay as? RadarTileOverlay {
                let r = MKTileOverlayRenderer(tileOverlay: tile)
                r.alpha = 0
                renderers[tile.frameTime] = r
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        // Dark Sky rule: mute everything that isn't rain.
        let cfg = MKStandardMapConfiguration(emphasisStyle: .muted)
        cfg.pointOfInterestFilter = .excludingAll
        map.preferredConfiguration = cfg
        map.showsCompass = false
        map.region = MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: 3.2, longitudeDelta: 3.2))
        let pin = MKPointAnnotation()
        pin.coordinate = center
        map.addAnnotation(pin)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        // Lazily add an overlay per frame (RainViewer "Dark Sky" scheme = color 8;
        // options 1_1 = smoothed + snow shown distinctly).
        for f in frames where context.coordinator.overlays[f.time] == nil {
            let template = host + f.path + "/256/{z}/{x}/{y}/8/1_1.png"
            let tile = RadarTileOverlay(urlTemplate: template)
            tile.frameTime = f.time
            tile.canReplaceMapContent = false
            context.coordinator.overlays[f.time] = tile
            map.addOverlay(tile, level: .aboveRoads)
        }
        guard frames.indices.contains(index) else { return }
        let current = frames[index].time
        for (time, renderer) in context.coordinator.renderers {
            renderer.alpha = (time == current) ? 0.75 : 0
        }
    }
}

// MARK: - Sheet

struct RadarView: View {
    let lat: Double
    let lon: Double
    let stationName: String

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = RadarModel()
    private let ticker = Timer.publish(every: 0.7, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            Group {
                if model.failed {
                    VStack(spacing: 10) {
                        Text("Couldn't load radar. Check your connection.")
                            .foregroundStyle(.secondary)
                        Button("Try again") { Task { await model.load() } }
                            .buttonStyle(.bordered)
                    }
                } else if model.frames.isEmpty {
                    ProgressView("Loading radar…")
                } else {
                    content
                }
            }
            .navigationTitle("Radar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await model.load() }
            .onReceive(ticker) { _ in
                guard model.playing, !model.frames.isEmpty else { return }
                model.index = (model.index + 1) % model.frames.count
            }
        }
    }

    private var content: some View {
        VStack(spacing: 10) {
            RadarMapView(host: model.host,
                         frames: model.frames,
                         index: model.index,
                         center: CLLocationCoordinate2D(latitude: lat, longitude: lon))
                .clipShape(RoundedRectangle(cornerRadius: 12))

            controls
            legend
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                model.playing.toggle()
            } label: {
                Image(systemName: model.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .semibold))
            }
            .buttonStyle(.plain)

            Slider(
                value: Binding(
                    get: { Double(model.index) },
                    set: { model.index = Int($0.rounded()); model.playing = false }
                ),
                in: 0...Double(max(1, model.frames.count - 1)),
                step: 1
            )

            Text(timeLabel)
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(currentFrame?.nowcast == true ? .orange : .secondary)
                .frame(width: 84, alignment: .trailing)
        }
    }

    private var currentFrame: RadarFrame? {
        model.frames.indices.contains(model.index) ? model.frames[model.index] : nil
    }

    private var timeLabel: String {
        guard let f = currentFrame else { return "" }
        let mins = Int((Date().timeIntervalSince1970 - Double(f.time)) / 60)
        if f.nowcast { return "+\(max(0, -mins))m forecast" }
        return mins <= 1 ? "now" : "\(mins)m ago"
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 14) {
                swatch(Color(red: 0.55, green: 0.75, blue: 0.95), "Light")
                swatch(Color(red: 0.13, green: 0.42, blue: 0.82), "Moderate")
                swatch(Color(red: 0.94, green: 0.65, blue: 0.15), "Heavy")
                Spacer()
            }
            Text("\(stationName) marked. Forecast frames show in orange on the timeline. Radar tiles by RainViewer, data from NOAA NEXRAD.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func swatch(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 14, height: 8)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
