import Foundation

/// A SIP trunk provider template exported from 3CX (`gateway-template`,
/// device type `provider`). It describes the provider's servers and options;
/// the account (number, auth ID, password) is never part of it.
public struct SIPTemplate: Identifiable, Equatable, Sendable {
    /// File name in the template store, unique per template.
    public var id: String { fileName }
    public var fileName: String

    public var name: String
    public var registrarHost: String
    public var registrarPort: Int
    /// Outbound proxy; nil when the registrar acts as proxy too.
    public var proxyHost: String?
    public var proxyPort: Int?
    /// 3CX `TransportRestriction`: ANY, UDP, TCP or TLS.
    public var transport: String
    /// 3CX `IPRestriction`: ANY, IPV4 or IPV6.
    public var ipRestriction: String
    /// Seconds between registrations.
    public var registrationExpiry: Int
    /// The template enables "3-way authentication": an auth ID distinct from
    /// the number.
    public var separateAuthID: Bool
    /// Codec names in the provider's order of preference, e.g. ["pcma", "g729"].
    public var codecs: [String]

    /// Whether the app's UDP-only SIP stack fits the provider.
    public var supportsUDP: Bool {
        transport == "ANY" || transport == "UDP"
    }
}

public enum SIPTemplateError: LocalizedError, Equatable {
    case unreadable
    case notGatewayTemplate
    case notProvider(String)
    case missingRegistrar

    public var errorDescription: String? {
        switch self {
        case .unreadable:
            "Il file non è un XML leggibile."
        case .notGatewayTemplate:
            "Il file non è un template 3CX (manca <type>gateway-template</type>)."
        case .notProvider(let type):
            "Il template è per un dispositivo di tipo “\(type)”: servono i template di provider SIP trunk."
        case .missingRegistrar:
            "Il template non indica il server SIP (RegistrarHost)."
        }
    }
}

extension SIPTemplate {
    /// Parses a 3CX provider template.
    public static func parse(_ data: Data, fileName: String) throws -> SIPTemplate {
        let reader = TemplateReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse() else { throw SIPTemplateError.unreadable }

        guard reader.headerType == "gateway-template" else { throw SIPTemplateError.notGatewayTemplate }
        let deviceType = reader.deviceType ?? ""
        guard deviceType == "provider" else { throw SIPTemplateError.notProvider(deviceType) }

        let fields = reader.fields
        func text(_ name: String) -> String? {
            guard let value = fields[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        guard let registrar = text("RegistrarHost") else { throw SIPTemplateError.missingRegistrar }

        let name = text("Name") ?? reader.headerName ?? registrar
        return SIPTemplate(
            fileName: fileName,
            name: name,
            registrarHost: registrar,
            registrarPort: text("RegistrarPort").flatMap(Int.init) ?? 5060,
            proxyHost: text("ProxyHost"),
            proxyPort: text("ProxyPort").flatMap(Int.init),
            transport: text("TransportRestriction")?.uppercased() ?? "ANY",
            ipRestriction: text("IPRestriction")?.uppercased() ?? "ANY",
            registrationExpiry: text("TimeBetweenRegistration").flatMap(Int.init) ?? 300,
            separateAuthID: fields.keys.contains("3wayauthenticationid"),
            codecs: reader.codecs)
    }
}

/// Collects what matters from the template: header type and name, device
/// type, the first value of each named field and the codec list. Comments and
/// the 3CX routing parameters are ignored.
private final class TemplateReader: NSObject, XMLParserDelegate {
    var headerType: String?
    var headerName: String?
    var deviceType: String?
    var fields: [String: String] = [:]
    var codecs: [String] = []

    private var path: [String] = []
    private var text = ""
    private var fieldName: String?

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        path.append(element)
        text = ""
        switch element {
        case "field": fieldName = attributes["name"]
        case "codec": if let name = attributes["rfcname"]?.lowercased(), !name.isEmpty { codecs.append(name) }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = path.dropLast().last
        switch (parent, element) {
        case ("header", "type"): headerType = value
        case ("header", "name"): headerName = value
        case ("device", "type"): deviceType = value
        case (_, "field"):
            if let fieldName, fields[fieldName] == nil { fields[fieldName] = value }
            fieldName = nil
        default: break
        }
        path.removeLast()
        text = ""
    }
}
