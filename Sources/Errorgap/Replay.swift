import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Options for session replay. Sessions are timeline only: no screenshots or
/// view snapshots are taken.
public struct ErrorgapReplayOptions {
    /// Shown with the release as the session's "browser", e.g. `Acme 2.3.0`.
    public var appName: String?
    /// Defaults to the running OS, e.g. `iOS 17.6`.
    public var os: String?
    /// `Mobile`, `Tablet` or `Desktop`. Defaults to the running device.
    public var device: String?
    /// How often recorded events are sent.
    public var flushInterval: TimeInterval

    public init(appName: String? = nil, os: String? = nil, device: String? = nil, flushInterval: TimeInterval = 10) {
        self.appName = appName
        self.os = os
        self.device = device
        self.flushInterval = flushInterval
    }
}

/// A session ends once the app has been in the background this long.
public let errorgapReplayBackgroundTimeout: TimeInterval = 30 * 60
let errorgapReplayMaxBatchEvents = 200
private let maxBufferedEvents = 1000
/// Before the session's first error, only the most recent events are held.
let errorgapReplayMaxPendingEvents = 300
private let maxLabel = 200

/// Records a session replay timeline: app start, screens, failed API calls,
/// reported errors and backgrounding. Whether a session is recorded is the
/// project's call: its replay settings are read when each session starts, and
/// a sampled share of sessions is recorded while replay is on.
final class ErrorgapReplayRecorder {
    private enum State { case pending, recording, skipped, stopped }

    private let configuration: ErrorgapConfiguration
    private let session: URLSession
    private let options: ErrorgapReplayOptions
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "io.errorgap.replay")

    private var state = State.pending
    private var sessionId = ""
    private var startedAt = Date()
    private var hadError = false
    private var events: [[String: Any]] = []
    private var lastScreen: String?
    private var pausedAt: Date?
    private var timer: DispatchSourceTimer?

    init(configuration: ErrorgapConfiguration, session: URLSession, options: ErrorgapReplayOptions) {
        self.configuration = configuration
        self.session = session
        self.options = options
    }

    var recording: Bool { locked { state == .recording } }

    private var base: String {
        let endpoint = configuration.endpoint.hasSuffix("/")
            ? String(configuration.endpoint.dropLast())
            : configuration.endpoint
        return "\(endpoint)/api/projects/\(configuration.projectSlug ?? "")"
    }

    func start() {
        newSession(label: "App started")
    }

    func stop() {
        locked {
            timer?.cancel()
            timer = nil
            state = .stopped
            events = []
        }
    }

    /// A screen is now showing.
    func screen(_ name: String) {
        let changed: Bool = locked {
            guard !name.isEmpty, name != lastScreen else { return false }
            lastScreen = name
            return true
        }
        if changed { push(type: "navigation", label: "Opened \(name)") }
    }

    /// The app went to the background.
    func paused() {
        let pause: Bool = locked {
            guard state != .stopped, pausedAt == nil else { return false }
            pausedAt = Date()
            return true
        }
        guard pause else { return }
        push(type: "exit", label: "App went to the background")
        flush(final: true)
    }

    /// The app is in the foreground again.
    func resumed() {
        let away: TimeInterval? = locked {
            guard state != .stopped, let pausedAt else { return nil }
            self.pausedAt = nil
            return Date().timeIntervalSince(pausedAt)
        }
        guard let away else { return }
        if away >= errorgapReplayBackgroundTimeout {
            newSession(label: "App opened")
        } else {
            push(type: "navigation", label: "Returned to the app")
        }
    }

    /// An error is being reported; call the result with its group id once the
    /// server has answered.
    func errorStarted(_ label: String) -> (String?) -> Void {
        let started: (t: Int, session: String)? = locked {
            guard state == .pending || state == .recording else { return nil }
            hadError = true
            return (offset(), sessionId)
        }
        guard let started else { return { _ in } }
        let doneLock = NSLock()
        var done = false
        return { [weak self] groupId in
            doneLock.lock()
            let first = !done
            done = true
            doneLock.unlock()
            guard first, let self, self.locked({ self.sessionId == started.session }) else { return }
            self.push(type: "error", label: label, t: started.t, groupId: groupId)
            self.flush(final: false)
        }
    }

    /// A call failed or answered 5xx.
    func apiError(method: String, url: URL?, status: Int) {
        let shown: String
        if let url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            // No query string: it carries tokens and ids.
            parts.query = nil
            parts.fragment = nil
            shown = parts.string ?? url.path
        } else {
            shown = url?.path ?? "?"
        }
        push(type: "api_error", label: "\(method.uppercased()) \(shown) → \(status == 0 ? "failed" : String(status))")
    }

    /// Sends what is recorded, once the session has an error. Only sessions
    /// that hit an error are kept: until then events are held and nothing is
    /// sent, and a session that ends without one is never sent.
    func flush(final: Bool) {
        var last = final
        while true {
            let batch: [String: Any]? = locked {
                guard state == .recording, hadError else { return nil }
                let take = Array(events.prefix(errorgapReplayMaxBatchEvents))
                events.removeFirst(take.count)
                if take.isEmpty && !last { return nil }
                return payload(take, final: last)
            }
            guard let batch else { return }
            send(batch)
            last = false
            if locked({ events.isEmpty }) { return }
        }
    }

    // MARK: - Sessions

    private func newSession(label: String) {
        let id: String = locked {
            timer?.cancel()
            timer = nil
            state = .pending
            sessionId = UUID().uuidString.lowercased()
            startedAt = Date()
            hadError = false
            events = []
            lastScreen = nil
            return sessionId
        }
        push(type: "page_load", label: label)
        decide(session: id)
    }

    private func decide(session id: String) {
        var components = URLComponents(string: "\(base)/sessions/config")
        if let key = configuration.apiKey, !key.isEmpty {
            components?.queryItems = [URLQueryItem(name: "api_key", value: key)]
        }
        guard let url = components?.url else { return skip() }
        session.dataTask(with: url) { [weak self] data, response, _ in
            guard let self else { return }
            var record = false
            if (response as? HTTPURLResponse)?.statusCode == 200,
               let data,
               let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let rate = (config["sample_rate"] as? NSNumber)?.doubleValue ?? 0
                record = (config["enabled"] as? Bool) == true && Double.random(in: 0..<1) < rate
            }
            let proceed: Bool = self.locked {
                guard self.sessionId == id, self.state == .pending else { return false }
                if !record { return false }
                self.state = .recording
                return true
            }
            if !proceed {
                if self.locked({ self.sessionId == id && self.state == .pending }) { self.skip() }
                return
            }
            self.startTimer()
            self.flush(final: false)
        }.resume()
    }

    private func skip() {
        locked {
            timer?.cancel()
            timer = nil
            state = .skipped
            events = []
        }
    }

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + options.flushInterval, repeating: options.flushInterval)
        timer.setEventHandler { [weak self] in self?.flush(final: false) }
        locked { self.timer = timer }
        timer.resume()
    }

    // MARK: - Events

    private func push(type: String, label: String, t: Int? = nil, groupId: String? = nil) {
        locked {
            guard state == .pending || state == .recording else { return }
            // Before an error, the recent past matters most: drop the oldest.
            if !hadError && events.count >= errorgapReplayMaxPendingEvents { events.removeFirst() }
            guard events.count < maxBufferedEvents else { return }
            var event: [String: Any] = [
                "t": t ?? offset(),
                "type": type,
                "label": label.count > maxLabel ? String(label.prefix(maxLabel - 1)) + "…" : label,
            ]
            if let groupId { event["group_id"] = groupId }
            events.append(event)
        }
    }

    // Called with `lock` held.
    private func payload(_ batch: [[String: Any]], final: Bool) -> [String: Any] {
        let now = Date()
        let app = options.appName ?? "App"
        let release = configuration.release ?? ""
        return [
            "session": [
                "id": sessionId,
                "browser": release.isEmpty ? app : "\(app) \(release)",
                "os": options.os ?? Self.runningOS(),
                "device": options.device ?? Self.runningDevice(),
                "started_at": iso(startedAt),
                "ended_at": iso(now),
                "duration_sec": offset(now),
                "outcome": hadError ? "error" : (final ? "completed" : "abandoned"),
            ] as [String: Any],
            "events": batch,
            "snapshots": [Any](),
        ]
    }

    private func send(_ payload: [String: Any]) {
        guard let body = JSON.encode(payload), let url = URL(string: "\(base)/sessions") else { return }
        let id = locked { sessionId }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if let key = configuration.apiKey, !key.isEmpty {
            request.setValue(key, forHTTPHeaderField: "x-errorgap-project-key")
        }
        session.dataTask(with: request) { [weak self] _, response, _ in
            guard let self, let status = (response as? HTTPURLResponse)?.statusCode else { return }
            // Replay switched off, or the session belongs elsewhere: stop this session.
            if [204, 401, 404, 409].contains(status),
               self.locked({ self.sessionId == id && self.state == .recording }) {
                self.skip()
            }
        }.resume()
    }

    // Called with `lock` held.
    private func offset(_ now: Date = Date()) -> Int {
        max(0, Int(now.timeIntervalSince(startedAt).rounded()))
    }

    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    static func runningOS() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        #if os(iOS)
        return "iOS \(v.majorVersion).\(v.minorVersion)"
        #elseif os(tvOS)
        return "tvOS \(v.majorVersion).\(v.minorVersion)"
        #elseif os(watchOS)
        return "watchOS \(v.majorVersion).\(v.minorVersion)"
        #elseif os(macOS)
        return "macOS \(v.majorVersion).\(v.minorVersion)"
        #else
        return "\(v.majorVersion).\(v.minorVersion)"
        #endif
    }

    static func runningDevice() -> String {
        #if os(iOS)
        return ProcessInfo.processInfo.isiOSAppOnMac ? "Desktop" : (isPad() ? "Tablet" : "Mobile")
        #elseif os(macOS)
        return "Desktop"
        #else
        return "Mobile"
        #endif
    }

    #if os(iOS)
    private static func isPad() -> Bool {
        // Avoids importing UIKit here; the model identifier says iPad.
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var machine = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.machine", &machine, &size, nil, 0)
        return String(cString: machine).hasPrefix("iPad")
    }
    #endif
}
