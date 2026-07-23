import SwiftUI
import WebKit
import AVFoundation

struct MaxWebView: UIViewRepresentable {
    let session: MaxofonSession
    let keyboardRequest: Int
    let keyboardVisible: Bool
    let composedText: String
    let composedTextRevision: Int
    let submitTextRevision: Int
    let keyboardLift: CGFloat

    func makeUIView(context: Context) -> TransformZoomWebContainer {
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(
            .playback,
            mode: .moviePlayback,
            options: [.allowAirPlay, .allowBluetoothA2DP]
        )
        try? audioSession.setActive(true)

        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(
            source: Self.audioUnlockScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        controller.addUserScript(WKUserScript(
            source: Self.mobileHelperScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        ))
        configuration.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.keyboardDismissMode = .interactive
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.panGestureRecognizer.isEnabled = false
        webView.scrollView.pinchGestureRecognizer?.isEnabled = false
        webView.allowsBackForwardNavigationGestures = false
        webView.load(URLRequest(url: Self.appURL(from: session.url)))

        let container = TransformZoomWebContainer(webView: webView)
        return container
    }

    func updateUIView(_ container: TransformZoomWebContainer, context: Context) {
        container.keyboardLift = keyboardLift

        if context.coordinator.lastKeyboardRequest != keyboardRequest {
            context.coordinator.lastKeyboardRequest = keyboardRequest
            container.setKeyboardVisible(keyboardVisible)
        }

        if context.coordinator.lastComposedTextRevision != composedTextRevision {
            context.coordinator.lastComposedTextRevision = composedTextRevision
            container.sendComposedText(composedText, coordinator: context.coordinator)
        }

        if context.coordinator.lastSubmitTextRevision != submitTextRevision {
            context.coordinator.lastSubmitTextRevision = submitTextRevision
            container.submitComposedText(coordinator: context.coordinator)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let session: MaxofonSession
        var lastKeyboardRequest = 0
        var lastComposedTextRevision = 0
        var lastSubmitTextRevision = 0
        var lastComposedText = ""

        init(session: MaxofonSession) {
            self.session = session
        }

        func webView(
            _ webView: WKWebView,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPBasic else {
                completionHandler(.performDefaultHandling, nil)
                return
            }

            let credential = URLCredential(
                user: session.username,
                password: session.password,
                persistence: .forSession
            )
            completionHandler(.useCredential, credential)
        }
    }

    private static let audioUnlockScript = """
    (function() {
      if (window.__maxofonAudioUnlockInstalled) return;
      window.__maxofonAudioUnlockInstalled = true;

      var contexts = [];

      function remember(context) {
        if (contexts.indexOf(context) === -1) contexts.push(context);
        context.resume().catch(function() {});
        return context;
      }

      function wrapAudioContext(name) {
        var Original = window[name];
        if (!Original || typeof Proxy === 'undefined') return;

        try {
          window[name] = new Proxy(Original, {
            construct: function(target, args) {
              return remember(Reflect.construct(target, args));
            }
          });
        } catch (_) {}
      }

      function resumeAudio() {
        contexts.forEach(function(context) {
          if (context.state !== 'running') context.resume().catch(function() {});
        });

        document.querySelectorAll('audio, video').forEach(function(media) {
          if (media.paused) media.play().catch(function() {});
        });
      }

      wrapAudioContext('AudioContext');
      wrapAudioContext('webkitAudioContext');

      ['pointerdown', 'touchend', 'click', 'keydown'].forEach(function(eventName) {
        window.addEventListener(eventName, resumeAudio, { capture: true, passive: true });
      });

      window.__maxofonResumeAudio = resumeAudio;
    })();
    """

    private static let mobileHelperScript = """
    (function() {
      var viewport = document.querySelector('meta[name=viewport]');
      if (!viewport) {
        viewport = document.createElement('meta');
        viewport.name = 'viewport';
        document.head.appendChild(viewport);
      }
      viewport.content = 'width=device-width, initial-scale=1, minimum-scale=0.5, maximum-scale=5, user-scalable=yes, viewport-fit=cover';

      document.documentElement.style.webkitTextSizeAdjust = '100%';
      document.body.style.webkitTouchCallout = 'none';
      document.body.style.webkitUserSelect = 'none';

      if (!window.__maxofonWheelTouchBridgeInstalled) {
        window.__maxofonWheelTouchBridgeInstalled = true;
        var touchStartX = 0;
        var touchStartY = 0;
        var lastTouchX = 0;
        var lastTouchY = 0;
        var scrolling = false;

        function isEditable(element) {
          if (!element) return false;
          var tag = (element.tagName || '').toLowerCase();
          return tag === 'textarea' ||
                 tag === 'select' ||
                 (tag === 'input' && element.type !== 'hidden') ||
                 element.isContentEditable === true;
        }

        function wheelTarget(pointX, pointY) {
          return document.elementFromPoint(pointX, pointY) ||
                 document.querySelector('canvas') ||
                 document.body;
        }

        document.addEventListener('touchstart', function(event) {
          if (event.touches.length !== 1 || isEditable(event.target)) {
            scrolling = false;
            return;
          }

          var touch = event.touches[0];
          touchStartX = lastTouchX = touch.clientX;
          touchStartY = lastTouchY = touch.clientY;
          scrolling = false;
        }, { passive: true, capture: true });

        document.addEventListener('touchmove', function(event) {
          if (event.touches.length !== 1 || isEditable(event.target)) {
            return;
          }

          var touch = event.touches[0];
          var dx = touch.clientX - lastTouchX;
          var dy = touch.clientY - lastTouchY;
          var totalX = touch.clientX - touchStartX;
          var totalY = touch.clientY - touchStartY;

          if (!scrolling) {
            scrolling = Math.abs(totalY) > 10 && Math.abs(totalY) > Math.abs(totalX) * 1.2;
          }

          if (!scrolling) {
            lastTouchX = touch.clientX;
            lastTouchY = touch.clientY;
            return;
          }

          event.preventDefault();
          var target = wheelTarget(touch.clientX, touch.clientY);
          var wheel = new WheelEvent('wheel', {
            bubbles: true,
            cancelable: true,
            clientX: touch.clientX,
            clientY: touch.clientY,
            deltaX: -dx,
            deltaY: -dy,
            deltaMode: 0
          });
          target.dispatchEvent(wheel);
          lastTouchX = touch.clientX;
          lastTouchY = touch.clientY;
        }, { passive: false, capture: true });

        document.addEventListener('touchend', function() {
          scrolling = false;
        }, { passive: true, capture: true });
      }
    })();
    """

    fileprivate static func javascriptLiteral(_ text: String) -> String {
        guard
            let data = try? JSONEncoder().encode(text),
            let literal = String(data: data, encoding: .utf8)
        else {
            return "''"
        }
        return literal
    }

    private static func appURL(from url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }

        var items = components.queryItems ?? []
        if !items.contains(where: { $0.name == "maxofon_native_keyboard" }) {
            items.append(URLQueryItem(name: "maxofon_native_keyboard", value: "1"))
        }
        items.removeAll(where: { $0.name == "maxofon_ui" })
        items.append(URLQueryItem(name: "maxofon_ui", value: "20260718-6"))
        components.queryItems = items
        return components.url ?? url
    }
}

final class TransformZoomWebContainer: UIView, UIGestureRecognizerDelegate {
    private let webView: WKWebView
    var keyboardLift: CGFloat = 0 {
        didSet {
            clampTranslation()
            applyTransform()
        }
    }
    private lazy var pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
    private lazy var panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
    private lazy var doubleTapGesture = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
    private var scale: CGFloat = 1.0
    private var baseScale: CGFloat = 1.0
    private var translation: CGPoint = .zero
    private var baseTranslation: CGPoint = .zero

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        webView.frame = bounds
        clampTranslation()
        applyTransform()
    }

    private func setup() {
        backgroundColor = .black
        clipsToBounds = true

        addSubview(webView)
        webView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        pinchGesture.delegate = self
        pinchGesture.cancelsTouchesInView = true
        addGestureRecognizer(pinchGesture)

        panGesture.minimumNumberOfTouches = 1
        panGesture.maximumNumberOfTouches = 1
        panGesture.delegate = self
        panGesture.cancelsTouchesInView = true
        addGestureRecognizer(panGesture)

        doubleTapGesture.numberOfTapsRequired = 2
        doubleTapGesture.numberOfTouchesRequired = 2
        doubleTapGesture.delegate = self
        addGestureRecognizer(doubleTapGesture)
    }

    func setKeyboardVisible(_ visible: Bool) {
        let script: String
        if visible {
            script = """
            (function() {
              var input = document.getElementById('noVNC_keyboardinput');
              if (input) input.focus();
              return 'focused';
            })();
            """
        } else {
            script = """
            (function() {
              if (document.activeElement) document.activeElement.blur();
              return 'blurred';
            })();
            """
        }
        webView.evaluateJavaScript(script)
    }

    func sendComposedText(_ text: String, coordinator: MaxWebView.Coordinator) {
        let oldText = coordinator.lastComposedText

        if text.hasPrefix(oldText) {
            let suffix = String(text.dropFirst(oldText.count))
            sendTextInput(suffix)
            coordinator.lastComposedText = text
            return
        }

        if oldText.hasPrefix(text) {
            let count = oldText.count - text.count
            sendBackspaces(count)
            coordinator.lastComposedText = text
            return
        }

        sendBackspaces(oldText.count)
        sendTextInput(text)
        coordinator.lastComposedText = text
    }

    func submitComposedText(coordinator: MaxWebView.Coordinator) {
        sendEnter()
        coordinator.lastComposedText = ""
    }

    private func sendTextInput(_ text: String) {
        guard !text.isEmpty else { return }
        let payload = MaxWebView.javascriptLiteral(text)
        let script = """
        (function() {
          var bridge = window.maxofonNativeInput;
          if (!bridge || !bridge.insertText) return 'missing-native-input-bridge';
          return bridge.insertText(\(payload)) ? 'ok' : 'failed';
        })();
        """
        webView.evaluateJavaScript(script)
    }

    private func sendBackspaces(_ count: Int) {
        guard count > 0 else { return }
        let script = """
        (function() {
          var bridge = window.maxofonNativeInput;
          if (!bridge || !bridge.backspace) return 'missing-native-input-bridge';
          return bridge.backspace(\(count)) ? 'ok' : 'failed';
        })();
        """
        webView.evaluateJavaScript(script)
    }

    private func sendEnter() {
        let script = """
        (function() {
          var bridge = window.maxofonNativeInput;
          if (!bridge || !bridge.enter) return 'missing-native-input-bridge';
          return bridge.enter() ? 'ok' : 'failed';
        })();
        """
        webView.evaluateJavaScript(script)
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        switch recognizer.state {
        case .began:
            baseScale = scale
        case .changed, .ended:
            scale = min(max(baseScale * recognizer.scale, 1.0), 4.0)
            if scale <= 1.01 {
                scale = 1.0
                translation = .zero
            }
            clampTranslation()
            applyTransform()
        default:
            break
        }
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard scale > 1.01 else { return }

        switch recognizer.state {
        case .began:
            baseTranslation = translation
        case .changed, .ended:
            let delta = recognizer.translation(in: self)
            translation = CGPoint(
                x: baseTranslation.x + delta.x,
                y: baseTranslation.y + delta.y
            )
            clampTranslation()
            applyTransform()
        default:
            break
        }
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        if scale > 1.05 {
            scale = 1.0
            translation = .zero
            UIView.animate(withDuration: 0.2) {
                self.applyTransform()
            }
            return
        }

        scale = 2.0
        translation = .zero
        clampTranslation()
        UIView.animate(withDuration: 0.2) {
            self.applyTransform()
        }
    }

    private func applyTransform() {
        webView.transform = CGAffineTransform(translationX: translation.x, y: translation.y - keyboardLift)
            .scaledBy(x: scale, y: scale)
    }

    private func clampTranslation() {
        guard scale > 1.0, bounds.width > 0, bounds.height > 0 else {
            translation = .zero
            return
        }

        let maxX = (bounds.width * (scale - 1.0)) / 2.0
        let maxY = (bounds.height * (scale - 1.0)) / 2.0
        translation.x = min(max(translation.x, -maxX), maxX)
        translation.y = min(max(translation.y, -maxY), maxY)
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGesture {
            return scale > 1.01
        }

        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer === pinchGesture ||
        otherGestureRecognizer === pinchGesture ||
        gestureRecognizer === panGesture ||
        otherGestureRecognizer === panGesture
    }
}
