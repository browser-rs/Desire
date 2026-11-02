import AVFoundation
import Foundation

/// 朗读声音/语速（v0.8.36）：UserDefaults 持久化，选中段与整章朗读共用。
struct ReaderSpeechSettings {
    var rate: Float
    var voiceIdentifier: String?

    static let defaultRate: Float = 0.5

    static func load() -> ReaderSpeechSettings {
        let defaults = UserDefaults.standard
        let stored = defaults.object(forKey: "reader.speech.rate") as? Double
        let rate = Float(stored ?? Double(defaultRate))
        let voice = defaults.string(forKey: "reader.speech.voice")
        return ReaderSpeechSettings(
            rate: min(max(rate, 0.3), 0.85),
            voiceIdentifier: (voice?.isEmpty ?? true) ? nil : voice)
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(Double(rate), forKey: "reader.speech.rate")
        if let voiceIdentifier, !voiceIdentifier.isEmpty {
            defaults.set(voiceIdentifier, forKey: "reader.speech.voice")
        } else {
            defaults.removeObject(forKey: "reader.speech.voice")
        }
    }

    static var availableVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().sorted {
            if $0.language != $1.language { return $0.language < $1.language }
            return $0.name < $1.name
        }
    }
}
