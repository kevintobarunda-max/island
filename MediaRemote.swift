import Foundation
import AppKit

// Lee y controla "Reproduciéndose ahora" del sistema.
// Funciona con cualquier reproductor: app de YouTube Music, navegadores, Spotify, etc.
enum MediaRemote {
    private typealias InfoFn = @convention(c) (DispatchQueue, @escaping @convention(block) (CFDictionary?) -> Void) -> Void
    private typealias CmdFn = @convention(c) (Int32, CFDictionary?) -> Bool
    private typealias SeekFn = @convention(c) (Double) -> Void

    private static let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY)

    private static func sym<T>(_ name: String, _ type: T.Type) -> T? {
        guard let h = handle, let p = dlsym(h, name) else { return nil }
        return unsafeBitCast(p, to: type)
    }

    static func nowPlaying(_ done: @escaping ([String: Any]?) -> Void) {
        guard let fn = sym("MRMediaRemoteGetNowPlayingInfo", InfoFn.self) else {
            done(nil)
            return
        }
        fn(DispatchQueue.main) { info in
            if let info { done(info as NSDictionary as? [String: Any]) } else { done(nil) }
        }
    }

    // 2 = play/pausa, 4 = siguiente, 5 = anterior
    static func send(_ command: Int32) {
        _ = sym("MRMediaRemoteSendCommand", CmdFn.self)?(command, nil)
    }

    static func seek(_ seconds: Double) {
        sym("MRMediaRemoteSetElapsedTime", SeekFn.self)?(seconds)
    }
}
