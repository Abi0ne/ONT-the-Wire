import Testing
@testable import ONTTheWireCore

struct SettingsValidatorTests {
    private let up = EthernetInterface(bsdName: "en8", displayName: "USB LAN", linkActive: true)
    private let down = EthernetInterface(bsdName: "en9", displayName: "USB LAN 2", linkActive: false)

    private func settings(_ bsd: String? = "en8", vlan: String = "835", user: String = "user") -> ConnectionSettings {
        ConnectionSettings(interfaceBSDName: bsd, vlanIDText: vlan, username: user)
    }

    @Test func completeSettingsHaveNoProblems() {
        #expect(SettingsValidator.problems(settings: settings(), password: "x", availableInterfaces: [up]).isEmpty)
    }

    @Test(arguments: ["0", "4095", "99999", "abc", "-1", "8.35"])
    func invalidVLANIsRejected(_ text: String) {
        let problems = SettingsValidator.problems(settings: settings(vlan: text), password: "x", availableInterfaces: [up])
        #expect(problems == [.vlanInvalid])
    }

    @Test func emptyVLANMeansUntagged() {
        #expect(settings(vlan: " ").vlanID == nil)
        #expect(SettingsValidator.problems(settings: settings(vlan: ""), password: "x", availableInterfaces: [up]).isEmpty)
    }

    @Test(arguments: [("1", 1), ("835", 835), (" 4094 ", 4094)])
    func validVLANParses(_ text: String, _ expected: Int) {
        #expect(settings(vlan: text).vlanID == expected)
    }

    @Test func reportsEveryMissingField() {
        let problems = SettingsValidator.problems(settings: settings(nil, vlan: "", user: " "), password: "", availableInterfaces: [up])
        #expect(problems == [.noInterface, .usernameEmpty, .passwordEmpty])
    }

    @Test func linkDownAndMissingInterface() {
        #expect(SettingsValidator.problems(settings: settings("en9"), password: "x", availableInterfaces: [up, down]) == [.linkDown])
        #expect(SettingsValidator.problems(settings: settings("en5"), password: "x", availableInterfaces: [up]) == [.interfaceMissing])
    }
}
