import AppKit
import SwiftUI

// Lee cada segundo lo que suena en Music o Spotify (canción, tiempo real, portada)
@MainActor
final class Player {
    private var timer: Timer?
    private weak var model: IslandModel?
    private var lastKey = ""

    func start(model: IslandModel) {
        self.model = model
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    // MARK: AppleScript

    static func exec(_ src: String) -> NSAppleEventDescriptor? {
        var err: NSDictionary?
        return NSAppleScript(source: src)?.executeAndReturnError(&err)
    }

    static func run(_ src: String) -> String? { exec(src)?.stringValue }

    static func seek(_ app: String, _ t: Double) {
        _ = run("tell application \"\(app)\" to set player position to \(t)")
    }

    private func script(_ app: String) -> String {
        """
        tell application "\(app)"
        if player state is stopped then return "stopped"
        set s to (player state as text)
        set tr to current track
        return s & tab & (name of tr) & tab & (artist of tr) & tab & (duration of tr) & tab & (player position)
        end tell
        """
    }

    // MARK: Sondeo

    private func poll() {
        guard let m = model else { return }
        let apps = [("Music", "com.apple.Music"), ("Spotify", "com.spotify.client")]
        for (app, bundle) in apps {
            // No abrimos la app si no está en ejecución
            if NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty { continue }
            guard let out = Self.run(script(app)), out != "stopped" else { continue }
            let p = out.components(separatedBy: "\t")
            guard p.count >= 5 else { continue }

            // Con idioma español, AppleScript devuelve decimales con coma
            func num(_ s: String) -> Double { Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0 }
            var total = num(p[3])
            if app == "Spotify" { total /= 1000 }   // Spotify entrega milisegundos

            let t = Track(title: p[1], artist: p[2], playing: p[0] == "playing",
                          total: total, source: app, artwork: nil)
            m.musicUpdate(t, position: num(p[4]), stopped: false)

            let key = "\(app)|\(p[1])|\(p[2])"
            if key != lastKey {
                lastKey = key
                fetchArtwork(app, title: p[1], model: m)
            }
            return
        }
        // Nada suena en las apps reales (la música demo no se toca)
        if m.track.source != "demo" {
            m.musicUpdate(m.track, position: 0, stopped: true)
        }
    }

    // MARK: Portada

    private func fetchArtwork(_ app: String, title: String, model m: IslandModel) {
        if app == "Spotify" {
            guard let s = Self.run("tell application \"Spotify\" to get artwork url of current track"),
                  let url = URL(string: s) else { return }
            Task {
                if let (data, _) = try? await URLSession.shared.data(from: url), let img = NSImage(data: data) {
                    m.setArtwork(img, for: title)
                }
            }
        } else if let d = Self.exec("tell application \"Music\" to get data of artwork 1 of current track") {
            let raw = d.data
            if let img = NSImage(data: raw) ?? NSImage(data: Data(raw.dropFirst(4))) {
                m.setArtwork(img, for: title)
            }
        }
    }
}

// MARK: - Barra de progreso arrastrable

struct Scrubber: View {
    var value: Double
    var total: Double
    var onSeek: (Double) -> Void
    @State private var dragging: Double? = nil

    var body: some View {
        GeometryReader { g in
            let shown = dragging ?? value
            let frac = CGFloat(min(max(shown / max(total, 1), 0), 1))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.25))
                Capsule().fill(Color.white).frame(width: g.size.width * frac)
            }
            .frame(height: dragging == nil ? 5 : 8)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        dragging = Double(min(max(v.location.x / g.size.width, 0), 1)) * total
                    }
                    .onEnded { v in
                        let t = Double(min(max(v.location.x / g.size.width, 0), 1)) * total
                        dragging = nil
                        onSeek(t)
                    }
            )
        }
        .frame(height: 12)
        .animation(.easeOut(duration: 0.15), value: dragging == nil)
    }
}

// MARK: - Portada real o degradado

extension IslandView {
    @ViewBuilder func artView(_ size: CGFloat) -> some View {
        if let img = m.track.artwork {
            Image(nsImage: img)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.27))
        } else {
            art(size)
        }
    }
}
