import Foundation
import Intents

/// SiriKit calling integration (D4). Two halves:
/// 1. `donate` — after a call is placed/answered, donate an INStartCallIntent interaction so
///    "call <friend> on Klic", CarPlay/Siri Suggestions, and Recents call-back all work.
/// 2. `request(from:)` — parse an incoming start-call NSUserActivity (Siri, CarPlay, or a
///    Phone-app Recents call-back) into the contact name + kind to dial.
/// No CarPlay template app yet — that needs the Apple-granted carplay-communication entitlement.
enum CallIntents {
    struct StartCallRequest {
        let contactName: String
        let isVideo: Bool
    }

    static func donate(peerName: String, peerId: String?, isVideo: Bool) {
        let handle = INPersonHandle(value: peerId ?? peerName, type: .unknown)
        let person = INPerson(
            personHandle: handle, nameComponents: nil, displayName: peerName,
            image: nil, contactIdentifier: nil, customIdentifier: peerId
        )
        let intent = INStartCallIntent(
            callRecordFilter: nil,
            callRecordToCallBack: nil,
            audioRoute: .unknown,
            destinationType: .normal,
            contacts: [person],
            callCapability: isVideo ? .videoCall : .audioCall
        )
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.donate { error in
            if let error {
                APIClient.mobileDiagnostic(event: "intents.donate.failed", detail: String(describing: error))
            }
        }
    }

    /// The contact + kind a Siri/CarPlay/Recents start-call activity asks for. Handles
    /// INStartCallIntent plus the legacy INStartAudio/VideoCallIntent some routes still send.
    static func request(from activity: NSUserActivity) -> StartCallRequest? {
        guard let intent = activity.interaction?.intent else { return nil }
        if let start = intent as? INStartCallIntent {
            guard let person = start.contacts?.first else { return nil }
            return StartCallRequest(
                contactName: contactName(of: person),
                isVideo: start.callCapability == .videoCall
            )
        }
        if let audio = intent as? INStartAudioCallIntent {
            guard let person = audio.contacts?.first else { return nil }
            return StartCallRequest(contactName: contactName(of: person), isVideo: false)
        }
        if let video = intent as? INStartVideoCallIntent {
            guard let person = video.contacts?.first else { return nil }
            return StartCallRequest(contactName: contactName(of: person), isVideo: true)
        }
        return nil
    }

    private static func contactName(of person: INPerson) -> String {
        if !person.displayName.isEmpty { return person.displayName }
        return person.personHandle?.value ?? ""
    }

    /// Resolve the spoken/tapped contact against the friends list and place the call.
    /// Matching is by display name (exact first, then contains), then username — the same
    /// values our donations and CallKit Recents handles carry.
    static func startCall(from activity: NSUserActivity) {
        guard let request = request(from: activity), !request.contactName.isEmpty else { return }
        APIClient.mobileDiagnostic(event: "intents.startCall", detail: request.contactName)
        Task { @MainActor in
            guard CallKitManager.shared.activeCall == nil else { return }
            guard let friends = try? await APIClient.shared.friends() else { return }
            let query = request.contactName.lowercased()
            let friend = friends.first { $0.displayName.lowercased() == query }
                ?? friends.first { $0.username.lowercased() == query }
                ?? friends.first { $0.displayName.lowercased().contains(query) }
            guard let friend else {
                APIClient.mobileDiagnostic(event: "intents.startCall.noMatch", detail: request.contactName)
                return
            }
            guard let convo = try? await APIClient.shared.openConversation(userId: friend.id),
                  let session = try? await APIClient.shared.startCall(
                      conversationId: convo.id, kind: request.isVideo ? "VIDEO" : "AUDIO"
                  )
            else { return }
            CallKitManager.shared.startOutgoing(
                session,
                peerName: friend.displayName,
                peerId: friend.id,
                peerAvatarUrl: friend.avatarUrl,
                conversationId: convo.id
            )
        }
    }
}
