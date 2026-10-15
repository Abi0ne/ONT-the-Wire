import AppKit
import ONTTheWireCore
import SwiftUI

@main
struct ONTTheWireApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("ONT The Wire", id: "main") {
            ContentView(controller: appDelegate.controller)
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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = ConnectionController()
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
        guard controller.needsTerminationWork else { return .terminateNow }
        Task {
            await controller.prepareForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
