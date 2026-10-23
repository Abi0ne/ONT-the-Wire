import AppKit
import ONTTheWireCore
import SwiftUI

@main
struct ONTTheWireApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("ONT The Wire", id: "main") {
            RootView(controller: appDelegate.controller, phone: appDelegate.phone)
                .frame(minWidth: 960, minHeight: 600)
                .updateAlert(appDelegate.updater, controller: appDelegate.controller)
        }
        .defaultSize(width: 1000, height: 615)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Controlla aggiornamenti…") {
                    Task { await appDelegate.updater.check(userInitiated: true) }
                }
                .disabled(appDelegate.updater.isWorking)
            }
            CommandGroup(replacing: .help) {
                Button("Manuale di ONT The Wire") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/\(UpdateFeed.repository)/blob/main/docs/MANUALE.md")!)
                }
                Button("Pagina del progetto su GitHub") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/\(UpdateFeed.repository)")!)
                }
            }
        }
    }
}

/// The two sections of the window, switched from the toolbar.
private struct RootView: View {
    let controller: ConnectionController
    let phone: SIPPhone
    @AppStorage("section") private var section: Section = .pppoe

    private enum Section: String { case pppoe, sip }

    var body: some View {
        Group {
            switch section {
            case .pppoe: ContentView(controller: controller)
            case .sip: SIPCallerView(phone: phone, controller: controller)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Sezione", selection: $section) {
                    Label("Connessione PPPoE", systemImage: "cable.connector").tag(Section.pppoe)
                    Label("SIP Caller", systemImage: "phone").tag(Section.sip)
                }
                .pickerStyle(.segmented)
                .labelStyle(.titleAndIcon)
                .labelsHidden()
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = ConnectionController()
    lazy var phone = SIPPhone()
    lazy var updater = Updater(log: controller.log)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (`swift run`) rather than
        // from the .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        // One administrator authorization per app run, asked up front.
        Task { await controller.authorize() }
        // Every launch: a newer signed release is downloaded in the background
        // and offered once it is ready.
        Task { await updater.check(userInitiated: false) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // An update the user postponed replaces the app now, without relaunch.
        _ = updater.scheduleInstall(relaunch: false)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard controller.needsTerminationWork || phone.needsShutdown else { return .terminateNow }
        Task {
            // Unregister first, while the PPPoE link may still carry it.
            await phone.shutdown()
            await controller.prepareForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
