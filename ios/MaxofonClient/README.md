# MaxofonClient iOS

Native iPhone shell for Polmira/Maxofon noVNC sessions.

## What It Does

- Accepts a pasted Maxofon message with URL, login, and password.
- Parses and stores the session in iOS Keychain.
- Requires Face ID / Touch ID / device passcode before opening the session.
- Opens the noVNC URL in a `WKWebView`.
- Injects mobile viewport and focus helpers for better iPhone keyboard behavior.

## Expected Message Format

The parser is intentionally loose. It accepts text like:

```text
Maxofon
URL: https://polmira.example/polmira/abc/vnc.html?autoconnect=1
Логин: Admin
Пароль: secret
```

It also recognizes `login`, `username`, `password`, `pass`, `ссылка`, `url`.

## Xcode Setup

1. Create a new iOS App project in Xcode.
2. Choose SwiftUI and Swift.
3. Add all files from `Sources/MaxofonClient` to the app target.
4. Add `NSFaceIDUsageDescription` to `Info.plist`:

```xml
<key>NSFaceIDUsageDescription</key>
<string>Maxofon unlocks your session with Face ID.</string>
```
