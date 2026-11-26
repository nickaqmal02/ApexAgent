import CryptoKit
import Foundation
import Security

// "Share my report": puts a copy of the habit report on the web (docs/architecture/share-v1-*).
//
// No account: the first time, the API gives this Mac a public share id (it goes in the link) and a
// private secret. The secret lives in the macOS Keychain; the share id and link live in share.json
// next to the study data. Every upload sends the secret; the server keeps only its hash.
// Only the report summary is sent (ReportBuilder forSharing: no raw sessions), at most every 15
// minutes and only when it changed.

// MARK: - Keychain (one generic-password item per Mac user)

enum ShareKeychain {
    static let service = "StudyNotch.share"

    static func save(_ secret: String, account: String) -> Bool {
        delete()
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                  kSecAttrAccount as String: account, kSecValueData as String: Data(secret.utf8),
                                  kSecAttrLabel as String: "StudyNotch report sharing"]
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func read() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }
}

// MARK: - What is remembered between launches (not secret)

struct ShareState: Codable, Equatable {
    var shareId: String
    var url: String
    var lastUpload: Date? = nil
    var lastHash: String? = nil
}

// MARK: - Manager

@MainActor
public final class ShareManager: ObservableObject {
    public static let minInterval: TimeInterval = 15 * 60   // at most one upload per 15 minutes

    let api: URL
    let dataFolder: URL
    private let session: URLSession
    private var stateURL: URL { dataFolder.appendingPathComponent("share.json") }
    @Published public private(set) var state: ShareStateView = .off
    @Published public private(set) var lastError: String? = nil
    private var saved: ShareState?
    private var pending: Timer?
    private var busy = false

    // What the menu needs to show
    public enum ShareStateView: Equatable { case off, working, on(url: String, lastUpload: Date?) }

    public init(api: URL, dataFolder: URL, session: URLSession = .shared) {
        self.api = api
        self.dataFolder = dataFolder
        self.session = session
        if let data = try? Data(contentsOf: stateURL), let s = try? JSONDecoder.iso.decode(ShareState.self, from: data),
           ShareKeychain.read() != nil {
            saved = s
            state = .on(url: s.url, lastUpload: s.lastUpload)
        }
    }

    public var isOn: Bool { if case .on = state { return true } else { return false } }

    // MARK: Turn on / off

    public func start() async {
        guard !busy, !isOn else { return }
        busy = true; state = .working; lastError = nil
        defer { busy = false }
        do {
            let body = try JSONSerialization.data(withJSONObject: ["app": "studynotch", "version": "0.2.0"])
            let json = try await call("POST", "register", body: body, secret: nil, shareId: nil)
            guard let id = json["shareId"] as? String, let secret = json["secret"] as? String, let url = json["url"] as? String else {
                throw ShareError.badReply
            }
            guard ShareKeychain.save(secret, account: id) else { throw ShareError.keychain }
            saved = ShareState(shareId: id, url: url)
            persist()
            state = .on(url: url, lastUpload: nil)
            await upload(force: true)
        } catch {
            state = .off
            lastError = (error as? ShareError)?.message ?? "Could not reach the share service. Check your internet and try again."
        }
    }

    public func stop() async {
        guard let s = saved, let secret = ShareKeychain.read() else { forget(); return }
        state = .working; lastError = nil
        do { _ = try await call("POST", "stop", body: Data("{}".utf8), secret: secret, shareId: s.shareId) }
        catch { lastError = "Stopped on this Mac. The page goes offline once the server is reachable again." }
        forget()
    }

    private func forget() {
        pending?.invalidate(); pending = nil
        ShareKeychain.delete()
        try? FileManager.default.removeItem(at: stateURL)
        saved = nil
        state = .off
    }

    // MARK: Uploads

    // Called whenever the study data changed (after a session, a check-in, an edit)
    public func reportChanged() {
        guard isOn else { return }
        Task { await upload(force: false) }
    }

    func upload(force: Bool) async {
        guard var s = saved, let secret = ShareKeychain.read() else { return }
        let data = ReportBuilder.json(dataFolder: dataFolder, forSharing: true)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if !force {
            if hash == s.lastHash { return }   // nothing new to show
            if let last = s.lastUpload, Date().timeIntervalSince(last) < Self.minInterval {
                schedule(after: Self.minInterval - Date().timeIntervalSince(last))
                return
            }
        }
        do {
            _ = try await call("PUT", "report", body: data, secret: secret, shareId: s.shareId)
            s.lastUpload = Date(); s.lastHash = hash
            saved = s; persist()
            state = .on(url: s.url, lastUpload: s.lastUpload)
            lastError = nil
        } catch ShareError.gone {
            forget()
            lastError = "This link was stopped on the server. Turn sharing on again for a new link."
        } catch {
            lastError = (error as? ShareError)?.message ?? "Upload failed; it will try again after the next session."
        }
    }

    private func schedule(after seconds: TimeInterval) {
        guard pending == nil else { return }
        pending = Timer.scheduledTimer(withTimeInterval: max(5, seconds), repeats: false) { _ in
            MainActor.assumeIsolated {
                ShareManagerRegistry.current?.pending = nil
                ShareManagerRegistry.current?.reportChanged()
            }
        }
        ShareManagerRegistry.current = self
    }

    private func persist() {
        guard let s = saved, let data = try? JSONEncoder.iso.encode(s) else { return }
        try? FileManager.default.createDirectory(at: dataFolder, withIntermediateDirectories: true)
        try? data.write(to: stateURL, options: .atomic)
    }

    // MARK: HTTP

    // One retry after a gateway error or a dropped connection: the service's first reply after a quiet
    // spell can time out while it wakes up
    private func call(_ method: String, _ path: String, body: Data, secret: String?, shareId: String?) async throws -> [String: Any] {
        do { return try await callOnce(method, path, body: body, secret: secret, shareId: shareId) }
        catch ShareError.server(let code) where (502...504).contains(code) {}
        catch is URLError {}
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        return try await callOnce(method, path, body: body, secret: secret, shareId: shareId)
    }

    private func callOnce(_ method: String, _ path: String, body: Data, secret: String?, shareId: String?) async throws -> [String: Any] {
        var req = URLRequest(url: api.appendingPathComponent(path), timeoutInterval: 15)
        req.httpMethod = method
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let secret { req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization") }
        if let shareId { req.setValue(shareId, forHTTPHeaderField: "X-Share-Id") }
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200..<300: return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        case 404, 403: throw ShareError.gone
        case 413: throw ShareError.tooBig
        case 429: throw ShareError.tooSoon
        default: throw ShareError.server(code)
        }
    }
}

// The timer callback needs a way back to the manager without capturing it across threads
@MainActor enum ShareManagerRegistry { static weak var current: ShareManager? }

enum ShareError: Error {
    case badReply, keychain, gone, tooBig, tooSoon, server(Int)
    var message: String {
        switch self {
        case .badReply: return "The share service replied with something unexpected."
        case .keychain: return "Could not save the link's key in your Keychain."
        case .gone: return "This link is no longer active."
        case .tooBig: return "Your report is too large to share."
        case .tooSoon: return "Uploaded very recently; it will try again shortly."
        case .server(let c): return "The share service had a problem (\(c)). It will try again later."
        }
    }
}

extension JSONEncoder { static var iso: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e } }
extension JSONDecoder { static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d } }

// MARK: - Local report (no network)

extension ReportBuilder {
    // Writes report.html next to the data, from the same template as the web page, and returns its URL.
    @discardableResult
    public static func writeLocalReport(dataFolder: URL) -> URL? {
        let json = String(decoding: json(dataFolder: dataFolder), as: UTF8.self)
        let html = ReportTemplate.html.replacingOccurrences(of: "__DATA__", with: json)
        let url = dataFolder.appendingPathComponent("report.html")
        do { try html.write(to: url, atomically: true, encoding: .utf8); return url } catch { return nil }
    }
}
