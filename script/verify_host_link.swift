import Foundation

@main struct HostLinkChecks {
    static func main() throws {
        var count = 0
        func check(_ value: Bool, _ label: String) {
            precondition(value, label); count += 1
        }
        let old = try JSONDecoder().decode(HostLinkPreferences.self, from: Data("{}".utf8))
        check(!old.enabled, "old settings default off")
        check(old.bundleIdentifier == "com.openai.codex", "target current desktop host, not a chat session")
        var prefs = old; prefs.enabled = true
        check(try JSONDecoder().decode(HostLinkPreferences.self, from: JSONEncoder().encode(prefs)) == prefs, "preference round trip")
        var state = HostLinkState()
        check(state.observe(enabled: false, hostProcesses: [1]) == .none, "disabled never opens pet")
        check(state.observe(enabled: true, hostProcesses: [1]) == .launch, "enable while host open")
        check(state.observe(enabled: true, hostProcesses: [1]) == .none, "no duplicate launch / manual quit respected")
        check(state.observe(enabled: true, hostProcesses: [1]) == .none, "switching chats/windows does nothing")
        check(state.observe(enabled: true, hostProcesses: []) == .quit, "last host instance exits")
        check(state.observe(enabled: true, hostProcesses: []) == .none, "no repeated quit")
        check(state.observe(enabled: true, hostProcesses: [1]) == .launch, "next host launch reopens pet")
        check(state.observe(enabled: false, hostProcesses: []) == .none, "disabling never closes pet")
        var absent = HostLinkState()
        check(absent.observe(enabled: true, hostProcesses: []) == .none, "helper startup while host absent permits settings")
        check(absent.observe(enabled: true, hostProcesses: [1]) == .launch, "first host launch")
        check(absent.observe(enabled: true, hostProcesses: [1]) == .none, "one of multiple host instances remains")
        check(absent.observe(enabled: true, hostProcesses: []) == .quit, "all host instances quit")
        var identities = HostLinkState()
        check(identities.observe(enabled: true, hostProcesses: [10]) == .launch, "first process")
        check(identities.observe(enabled: true, hostProcesses: [11]) == .launch, "fast restart without absent snapshot")
        check(identities.observe(enabled: true, hostProcesses: [11]) == .none, "manual pet quit with unchanged process")
        check(identities.observe(enabled: true, hostProcesses: [11, 12]) == .launch, "new host instance")
        check(identities.observe(enabled: true, hostProcesses: [12]) == .none, "remaining instance is not a restart")
        check(identities.observe(enabled: true, hostProcesses: []) == .quit, "last process exit")
        print("Host link: \(count) checks passed")
    }
}
