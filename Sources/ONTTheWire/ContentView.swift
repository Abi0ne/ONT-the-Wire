import ONTTheWireCore
import SwiftUI

struct ContentView: View {
    @Bindable var controller: ConnectionController
    let navigation: Navigation

    var body: some View {
        HStack(spacing: 0) {
            SettingsColumn(controller: controller)
                .frame(minWidth: 400, idealWidth: 440, maxWidth: 520)

            Divider()

            SessionColumn(controller: controller, navigation: navigation)
                .frame(minWidth: 380, maxWidth: .infinity)
        }
    }
}

// MARK: - Left column: configuration

private struct SettingsColumn: View {
    @Bindable var controller: ConnectionController

    private var inputsLocked: Bool {
        controller.state.isBusy || controller.state.isSessionActive
    }

    var body: some View {
        Form {
            adapterSection
            vlanSection
            credentialsSection
            optionsSection
        }
        .formStyle(.grouped)
        .disabled(inputsLocked)
    }

    private var adapterSection: some View {
        Section {
            if controller.catalog.interfaces.isEmpty {
                Label("Nessun adattatore Ethernet collegato.", systemImage: "cable.connector.slash")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Adattatore", selection: $controller.settings.interfaceBSDName) {
                    Text("Seleziona…").tag(String?.none)
                    ForEach(controller.catalog.interfaces) { iface in
                        Text("\(iface.displayName) (\(iface.bsdName))")
                            .tag(Optional(iface.bsdName))
                    }
                }
                if let iface = controller.catalog.interface(named: controller.settings.interfaceBSDName) {
                    LabeledContent("Link") {
                        LinkIndicator(active: iface.linkActive)
                    }
                }
            }
        } header: {
            HStack {
                Text("Adattatore Ethernet")
                Spacer()
                Button {
                    controller.catalog.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Aggiorna l’elenco degli adattatori")
            }
        } footer: {
            Text("L’adattatore collegato con un cavo alla porta LAN dell’ONT.")
                .foregroundStyle(.secondary)
        }
    }

    private var vlanSection: some View {
        Section {
            TextField("VLAN ID", text: $controller.settings.vlanIDText, prompt: Text("es. 835"))
                .onChange(of: controller.settings.vlanIDText) { _, newValue in
                    let digits = String(newValue.filter(\.isNumber).prefix(4))
                    if digits != newValue { controller.settings.vlanIDText = digits }
                }
            if !controller.settings.vlanIDText.isEmpty && controller.settings.vlanID == nil {
                Text(SettingsProblem.vlanInvalid.message)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("VLAN")
        } footer: {
            Text("Il tag 802.1Q indicato dall’operatore (TIM: 835). Vuoto: frame senza tag.")
                .foregroundStyle(.secondary)
        }
    }

    private var credentialsSection: some View {
        Section {
            TextField("Username", text: $controller.settings.username, prompt: Text("utente PPPoE"))
                .autocorrectionDisabled()
            SecureField("Password", text: $controller.password, prompt: Text("password PPPoE"))
        } header: {
            Text("Credenziali PPPoE")
        } footer: {
            Text("Usate solo finché l’app resta aperta: non vengono salvate da nessuna parte.")
                .foregroundStyle(.secondary)
        }
    }

    private var optionsSection: some View {
        Section("Opzioni") {
            Toggle(isOn: $controller.settings.useAsPrimary) {
                Text("Usa come connessione principale")
                Text("Route predefinita e DNS passano dal PPPoE anche con il Wi‑Fi attivo.")
            }
        }
    }
}

// MARK: - Right column: status, actions, summary and log

private struct SessionColumn: View {
    let controller: ConnectionController
    // Tab state lives in Navigation rather than @State: with Command Line
    // Tools only, the SwiftUIMacros plugin behind the macOS 26 SDK's @State
    // is unavailable.
    @Bindable var navigation: Navigation

    private typealias Tab = Navigation.SessionTab

    private var inputsLocked: Bool {
        controller.state.isBusy || controller.state.isSessionActive
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StatusView(state: controller.state, onDismissError: controller.clearError)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))

            actions

            Picker("", selection: $navigation.sessionTab) {
                Text("Riepilogo").tag(Tab.summary)
                Text(logTabTitle).tag(Tab.log)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch navigation.sessionTab {
                case .summary:
                    ScrollView {
                        VStack(spacing: 14) {
                            SummaryView(controller: controller)
                            SpeedTestView(controller: controller)
                        }
                    }
                case .log: LogView(log: controller.log)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(16)
    }

    private var logTabTitle: String {
        let count = controller.log.entries.count
        return count == 0 ? "Log" : "Log (\(count))"
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    Task { await controller.connect() }
                } label: {
                    Text("Connetti").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!controller.canConnect)

                Button {
                    Task { await controller.disconnect() }
                } label: {
                    Text("Disconnetti").frame(maxWidth: .infinity)
                }
                .disabled(!controller.canDisconnect)
            }
            .controlSize(.large)

            if !controller.problems.isEmpty && !inputsLocked {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Per connetterti manca:")
                        .font(.callout.weight(.semibold))
                    ForEach(controller.problems, id: \.self) { problem in
                        Label(problem.message, systemImage: "exclamationmark.circle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else if !inputsLocked && !controller.isAuthorized {
                Label(
                    "Alla connessione macOS chiederà una volta l’autorizzazione di amministratore, valida finché l’app resta aperta.",
                    systemImage: "lock")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct SummaryView: View {
    let controller: ConnectionController

    var body: some View {
        let settings = controller.settings
        let details = controller.details
        let iface = controller.catalog.interface(named: settings.interfaceBSDName)

        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 10) {
            row("Adattatore", iface.map { "\($0.displayName) (\($0.bsdName))" } ?? "—")
            GridRow {
                label("Link")
                if let iface { LinkIndicator(active: iface.linkActive) } else { Text("—") }
            }
            Divider()
            row("VLAN", settings.vlanID.map(String.init) ?? "senza tag")
            Divider()
            row("Concentratore", details.concentrator ?? "—")
            row("Sessione PPPoE", details.sessionID.map(String.init) ?? "—")
            row("Interfaccia PPP", details.pppInterface ?? "—")
            row("Indirizzo", details.localAddress ?? "—")
            row("Gateway", details.remoteAddress ?? "—")
            row("DNS", details.dnsServers.isEmpty ? "—" : details.dnsServers.joined(separator: "\n"))
            row("Connessione principale", settings.useAsPrimary ? "sì" : "no")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            label(title)
            Text(value).textSelection(.enabled)
        }
    }

    private func label(_ title: String) -> some View {
        Text(title)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }

}


private struct LinkIndicator: View {
    let active: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(active ? .green : .orange)
                .frame(width: 8, height: 8)
            Text(active ? "Attivo" : "Non attivo")
        }
    }
}
