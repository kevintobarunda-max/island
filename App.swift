import SwiftUI
import AppKit

// Vista que deja pasar los clics fuera de la isla
final class IslandHost: NSHostingView<IslandView> {
    var model: IslandModel?

    required init(rootView: IslandView) { super.init(rootView: rootView) }
    @objc required dynamic init?(coder: NSCoder) { fatalError("init(coder:) no implementado") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let m = model else { return super.hitTest(point) }
        let p = convert(point, from: superview)
        let s = m.size
        let y = isFlipped ? 0 : bounds.height - s.height
        let rect = NSRect(x: (bounds.width - s.width) / 2, y: y, width: s.width, height: s.height)
            .insetBy(dx: -8, dy: -8)
        return rect.contains(p) ? super.hitTest(point) : nil
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = IslandModel()
    let battery = BatteryMonitor()
    let music = MusicMonitor()
    var panel: NSPanel!
    var statusItem: NSStatusItem!
    var actions: [Int: () -> Void] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildPanel()
        buildMenu()
        music.start(model: model)
        battery.start(model: model)
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.model.refreshMetrics()
                self?.position()
            }
        }
    }

    // MARK: Panel flotante sobre el notch

    func buildPanel() {
        let host = IslandHost(rootView: IslandView(m: model))
        host.model = model

        panel = NSPanel(contentRect: .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        position()
        panel.orderFrontRegardless()
    }

    func position() {
        let s = IslandModel.targetScreen()
        let w: CGFloat = 480, h: CGFloat = 300
        panel.setFrame(NSRect(x: s.frame.midX - w / 2, y: s.frame.maxY - h, width: w, height: h), display: true)
    }

    // MARK: Menú de la barra (disparadores de cada acción)

    func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "Isla Dinámica")

        let menu = NSMenu()
        menu.addItem(NSMenuItem.sectionHeader(title: "Actividades en vivo"))
        add(menu, "Música")            { self.model.toggleLive(.music) }
        add(menu, "Temporizador")      { self.model.toggleLive(.timer) }
        add(menu, "Llamada entrante")  { self.model.toggleLive(.call) }
        add(menu, "Grabación de voz")  { self.model.toggleLive(.recording) }
        add(menu, "Navegación")        { self.model.toggleLive(.navigation) }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem.sectionHeader(title: "Eventos temporales"))
        add(menu, "AirDrop")           { self.model.show(.airdrop, for: 8) }
        add(menu, "Cargando")          { self.model.show(.charging) }
        add(menu, "AirPods conectados"){ self.model.show(.airpods) }
        add(menu, "Modo silencio")     { self.model.show(.silent) }
        add(menu, "Desbloqueo")        { self.model.show(.unlock, for: 2) }
        add(menu, "Mensaje nuevo")     {
            self.model.show(.message, toast: Toast(symbol: "envelope.fill", color: .green,
                                                   title: "Valentina", subtitle: "¿Almorzamos hoy a las 2?"))
        }

        menu.addItem(.separator())
        add(menu, "Reiniciar isla")    { self.model.reset() }
        add(menu, "Salir")             { NSApp.terminate(nil) }
        statusItem.menu = menu
    }

    func add(_ menu: NSMenu, _ title: String, _ action: @escaping () -> Void) {
        let item = NSMenuItem(title: title, action: #selector(fire(_:)), keyEquivalent: "")
        item.target = self
        item.tag = actions.count
        actions[item.tag] = action
        menu.addItem(item)
    }

    @objc func fire(_ sender: NSMenuItem) { actions[sender.tag]?() }
}

@main
enum Launcher {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // sin icono en el Dock
        app.run()
    }
}
