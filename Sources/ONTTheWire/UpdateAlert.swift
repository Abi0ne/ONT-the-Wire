import AppKit
import ONTTheWireCore
import SwiftUI

extension View {
    /// The update alert: a downloaded update ready to install, or the result
    /// of "Controlla aggiornamenti…".
    func updateAlert(_ updater: Updater, controller: ConnectionController) -> some View {
        modifier(UpdateAlert(updater: updater, controller: controller))
    }
}

private struct UpdateAlert: ViewModifier {
    @Bindable var updater: Updater
    let controller: ConnectionController

    func body(content: Content) -> some View {
        content.alert(title, isPresented: $updater.showAlert) {
            if let release = updater.readyRelease {
                Button("Riavvia e installa") {
                    if updater.scheduleInstall(relaunch: true) { NSApp.terminate(nil) }
                }
                Button("Novità") { NSWorkspace.shared.open(release.pageURL) }
                Button("Alla chiusura", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: {
            Text(message)
        }
    }

    private var title: String {
        switch updater.phase {
        case .ready(let release): "ONT The Wire \(release.version) è pronta"
        case .upToDate: "ONT The Wire è aggiornata"
        case .failed: "Aggiornamento non riuscito"
        default: "Aggiornamenti"
        }
    }

    private var message: String {
        switch updater.phase {
        case .ready:
            var text = "La nuova versione è stata scaricata e la firma è stata verificata (versione attuale: \(updater.currentVersion))."
            if controller.state.isSessionActive {
                text += " Il riavvio chiude la connessione PPPoE attiva."
            }
            return text + " Se scegli “Alla chiusura”, verrà installata quando esci dall’app."
        case .upToDate:
            return "Stai usando l’ultima versione (\(updater.currentVersion))."
        case .failed(let message):
            return message
        default:
            return ""
        }
    }
}
