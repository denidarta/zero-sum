import Foundation

@testable import ZeroSumKit

struct Down: Transport {
    func push(deviceId: String, ops: [Op]) async throws -> PushOutcome { throw URLError(.notConnectedToInternet) }
    func pull(since: Int64) async throws -> PullPage { throw URLError(.notConnectedToInternet) }
}

func op(_ kind: Kind, _ id: String, _ fields: [String: JSONValue], ts: Int64) -> Op {
    Op(opId: Ledger.newID(), ts: ts, kind: kind, entityId: id, fields: fields, deleted: nil)
}

func defaults(server: String?) -> UserDefaults {
    let d = UserDefaults(suiteName: "zs-test-\(UUID().uuidString)")!
    if let server { d.set(server, forKey: Ledger.serverKey) }
    return d
}

func tempDBPath() -> String {
    FileManager.default.temporaryDirectory.appendingPathComponent("zs-\(UUID().uuidString).sqlite").path
}
