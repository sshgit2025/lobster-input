import Foundation

enum KeyboardHandoffOperation: String, Codable {
    case transcribe
    case rewrite
}

enum KeyboardHandoffTarget: String, Codable {
    case none
    case selectedText
    case lastInserted
}

struct KeyboardRecordingRequest: Codable, Equatable {
    let id: String
    let operation: KeyboardHandoffOperation
    let target: KeyboardHandoffTarget
    let selectedText: String?
    let replacementText: String?
    let context: String?
    let fastMode: Bool
    let realtimeMode: Bool
    let createdAt: TimeInterval

    init(
        id: String,
        operation: KeyboardHandoffOperation,
        target: KeyboardHandoffTarget,
        selectedText: String?,
        replacementText: String?,
        context: String?,
        fastMode: Bool,
        realtimeMode: Bool,
        createdAt: TimeInterval
    ) {
        self.id = id
        self.operation = operation
        self.target = target
        self.selectedText = selectedText
        self.replacementText = replacementText
        self.context = context
        self.fastMode = fastMode
        self.realtimeMode = realtimeMode
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, operation, target, selectedText, replacementText, context, fastMode, realtimeMode, createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        operation = try c.decode(KeyboardHandoffOperation.self, forKey: .operation)
        target = try c.decode(KeyboardHandoffTarget.self, forKey: .target)
        selectedText = try c.decodeIfPresent(String.self, forKey: .selectedText)
        replacementText = try c.decodeIfPresent(String.self, forKey: .replacementText)
        context = try c.decodeIfPresent(String.self, forKey: .context)
        fastMode = (try? c.decode(Bool.self, forKey: .fastMode)) ?? false
        realtimeMode = (try? c.decode(Bool.self, forKey: .realtimeMode)) ?? false
        createdAt = try c.decode(TimeInterval.self, forKey: .createdAt)
    }
}

struct KeyboardRecordingResult: Codable, Equatable {
    let requestID: String
    let operation: KeyboardHandoffOperation
    let target: KeyboardHandoffTarget
    let replacementText: String?
    let transcript: String
    let result: String
    let actionType: String?
    let error: String?
    let createdAt: TimeInterval
}

struct KeyboardRecordingDiagnostic: Codable, Equatable {
    let error: String
    let hasFullAccess: Bool
    let recordPermission: String
    let createdAt: TimeInterval
}

enum KeyboardRecordingBridge {
    private enum Key {
        static let request = "ios_keyboard_recording_request"
        static let result = "ios_keyboard_recording_result"
        static let consumedResultIDs = "ios_keyboard_consumed_result_ids"
        static let diagnostic = "ios_keyboard_recording_diagnostic"
    }

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: APIConfig.appGroupID) ?? .standard
    }

    @discardableResult
    static func requestRecording(
        operation: KeyboardHandoffOperation,
        target: KeyboardHandoffTarget,
        selectedText: String?,
        replacementText: String?,
        context: String?,
        fastMode: Bool,
        realtimeMode: Bool = false
    ) -> KeyboardRecordingRequest {
        let request = KeyboardRecordingRequest(
            id: UUID().uuidString,
            operation: operation,
            target: target,
            selectedText: selectedText,
            replacementText: replacementText,
            context: context,
            fastMode: fastMode,
            realtimeMode: realtimeMode,
            createdAt: Date().timeIntervalSince1970
        )
        save(request, key: Key.request)
        defaults.removeObject(forKey: Key.result)
        return request
    }

    static func currentRequest(maxAge: TimeInterval = 600) -> KeyboardRecordingRequest? {
        guard let request: KeyboardRecordingRequest = load(Key.request) else { return nil }
        guard Date().timeIntervalSince1970 - request.createdAt <= maxAge else {
            defaults.removeObject(forKey: Key.request)
            return nil
        }
        return request
    }

    static func complete(
        request: KeyboardRecordingRequest,
        transcript: String,
        result: String,
        actionType: String?,
        error: String?
    ) {
        let result = KeyboardRecordingResult(
            requestID: request.id,
            operation: request.operation,
            target: request.target,
            replacementText: request.replacementText,
            transcript: transcript,
            result: result,
            actionType: actionType,
            error: error,
            createdAt: Date().timeIntervalSince1970
        )
        save(result, key: Key.result)
        defaults.removeObject(forKey: Key.request)
        KeyboardVoiceSessionBridge.postResultReady()
    }

    static func saveDiagnostic(error: String, hasFullAccess: Bool, recordPermission: String) {
        let diagnostic = KeyboardRecordingDiagnostic(
            error: error,
            hasFullAccess: hasFullAccess,
            recordPermission: recordPermission,
            createdAt: Date().timeIntervalSince1970
        )
        save(diagnostic, key: Key.diagnostic)
    }

    static func latestDiagnostic(maxAge: TimeInterval = 86_400) -> KeyboardRecordingDiagnostic? {
        guard let diagnostic: KeyboardRecordingDiagnostic = load(Key.diagnostic) else { return nil }
        guard Date().timeIntervalSince1970 - diagnostic.createdAt <= maxAge else {
            defaults.removeObject(forKey: Key.diagnostic)
            return nil
        }
        return diagnostic
    }

    static func clearDiagnostic() {
        defaults.removeObject(forKey: Key.diagnostic)
    }

    static func peekResult(forRequestID requestID: String, maxAge: TimeInterval = 600) -> KeyboardRecordingResult? {
        guard let result: KeyboardRecordingResult = load(Key.result) else { return nil }
        guard result.requestID == requestID else { return nil }
        guard Date().timeIntervalSince1970 - result.createdAt <= maxAge else { return nil }
        return result
    }

    static func consumeResult(maxAge: TimeInterval = 600) -> KeyboardRecordingResult? {
        guard let result: KeyboardRecordingResult = load(Key.result) else { return nil }
        guard Date().timeIntervalSince1970 - result.createdAt <= maxAge else {
            defaults.removeObject(forKey: Key.result)
            return nil
        }
        var consumed = Set(defaults.stringArray(forKey: Key.consumedResultIDs) ?? [])
        guard !consumed.contains(result.requestID) else {
            defaults.removeObject(forKey: Key.result)
            return nil
        }
        consumed.insert(result.requestID)
        defaults.set(Array(consumed.suffix(20)), forKey: Key.consumedResultIDs)
        defaults.removeObject(forKey: Key.result)
        return result
    }

    private static func save<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
        defaults.synchronize()
    }

    private static func load<T: Decodable>(_ key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
