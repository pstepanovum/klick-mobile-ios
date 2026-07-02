import Foundation
import CoreGraphics
import AudioToolbox

// MARK: - Upload quality (§8.3)

/// HD / Standard upload pref, consulted wherever images (and camera video) are
/// compressed before upload. Standard = the pre-v0.5.1 compression.
enum UploadQuality: String, CaseIterable, Identifiable {
    case standard, hd

    var id: String { rawValue }
    var label: String { self == .hd ? "HD" : "Standard" }
    var subtitle: String {
        self == .hd ? "Larger files, best quality" : "Faster uploads, less data"
    }

    /// JPEG pipeline parameters for chat images.
    var imageMaxDimension: CGFloat { self == .hd ? 4096 : 2048 }
    var imageJpegQuality: CGFloat { self == .hd ? 0.92 : 0.85 }

    private static let key = "pref.uploadQuality"
    static var current: UploadQuality {
        get { UserDefaults.standard.string(forKey: key).flatMap(UploadQuality.init) ?? .standard }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}

// MARK: - Media auto-download matrix (§8.3)

/// Photos / Audio / Video / Documents × Wi-Fi / Cellular. When the current network
/// disallows a kind, media bubbles show a placeholder with a manual download button
/// instead of auto-fetching.
enum AutoDownloadPrefs {
    enum Kind: String, CaseIterable, Identifiable {
        case photos, audio, video, documents

        var id: String { rawValue }
        var label: String {
            switch self {
            case .photos: return "Photos"
            case .audio: return "Audio"
            case .video: return "Video"
            case .documents: return "Documents"
            }
        }

        /// WhatsApp-style defaults: photos everywhere, the rest Wi-Fi only.
        var defaultWifi: Bool { true }
        var defaultCellular: Bool { self == .photos }
    }

    private static func key(_ kind: Kind, cellular: Bool) -> String {
        "autodl.\(kind.rawValue).\(cellular ? "cellular" : "wifi")"
    }

    static func allowed(_ kind: Kind, cellular: Bool) -> Bool {
        let defaults = UserDefaults.standard
        let key = key(kind, cellular: cellular)
        if defaults.object(forKey: key) == nil {
            return cellular ? kind.defaultCellular : kind.defaultWifi
        }
        return defaults.bool(forKey: key)
    }

    static func set(_ kind: Kind, cellular: Bool, allowed: Bool) {
        UserDefaults.standard.set(allowed, forKey: key(kind, cellular: cellular))
    }

    /// Whether the given kind may auto-download on the network we're on right now.
    static func allowedNow(_ kind: Kind) -> Bool {
        allowed(kind, cellular: DataUsageTracker.shared.isOnCellular)
    }
}

// MARK: - Bundled tones (§8.4)

/// Alert tones and ringtones bundled with the app. Tones are LOCAL device prefs:
/// the per-chat alert tone applies to in-app/foreground sounds only (the APNs push
/// sound stays "default" — iOS picks the payload sound server-side), and CallKit's
/// ringtone is a single global provider setting (the per-chat pick applies where
/// the app itself controls playback).
struct KlicTone: Identifiable, Equatable {
    let name: String
    /// Bundled resource file, nil = system default.
    let file: String?

    var id: String { file ?? "default" }

    static let alertTones: [KlicTone] = [
        KlicTone(name: "Default", file: nil),
        KlicTone(name: "Chime", file: "tone_chime.caf"),
        KlicTone(name: "Pulse", file: "tone_pulse.caf"),
        KlicTone(name: "Bell", file: "tone_bell.caf"),
    ]

    static let ringtones: [KlicTone] = [
        KlicTone(name: "Klic", file: "ringtone.caf"),    // the shipped default
        KlicTone(name: "Classic", file: "ringtone_classic.caf"),
    ]

    /// Play the tone once via the system-sound API (doesn't touch the shared
    /// AVAudioSession, so in-call audio is never disturbed).
    func preview() {
        if let file {
            Self.play(file: file)
        } else {
            // "Default" = the system's received-message tri-tone.
            AudioServicesPlaySystemSound(1007)
        }
    }

    static func play(file: String) {
        let base = (file as NSString).deletingPathExtension
        let ext = (file as NSString).pathExtension
        guard let url = Bundle.main.url(forResource: base, withExtension: ext.isEmpty ? "caf" : ext) else { return }
        var soundId: SystemSoundID = 0
        guard AudioServicesCreateSystemSoundID(url as CFURL, &soundId) == kAudioServicesNoError else { return }
        AudioServicesPlaySystemSoundWithCompletion(soundId) {
            AudioServicesDisposeSystemSoundID(soundId)
        }
    }
}

// MARK: - Per-chat local prefs + cached mute state (§8.4)

/// Local (device-only) per-conversation preferences, plus a mirror of the
/// server-side mute state so foreground banner/sound/ring paths can gate
/// synchronously without a network round-trip.
enum ChatLocalPrefs {
    // MARK: Save to Photos

    enum SaveToPhotosMode: String, CaseIterable, Identifiable {
        case standard = "default"   // follows the (off) default
        case always, never

        var id: String { rawValue }
        var label: String {
            switch self {
            case .standard: return "Default (Off)"
            case .always: return "Always"
            case .never: return "Never"
            }
        }
    }

    static func saveToPhotos(_ conversationId: String) -> SaveToPhotosMode {
        UserDefaults.standard.string(forKey: "chat.saveToPhotos.\(conversationId)")
            .flatMap(SaveToPhotosMode.init) ?? .standard
    }

    static func setSaveToPhotos(_ mode: SaveToPhotosMode, _ conversationId: String) {
        UserDefaults.standard.set(mode.rawValue, forKey: "chat.saveToPhotos.\(conversationId)")
    }

    // MARK: Tones (local-only)

    /// Per-chat alert tone file (nil = Default). Foreground/in-app sound only.
    static func alertTone(_ conversationId: String) -> String? {
        UserDefaults.standard.string(forKey: "chat.tone.\(conversationId)")
    }

    static func setAlertTone(_ file: String?, _ conversationId: String) {
        let key = "chat.tone.\(conversationId)"
        if let file { UserDefaults.standard.set(file, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }

    /// Per-chat ringtone file (nil = the global default). Applies where the app
    /// controls playback — CallKit's ring stays the single global pick.
    static func ringtone(_ conversationId: String) -> String? {
        UserDefaults.standard.string(forKey: "chat.ringtone.\(conversationId)")
    }

    static func setRingtone(_ file: String?, _ conversationId: String) {
        let key = "chat.ringtone.\(conversationId)"
        if let file { UserDefaults.standard.set(file, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }

    /// Global default ringtone — what CallKit's provider configuration uses for every
    /// incoming ring. Falls back to the bundled "Klic" ringtone.
    static var globalRingtone: String? {
        get { UserDefaults.standard.string(forKey: "notif.ringtone.global") ?? "ringtone.caf" }
        set {
            let key = "notif.ringtone.global"
            if let newValue { UserDefaults.standard.set(newValue, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    /// Wipe every local tone pick (part of "Reset notification settings").
    static func resetAllTones() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix("chat.tone.") || key.hasPrefix("chat.ringtone.") {
            defaults.removeObject(forKey: key)
        }
        globalRingtone = nil
    }

    // MARK: Cached mute state (mirrors /conversations/:id/prefs)

    static func cacheMutes(_ conversationId: String, prefs: ConversationPrefs) {
        let defaults = UserDefaults.standard
        set(defaults, "chat.mute.messages.\(conversationId)", prefs.messagesMutedUntil)
        set(defaults, "chat.mute.calls.\(conversationId)", prefs.callsMutedUntil)
        defaults.set(prefs.muteMentions ?? false, forKey: "chat.mute.mentions.\(conversationId)")
    }

    private static func set(_ defaults: UserDefaults, _ key: String, _ value: String?) {
        if let value { defaults.set(value, forKey: key) }
        else { defaults.removeObject(forKey: key) }
    }

    static func messagesMuted(_ conversationId: String) -> Bool {
        isMuted(UserDefaults.standard.string(forKey: "chat.mute.messages.\(conversationId)"))
    }

    static func callsMuted(_ conversationId: String) -> Bool {
        isMuted(UserDefaults.standard.string(forKey: "chat.mute.calls.\(conversationId)"))
    }

    static func muteMentions(_ conversationId: String) -> Bool {
        UserDefaults.standard.bool(forKey: "chat.mute.mentions.\(conversationId)")
    }

    // MARK: Cached global prefs (mirrors /me/notification-prefs)

    static func cacheGlobalPrefs(_ prefs: NotificationPrefs) {
        let defaults = UserDefaults.standard
        defaults.set(prefs.messages, forKey: "notifprefs.messages")
        defaults.set(prefs.groups, forKey: "notifprefs.groups")
        defaults.set(prefs.calls, forKey: "notifprefs.calls")
        defaults.set(prefs.friendRequests, forKey: "notifprefs.friendRequests")
    }

    static func cachedGlobalPrefs() -> NotificationPrefs {
        let defaults = UserDefaults.standard
        func flag(_ key: String) -> Bool {
            defaults.object(forKey: key) == nil ? true : defaults.bool(forKey: key)
        }
        return NotificationPrefs(
            messages: flag("notifprefs.messages"),
            groups: flag("notifprefs.groups"),
            calls: flag("notifprefs.calls"),
            friendRequests: flag("notifprefs.friendRequests")
        )
    }

    // MARK: Mute plumbing

    /// "Always" muted sentinel (CALLS.md §8.2).
    static let alwaysMutedISO = "9999-12-31T00:00:00.000Z"

    static func isMuted(_ iso: String?) -> Bool {
        guard let date = parseISO(iso) else { return false }
        return date > Date()
    }

    static func parseISO(_ iso: String?) -> Date? {
        guard let iso, !iso.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return withFraction.date(from: iso) ?? plain.date(from: iso)
    }

    static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// Human summary for a mute state ("Off", "Until 3:26 PM", "Always").
    static func muteSummary(_ iso: String?) -> String {
        guard let date = parseISO(iso), date > Date() else { return "Off" }
        if date.timeIntervalSinceNow > 365 * 24 * 3600 { return "Always" }
        let formatter = DateFormatter()
        formatter.dateStyle = Calendar.current.isDateInToday(date) ? .none : .short
        formatter.timeStyle = .short
        return "Until \(formatter.string(from: date))"
    }
}
