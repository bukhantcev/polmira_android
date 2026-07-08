import Foundation

enum MessageParser {
    enum ParseError: LocalizedError {
        case missingURL
        case missingUsername
        case missingPassword

        var errorDescription: String? {
            switch self {
            case .missingURL:
                return "Не нашёл ссылку."
            case .missingUsername:
                return "Не нашёл логин."
            case .missingPassword:
                return "Не нашёл пароль."
            }
        }
    }

    static func parse(_ text: String) throws -> MaxofonSession {
        let url = try parseURL(text)
        let username = try parseValue(
            text,
            keys: ["login", "username", "user", "логин", "пользователь"]
        ).okOrThrow(ParseError.missingUsername)
        let password = try parseValue(
            text,
            keys: ["password", "pass", "пароль"]
        ).okOrThrow(ParseError.missingPassword)

        return MaxofonSession(url: url, username: username, password: password)
    }

    private static func parseURL(_ text: String) throws -> URL {
        let pattern = #"https?://[^\s<>"']+"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)

        guard
            let match = regex.firstMatch(in: text, range: range),
            let swiftRange = Range(match.range, in: text)
        else {
            throw ParseError.missingURL
        }

        var raw = String(text[swiftRange])
        raw = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".,;) \n\r\t"))

        guard let url = URL(string: raw) else {
            throw ParseError.missingURL
        }

        return url
    }

    private static func parseValue(_ text: String, keys: [String]) throws -> String? {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        for line in lines {
            let normalized = line.lowercased()

            for key in keys {
                guard normalized.contains(key.lowercased()) else {
                    continue
                }

                if let value = valueAfterSeparator(in: line) {
                    return value
                }
            }
        }

        return nil
    }

    private static func valueAfterSeparator(in line: String) -> String? {
        for separator in [":", "=", "-", "—"] {
            guard let index = line.firstIndex(of: Character(separator)) else {
                continue
            }

            let value = line[line.index(after: index)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if !value.isEmpty {
                return value
            }
        }

        return nil
    }
}

private extension Optional {
    func okOrThrow(_ error: Error) throws -> Wrapped {
        guard let value = self else {
            throw error
        }

        return value
    }
}
