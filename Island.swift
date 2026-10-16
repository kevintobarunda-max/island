import SwiftUI
import AppKit

// MARK: - Modelo

enum Activity: Hashable {
    case idle
    // Actividades en vivo
    case music, timer, call, recording, navigation
    // Eventos temporales
    case airdrop, charging, airpods, silent, unlock, message
}

struct Track {
    var title = "Medianoche en Santiago"
    var artist = "Los Andes Sur"
    var playing = true
    var total: Double = 214
    var source = "demo"          // "Music", "Spotify" o "demo"
    var artwork: NSImage? = nil
}

struct Toast {
    var symbol: String
    var color: Color
    var title: String
    var subtitle: String
}

@MainActor
final class IslandModel: ObservableObject {
    @Published var live: Activity = .idle
    @Published var transient: Activity? = nil
    @Published var expanded = false
    @Published var callAnswered = false
    @Published var elapsed: Double = 0
    @Published var remaining = 300
    @Published var distance = 400
    @Published var battery = 100
    @Published var track = Track()
    @Published var toast = Toast(symbol: "envelope.fill", color: .green, title: "Valentina", subtitle: "¿Almorzamos hoy a las 2?")
    @Published var notchW: CGFloat = 190
    @Published var notchH: CGFloat = 34

    @Published var hovering = false
    private var collapseTask: Task<Void, Never>?
    private var ticker: Timer?
    private var transientTask: Task<Void, Never>?

    var current: Activity { transient ?? live }

    init() {
        refreshMetrics()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    // Pantalla con notch (o la principal si no hay)
    static func targetScreen() -> NSScreen {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    func refreshMetrics() {
        let s = Self.targetScreen()
        if s.safeAreaInsets.top > 0, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
            notchW = s.frame.width - l.width - r.width
            notchH = s.safeAreaInsets.top
        } else {
            notchW = 190
            notchH = 34
        }
    }

    // MARK: Tamaños

    var isBig: Bool {
        switch current {
        case .airdrop, .airpods, .message: return true
        case .call: return !callAnswered || expanded
        case .music, .timer, .navigation, .recording: return expanded
        default: return false
        }
    }

    var bodyHeight: CGFloat {
        switch current {
        case .music: return 156
        case .timer, .navigation: return 60
        case .recording: return 80
        case .call: return callAnswered ? 60 : 84
        case .airdrop: return 84
        case .airpods, .message: return 56
        default: return 0
        }
    }

    var size: CGSize {
        if current == .idle { return CGSize(width: notchW, height: notchH) }
        if isBig { return CGSize(width: 390, height: notchH + 4 + bodyHeight + 18) }
        let extra: CGFloat
        switch current {
        case .charging, .silent: extra = 130
        case .unlock: extra = 50
        default: extra = 150
        }
        return CGSize(width: notchW + extra, height: notchH)
    }

    // MARK: Acciones

    func start(_ a: Activity) {
        transientTask?.cancel()
        transient = nil
        live = a
        elapsed = 0
        remaining = 300
        distance = 400
        callAnswered = false
        expanded = (a == .call)
        if a == .music { track = Track() }
    }

    func stopLive() {
        live = .idle
        expanded = false
        callAnswered = false
    }

    func toggleLive(_ a: Activity) {
        live == a ? stopLive() : start(a)
    }

    func show(_ a: Activity, toast t: Toast? = nil, for seconds: Double = 3.6) {
        if let t { toast = t }
        transientTask?.cancel()
        transient = a
        transientTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled { self?.transient = nil }
        }
    }

    func dismiss() {
        transientTask?.cancel()
        transient = nil
    }

    func tapIsland() {
        guard transient == nil, live != .idle else { return }
        if live == .call && !callAnswered { return }
        expanded.toggle()
    }

    func answerCall() { callAnswered = true; elapsed = 0; expanded = true }

    func reset() {
        transientTask?.cancel()
        transient = nil
        stopLive()
    }

    // MARK: Música (Music.app / Spotify / demo)

    func musicUpdate(_ t: Track, position: Double, stopped: Bool) {
        var t = t
        let changed = t.title != track.title || t.source != track.source
        if t.artwork == nil && !changed { t.artwork = track.artwork }
        track = t
        elapsed = position
        if stopped {
            if live == .music { stopLive() }
            return
        }
        if live == .idle || live == .music {
            live = .music
            if changed && transient == nil { peek() }
        }
    }

    // Al cambiar de canción la isla se abre unos segundos
    func peek() {
        expanded = true
        collapseTask?.cancel()
        collapseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            if !Task.isCancelled, let self, !self.hovering, self.live == .music { self.expanded = false }
        }
    }

    // Pasar el mouse expande la isla de música
    func hover(_ inside: Bool) {
        hovering = inside
        guard transient == nil, live == .music else { return }
        expanded = inside
    }

    func seek(_ t: Double) {
        elapsed = t
        if track.source != "demo" { Player.seek(track.source, t) }
    }

    func setArtwork(_ img: NSImage, for title: String) {
        if track.title == title { track.artwork = img }
    }

    func control(_ command: String) {
        if track.source == "demo" {
            if command == "playpause" { track.playing.toggle() } else { elapsed = 0 }
            return
        }
        if track.source == "mr" {
            Player.mrControl(command)
            return
        }
        if track.source.hasPrefix("yt:") {
            Player.ytControl(String(track.source.dropFirst(3)), command)
            return
        }
        let app = track.source
        Task.detached {
            var err: NSDictionary?
            NSAppleScript(source: "tell application \"\(app)\" to \(command)")?.executeAndReturnError(&err)
        }
    }

    private func tick() {
        switch live {
        case .music: if track.playing { elapsed += 1 }
        case .call: if callAnswered { elapsed += 1 }
        case .recording: elapsed += 1
        case .navigation: distance = max(20, distance - 20)
        case .timer:
            if remaining > 0 { remaining -= 1 }
            if remaining == 0 {
                stopLive()
                show(.message, toast: Toast(symbol: "timer", color: .orange, title: "Temporizador", subtitle: "Se acabó el tiempo"), for: 5)
            }
        default: break
        }
    }
}

// MARK: - Forma con esquinas inferiores redondeadas

struct NotchShape: Shape {
    var r: CGFloat
    var animatableData: CGFloat {
        get { r }
        set { r = newValue }
    }
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: rect.maxX, y: 0))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: 0, y: rect.maxY - r), control: CGPoint(x: 0, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

struct Equalizer: View {
    var active: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.06, paused: !active)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    Capsule().fill(Color.green)
                        .frame(width: 3, height: active ? CGFloat(4 + 11 * abs(sin(t * 4 + Double(i) * 1.3))) : 4)
                }
            }
            .frame(height: 16)
        }
    }
}

// MARK: - Vista de la isla

struct IslandView: View {
    @ObservedObject var m: IslandModel
    private let spring = Animation.spring(response: 0.5, dampingFraction: 0.7)

    var body: some View {
        let s = m.size
        let id = "\(m.current)-\(m.expanded)-\(m.callAnswered)"
        ZStack(alignment: .top) {
            content
                .id(id)
                .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .top)))
        }
        .animation(.easeInOut(duration: 0.22), value: id)
        .frame(width: s.width, height: s.height, alignment: .top)
        .background(Color.black)
        .clipShape(NotchShape(r: m.isBig ? 32 : 16))
        .animation(spring, value: s)
        .animation(spring, value: m.isBig)
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .onTapGesture { m.tapIsland() }
        .onHover { m.hover($0) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: Contenido

    @ViewBuilder var content: some View {
        switch m.current {
        case .idle:
            Color.clear
        case .music:
            if m.expanded { musicBig } else { compact(artView(22), Equalizer(active: m.track.playing)) }
        case .timer:
            if m.expanded { timerBig } else {
                compact(Image(systemName: "timer").foregroundStyle(.orange),
                        Text(fmt(m.remaining)).foregroundStyle(.orange).monospacedDigit())
            }
        case .call:
            if !m.callAnswered { callIncoming }
            else if m.expanded { callBig }
            else {
                compact(Image(systemName: "phone.fill").foregroundStyle(.green),
                        Text(fmt(Int(m.elapsed))).foregroundStyle(.green).monospacedDigit())
            }
        case .recording:
            if m.expanded { recBig } else {
                compact(Circle().fill(.red).frame(width: 9, height: 9),
                        Text(fmt(Int(m.elapsed))).monospacedDigit())
            }
        case .navigation:
            if m.expanded { navBig } else {
                compact(Image(systemName: "arrow.turn.up.right").foregroundStyle(.blue),
                        Text("\(m.distance) m").monospacedDigit())
            }
        case .charging:
            compact(Image(systemName: "bolt.fill").foregroundStyle(.green),
                    HStack(spacing: 4) { Text("\(m.battery)%").font(.system(size: 12)); Image(systemName: "battery.100.bolt").foregroundStyle(.green) })
        case .silent:
            compact(Image(systemName: "bell.slash.fill").foregroundStyle(.orange), Text("Silencio").font(.system(size: 12)))
        case .unlock:
            compact(Image(systemName: "lock.open.fill").foregroundStyle(.green), Color.clear.frame(width: 1))
        case .airdrop:
            big {
                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        icon("dot.radiowaves.left.and.right", .blue)
                        titles("AirDrop de Matías", "foto-cordillera.heic")
                        Spacer()
                    }
                    HStack(spacing: 10) {
                        pill("Rechazar", Color(white: 0.2)) { m.dismiss() }
                        pill("Aceptar", .green) { m.dismiss() }
                    }
                }
            }
        case .airpods:
            big {
                HStack(spacing: 12) {
                    icon("airpodspro", Color(white: 0.2))
                    titles("AirPods Pro", "Conectados · L 92% · R 90%")
                    Spacer()
                }
            }
        case .message:
            big {
                HStack(spacing: 12) {
                    icon(m.toast.symbol, m.toast.color)
                    titles(m.toast.title, m.toast.subtitle)
                    Spacer()
                }
            }
        }
    }

    // MARK: Bloques expandidos

    var musicBig: some View {
        big {
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    artView(52)
                    titles(m.track.title, m.track.artist)
                    Spacer()
                    Equalizer(active: m.track.playing)
                }
                VStack(spacing: 3) {
                    Scrubber(value: m.elapsed, total: m.track.total) { m.seek($0) }
                    HStack {
                        Text(fmt(Int(m.elapsed)))
                        Spacer()
                        Text("-" + fmt(max(0, Int(m.track.total - m.elapsed))))
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }
                HStack(spacing: 36) {
                    ctl("backward.fill", "previous track")
                    ctl(m.track.playing ? "pause.fill" : "play.fill", "playpause")
                    ctl("forward.fill", "next track")
                }
            }
        }
    }

    var timerBig: some View {
        big {
            HStack(spacing: 12) {
                Image(systemName: "timer").font(.system(size: 26)).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Temporizador").font(.system(size: 12)).foregroundStyle(.secondary)
                    Text(fmt(m.remaining)).font(.system(size: 26, weight: .semibold)).monospacedDigit()
                }
                Spacer()
                pill("Detener", Color(white: 0.2), fill: false) { m.stopLive() }
            }
        }
    }

    var callIncoming: some View {
        big {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    icon("person.fill", .blue)
                    titles("Camila Rojas", "Llamada de FaceTime")
                    Spacer()
                }
                HStack(spacing: 10) {
                    pill("Rechazar", .red) { m.stopLive() }
                    pill("Aceptar", .green) { m.answerCall() }
                }
            }
        }
    }

    var callBig: some View {
        big {
            HStack(spacing: 12) {
                icon("person.fill", .green)
                titles("Camila Rojas", "En llamada \(fmt(Int(m.elapsed)))")
                Spacer()
                pill("Colgar", .red, fill: false) { m.stopLive() }
            }
        }
    }

    var recBig: some View {
        big {
            VStack(spacing: 10) {
                HStack {
                    Circle().fill(.red).frame(width: 10, height: 10)
                    Text(fmt(Int(m.elapsed))).font(.system(size: 26, weight: .semibold)).monospacedDigit()
                    Spacer()
                    Equalizer(active: true)
                }
                pill("Detener grabación", .red) { m.stopLive() }
            }
        }
    }

    var navBig: some View {
        big {
            HStack(spacing: 14) {
                Image(systemName: "arrow.turn.up.right").font(.system(size: 34)).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(m.distance) m").font(.system(size: 26, weight: .semibold)).monospacedDigit()
                    Text("Gira a la derecha en Av. Providencia").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }

    // MARK: Piezas

    func compact<L: View, T: View>(_ l: L, _ t: T) -> some View {
        HStack {
            l
            Spacer(minLength: m.notchW)
            t
        }
        .font(.system(size: 13, weight: .semibold))
        .padding(.horizontal, 18)
        .frame(height: m.notchH)
    }

    func big<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        c()
            .padding(.top, m.notchH + 4)
            .padding(.horizontal, 22)
            .padding(.bottom, 14)
    }

    func art(_ size: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: size * 0.27)
            .fill(LinearGradient(colors: [.orange, .pink], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
    }

    func icon(_ name: String, _ color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 18))
            .frame(width: 40, height: 40)
            .background(color, in: RoundedRectangle(cornerRadius: 11))
    }

    func titles(_ a: String, _ b: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(a).font(.system(size: 14, weight: .semibold)).lineLimit(1)
            Text(b).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    func pill(_ t: String, _ c: Color, fill: Bool = true, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t)
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: fill ? .infinity : nil)
                .padding(.vertical, 8)
                .padding(.horizontal, fill ? 0 : 18)
                .background(c, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    func ctl(_ symbol: String, _ cmd: String) -> some View {
        Button { m.control(cmd) } label: {
            Image(systemName: symbol).font(.system(size: 20))
        }
        .buttonStyle(.plain)
    }

    func fmt(_ s: Int) -> String { String(format: "%d:%02d", s / 60, s % 60) }
}
