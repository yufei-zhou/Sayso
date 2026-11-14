import Foundation

enum APIError: LocalizedError {
    case noKey
    case badKey
    case http(Int, String)
    case cutOff

    var errorDescription: String? {
        switch self {
        case .noKey: "No OpenAI API key yet."
        case .badKey: "OpenAI rejected the API key."
        case .cutOff: "The answer was cut off. Press ↩ to try again."
        case .http(429, let message): message.isEmpty ? "OpenAI is busy (too many requests). Try again in a moment." : message
        case .http(let code, let message) where code >= 500:
            "OpenAI had a problem (HTTP \(code)). Press ↩ to try again." + (message.isEmpty ? "" : "\n" + message)
        case .http(let code, let message): message.isEmpty ? "OpenAI returned HTTP \(code)." : message
        }
    }

    /// Whether the fix is in Settings (so the message can offer a button).
    var needsSettings: Bool {
        switch self {
        case .noKey, .badKey: true
        case .http(let code, _): code == 403
        case .cutOff: false
        }
    }

    /// Short wording for network failures instead of URLSession's long sentences.
    static func describe(_ error: Error) -> String {
        guard let url = error as? URLError else { return error.localizedDescription }
        switch url.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
            return "You're offline. Press ↩ to try again once you're connected."
        case .timedOut:
            return "OpenAI took too long to answer. Press ↩ to try again."
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return "Couldn't reach OpenAI. Press ↩ to try again."
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate:
            return "Couldn't open a secure connection to OpenAI (a VPN or proxy may be in the way)."
        default:
            return url.localizedDescription
        }
    }
}

/// Streams text from the OpenAI Responses API.
enum OpenAIClient {
    /// `SAYSO_API_BASE` points the app at a local mock server when testing error handling.
    private static let base = ProcessInfo.processInfo.environment["SAYSO_API_BASE"] ?? "https://api.openai.com"
    private static let endpoint = URL(string: base + "/v1/responses")!

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        // The longest wait for the next piece of an answer; answers normally start within a second or two.
        config.timeoutIntervalForRequest = 30
        config.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: config)
    }()

    /// Opens the TLS connection ahead of time, so the first real request doesn't pay for the handshake.
    static func warmUp() {
        var request = URLRequest(url: URL(string: base + "/v1/models?limit=1")!)
        request.httpMethod = "HEAD"
        session.dataTask(with: request).resume()
    }

    /// OpenAI sends requests that begin with the same text to the same machines (that is how its prompt cache
    /// works). When those machines are backed up, every request of that kind waits, for seconds, while the same
    /// request with a different beginning is answered at once. So each request starts with one of these invisible
    /// prefixes, picked at random, and a request that is slow to start gets a second try down another route.
    private static let routes = ["", "\n", "\n\n", " ", "  ", "\t", "\n\n\n", " \n"]
    /// How long to wait for the first text before trying a second route (answers normally start in about 1 s).
    private static let hedgeDelay: TimeInterval = 2.0

    /// Decides which of the two tries gets to deliver: the first one that has text.
    private actor Race {
        private(set) var winner: Int?
        func claim(_ id: Int) -> Bool {
            if winner == nil { winner = id }
            return winner == id
        }
    }

    private enum Outcome { case timer, delivered, empty }
    private struct TryError: Error {
        let id: Int
        let underlying: Error
    }

    /// Errors another try can't fix.
    private static func isFinal(_ error: Error) -> Bool {
        switch error {
        case APIError.noKey, APIError.badKey: return true
        case APIError.http(let code, _): return (400..<500).contains(code) && code != 429 && code != 408
        case let url as URLError:
            return [.notConnectedToInternet, .dataNotAllowed, .cannotFindHost, .dnsLookupFailed].contains(url.code)
        default: return false
        }
    }

    /// Calls `onDelta` with each piece of text as it arrives. `emptyIsAnAnswer`: an answer with no text is a real
    /// answer (the grammar check finding nothing) rather than a reason to try again.
    static func stream(model: ModelOption, instructions: String, input: Any, emptyIsAnAnswer: Bool = false,
                       onDelta: @escaping @Sendable (String) async -> Void) async throws {
        let body = try requestBody(model: model, instructions: instructions, input: input)
        let prefixes = routes.shuffled()
        let race = Race()

        @Sendable func attempt(_ id: Int) async throws -> Outcome {
            do {
                try await single(body: body, instructionsPrefix: prefixes[id]) { delta in
                    // Only one try delivers; the other stops as soon as it would have something to say.
                    guard await race.claim(id) else { throw CancellationError() }
                    await onDelta(delta)
                }
                return await race.winner == id ? .delivered : .empty
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                throw TryError(id: id, underlying: error)
            }
        }

        try await withThrowingTaskGroup(of: Outcome.self) { group in
            group.addTask { try await attempt(0) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(hedgeDelay * 1_000_000_000))
                return .timer
            }
            var launched = 1, running = 1
            var firstError: Error?
            func launchSecond(_ why: String) {
                guard launched == 1 else { return }
                launched = 2
                running += 1
                Task { @MainActor in DebugLog.write("request: second route (\(why))") }
                group.addTask { try await attempt(1) }
            }
            while let result = await group.nextResult() {
                switch result {
                case .success(.timer):
                    if !Task.isCancelled, await race.winner == nil, running > 0 { launchSecond("no text after \(hedgeDelay)s") }
                case .success(.delivered):
                    group.cancelAll()
                    return
                case .success(.empty):
                    running -= 1
                    if emptyIsAnAnswer { group.cancelAll(); return }
                    if launched == 1 { launchSecond("empty answer") } else if running == 0 { group.cancelAll(); return }
                case .failure(let error):
                    guard let failed = error as? TryError else {
                        // A try that lost the race, the timer after the answer finished, or the whole request cancelled.
                        if Task.isCancelled { throw CancellationError() }
                        continue
                    }
                    running -= 1
                    let winner = await race.winner
                    if winner != nil, winner != failed.id { continue } // the losing try failing doesn't matter
                    if winner == failed.id || isFinal(failed.underlying) {
                        group.cancelAll()
                        throw failed.underlying
                    }
                    firstError = firstError ?? failed.underlying
                    if launched == 1 {
                        launchSecond("first try failed")
                    } else if running == 0 {
                        group.cancelAll()
                        throw firstError!
                    }
                }
            }
        }
    }

    private static func requestBody(model: ModelOption, instructions: String, input: Any) throws -> [String: Any] {
        ["model": model.id, "instructions": instructions, "input": input, "stream": true, "store": false,
         "reasoning": ["effort": model.effort]]
    }

    /// One request. `onDelta` may throw to stop it.
    private static func single(body: [String: Any], instructionsPrefix: String,
                               onDelta: @escaping @Sendable (String) async throws -> Void) async throws {
        // `SAYSO_API_KEY` (tests only) skips the Keychain.
        let testKey = ProcessInfo.processInfo.environment["SAYSO_API_KEY"]
        guard let key = testKey.map({ $0.isEmpty ? nil : $0 }) ?? Keychain.readKey() else { throw APIError.noKey }
        var body = body
        body["instructions"] = instructionsPrefix + (body["instructions"] as? String ?? "")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var raw = ""
            for try await line in bytes.lines { raw += line }
            if status == 401 { throw APIError.badKey }
            let message = ((try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any])
                .flatMap { $0["error"] as? [String: Any] }?["message"] as? String
            throw APIError.http(status, message ?? "")
        }
        var received = false, completed = false
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:"),
                  let event = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8)) as? [String: Any],
                  let type = event["type"] as? String else { continue }
            switch type {
            case "response.output_text.delta":
                if let delta = event["delta"] as? String { received = true; try await onDelta(delta) }
            case "error", "response.failed":
                let error = (event["error"] as? [String: Any]) ?? ((event["response"] as? [String: Any])?["error"] as? [String: Any])
                throw APIError.http(status, error?["message"] as? String ?? "The response failed.")
            case "response.refusal.done":
                throw APIError.http(status, "OpenAI declined to answer this text.")
            case "response.completed":
                completed = true
            case "response.incomplete":
                completed = true
                if !received { throw APIError.http(status, "The answer was cut off before any text arrived.") }
            default:
                break
            }
        }
        try Task.checkCancellation()
        if !completed { throw APIError.cutOff }
    }
}
