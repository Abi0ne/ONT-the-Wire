import AppKit
import ONTTheWireCore
import SwiftUI
import UniformTypeIdentifiers

/// SIP Caller: registers a SIP account from a 3CX template and runs test
/// calls in both directions, on any network of the Mac.
struct SIPCallerView: View {
    @Bindable var phone: SIPPhone
    let controller: ConnectionController
    let navigation: Navigation

    var body: some View {
        HStack(spacing: 0) {
            SIPAccountColumn(phone: phone)
                .frame(minWidth: 400, idealWidth: 440, maxWidth: 520)

            Divider()

            SIPTestColumn(phone: phone, navigation: navigation)
                .frame(minWidth: 380, maxWidth: .infinity)
        }
        .onAppear { phone.refreshLinks() }
        // A PPPoE session coming up or going down changes the networks.
        .onChange(of: controller.details.pppInterface) { _, _ in phone.refreshLinks() }
        .onChange(of: controller.details.localAddress) { _, _ in phone.refreshLinks() }
    }
}

// MARK: - Left column: template, account, network

private struct SIPAccountColumn: View {
    @Bindable var phone: SIPPhone

    var body: some View {
        Form {
            templateSection
            accountSection
            networkSection
        }
        .formStyle(.grouped)
    }

    private var locked: Bool { phone.registration.isActive }

    private var templateSection: some View {
        Section {
            if phone.templates.templates.isEmpty {
                Label("Nessun template importato.", systemImage: "doc.badge.plus")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Provider", selection: $phone.selectedTemplateID) {
                    Text("Seleziona…").tag(String?.none)
                    ForEach(phone.templates.templates) { template in
                        Text(template.name).tag(Optional(template.id))
                    }
                }
            }
        } header: {
            HStack {
                Text("Template 3CX")
                Spacer()
                Button {
                    importTemplate()
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .buttonStyle(.borderless)
                .help("Importa un template di provider esportato da 3CX (.xml)")
                Button {
                    phone.removeSelectedTemplate()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(phone.template == nil)
                .help("Rimuovi il template selezionato")
            }
        } footer: {
            Text(templateFooter)
                .foregroundStyle(.secondary)
        }
        .disabled(locked)
    }

    private var templateFooter: String {
        guard let template = phone.template else {
            return phone.templates.templates.isEmpty
                ? "Importa il file del provider esportato da 3CX, oppure compila i campi a mano."
                : "Scegli il provider per compilare server e porta, oppure compila i campi a mano."
        }
        var parts = ["\(template.registrarHost):\(template.registrarPort)"]
        if let proxy = template.proxyHost { parts.append("proxy \(proxy):\(template.proxyPort ?? 5060)") }
        parts.append(template.transport == "ANY" ? "UDP/TCP" : template.transport)
        parts.append("registrazione ogni \(template.registrationExpiry) s")
        if !template.codecs.isEmpty {
            parts.append("codec " + template.codecs.map { $0.uppercased() }.joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }

    private var accountSection: some View {
        Section {
            TextField("Numero / ID", text: $phone.number, prompt: Text("es. 0612345678"))
                .autocorrectionDisabled()
            TextField("Auth ID", text: $phone.authID, prompt: Text("uguale al numero"))
                .autocorrectionDisabled()
            SecureField("Password", text: $phone.password, prompt: Text("password SIP"))
            TextField("Server SIP", text: $phone.server, prompt: Text("es. voip.provider.it"))
                .autocorrectionDisabled()
            TextField("Porta", text: $phone.portText, prompt: Text("es. 5060"))
                .onChange(of: phone.portText) { _, newValue in
                    let digits = String(newValue.filter(\.isNumber).prefix(5))
                    if digits != newValue { phone.portText = digits }
                }
        } header: {
            Text("Account SIP")
        } footer: {
            Text(phone.template?.separateAuthID == true
                 ? "Questo provider usa un Auth ID distinto dal numero. Le credenziali restano in memoria finché l’app è aperta."
                 : "Le credenziali restano in memoria finché l’app è aperta: non vengono salvate.")
                .foregroundStyle(.secondary)
        }
        .disabled(locked)
    }

    private var networkSection: some View {
        Section {
            Picker("Rete", selection: $phone.networkInterface) {
                Text("Automatica (rete principale del Mac)").tag(String?.none)
                ForEach(phone.links) { link in
                    Text("\(link.displayName) (\(link.bsdName)) · \(link.address)").tag(Optional(link.bsdName))
                }
                if let chosen = phone.networkInterface, !phone.links.contains(where: { $0.bsdName == chosen }) {
                    Text("\(chosen) (non disponibile)").tag(Optional(chosen))
                }
            }
        } header: {
            HStack {
                Text("Rete")
                Spacer()
                Button {
                    phone.refreshLinks()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Aggiorna l’elenco delle reti")
            }
        } footer: {
            Text("Va bene qualsiasi connessione: il PPPoE di ONT The Wire, il Wi‑Fi o un cavo. Dietro un router il test usa l’indirizzo pubblico indicato dal server.")
                .foregroundStyle(.secondary)
        }
        .disabled(locked)
    }

    private func importTemplate() {
        let panel = NSOpenPanel()
        panel.title = "Importa template 3CX"
        panel.prompt = "Importa"
        panel.allowedContentTypes = [.xml]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            do {
                try phone.importTemplate(from: url)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Impossibile importare “\(url.lastPathComponent)”"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }
}

// MARK: - Right column: registration, test calls, log

private struct SIPTestColumn: View {
    @Bindable var phone: SIPPhone
    @Bindable var navigation: Navigation

    private typealias Tab = Navigation.SIPTab

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SIPStatusView(phone: phone)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))

            registrationActions

            Picker("", selection: $navigation.sipTab) {
                Text("Test").tag(Tab.tests)
                Text(phone.log.entries.isEmpty ? "Log" : "Log (\(phone.log.entries.count))").tag(Tab.log)
                Text("Traccia SIP").tag(Tab.trace)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch navigation.sipTab {
                case .tests:
                    ScrollView {
                        VStack(spacing: 14) {
                            OutgoingCallCard(phone: phone)
                            IncomingCallCard(phone: phone)
                            CallReportCard(phone: phone)
                        }
                    }
                case .log: LogView(log: phone.log)
                case .trace: SIPTraceView(phone: phone)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(16)
    }

    private var registrationActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    Task { await phone.register() }
                } label: {
                    Text("Registra").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!phone.canRegister)

                Button {
                    Task { await phone.unregister() }
                } label: {
                    Text("Deregistra").frame(maxWidth: .infinity)
                }
                .disabled(!phone.registration.isActive)
            }
            .controlSize(.large)

            if !phone.problems.isEmpty && !phone.registration.isActive {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Per registrarti manca:")
                        .font(.callout.weight(.semibold))
                    ForEach(phone.problems, id: \.self) { problem in
                        Label(problem, systemImage: "exclamationmark.circle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

private struct SIPStatusView: View {
    let phone: SIPPhone

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 26))
                .foregroundStyle(color)
                .frame(width: 32)
                .symbolEffect(.pulse, isActive: busy)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title3.weight(.semibold))
                if let detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if case .failed = phone.registration {
                Button("OK") { phone.clearError() }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var busy: Bool {
        switch phone.registration {
        case .registering, .unregistering: true
        default: false
        }
    }

    private var symbol: String {
        switch phone.registration {
        case .idle: "phone.down"
        case .registering, .unregistering: "phone.arrow.up.right"
        case .registered: "phone.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch phone.registration {
        case .registered: .green
        case .failed: .red
        case .idle: .secondary
        default: .orange
        }
    }

    private var title: String {
        switch phone.registration {
        case .idle: "Non registrato"
        case .registering: "Registrazione…"
        case .registered: "Registrato"
        case .unregistering: "Deregistrazione…"
        case .failed: "Registrazione non riuscita"
        }
    }

    private var detail: String? {
        switch phone.registration {
        case .idle: "Scegli un template, inserisci le credenziali e registra l’account."
        case .registering, .unregistering: phone.binding
        case .registered(let expires):
            [phone.binding, "Rinnovo ogni \(expires) s."].compactMap { $0 }.joined(separator: "\n")
        case .failed(let message): message
        }
    }
}

private struct OutgoingCallCard: View {
    @Bindable var phone: SIPPhone

    private var inOutgoingCall: Bool {
        switch phone.call {
        case .dialing, .ringing: true
        case .active(let direction, _, _): direction == .outgoing
        default: false
        }
    }

    var body: some View {
        Card(title: "Chiamata in uscita", systemImage: "phone.arrow.up.right") {
            HStack {
                TextField("Numero da chiamare", text: $phone.destination, prompt: Text("es. il tuo cellulare"))
                    .textFieldStyle(.roundedBorder)
                    .disabled(!phone.call.isIdle)
                    .onSubmit { phone.startOutgoingCall() }
                if inOutgoingCall {
                    Button("Riaggancia", role: .destructive) { phone.hangUp() }
                } else {
                    Button("Chiama") { phone.startOutgoingCall() }
                        .disabled(!phone.canCall)
                }
            }
            Text("Chi risponde sente due toni e poi la propria voce in eco: così verifichi l’audio in entrambe le direzioni. La chiamata si chiude da sola dopo \(Int(SIPPhone.maxCallDuration)) secondi.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct IncomingCallCard: View {
    let phone: SIPPhone

    private var inIncomingCall: Bool {
        switch phone.call {
        case .waitingIncoming, .answering: true
        case .active(let direction, _, _): direction == .incoming
        default: false
        }
    }

    var body: some View {
        Card(title: "Chiamata in entrata", systemImage: "phone.arrow.down.left") {
            HStack {
                Text(hint)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if inIncomingCall {
                    Button(phone.call == .waitingIncoming ? "Annulla" : "Riaggancia", role: .destructive) { phone.hangUp() }
                } else {
                    Button("Attendi chiamata") { phone.waitForIncomingCall() }
                        .disabled(!phone.registration.isRegistered || !phone.call.isIdle)
                }
            }
        }
    }

    private var hint: String {
        let number = phone.number.isEmpty ? "il numero" : phone.number
        return "Chiama \(number) da un altro telefono: l’app risponde dopo due squilli con lo stesso test eco."
    }
}

private struct CallReportCard: View {
    let phone: SIPPhone

    var body: some View {
        Card(title: "Esito", systemImage: "waveform") {
            Text(text)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(phone.call.isIdle && phone.report == nil ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if let report = phone.report, phone.call.isIdle {
                Label(report.outcome, systemImage: report.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(report.success ? .green : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var text: String {
        switch phone.call {
        case .idle:
            guard let report = phone.report else {
                return phone.registration.isRegistered
                    ? "Nessuna prova ancora: chiama un numero o attendi una chiamata."
                    : "Disponibile dopo la registrazione."
            }
            var lines = [
                "  Direzione  " + (report.direction == .outgoing ? "uscita verso \(report.peer)" : "entrata da \(report.peer)"),
                "   Risposta  " + (report.answered ? "sì" : "no"),
            ]
            if let duration = report.duration { lines.append(String(format: "     Durata  %.0f s", duration)) }
            if report.answered {
                lines.append("      Codec  " + (report.codec ?? "—"))
                lines.append("  Audio RTP  \(report.packetsSent) inviati · \(report.packetsReceived) ricevuti")
                if let level = report.peakLevel { lines.append(String(format: "    Livello  picco %.0f dBFS", level)) }
                if let media = report.remoteMedia { lines.append("   Remoto  \(media)") }
            }
            return lines.joined(separator: "\n")
        case .dialing(let peer): return "Chiamata verso \(peer)…"
        case .ringing(let peer): return "\(peer) squilla…"
        case .waitingIncoming: return "In attesa di una chiamata verso \(phone.number)…"
        case .answering(let peer): return "Chiamata in arrivo da \(peer), risposta in corso…"
        case .ending: return "Chiusura della chiamata…"
        case .active(let direction, let peer, let since):
            var lines = [
                "  In linea con  \(peer) (\(direction == .outgoing ? "uscita" : "entrata"))",
                "        Durata  \(Int(Date().timeIntervalSince(since))) s",
            ]
            if let audio = phone.audio {
                lines.append("     Audio RTP  \(audio.sent) inviati · \(audio.received) ricevuti")
                if let level = audio.peakLevel { lines.append(String(format: "       Livello  picco %.0f dBFS", level)) }
            }
            return lines.joined(separator: "\n")
        }
    }
}

private struct SIPTraceView: View {
    let phone: SIPPhone

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Messaggi SIP completi, password e risposte digest escluse.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copia") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(phone.traceText, forType: .string)
                }
                .disabled(phone.trace.isEmpty)
                Button("Pulisci") { phone.clearTrace() }
                    .disabled(phone.trace.isEmpty)
            }
            .controlSize(.small)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(phone.trace.enumerated()), id: \.offset) { index, entry in
                            Text(entry)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(8)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                .overlay {
                    if phone.trace.isEmpty { Text("Nessun messaggio").foregroundStyle(.tertiary) }
                }
                .onChange(of: phone.trace.count) { _, count in
                    if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
                }
            }
        }
    }
}

private struct Card<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}
