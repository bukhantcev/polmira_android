import Foundation

struct MaxofonSession: Codable, Equatable {
    var url: URL
    var username: String
    var password: String

    var hostLabel: String {
        url.host(percentEncoded: false) ?? url.absoluteString
    }

    static func fromManualInput(urlText: String, username: String, password: String) throws -> MaxofonSession {
        let cleanURL = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)

        guard
            let url = URL(string: cleanURL),
            let scheme = url.scheme?.lowercased(),
            ["http", "https"].contains(scheme),
            url.host(percentEncoded: false) != nil
        else {
            throw ManualInputError.invalidURL
        }

        guard !cleanUsername.isEmpty else {
            throw ManualInputError.missingUsername
        }

        guard !password.isEmpty else {
            throw ManualInputError.missingPassword
        }

        return MaxofonSession(url: url, username: cleanUsername, password: password)
    }
}

enum ManualInputError: LocalizedError {
    case invalidURL
    case missingUsername
    case missingPassword

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Проверь ссылку. Нужен полный адрес с http:// или https://."
        case .missingUsername:
            return "Введи логин."
        case .missingPassword:
            return "Введи пароль."
        }
    }
}
