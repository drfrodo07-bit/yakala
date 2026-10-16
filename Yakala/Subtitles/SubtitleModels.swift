import Foundation

struct SubtitleCue: Identifiable, Hashable {
    let id: UUID
    var start: Double
    var end: Double
    var text: String

    init(id: UUID = UUID(), start: Double, end: Double, text: String) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
    }
}

struct LanguageOption: Identifiable, Hashable {
    let code: String
    let name: String
    var id: String { code }
}

enum Languages {
    static let common: [LanguageOption] = [
        LanguageOption(code: "tr", name: "Türkçe"),
        LanguageOption(code: "en", name: "İngilizce"),
        LanguageOption(code: "de", name: "Almanca"),
        LanguageOption(code: "fr", name: "Fransızca"),
        LanguageOption(code: "es", name: "İspanyolca"),
        LanguageOption(code: "it", name: "İtalyanca"),
        LanguageOption(code: "pt", name: "Portekizce"),
        LanguageOption(code: "ru", name: "Rusça"),
        LanguageOption(code: "ar", name: "Arapça"),
        LanguageOption(code: "ja", name: "Japonca"),
        LanguageOption(code: "ko", name: "Korece"),
        LanguageOption(code: "zh", name: "Çince"),
        LanguageOption(code: "nl", name: "Felemenkçe"),
        LanguageOption(code: "pl", name: "Lehçe"),
        LanguageOption(code: "uk", name: "Ukraynaca"),
        LanguageOption(code: "hi", name: "Hintçe"),
        LanguageOption(code: "id", name: "Endonezce"),
        LanguageOption(code: "vi", name: "Vietnamca"),
        LanguageOption(code: "th", name: "Tayca")
    ]

    static func name(for code: String) -> String {
        if let match = common.first(where: { $0.code == code }) {
            return match.name
        }
        return Locale(identifier: "tr_TR").localizedString(forLanguageCode: code) ?? code
    }

    /// Whisper dil kodunu Apple Çeviri diline çevirir
    static func appleLanguage(_ code: String) -> Locale.Language {
        switch code {
        case "zh": return Locale.Language(identifier: "zh-Hans")
        default: return Locale.Language(identifier: code)
        }
    }
}

enum SubtitleFormatter {
    static let maxCharsPerCue = 84
    static let maxLineLength = 42
    static let minCueDuration = 0.8

    /// Whisper'ın özel işaretlerini ve fazla boşlukları temizler
    static func clean(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "<\\|[^|>]*\\|>", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Uzun parçaları ekranda rahat okunacak kısa altyazılara böler
    static func split(_ cues: [SubtitleCue]) -> [SubtitleCue] {
        var result: [SubtitleCue] = []
        for cue in cues {
            let text = clean(cue.text)
            guard !text.isEmpty else { continue }
            let pieces = chunk(text)
            let totalChars = Double(pieces.reduce(0) { $0 + $1.count })
            let duration = max(cue.end - cue.start, minCueDuration)
            var cursor = cue.start
            for piece in pieces {
                let share = duration * Double(piece.count) / max(totalChars, 1)
                result.append(SubtitleCue(start: cursor, end: cursor + share, text: piece))
                cursor += share
            }
        }
        // Çakışmaları düzelt
        for index in result.indices.dropLast() where result[index].end > result[index + 1].start {
            result[index].end = max(result[index].start + 0.3, result[index + 1].start)
        }
        return result
    }

    static func chunk(_ text: String) -> [String] {
        guard text.count > maxCharsPerCue else { return [text] }
        let words = text.split(separator: " ").map(String.init)
        var chunks: [String] = []
        var current = ""
        for word in words {
            if current.isEmpty {
                current = word
            } else if current.count + 1 + word.count <= maxCharsPerCue {
                current += " " + word
            } else {
                chunks.append(current)
                current = word
            }
            // Cümle sonunda ve yeterince uzunsa böl
            if let last = current.last, ".!?".contains(last), current.count >= maxCharsPerCue / 2 {
                chunks.append(current)
                current = ""
            }
        }
        if !current.isEmpty {
            if current.count < 15, let previous = chunks.last, previous.count + 1 + current.count <= maxCharsPerCue + 15 {
                chunks[chunks.count - 1] = previous + " " + current
            } else {
                chunks.append(current)
            }
        }
        return chunks
    }

    /// Uzun satırı ortadaki boşluktan ikiye böler
    static func wrap(_ text: String) -> String {
        guard text.count > maxLineLength, !text.contains("\n") else { return text }
        let characters = Array(text)
        let middle = characters.count / 2
        var splitIndex: Int?
        for offset in 0..<middle {
            let candidates = [middle - offset, middle + offset]
            if let found = candidates.first(where: { $0 > 0 && $0 < characters.count && characters[$0] == " " }) {
                splitIndex = found
                break
            }
        }
        guard let index = splitIndex else { return text }
        return String(characters[..<index]) + "\n" + String(characters[(index + 1)...])
    }
}

enum SRTWriter {
    static func timestamp(_ seconds: Double) -> String {
        let totalMilliseconds = Int((max(seconds, 0) * 1000).rounded())
        let hours = totalMilliseconds / 3_600_000
        let minutes = (totalMilliseconds / 60_000) % 60
        let secs = (totalMilliseconds / 1000) % 60
        let millis = totalMilliseconds % 1000
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, secs, millis)
    }

    static func make(_ cues: [SubtitleCue]) -> String {
        cues.enumerated().map { index, cue in
            "\(index + 1)\n\(timestamp(cue.start)) --> \(timestamp(cue.end))\n\(SubtitleFormatter.wrap(cue.text))\n"
        }
        .joined(separator: "\n")
    }
}
