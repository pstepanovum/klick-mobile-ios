import Foundation
import CallKit
import AVFoundation

/// Reports incoming calls to the system so Klic rings with the native call UI even when
/// backgrounded. Wire `reportIncoming` to a PushKit VoIP push in M3.
final class CallKitManager: NSObject {
    static let shared = CallKitManager()

    private let provider: CXProvider
    private let callController = CXCallController()

    override init() {
        let config = CXProviderConfiguration()
        config.supportsVideo = true
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.generic]
        provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: nil)
    }

    func reportIncoming(callId: String, from displayName: String, hasVideo: Bool) {
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: displayName)
        update.hasVideo = hasVideo
        provider.reportNewIncomingCall(with: uuid(for: callId), update: update) { _ in }
    }

    func endCall(callId: String) {
        let action = CXEndCallAction(call: uuid(for: callId))
        callController.request(CXTransaction(action: action)) { _ in }
    }

    private func uuid(for callId: String) -> UUID {
        UUID(uuidString: callId) ?? UUID()
    }
}

extension CallKitManager: CXProviderDelegate {
    func providerDidReset(_ provider: CXProvider) {}

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        // M3: join the LiveKit room for this call, then:
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Task { await CallService.shared.leave() }
        action.fulfill()
    }
}
