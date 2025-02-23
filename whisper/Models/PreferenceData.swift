// Copyright 2023 Daniel C Brotsky.  All rights reserved.
//
// All material in this project and repository is licensed under the
// GNU Affero General Public License v3. See the LICENSE file for details.

import CoreBluetooth
import CryptoKit

enum OperatingMode: Int {
    case ask = 0, listen = 1, whisper = 2
}

struct PreferenceData {
    private static var defaults = UserDefaults.standard
    
    // publisher URLs
    #if DEBUG
    static var whisperServer = "https://stage.whisper.clickonetwo.io"
    #else
    static var whisperServer = "https://whisper.clickonetwo.io"
    #endif
    static func publisherUrlToClientId(url: String) -> String? {
        let publisherRegex = /https:\/\/(stage\.)?whisper.clickonetwo.io\/subscribe\/([-a-zA-Z0-9]{36})/
        guard let match = url.wholeMatch(of: publisherRegex) else {
            return nil
        }
        return String(match.2)
    }
    
    // client IDs for TCP transport
    static var clientId: String = {
        if let id = defaults.string(forKey: "whisper_client_id") {
            return id
        } else {
            let id = UUID().uuidString
            defaults.setValue(id, forKey: "whisper_client_id")
            return id
        }
    }()
    
    // client secrets for TCP transport
    //
    // Secrets rotate.  The client generates its first secret, and always
    // sets that as both the current and prior secret.  After that, every
    // time the server sends a new secret, the current secret rotates to
    // be the prior secret.  We send the prior secret with every launch,
    // because this allows the server to know when we've gone out of sync
    // (for example, when a client moves from apns dev to apns prod),
    // and it rotates the secret when that happens.  We sign auth requests
    // with the current secret, but the server allows use of the prior
    // secret as a one-time fallback when we've gone out of sync.
    static func lastClientSecret() -> String {
        if let prior = defaults.string(forKey: "whisper_last_client_secret") {
            return prior
        } else {
            let prior = makeSecret()
            defaults.setValue(prior, forKey: "whisper_last_client_secret")
            return prior
        }
    }
    static func clientSecret() -> String? {
        if let current = defaults.string(forKey: "whisper_client_secret") {
            return current
        } else {
            let prior = lastClientSecret()
            defaults.setValue(prior, forKey: "whisper_client_secret")
            return prior
        }
    }
    static func updateClientSecret(_ secret: String) {
        // if the new secret is different than the old secret, save the old secret
        if let current = defaults.string(forKey: "whisper_client_secret"), secret != current {
            defaults.setValue(current, forKey: "whisper_last_client_secret")
        }
        defaults.setValue(secret, forKey: "whisper_client_secret")
    }
    static func makeSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let result = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard result == errSecSuccess else {
            fatalError("Couldn't generate random bytes")
        }
        return Data(bytes).base64EncodedString()
    }
    
    // layout control of listeners
    static func listenerMatchesWhisperer() -> Bool {
        return defaults.string(forKey: "newest_whisper_location_preference") == "bottom"
    }
    
    // whether to speak past text
    static var speakWhenWhispering: Bool {
        get { defaults.bool(forKey: "speak_when_whispering_setting") }
        set (new) { defaults.setValue(new, forKey: "speak_when_whispering_setting") }
    }
    static var speakWhenListening: Bool {
        get { defaults.bool(forKey: "speak_when_listening_setting") }
        set (new) { defaults.setValue(new, forKey: "speak_when_listening_setting") }
    }

    // user name and session memory
    private static var session_name: String = ""
    static func userName() -> String {
        var name = session_name
        if name.isEmpty {
            if defaults.object(forKey: "remember_name_preference") as? Bool ?? true {
                name = defaults.string(forKey: "session_name") ?? ""
            }
        } else {
            // this might seem unnecessary, but it's needed in case the setting was changed
            // *after* the session name was set.  In that case we need to save the current
            // session name for the next session.
            if defaults.object(forKey: "remember_name_preference") as? Bool ?? true {
                defaults.setValue(name, forKey: "session_name")
            }
        }
        return name
    }
    static func updateUserName(_ name: String) {
        session_name = name
        if defaults.object(forKey: "remember_name_preference") as? Bool ?? true {
            defaults.setValue(name, forKey: "session_name")
        }
    }
    
    // require Bluetooth listeners to pair?
    static func requireAuthentication() -> Bool {
        let result = defaults.bool(forKey: "listener_authentication_preference")
        return result
    }
    
    // alert sounds
    struct AlertSoundChoice: Identifiable {
        var id: String
        var name: String
    }
    static let alertSoundChoices: [AlertSoundChoice] = [
        AlertSoundChoice(id: "air-horn", name: "Air Horn"),
        AlertSoundChoice(id: "bike-horn", name: "Bicycle Horn"),
        AlertSoundChoice(id: "bike-bell", name: "Bicycle Bell"),
    ]
    static var alertSound: String {
        get {
            return defaults.string(forKey: "alert_sound_preference") ?? "bike-horn"
        }
        set(new) {
            defaults.setValue(new, forKey: "alert_sound_preference")
        }
    }
    
    // last used listener URL
    static var lastSubscriberUrl: String? {
        get {
            defaults.string(forKey: "last_subscriber_url")
        }
        set(newUrl) {
            if newUrl != nil {
                defaults.setValue(newUrl, forKey: "last_subscriber_url")
            } else {
                defaults.removeObject(forKey: "last_subscriber_url")
            }
        }
    }
    
    // metrics of errors to send in diagnostics to server
    static var droppedErrorCount: Int {
        get {
            defaults.integer(forKey: "dropped_error_count")
        }
        set(newVal) {
            defaults.setValue(newVal, forKey: "dropped_error_count")
        }
    }
    static var tcpErrorCount: Int {
        get {
            defaults.integer(forKey: "tcp_error_count")
        }
        set(newVal) {
            defaults.setValue(newVal, forKey: "tcp_error_count")
        }
    }
    static var authenticationErrorCount: Int {
        get {
            defaults.integer(forKey: "authentication_error_count")
        }
        set(newVal) {
            defaults.setValue(newVal, forKey: "authentication_error_count")
        }
    }
}
