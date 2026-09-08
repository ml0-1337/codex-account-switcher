import Foundation

public enum SafeText {
    public static func bounded(_ value: String, maximumLength: Int = 240) -> String {
        let singleLine = value.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) ? " " : String(scalar)
        }.joined()
        let redacted = redactLikelySecrets(in: singleLine)
        if redacted.count <= maximumLength {
            return redacted
        }
        return String(redacted.prefix(maximumLength)) + "…"
    }

    private static func redactLikelySecrets(in value: String) -> String {
        let patterns = [
            #"eyJ[A-Za-z0-9_-]{20,}(?:\.[A-Za-z0-9_-]{10,}){1,2}"#,
            #"sk-[A-Za-z0-9_-]{12,}"#,
            #"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{8,}"#,
            #"(?i)[\"']?(access[_-]?token|refresh[_-]?token|id[_-]?token|authorization|api[_-]?key|account[_-]?id|email|device[_-]?code|user[_-]?code)[\"']?\s*[:=]\s*[\"']?[^\"',}\s]+[\"']?"#,
            #"[A-Za-z0-9_-]{32,}"#,
            #"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#,
        ]
        return patterns.reduce(value) { partial, pattern in
            guard let expression = try? NSRegularExpression(pattern: pattern) else {
                return partial
            }
            let range = NSRange(partial.startIndex..<partial.endIndex, in: partial)
            return expression.stringByReplacingMatches(
                in: partial,
                options: [],
                range: range,
                withTemplate: "<redacted>"
            )
        }
    }
}
