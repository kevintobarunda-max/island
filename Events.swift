import Foundation
import AppKit
import CoreAudio
import AudioToolbox
import IOBluetooth

// Pon esto en false si la app se cierra sola al iniciar (permiso de Bluetooth)
let enableBluetooth = true

// Escucha el volumen, el micrófono, el bloqueo de pantalla y el Bluetooth
final class BTWatcher: NSObject {
    var model: IslandModel?

    func start(_ m: IslandModel) {
        model = m
        IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(connected(_:device:)))
    }

    @objc func connected(_ n: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let name = device.name ?? "Dispositivo"
        let air = name.localizedCaseInsensitiveContains("airpods")
        let toast = Toast(symbol: air ? "airpodspro" : "headphones", color: .blue, title: name, subtitle: "Conectado")
        Task { @MainActor in self.model?.show(.message, toast: toast) }
    }
}

@MainActor
enum SystemEvents {
    static let bt = BTWatcher()
    static let player = Player()

    static func start(model: IslandModel) {
        // Música real: canción, tiempo y portada
        player.start(model: model)

        // Pantalla desbloqueada
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { _ in
            Task { @MainActor in model.show(.unlock, for: 2.5) }
        }

        // Volumen y silencio de la salida de audio
        let out = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        for sel in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute] {
            listen(out, sel, kAudioDevicePropertyScopeOutput) {
                Task { @MainActor in reportVolume(model) }
            }
        }

        // Micrófono en uso por cualquier app
        let input = defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
        listen(input, kAudioDevicePropertyDeviceIsRunningSomewhere, kAudioObjectPropertyScopeGlobal) {
            let on: UInt32? = prop(input, kAudioDevicePropertyDeviceIsRunningSomewhere, kAudioObjectPropertyScopeGlobal, UInt32(0))
            if on == 1 {
                let t = Toast(symbol: "mic.fill", color: .orange, title: "Micrófono en uso", subtitle: "Una app está grabando audio")
                Task { @MainActor in model.show(.message, toast: t, for: 4) }
            }
        }

        // Dispositivos Bluetooth (AirPods, auriculares…)
        if enableBluetooth { bt.start(model) }
    }

    // MARK: Volumen

    static func reportVolume(_ model: IslandModel) {
        let dev = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        let muted: UInt32 = prop(dev, kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput, UInt32(0)) ?? 0
        let vol: Float32 = prop(dev, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput, Float32(0)) ?? 0
        if muted == 1 || vol == 0 {
            model.show(.silent, for: 2)
        } else {
            let t = Toast(symbol: "speaker.wave.2.fill", color: .blue, title: "Volumen", subtitle: "\(Int(vol * 100))%")
            model.show(.message, toast: t, for: 1.6)
        }
    }

    // MARK: Utilidades de CoreAudio

    static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioObjectID {
        prop(AudioObjectID(kAudioObjectSystemObject), selector, kAudioObjectPropertyScopeGlobal, AudioObjectID(0)) ?? 0
    }

    static func prop<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope, _ initial: T) -> T? {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    static func listen(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector,
                       _ scope: AudioObjectPropertyScope, _ handler: @escaping () -> Void) {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(obj, &addr, DispatchQueue.main) { _, _ in handler() }
    }
}
