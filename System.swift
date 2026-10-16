import Foundation
import IOKit.ps

// Detecta cuando conectas el cargador (evento real del sistema)
@MainActor
final class BatteryMonitor {
    private var wasCharging: Bool?
    private weak var model: IslandModel?

    func start(model: IslandModel) {
        self.model = model
        check()
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { ctx in
            guard let ctx else { return }
            let me = Unmanaged<BatteryMonitor>.fromOpaque(ctx).takeUnretainedValue()
            Task { @MainActor in me.check() }
        }
        if let src = IOPSNotificationCreateRunLoopSource(callback, ctx)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        }
    }

    func check() {
        guard let snap = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snap)?.takeRetainedValue() as? [CFTypeRef] else { return }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(snap, ps)?.takeUnretainedValue() as? [String: Any] else { continue }
            let charging = d[kIOPSIsChargingKey] as? Bool ?? false
            let level = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            model?.battery = level
            if let was = wasCharging, !was, charging { model?.show(.charging) }
            wasCharging = charging
            return
        }
    }
}

// Escucha la reproducción real de Music.app y Spotify
@MainActor
final class MusicMonitor {
    func start(model: IslandModel) {
        observe("com.apple.Music.playerInfo", source: "Music", model: model)
        observe("com.spotify.client.PlaybackStateChanged", source: "Spotify", model: model)
    }

    private func observe(_ name: String, source: String, model: IslandModel) {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(name), object: nil, queue: .main
        ) { n in
            let u = n.userInfo ?? [:]
            let state = u["Player State"] as? String ?? ""
            let totalMs = ((u["Total Time"] as? NSNumber) ?? (u["Duration"] as? NSNumber))?.doubleValue ?? 0
            let pos = (u["Playback Position"] as? NSNumber)?.doubleValue ?? 0
            let track = Track(title: u["Name"] as? String ?? "Sin título",
                              artist: u["Artist"] as? String ?? "",
                              playing: state == "Playing",
                              total: totalMs / 1000,
                              source: source)
            Task { @MainActor in
                model.musicUpdate(track, position: pos, stopped: state == "Stopped")
            }
        }
    }
}
