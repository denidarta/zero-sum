import Foundation

public enum SyncState: Equatable {
    /// No server URL yet.
    case unconfigured
    case idle
    case syncing
    case offline
}

/// The local database plus the sync engine. Same design as `clients/web/src/db.ts`.
///
/// Edits apply to the local copy at once and queue in an outbox. Push sends the outbox,
/// pull fetches entity state changed on the server. After a pull, ops still unsent are
/// merged over the server state again, so edits made offline are never lost. Merge is
/// idempotent, which makes that safe.
@MainActor
public final class Ledger: ObservableObject {
    @Published public private(set) var entities: [String: Entity] = [:] {
        didSet { revision += 1 }
    }
    @Published public private(set) var outbox: [Op] = []
    @Published public private(set) var state: SyncState = .idle
    @Published public private(set) var serverURL: String
    /// Set when an edit is invalid. The UI shows it once and clears it.
    @Published public var lastError: String?

    public private(set) var deviceId: String
    private var cursor: Int64 = 0
    private var lastTs: Int64 = 0

    private let store: LocalStore
    private let defaults: UserDefaults
    private let makeTransport: (URL) -> Transport

    private var revision = 0
    private var budgetCache: (revision: Int, month: String, value: BudgetMonth)?

    private var syncTask: Task<Void, Never>?
    private var again = false

    private var socket: URLSessionWebSocketTask?
    private var wantsSocket = false
    private var socketGeneration = 0
    private var socketDelay = 1.0

    private static let pushBatch = 500
    nonisolated static let serverKey = "zs.server"

    public init(
        store: LocalStore,
        defaults: UserDefaults = .standard,
        transport: @escaping (URL) -> Transport = { HTTPTransport(base: $0) }
    ) throws {
        self.store = store
        self.defaults = defaults
        self.makeTransport = transport
        serverURL = defaults.string(forKey: Self.serverKey) ?? ""

        let saved = try store.load()
        entities = Dictionary(saved.entities.map { (Self.key($0.kind, $0.id), $0) }, uniquingKeysWith: { _, b in b })
        outbox = saved.outbox
        cursor = saved.cursor
        lastTs = saved.outbox.map(\.ts).max() ?? 0
        if let id = saved.deviceId {
            deviceId = id
        } else {
            deviceId = Self.newID()
            try store.setDeviceId(deviceId)
        }
        state = serverBase == nil ? .unconfigured : .idle
    }

    /// The database in Application Support.
    public static func openDefault() throws -> Ledger {
        let dir = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return try Ledger(store: LocalStore(path: dir.appendingPathComponent("zero-sum.sqlite").path))
    }

    /// Lowercase, because the server and the web client write ids that way.
    nonisolated public static func newID() -> String { UUID().uuidString.lowercased() }

    private static func key(_ kind: Kind, _ id: String) -> String { "\(kind.rawValue):\(id)" }

    // MARK: Reading

    /// Live (not deleted) entities of a kind, unsorted.
    public func list(_ kind: Kind) -> [Entity] {
        entities.values.filter { $0.kind == kind && !$0.deleted }
    }

    /// Live entities ordered by `sort`, then name. Used for accounts, groups and categories.
    public func sorted(_ kind: Kind) -> [Entity] {
        list(kind).sorted { a, b in
            if a.int("sort") != b.int("sort") { return a.int("sort") < b.int("sort") }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// One live entity, or nil when missing or deleted.
    public func get(_ kind: Kind, _ id: String) -> Entity? {
        entities[Self.key(kind, id)].flatMap { $0.deleted ? nil : $0 }
    }

    public func names(_ kind: Kind) -> [String: String] {
        Dictionary(list(kind).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
    }

    /// Account id to balance, over all live transactions (on and off budget).
    public func balances() -> [String: Int64] {
        var out: [String: Int64] = [:]
        for t in list(.transaction) {
            if let a = t.string("account_id") { out[a, default: 0] += t.int("amount") }
        }
        return out
    }

    /// Derived budget, recomputed by the Rust core only when data or month changed.
    public func budget(month: String) -> BudgetMonth {
        if let c = budgetCache, c.revision == revision, c.month == month { return c.value }
        let value: BudgetMonth
        do {
            value = try Core.budget(Array(entities.values), month: month)
        } catch {
            NSLog("budget failed: \(error)")
            value = .empty(month)
        }
        budgetCache = (revision, month, value)
        return value
    }

    // MARK: Writing

    /// Apply an edit locally and queue it for the server. Throws when the core rejects it;
    /// nothing is stored or queued then.
    public func edit(
        _ kind: Kind, _ id: String, _ fields: [String: JSONValue], deleted: Bool? = nil
    ) throws {
        // Strictly increasing, so a later local edit always beats an earlier one.
        lastTs = max(Int64(Date().timeIntervalSince1970 * 1000), lastTs + 1)
        let op = Op(opId: Self.newID(), ts: lastTs, kind: kind, entityId: id, fields: fields, deleted: deleted)
        let merged = try Core.merge(entities[Self.key(kind, id)], op).state
        try store.saveEdit(merged, op)
        entities[Self.key(kind, id)] = merged
        outbox.append(op)
        Task { await sync() }
    }

    public func remove(_ kind: Kind, _ id: String) throws {
        try edit(kind, id, [:], deleted: true)
    }

    /// Run UI work and show any failure through `lastError`.
    public func run(_ body: () throws -> Void) {
        do { try body() } catch { lastError = error.localizedDescription }
    }

    /// Budget entry id for a category and month, as the core defines it.
    public func entryId(category: String, month: String) throws -> String {
        try Core.entryId(category: category, month: month)
    }

    // MARK: Server

    /// Normalized base URL. A missing scheme means https.
    private var serverBase: URL? {
        var s = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if s.isEmpty { return nil }
        if !s.contains("://") { s = "https://" + s }
        return URL(string: s)
    }

    public func setServer(_ url: String) {
        serverURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(serverURL, forKey: Self.serverKey)
        if wantsSocket { openSocket() }
        Task { await sync() }
    }

    // MARK: Sync

    /// Push then pull. Calls made while a sync runs are folded into one rerun.
    public func sync() async {
        if let running = syncTask {
            again = true
            return await running.value
        }
        let task = Task { await runSync() }
        syncTask = task
        await task.value
    }

    private func runSync() async {
        defer { syncTask = nil }
        guard let base = serverBase else {
            setState(.unconfigured)
            return
        }
        let transport = makeTransport(base)
        repeat {
            again = false
            setState(.syncing)
            do {
                try await push(transport)
                try await pull(transport)
                setState(.idle)
            } catch {
                NSLog("sync failed: \(error)")
                setState(.offline)
                return
            }
        } while again
    }

    private func setState(_ s: SyncState) {
        if state != s { state = s }
    }

    private func push(_ transport: Transport) async throws {
        while !outbox.isEmpty {
            let batch = Array(outbox.prefix(Self.pushBatch))
            let out = try await transport.push(deviceId: deviceId, ops: batch)
            for r in out.results where r.status == "rejected" {
                NSLog("op rejected: \(r.reason ?? "?")")
            }
            // Every status is final, including rejected: resending cannot help.
            let done = Set(out.results.map(\.opId))
            if done.isEmpty { throw TransportError.status(0) }  // no progress, avoid spinning
            try store.removeOutbox(Array(done))
            outbox.removeAll { done.contains($0.opId) }
        }
    }

    private func pull(_ transport: Transport) async throws {
        while true {
            let page = try await transport.pull(since: cursor, limit: 500)
            // Everything below runs without a suspension point, so no edit can slip in between.
            var next = entities
            var saved: [Entity] = []
            for change in page.changes {
                var merged = change.entity
                for op in outbox where op.kind == merged.kind && op.entityId == merged.id {
                    // An op that is invalid against server state is rejected by the next push.
                    if let m = try? Core.merge(merged, op) { merged = m.state }
                }
                next[Self.key(merged.kind, merged.id)] = merged
                saved.append(merged)
            }
            try store.savePull(saved, cursor: page.cursor)
            entities = next
            cursor = page.cursor
            if !page.hasMore { break }
        }
    }

    // MARK: Realtime nudge

    /// Open the WebSocket. A message only means "pull now". Reconnects with backoff.
    public func connect() {
        wantsSocket = true
        openSocket()
    }

    public func disconnect() {
        wantsSocket = false
        closeSocket()
    }

    private func closeSocket() {
        socketGeneration += 1
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    private func openSocket() {
        closeSocket()
        guard let base = serverBase,
            var parts = URLComponents(url: base.appendingPathComponent("sync/ws"), resolvingAgainstBaseURL: false)
        else { return }
        parts.scheme = base.scheme == "http" ? "ws" : "wss"
        guard let url = parts.url else { return }
        let task = URLSession.shared.webSocketTask(with: url)
        socket = task
        task.resume()
        let generation = socketGeneration
        Task { await listen(task, generation) }
    }

    private func listen(_ task: URLSessionWebSocketTask, _ generation: Int) async {
        do {
            while true {
                _ = try await task.receive()
                socketDelay = 1  // the server sends its head right after connect, so we are up
                Task { await sync() }
            }
        } catch {
            guard generation == socketGeneration, wantsSocket else { return }
            try? await Task.sleep(nanoseconds: UInt64(socketDelay * 1_000_000_000))
            socketDelay = min(socketDelay * 2, 30)
            guard generation == socketGeneration, wantsSocket else { return }
            openSocket()
        }
    }
}
