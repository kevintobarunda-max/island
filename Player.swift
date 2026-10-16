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

    private static var lastErr = ""

    static func exec(_ src: String) -> NSAppleEventDescriptor? {
        var err: NSDictionary?
        let result = NSAppleScript(source: src)?.executeAndReturnError(&err)
        if let err {
            let key = "\(err["NSAppleScriptErrorNumber"] ?? 0): \(err["NSAppleScriptErrorMessage"] ?? "error")"
            if key != lastErr {
                lastErr = key
                print("[AppleScript] \(key)")
            }
        }
        return result
    }

    static func run(_ src: String) -> String? { exec(src)?.stringValue }

    static func seek(_ app: String, _ t: Double) {
        if app == "mr" {
            MediaRemote.seek(t)
            return
        }
        if app.hasPrefix("yt:") {
            _ = ytJS(String(app.dropFirst(3)), "var v=document.querySelector('video');if(v)v.currentTime=\(t);")
            return
        }
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

    private var ytPaused: (Track, Double)?

    private func poll() {
        guard let m = model else { return }
        ytPaused = nil
        // YouTube Music (en el navegador) tiene prioridad si está sonando
        if pollYouTubeMusic(m) { return }
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
        // YouTube Music en pausa: la isla se queda mostrándolo
        if let (t, pos) = ytPaused, m.track.source.hasPrefix("yt:") {
            m.musicUpdate(t, position: pos, stopped: false)
            return
        }
        // Cualquier otro reproductor (app de YouTube Music, etc.) vía el sistema
        pollSystem(m)
    }

    private func pollSystem(_ m: IslandModel) {
        MediaRemote.nowPlaying { [weak self] info in
            guard let self else { return }
            guard let info,
                  let title = info["kMRMediaRemoteNowPlayingInfoTitle"] as? String, !title.isEmpty else {
                // Nada suena (la música demo no se toca)
                if m.track.source != "demo" { m.musicUpdate(m.track, position: 0, stopped: true) }
                return
            }
            let artist = info["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? ""
            let total = info["kMRMediaRemoteNowPlayingInfoDuration"] as? Double ?? 0
            let rate = info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double ?? 1
            var pos = info["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? Double ?? 0
            if rate > 0, let ts = info["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date {
                pos += Date().timeIntervalSince(ts) * rate
            }
            var t = Track(title: title, artist: artist, playing: rate > 0,
                          total: total, source: "mr", artwork: nil)
            if let d = info["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data { t.artwork = NSImage(data: d) }

            let key = "mr|\(title)|\(artist)"
            if key != self.lastKey {
                self.lastKey = key
                print("[Sistema] \(title) - \(artist)")
            }
            m.musicUpdate(t, position: total > 0 ? min(pos, total) : pos, stopped: false)
        }
    }

    static func mrControl(_ command: String) {
        switch command {
        case "next track": MediaRemote.send(4)
        case "previous track": MediaRemote.send(5)
        default: MediaRemote.send(2)
        }
    }

    // MARK: YouTube Music (pestaña del navegador)

    private static let browsers = [
        ("Google Chrome", "com.google.Chrome"),
        ("Brave Browser", "com.brave.Browser"),
        ("Microsoft Edge", "com.microsoft.edgemac"),
        ("Safari", "com.apple.Safari")
    ]

    private static let readJS = "(function(){var v=document.querySelector('video');if(!v)return 'none';var m=navigator.mediaSession&&navigator.mediaSession.metadata;var a=(m&&m.artwork&&m.artwork.length)?m.artwork[m.artwork.length-1].src:'';return [v.paused?'paused':'playing',m?m.title:'',m?m.artist:'',v.duration||0,v.currentTime||0,a].join('@@');})()"

    // Ejecuta JavaScript en la pestaña de music.youtube.com del navegador
    static func ytJS(_ browser: String, _ js: String) -> String? {
        let script: String
        if browser == "Safari" {
            script = """
            tell application "Safari"
            repeat with w in windows
            repeat with t in tabs of w
            try
            if (URL of t) contains "music.youtube.com" then return (do JavaScript "\(js)" in t)
            end try
            end repeat
            end repeat
            return "none"
            end tell
            """
        } else {
            script = """
            tell application "\(browser)"
            repeat with w in windows
            repeat with t in tabs of w
            try
            if (URL of t) contains "music.youtube.com" then return (execute t javascript "\(js)")
            end try
            end repeat
            end repeat
            return "none"
            end tell
            """
        }
        return run(script)
    }

    static func ytControl(_ browser: String, _ command: String) {
        let js: String
        switch command {
        case "next track": js = "var b=document.querySelector('.next-button');if(b)b.click();"
        case "previous track": js = "var b=document.querySelector('.previous-button');if(b)b.click();"
        default: js = "var v=document.querySelector('video');if(v){if(v.paused){v.play();}else{v.pause();}}"
        }
        _ = ytJS(browser, js)
    }

    private func pollYouTubeMusic(_ m: IslandModel) -> Bool {
        for (name, bundle) in Self.browsers {
            if NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty { continue }
            guard let out = Self.ytJS(name, Self.readJS), out != "none", out != "missing value" else { continue }
            let p = out.components(separatedBy: "@@")
            guard p.count >= 6, !p[1].isEmpty else { continue }

            func num(_ s: String) -> Double { Double(s) ?? 0 }
            let t = Track(title: p[1], artist: p[2], playing: p[0] == "playing",
                          total: num(p[3]), source: "yt:\(name)", artwork: nil)
            let pos = num(p[4])

            let key = "yt|\(p[1])|\(p[2])"
            if key != lastKey {
                lastKey = key
                print("[YouTube Music] \(name): \(p[1]) - \(p[2]) (\(p[0]))")
                if let url = URL(string: p[5]) {
                    let title = p[1]
                    Task {
                        if let (data, _) = try? await URLSession.shared.data(from: url), let img = NSImage(data: data) {
                            m.setArtwork(img, for: title)
                        }
                    }
                }
            }

            if t.playing {
                m.musicUpdate(t, position: pos, stopped: false)
                return true
            }
            ytPaused = (t, pos)
        }
        return false
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
