(() => {
  "use strict";

  const audioContexts = new Set();
  const audioWorkerBlobs = new WeakSet();
  const audioWorkerUrls = new Set();
  const boostedAudioOutputs = new WeakMap();
  const textInputBridges = new WeakSet();
  const mobileAssistInputBridges = new WeakSet();
  const mobileAssistStates = new WeakMap();
  const mobilePaneInputBridges = new WeakSet();
  const mobileCursorBridges = new WeakSet();
  const mobileAssistModifierKeys = new Set([
    "Alt",
    "AltGraph",
    "CapsLock",
    "Control",
    "Meta",
    "Shift",
  ]);
  const remoteModifierKeysyms = [
    65027, // ISO_Level3_Shift / AltGraph
    65505, // Shift_L
    65506, // Shift_R
    65507, // Control_L
    65508, // Control_R
    65509, // Caps_Lock
    65513, // Alt_L
    65514, // Alt_R
    65515, // Super_L
    65516, // Super_R
  ];
  const nativeSetInterval = window.setInterval.bind(window);
  const isMobileTouchClient = (
    /Android|iP(?:hone|ad|od)|Mobile/i.test(navigator.userAgent)
    && navigator.maxTouchPoints > 0
  );
  const isStandaloneApp = (
    (
      typeof window.matchMedia === "function"
      && window.matchMedia("(display-mode: standalone)").matches
    )
    || window.navigator.standalone === true
  );
  const authRecheckAfterMs = 12000;
  const usesAudioDecoderFallback = (
    /iP(?:hone|ad|od)/.test(navigator.userAgent)
    || typeof window.AudioDecoder !== "function"
  );
  const desktopAudioGain = 4;
  const displacedStorageKey = "maxofon-primary-session-displaced";
  const mobileAssistSeed = ". ";
  const landscapeResolution = { width: 1280, height: 720 };
  const maxWindowGeometry = {
    contentTop: 26,
    sidebarEndRatio: 77 / 1280,
    listEndRatio: 445 / 1280,
  };
  const pageSessionId = (
    crypto.randomUUID?.()
    || `${Date.now()}-${Math.random().toString(16).slice(2)}`
  );
  let lastInput = null;
  let lastElement = null;
  let gesture = null;
  let pendingMobileText = "";
  let pendingMobileTextFallback = null;
  const mobileInputJobs = [];
  let mobileInputProcessing = false;
  let mobileTextFlushTimer = null;
  let mobileTextPipeline = Promise.resolve();
  let mobilePaneMode = "list";
  let mobilePaneLayout = null;
  let mobilePaneBaselineHeight = 0;
  let mobilePaneUpdateFrame = null;
  let mobileResolutionRequest = null;
  let mobileResolutionMatchedAt = 0;
  let mobileChatsPrimedAt = 0;
  let mobileChatsPrimeTimer = null;
  let mobileMediaStateActive = false;
  let mobileMediaStatePending = false;
  let mobileMediaStateTimer = null;
  let mobileNavOpen = false;
  let mobileRemoteTextCursor = false;
  let sessionDisplaced = sessionStorage.getItem(displacedStorageKey) === "1";
  let hiddenAt = 0;

  if (
    isMobileTouchClient
    && (
      window.innerHeight >= window.innerWidth
      || window.screen?.orientation?.type?.startsWith("portrait")
    )
  ) {
    document.documentElement.classList.add("maxofon-mobile-starting");
  }

  if (isMobileTouchClient && isStandaloneApp) {
    document.addEventListener("visibilitychange", () => {
      if (document.visibilityState === "hidden") {
        hiddenAt = Date.now();
        return;
      }

      if (hiddenAt && Date.now() - hiddenAt >= authRecheckAfterMs) {
        const target = new URL(window.location.href);
        target.searchParams.set("_maxofon_auth", String(Date.now()));
        window.location.replace(target.toString());
      }
      hiddenAt = 0;
    });
  }

  function installAudioDecoderFallback() {
    if (!usesAudioDecoderFallback) {
      return;
    }

    const NativeBlob = window.Blob;
    const NativeWorker = window.Worker;
    const nativeCreateObjectURL = URL.createObjectURL.bind(URL);
    const nativeRevokeObjectURL = URL.revokeObjectURL.bind(URL);

    window.Blob = new Proxy(NativeBlob, {
      construct(target, args) {
        const blob = Reflect.construct(target, args, target);
        const parts = Array.isArray(args[0]) ? args[0] : [];
        if (
          parts.some(
            (part) => (
              typeof part === "string"
              && part.includes("let decoderAudio;")
              && part.includes("new AudioDecoder")
              && part.includes("decodedAudioData")
            ),
          )
        ) {
          audioWorkerBlobs.add(blob);
        }
        return blob;
      },
    });

    URL.createObjectURL = (blob) => {
      const url = nativeCreateObjectURL(blob);
      if (audioWorkerBlobs.has(blob)) {
        audioWorkerUrls.add(url);
      }
      return url;
    };

    URL.revokeObjectURL = (url) => {
      nativeRevokeObjectURL(url);
      audioWorkerUrls.delete(String(url));
    };

    window.Worker = new Proxy(NativeWorker, {
      construct(target, args) {
        if (audioWorkerUrls.has(String(args[0]))) {
          const fallbackUrl = new URL(
            "./polmira-opus-worker.js?v=20260723-mobile3",
            document.baseURI,
          ).href;
          console.log("Maxofon: using the Safari Opus decoder.");
          return Reflect.construct(target, [fallbackUrl, args[1]], target);
        }
        return Reflect.construct(target, args, target);
      },
    });
  }

  function showDisplacedSession() {
    let notice = document.getElementById("maxofon-session-displaced");
    if (notice) {
      return;
    }

    notice = document.createElement("div");
    notice.id = "maxofon-session-displaced";
    notice.style.cssText = [
      "position:fixed",
      "inset:0",
      "z-index:2147483647",
      "display:flex",
      "align-items:center",
      "justify-content:center",
      "padding:24px",
      "background:rgba(15,23,42,.86)",
      "font:16px system-ui,sans-serif",
      "color:#fff",
    ].join(";");

    const button = document.createElement("button");
    button.type = "button";
    button.textContent = "Подключить на этом устройстве";
    button.style.cssText = [
      "min-height:48px",
      "padding:12px 18px",
      "border:0",
      "border-radius:8px",
      "background:#1683ff",
      "color:#fff",
      "font:600 16px system-ui,sans-serif",
    ].join(";");
    button.addEventListener("click", () => {
      sessionStorage.removeItem(displacedStorageKey);
      location.reload();
    });

    const content = document.createElement("div");
    content.style.cssText = "max-width:360px;text-align:center";
    const message = document.createElement("p");
    message.textContent = "Сессия открыта на другом устройстве.";
    message.style.cssText = "margin:0 0 16px";
    content.append(message, button);
    notice.append(content);
    document.body.append(notice);
  }

  function installSingleSessionGuard() {
    const NativeWebSocket = window.WebSocket;

    class BlockedWebSocket extends EventTarget {
      constructor(url) {
        super();
        this.url = String(url);
        this.binaryType = "blob";
        this.bufferedAmount = 0;
        this.extensions = "";
        this.protocol = "";
        this.readyState = NativeWebSocket.CONNECTING;
        queueMicrotask(() => {
          this.readyState = NativeWebSocket.CLOSED;
          this.dispatchEvent(new Event("error"));
          this.dispatchEvent(
            new CloseEvent("close", {
              code: 4001,
              reason: "primary session displaced",
              wasClean: true,
            }),
          );
        });
      }

      send() {
        throw new DOMException(
          "The session is active on another device.",
          "InvalidStateError",
        );
      }

      close() {
        this.readyState = NativeWebSocket.CLOSED;
      }
    }

    for (const [name, value] of [
      ["CONNECTING", NativeWebSocket.CONNECTING],
      ["OPEN", NativeWebSocket.OPEN],
      ["CLOSING", NativeWebSocket.CLOSING],
      ["CLOSED", NativeWebSocket.CLOSED],
    ]) {
      Object.defineProperty(BlockedWebSocket, name, { value });
      Object.defineProperty(BlockedWebSocket.prototype, name, { value });
    }

    window.WebSocket = new Proxy(NativeWebSocket, {
      construct(target, args) {
        if (sessionDisplaced) {
          queueMicrotask(showDisplacedSession);
          return new BlockedWebSocket(args[0]);
        }

        const socketArgs = [...args];
        try {
          const socketUrl = new URL(String(socketArgs[0]), location.href);
          if (socketUrl.pathname.endsWith("/websockets")) {
            socketUrl.searchParams.set("maxofon_client", pageSessionId);
            socketArgs[0] = socketUrl.href;
          }
        } catch {
          // Let the native constructor report malformed URLs.
        }

        const socket = Reflect.construct(target, socketArgs, target);
        socket.addEventListener("close", (event) => {
          if (
            event.code === 4009
            || (
              typeof event.reason === "string"
              && (
                event.reason.includes("Superseded by new client")
                || event.reason.includes("Primary session superseded")
              )
            )
          ) {
            sessionDisplaced = true;
            sessionStorage.setItem(displacedStorageKey, "1");
            showDisplacedSession();
          }
        });
        return socket;
      },
    });

    window.setInterval = (handler, timeout, ...args) => (
      nativeSetInterval(() => {
        if (sessionDisplaced) {
          return;
        }
        if (typeof handler === "function") {
          handler(...args);
        } else {
          Function(handler)();
        }
      }, timeout)
    );

    if (sessionDisplaced) {
      window.addEventListener("DOMContentLoaded", showDisplacedSession, {
        once: true,
      });
    }
  }

  installAudioDecoderFallback();
  installSingleSessionGuard();

  const nativeAudioNodeConnect = window.AudioNode?.prototype?.connect;

  function createBoostedAudioOutput(context) {
    if (
      usesAudioDecoderFallback
      || typeof nativeAudioNodeConnect !== "function"
      || typeof context.createGain !== "function"
    ) {
      return;
    }

    const gain = context.createGain();
    gain.gain.value = desktopAudioGain;
    const limiter = context.createDynamicsCompressor?.();

    if (limiter) {
      limiter.threshold.value = -3;
      limiter.knee.value = 0;
      limiter.ratio.value = 20;
      limiter.attack.value = 0.003;
      limiter.release.value = 0.15;
      nativeAudioNodeConnect.call(gain, limiter);
      nativeAudioNodeConnect.call(limiter, context.destination);
    } else {
      nativeAudioNodeConnect.call(gain, context.destination);
    }

    boostedAudioOutputs.set(context, {
      destination: context.destination,
      input: gain,
    });
  }

  if (typeof nativeAudioNodeConnect === "function") {
    Object.defineProperty(window.AudioNode.prototype, "connect", {
      configurable: true,
      value(destination, ...args) {
        const output = boostedAudioOutputs.get(this.context);
        const target = (
          output && destination === output.destination
            ? output.input
            : destination
        );
        return nativeAudioNodeConnect.call(this, target, ...args);
      },
      writable: true,
    });
  }

  function replaceAudioContext(name, NativeAudioContext) {
    if (typeof NativeAudioContext !== "function" || NativeAudioContext.__polmiraWrapped) {
      return NativeAudioContext;
    }

    const WrappedAudioContext = new Proxy(NativeAudioContext, {
      construct(target, args) {
        const context = Reflect.construct(target, args, target);
        audioContexts.add(context);
        createBoostedAudioOutput(context);
        context.addEventListener?.("statechange", () => {
          if (context.state === "closed") {
            audioContexts.delete(context);
          }
        });
        return context;
      },
    });

    Object.defineProperty(WrappedAudioContext, "__polmiraWrapped", {
      value: true,
    });

    try {
      Object.defineProperty(window, name, {
        configurable: true,
        value: WrappedAudioContext,
        writable: true,
      });
    } catch (error) {
      console.warn(`Maxofon: could not wrap ${name}.`, error);
    }

    return WrappedAudioContext;
  }

  const nativeAudioContext = window.AudioContext || window.webkitAudioContext;
  const wrappedAudioContext = replaceAudioContext("AudioContext", nativeAudioContext);
  if (window.webkitAudioContext) {
    replaceAudioContext("webkitAudioContext", wrappedAudioContext);
  }

  function unlockAudio() {
    for (const context of audioContexts) {
      if (context.state === "suspended") {
        context.resume().catch(() => {});
      }
    }
  }

  function installLandscapeKeyboardLift() {
    const viewport = window.visualViewport;
    if (!isMobileTouchClient || !viewport) {
      return;
    }

    const baselineHeights = new Map();
    let liftedElement = null;
    let originalTranslate = "";
    let originalTranslatePriority = "";
    let currentLift = 0;

    function orientationKey() {
      return window.innerWidth > window.innerHeight ? "landscape" : "portrait";
    }

    function textEntryFocused() {
      const element = document.activeElement;
      const tagName = element?.tagName?.toLowerCase();
      return (
        tagName === "input"
        || tagName === "textarea"
        || element?.isContentEditable === true
      );
    }

    function restoreLift() {
      if (liftedElement) {
        if (originalTranslate) {
          liftedElement.style.setProperty(
            "translate",
            originalTranslate,
            originalTranslatePriority,
          );
        } else {
          liftedElement.style.removeProperty("translate");
        }
        liftedElement.style.removeProperty("will-change");
      }
      liftedElement = null;
      currentLift = 0;
    }

    function applyLift(lift) {
      const element = document.getElementById("app");
      if (!element) {
        return;
      }

      if (liftedElement !== element) {
        restoreLift();
        liftedElement = element;
        originalTranslate = element.style.getPropertyValue("translate");
        originalTranslatePriority = element.style.getPropertyPriority("translate");
      }

      currentLift = lift;
      element.style.setProperty("translate", `0 ${-lift}px`, "important");
      element.style.setProperty("will-change", "translate");
    }

    function updateKeyboardLift() {
      const key = orientationKey();
      const visibleBottom = viewport.height + viewport.offsetTop;
      let baseline = baselineHeights.get(key);
      if (!baseline) {
        baseline = Math.max(window.innerHeight, visibleBottom);
        baselineHeights.set(key, baseline);
      }

      const obscuredHeight = Math.max(0, baseline - visibleBottom);
      if (obscuredHeight < 80) {
        baselineHeights.set(
          key,
          Math.max(baseline, window.innerHeight, visibleBottom),
        );
        restoreLift();
        return;
      }

      if (
        key !== "landscape"
        || (!textEntryFocused() && currentLift === 0)
      ) {
        restoreLift();
        return;
      }

      applyLift(
        Math.round(Math.min(obscuredHeight, baseline * 0.7)),
      );
    }

    for (const eventName of ["resize", "scroll"]) {
      viewport.addEventListener(eventName, updateKeyboardLift);
    }
    window.addEventListener("resize", updateKeyboardLift);
    window.addEventListener("orientationchange", () => {
      restoreLift();
      baselineHeights.clear();
      setTimeout(updateKeyboardLift, 250);
    });
    document.addEventListener("focusin", () => {
      setTimeout(updateKeyboardLift, 50);
    });
    document.addEventListener("focusout", () => {
      setTimeout(updateKeyboardLift, 50);
    });
    window.addEventListener("pagehide", restoreLift, { once: true });

    baselineHeights.set(
      orientationKey(),
      Math.max(window.innerHeight, viewport.height + viewport.offsetTop),
    );
  }

  installLandscapeKeyboardLift();

  function mobileScreenIsPortrait() {
    const viewportWidth = (
      window.visualViewport?.width
      || document.documentElement.clientWidth
      || window.innerWidth
    );
    const viewportHeight = (
      window.visualViewport?.height
      || document.documentElement.clientHeight
      || window.innerHeight
    );
    if (viewportHeight >= viewportWidth * 1.08) {
      return true;
    }
    if (
      document.activeElement?.id === "keyboard-input-assist"
      && mobilePaneBaselineHeight >= viewportWidth * 1.08
    ) {
      return true;
    }
    if (viewportWidth >= viewportHeight * 1.08) {
      return false;
    }

    const orientationType = window.screen?.orientation?.type;
    if (typeof orientationType === "string") {
      return orientationType.startsWith("portrait");
    }

    if (typeof window.orientation === "number") {
      return Math.abs(window.orientation) % 180 === 0;
    }

    return window.innerHeight >= window.innerWidth;
  }

  function mobilePaneIsActive() {
    return isMobileTouchClient && mobileScreenIsPortrait();
  }

  function ensureMobilePaneChrome() {
    if (!isMobileTouchClient || !document.head) {
      return;
    }

    if (!document.getElementById("maxofon-mobile-pane-style")) {
      const style = document.createElement("style");
      style.id = "maxofon-mobile-pane-style";
      style.textContent = `
        body.maxofon-mobile-pane {
          overflow: hidden !important;
          background: #fff !important;
        }

        html.maxofon-mobile-starting body.maxofon-mobile-pane
          .video-container {
          opacity: 0 !important;
        }

        html.maxofon-mobile-starting body.maxofon-mobile-pane::after {
          content: "MAX";
          position: fixed;
          inset: 0;
          z-index: 2147483644;
          display: grid;
          place-items: center;
          background: #fff;
          color: #111827;
          font: 700 24px/1 system-ui, sans-serif;
          letter-spacing: 0;
          pointer-events: none;
        }

        body.maxofon-mobile-pane #app {
          width: 100vw !important;
          height: var(--maxofon-pane-viewport-height) !important;
          overflow: hidden !important;
        }

        body.maxofon-mobile-pane .video-container {
          width: 100% !important;
          height: 100% !important;
          overflow: hidden !important;
        }

        body.maxofon-mobile-pane .video-container #videoCanvas,
        body.maxofon-mobile-pane .video-container #stream,
        body.maxofon-mobile-pane .video-container #overlayInput {
          position: absolute !important;
          left: var(--maxofon-pane-layer-left) !important;
          top: var(--maxofon-pane-layer-top) !important;
          width: var(--maxofon-pane-layer-width) !important;
          height: var(--maxofon-pane-layer-height) !important;
          max-width: none !important;
          max-height: none !important;
          object-fit: fill !important;
        }

        .maxofon-mobile-control {
          position: fixed;
          z-index: 2147483645;
          display: none;
          width: 44px;
          height: 44px;
          padding: 0;
          border: 1px solid rgba(15, 23, 42, .14);
          border-radius: 8px;
          background: rgba(255, 255, 255, .94);
          box-shadow: 0 2px 10px rgba(15, 23, 42, .18);
          color: #0f172a;
          text-align: center;
          touch-action: manipulation;
          -webkit-tap-highlight-color: transparent;
          backdrop-filter: blur(12px);
          -webkit-backdrop-filter: blur(12px);
        }

        #maxofon-mobile-back {
          top: max(8px, env(safe-area-inset-top));
          left: max(8px, env(safe-area-inset-left));
          font: 400 32px/40px system-ui, sans-serif;
        }

        #maxofon-mobile-menu {
          left: max(10px, env(safe-area-inset-left));
          bottom: max(10px, env(safe-area-inset-bottom));
          font: 600 22px/42px system-ui, sans-serif;
        }

        body.maxofon-mobile-pane.maxofon-mobile-pane-chat
          #maxofon-mobile-back,
        body.maxofon-mobile-pane.maxofon-mobile-pane-media
          #maxofon-mobile-back {
          display: block;
        }

        body.maxofon-mobile-pane.maxofon-mobile-pane-list
          #maxofon-mobile-menu {
          display: block;
        }

        body.maxofon-mobile-pane .virtual-keyboard-button {
          display: none !important;
        }

        #maxofon-mobile-nav-scrim {
          position: fixed;
          inset: 0;
          z-index: 2147483646;
          display: none;
          background: rgba(15, 23, 42, .34);
          touch-action: none;
        }

        #maxofon-mobile-nav {
          position: fixed;
          inset: 0 auto 0 0;
          z-index: 2147483647;
          display: flex;
          width: min(280px, 82vw);
          padding:
            max(14px, env(safe-area-inset-top))
            0
            max(14px, env(safe-area-inset-bottom));
          flex-direction: column;
          overflow: hidden;
          background: #fff;
          box-shadow: 8px 0 28px rgba(15, 23, 42, .2);
          transform: translateX(-105%);
          transition: transform 180ms ease-out;
          touch-action: manipulation;
        }

        body.maxofon-mobile-nav-open #maxofon-mobile-nav-scrim {
          display: block;
        }

        body.maxofon-mobile-nav-open #maxofon-mobile-nav {
          transform: translateX(0);
        }

        #maxofon-mobile-nav-title {
          padding: 8px 20px 14px;
          color: #0f172a;
          font: 700 21px/28px system-ui, sans-serif;
        }

        .maxofon-mobile-nav-item {
          display: flex;
          width: 100%;
          min-height: 52px;
          padding: 0 20px;
          align-items: center;
          border: 0;
          border-radius: 0;
          background: transparent;
          color: #172033;
          font: 500 17px/24px system-ui, sans-serif;
          text-align: left;
          letter-spacing: 0;
          touch-action: manipulation;
        }

        .maxofon-mobile-nav-item:active {
          background: #eef6ff;
        }

        .maxofon-mobile-nav-separator {
          height: 1px;
          margin: 8px 20px;
          background: #e2e8f0;
        }

        .maxofon-mobile-nav-bottom {
          margin-top: auto;
        }
      `;
      document.head.append(style);
    }

    if (!document.body) {
      return;
    }

    if (!document.getElementById("maxofon-mobile-back")) {
      const button = document.createElement("button");
      button.id = "maxofon-mobile-back";
      button.className = "maxofon-mobile-control";
      button.type = "button";
      button.textContent = "‹";
      button.title = "Назад к чатам";
      button.setAttribute("aria-label", "Назад к чатам");
      for (const eventName of ["pointerdown", "touchstart"]) {
        button.addEventListener(eventName, (event) => {
          event.stopPropagation();
        });
      }
      button.addEventListener("click", (event) => {
        event.preventDefault();
        event.stopPropagation();
        returnToMobileChatList();
      });
      document.body.append(button);
    }

    if (!document.getElementById("maxofon-mobile-menu")) {
      const button = document.createElement("button");
      button.id = "maxofon-mobile-menu";
      button.className = "maxofon-mobile-control";
      button.type = "button";
      button.textContent = "☰";
      button.title = "Разделы MAX";
      button.setAttribute("aria-label", "Открыть разделы MAX");
      for (const eventName of ["pointerdown", "touchstart"]) {
        button.addEventListener(eventName, (event) => {
          event.stopPropagation();
        });
      }
      button.addEventListener("click", (event) => {
        event.preventDefault();
        event.stopPropagation();
        setMobileNavOpen(true);
      });
      document.body.append(button);
    }

    if (!document.getElementById("maxofon-mobile-nav")) {
      const scrim = document.createElement("div");
      scrim.id = "maxofon-mobile-nav-scrim";
      scrim.addEventListener("pointerdown", (event) => {
        event.preventDefault();
        event.stopPropagation();
        setMobileNavOpen(false);
      });

      const nav = document.createElement("nav");
      nav.id = "maxofon-mobile-nav";
      nav.setAttribute("aria-label", "Разделы MAX");

      const title = document.createElement("div");
      title.id = "maxofon-mobile-nav-title";
      title.textContent = "MAX";
      nav.append(title);

      const items = [
        ["all", "Чаты"],
        ["new", "Новые"],
        ["channels", "Каналы"],
        ["separator", ""],
        ["contacts", "Контакты"],
        ["calls", "Звонки"],
        ["settings", "Настройки"],
      ];
      for (const [action, label] of items) {
        if (action === "separator") {
          const separator = document.createElement("div");
          separator.className = "maxofon-mobile-nav-separator";
          nav.append(separator);
          continue;
        }

        const button = document.createElement("button");
        button.type = "button";
        button.className = "maxofon-mobile-nav-item";
        if (action === "settings") {
          button.classList.add("maxofon-mobile-nav-bottom");
        }
        button.dataset.maxofonNavAction = action;
        button.textContent = label;
        button.addEventListener("click", (event) => {
          event.preventDefault();
          event.stopPropagation();
          activateMobileNavItem(action);
        });
        nav.append(button);
      }

      document.body.append(scrim, nav);
    }
  }

  function setMobileNavOpen(open) {
    mobileNavOpen = Boolean(open && mobilePaneIsActive());
    document.body?.classList.toggle(
      "maxofon-mobile-nav-open",
      mobileNavOpen,
    );
  }

  function sendRemoteClick(x, y) {
    const input = window.webrtcInput;
    if (!input || typeof input._sendMouseState !== "function") {
      return false;
    }

    input.x = Math.round(x);
    input.y = Math.round(y);
    input.buttonMask = (input.buttonMask || 0) | 1;
    input._sendMouseState();
    setTimeout(() => {
      input.buttonMask &= ~1;
      input._sendMouseState?.();
    }, 100);
    return true;
  }

  function activateMobileNavItem(action) {
    const remoteHeight = mobilePaneLayout?.remoteHeight || 720;
    const contentTop = (
      mobilePaneLayout?.contentTop || maxWindowGeometry.contentTop
    );
    const positions = {
      all: contentTop + 38,
      new: contentTop + 102,
      channels: contentTop + 166,
      contacts: contentTop + 248,
      calls: contentTop + 314,
      settings: remoteHeight - contentTop,
    };
    const y = positions[action];
    if (typeof y !== "number") {
      return;
    }

    sendRemoteClick(38, y);
    setMobileNavOpen(false);
    setTimeout(() => {
      setMobilePaneMode("list");
    }, 120);
  }

  function clearMobilePaneLayout() {
    mobilePaneLayout = null;
    mobilePaneBaselineHeight = 0;
    mobileResolutionMatchedAt = 0;
    if (mobileChatsPrimeTimer !== null) {
      clearTimeout(mobileChatsPrimeTimer);
      mobileChatsPrimeTimer = null;
    }
    setMobileNavOpen(false);
    document.documentElement.classList.remove("maxofon-mobile-starting");
    if (!document.body) {
      return;
    }

    document.body.classList.remove(
      "maxofon-mobile-pane",
      "maxofon-mobile-pane-list",
      "maxofon-mobile-pane-chat",
      "maxofon-mobile-pane-media",
    );
    for (const property of [
      "--maxofon-pane-viewport-height",
      "--maxofon-pane-layer-left",
      "--maxofon-pane-layer-top",
      "--maxofon-pane-layer-width",
      "--maxofon-pane-layer-height",
    ]) {
      document.documentElement.style.removeProperty(property);
    }
  }

  function evenDimension(value) {
    const rounded = Math.max(2, Math.round(value));
    return rounded % 2 === 0 ? rounded : rounded - 1;
  }

  function requestRemoteResolution(width, height) {
    const canvas = document.getElementById("videoCanvas");
    const target = {
      width: evenDimension(width),
      height: evenDimension(height),
    };
    if (
      Number(canvas?.width) === target.width
      && Number(canvas?.height) === target.height
    ) {
      if (
        mobileResolutionRequest?.width !== target.width
        || mobileResolutionRequest?.height !== target.height
      ) {
        mobileResolutionRequest = {
          ...target,
          requestedAt: Date.now(),
        };
      }
      return;
    }

    const now = Date.now();
    if (
      mobileResolutionRequest?.width === target.width
      && mobileResolutionRequest?.height === target.height
      && now - mobileResolutionRequest.requestedAt < 1500
    ) {
      return;
    }

    mobileResolutionRequest = { ...target, requestedAt: now };
    mobileResolutionMatchedAt = 0;
    document.documentElement.classList.add("maxofon-mobile-starting");
    window.postMessage(
      {
        type: "setManualResolution",
        width: target.width,
        height: target.height,
      },
      window.location.origin,
    );
  }

  function resetMobileRemoteInput() {
    const input = window.webrtcInput;
    gesture = null;
    if (!input) {
      return;
    }

    for (const property of [
      "_longPressTimer",
      "_trackpadTapTimeout",
    ]) {
      cancelTimer(input, property);
    }
    input._longPressTouchIdentifier = null;
    input._trackpadGestureMode = null;
    input._trackpadLastScrollCentroid = null;
    input._touchScrollLastCentroid = null;
    input._isTwoFingerGesture = false;
    input._activeTouchIdentifier = null;
    input._activeTouches?.clear?.();
    input._trackpadTouches?.clear?.();
    input._trackpadLastTapTime = 0;
    if (input.buttonMask) {
      input.buttonMask = 0;
      input._sendMouseState?.();
    }
    releaseRemoteModifiers(input);
  }

  function primeMobileChatList() {
    if (
      !mobilePaneIsActive()
      || mobileChatsPrimedAt
      || !window.webrtcInput
    ) {
      return;
    }

    const contentTop = (
      mobilePaneLayout?.contentTop || maxWindowGeometry.contentTop
    );
    if (!sendRemoteClick(38, contentTop + 38)) {
      return;
    }

    mobileChatsPrimedAt = Date.now();
    mobilePaneMode = "list";
    setMobileNavOpen(false);
    scheduleMobilePaneLayout();
  }

  function scheduleMobileChatListPrime() {
    if (mobileChatsPrimedAt || mobileChatsPrimeTimer !== null) {
      return;
    }

    mobileChatsPrimeTimer = setTimeout(() => {
      mobileChatsPrimeTimer = null;
      primeMobileChatList();
    }, 180);
  }

  function portraitRemoteHeight(viewportWidth, viewportHeight) {
    const listEnd = Math.round(
      landscapeResolution.width * maxWindowGeometry.listEndRatio,
    );
    const conversationWidth = landscapeResolution.width - listEnd;
    const contentHeight = (
      conversationWidth * viewportHeight / Math.max(1, viewportWidth)
    );
    return evenDimension(Math.min(
      2400,
      Math.max(960, maxWindowGeometry.contentTop + contentHeight),
    ));
  }

  function updateMobilePaneLayout() {
    mobilePaneUpdateFrame = null;
    if (!mobilePaneIsActive()) {
      requestRemoteResolution(
        landscapeResolution.width,
        landscapeResolution.height,
      );
      clearMobilePaneLayout();
      return;
    }

    ensureMobilePaneChrome();
    const canvas = document.getElementById("videoCanvas");
    if (!canvas || !document.body) {
      return;
    }

    const viewport = window.visualViewport;
    const viewportWidth = Math.max(
      1,
      viewport?.width || document.documentElement.clientWidth || window.innerWidth,
    );
    const visibleTop = viewport?.offsetTop || 0;
    const visibleBottom = visibleTop + (
      viewport?.height || window.innerHeight
    );
    if (
      !mobilePaneBaselineHeight
      || visibleBottom >= mobilePaneBaselineHeight - 60
    ) {
      mobilePaneBaselineHeight = Math.max(
        mobilePaneBaselineHeight,
        window.innerHeight,
        visibleBottom,
      );
    }

    const targetHeight = portraitRemoteHeight(
      viewportWidth,
      mobilePaneBaselineHeight,
    );
    requestRemoteResolution(landscapeResolution.width, targetHeight);

    const remoteWidth = Math.max(1, Number(canvas.width) || 1280);
    const remoteHeight = Math.max(1, Number(canvas.height) || 720);
    const contentTop = maxWindowGeometry.contentTop;
    const sidebarEnd = Math.round(
      remoteWidth * maxWindowGeometry.sidebarEndRatio,
    );
    const listEnd = Math.round(
      remoteWidth * maxWindowGeometry.listEndRatio,
    );
    const mediaActive = (
      mobilePaneMode === "chat" && mobileMediaStateActive
    );
    const paneX = (
      mediaActive ? 0 : (mobilePaneMode === "chat" ? listEnd : sidebarEnd)
    );
    const paneWidth = (
      mediaActive
        ? remoteWidth
        : mobilePaneMode === "chat"
        ? remoteWidth - listEnd
        : listEnd - sidebarEnd
    );
    const visibleHeight = Math.max(1, visibleBottom - visibleTop);
    const widthScale = viewportWidth / Math.max(1, paneWidth);
    const scale = (
      mediaActive
        ? Math.min(widthScale, visibleHeight / remoteHeight)
        : widthScale
    );
    const layerWidth = remoteWidth * scale;
    const layerHeight = remoteHeight * scale;
    const viewportLeft = viewport?.offsetLeft || 0;
    const layerLeft = (
      mediaActive
        ? viewportLeft + (viewportWidth - layerWidth) / 2
        : viewportLeft - paneX * scale
    );
    const keyboardOpen = (
      document.activeElement?.id === "keyboard-input-assist"
      && mobilePaneBaselineHeight - visibleBottom >= 80
    );
    const layerTop = (
      mediaActive
        ? visibleTop + (visibleHeight - layerHeight) / 2
        : mobilePaneMode === "chat" && keyboardOpen
        ? visibleBottom - layerHeight
        : visibleTop - contentTop * scale
    );

    mobilePaneLayout = {
      contentTop,
      layerHeight,
      layerLeft,
      layerTop,
      listEnd,
      layerWidth,
      remoteHeight,
      remoteWidth,
      scale,
      sidebarEnd,
      splitX: listEnd,
    };

    const rootStyle = document.documentElement.style;
    rootStyle.setProperty(
      "--maxofon-pane-viewport-height",
      `${mobilePaneBaselineHeight}px`,
    );
    rootStyle.setProperty("--maxofon-pane-layer-left", `${layerLeft}px`);
    rootStyle.setProperty("--maxofon-pane-layer-top", `${layerTop}px`);
    rootStyle.setProperty("--maxofon-pane-layer-width", `${layerWidth}px`);
    rootStyle.setProperty("--maxofon-pane-layer-height", `${layerHeight}px`);
    document.body.classList.add("maxofon-mobile-pane");
    document.body.classList.toggle(
      "maxofon-mobile-pane-list",
      mobilePaneMode === "list",
    );
    document.body.classList.toggle(
      "maxofon-mobile-pane-chat",
      mobilePaneMode === "chat" && !mediaActive,
    );
    document.body.classList.toggle(
      "maxofon-mobile-pane-media",
      mediaActive,
    );

    const backButton = document.getElementById("maxofon-mobile-back");
    if (backButton) {
      const label = mediaActive ? "Закрыть фото" : "Назад к чатам";
      backButton.title = label;
      backButton.setAttribute("aria-label", label);
    }

    const targetMatches = (
      remoteWidth === landscapeResolution.width
      && remoteHeight === targetHeight
    );
    if (!targetMatches) {
      mobileResolutionMatchedAt = 0;
      document.documentElement.classList.add("maxofon-mobile-starting");
      return;
    }

    if (!mobileResolutionMatchedAt) {
      mobileResolutionMatchedAt = Date.now();
      setTimeout(scheduleMobilePaneLayout, 180);
    }
    scheduleMobileChatListPrime();

    const ready = (
      Date.now() - mobileResolutionMatchedAt >= 160
      && mobileChatsPrimedAt
      && Date.now() - mobileChatsPrimedAt >= 220
    );
    document.documentElement.classList.toggle(
      "maxofon-mobile-starting",
      !ready,
    );
    if (!ready) {
      setTimeout(scheduleMobilePaneLayout, 80);
    }
  }

  function scheduleMobilePaneLayout() {
    if (mobilePaneUpdateFrame !== null) {
      return;
    }
    mobilePaneUpdateFrame = requestAnimationFrame(updateMobilePaneLayout);
  }

  function setMobilePaneMode(mode, pushHistory = false) {
    if (mode !== "list" && mode !== "chat") {
      return;
    }

    mobilePaneMode = mode;
    setMobileNavOpen(false);
    if (pushHistory && mode === "chat") {
      const currentState = (
        history.state && typeof history.state === "object"
          ? history.state
          : {}
      );
      history.pushState(
        { ...currentState, maxofonMobilePane: "chat" },
        "",
      );
    }
    scheduleMobilePaneLayout();
  }

  function returnToMobileChatList() {
    if (mobileMediaStateActive) {
      mobileMediaStateActive = false;
      queueMobileKey(window.webrtcInput, 65307);
      scheduleMobilePaneLayout();
      return;
    }

    if (history.state?.maxofonMobilePane === "chat") {
      history.back();
      return;
    }
    setMobilePaneMode("list");
  }

  function mobilePanePoint(clientX, clientY) {
    if (!mobilePaneLayout || !mobilePaneIsActive()) {
      return null;
    }

    const x = (
      (clientX - mobilePaneLayout.layerLeft)
      * mobilePaneLayout.remoteWidth
      / mobilePaneLayout.layerWidth
    );
    const y = (
      (clientY - mobilePaneLayout.layerTop)
      * mobilePaneLayout.remoteHeight
      / mobilePaneLayout.layerHeight
    );
    return {
      x: Math.max(0, Math.min(mobilePaneLayout.remoteWidth, x)),
      y: Math.max(0, Math.min(mobilePaneLayout.remoteHeight, y)),
    };
  }

  function bridgeMobilePaneCoordinates(input) {
    if (
      !isMobileTouchClient
      || mobilePaneInputBridges.has(input)
      || typeof input._calculateTouchCoordinates !== "function"
    ) {
      return;
    }

    const nativeCalculateTouchCoordinates = (
      input._calculateTouchCoordinates.bind(input)
    );
    input._calculateTouchCoordinates = (point) => {
      nativeCalculateTouchCoordinates(point);
      const mapped = mobilePanePoint(point.clientX, point.clientY);
      if (mapped) {
        input.x = Math.round(mapped.x);
        input.y = Math.round(mapped.y);
      }
    };

    if (
      typeof input._clientToServerX === "function"
      && typeof input._clientToServerY === "function"
    ) {
      const nativeClientToServerX = input._clientToServerX.bind(input);
      const nativeClientToServerY = input._clientToServerY.bind(input);
      input._clientToServerX = (clientX) => (
        mobilePanePoint(clientX, 0)?.x ?? nativeClientToServerX(clientX)
      );
      input._clientToServerY = (clientY) => (
        mobilePanePoint(0, clientY)?.y ?? nativeClientToServerY(clientY)
      );
    }

    mobilePaneInputBridges.add(input);
  }

  function bridgeMobileCursorDetection(input) {
    if (
      !isMobileTouchClient
      || mobileCursorBridges.has(input)
      || typeof input.updateServerCursor !== "function"
    ) {
      return;
    }

    const nativeUpdateServerCursor = input.updateServerCursor.bind(input);
    input.updateServerCursor = (cursor) => {
      const width = Number(cursor?.width) || 0;
      const height = Number(cursor?.height) || 0;
      const hotX = Number(cursor?.hotx) || 0;
      const hotY = Number(cursor?.hoty) || 0;
      const hasCursor = Boolean(
        cursor?.curdata && Number.parseInt(cursor?.handle, 10) !== 0
      );

      mobileRemoteTextCursor = Boolean(
        hasCursor
        && width > 0
        && height > 0
        && hotX >= width * 0.3
        && hotX <= width * 0.7
        && hotY >= height * 0.35
        && hotY <= height * 0.7
      );
      return nativeUpdateServerCursor(cursor);
    };
    mobileCursorBridges.add(input);
  }

  function mobileTapTargetsTextField(source) {
    if (!source || !mobilePaneLayout) {
      return false;
    }

    if (mobileRemoteTextCursor) {
      return true;
    }

    if (
      mobilePaneMode === "chat"
      && source.x >= mobilePaneLayout.listEnd
      && source.y >= mobilePaneLayout.remoteHeight - 100
    ) {
      return true;
    }

    return (
      mobilePaneMode === "list"
      && source.x >= mobilePaneLayout.sidebarEnd
      && source.x < mobilePaneLayout.listEnd
      && source.y >= mobilePaneLayout.contentTop + 34
      && source.y <= mobilePaneLayout.contentTop + 112
    );
  }

  function syncMobileKeyboardForTap(source) {
    const assist = (
      lastInput?.keyboardInputAssist
      || document.getElementById("keyboard-input-assist")
    );
    if (!assist) {
      return;
    }

    if (mobileTapTargetsTextField(source)) {
      assist.focus({ preventScroll: true });
    } else if (document.activeElement === assist) {
      assist.blur();
    }
  }

  function installMobilePaneLayout() {
    if (!isMobileTouchClient) {
      return;
    }

    const initialize = () => {
      ensureMobilePaneChrome();
      scheduleMobilePaneLayout();
    };
    if (document.readyState === "loading") {
      document.addEventListener("DOMContentLoaded", initialize, { once: true });
    } else {
      initialize();
    }

    for (const eventName of ["resize", "orientationchange"]) {
      window.addEventListener(eventName, () => {
        if (eventName === "orientationchange") {
          mobilePaneBaselineHeight = 0;
        }
        scheduleMobilePaneLayout();
      });
    }
    for (const eventName of ["resize", "scroll"]) {
      window.visualViewport?.addEventListener(
        eventName,
        scheduleMobilePaneLayout,
      );
    }
    document.addEventListener("focusin", () => {
      setTimeout(scheduleMobilePaneLayout, 50);
    });
    document.addEventListener("focusout", () => {
      setTimeout(scheduleMobilePaneLayout, 50);
    });
    const restoreAfterResume = () => {
      if (document.visibilityState === "hidden") {
        return;
      }

      resetMobileRemoteInput();
      mobilePaneBaselineHeight = 0;
      mobileResolutionRequest = null;
      mobileResolutionMatchedAt = 0;
      if (mobileScreenIsPortrait()) {
        document.documentElement.classList.add("maxofon-mobile-starting");
      }
      for (const delay of [0, 60, 180, 420, 900]) {
        setTimeout(() => {
          if (document.visibilityState !== "hidden") {
            scheduleMobilePaneLayout();
          }
        }, delay);
      }
    };
    document.addEventListener("visibilitychange", restoreAfterResume);
    window.addEventListener("pageshow", restoreAfterResume);
    window.addEventListener("popstate", (event) => {
      setMobilePaneMode(
        event.state?.maxofonMobilePane === "chat" ? "chat" : "list",
      );
    });
  }

  installMobilePaneLayout();

  function relativeEndpoint(path) {
    const endpoint = new URL(path, window.location.href);
    endpoint.search = "";
    endpoint.hash = "";
    return endpoint.href;
  }

  function scheduleMobileMediaState(delay = 450) {
    if (!isMobileTouchClient) {
      return;
    }
    if (mobileMediaStateTimer !== null) {
      clearTimeout(mobileMediaStateTimer);
    }
    mobileMediaStateTimer = setTimeout(checkMobileMediaState, delay);
  }

  async function checkMobileMediaState() {
    mobileMediaStateTimer = null;
    if (mobileMediaStatePending) {
      scheduleMobileMediaState();
      return;
    }

    if (
      document.visibilityState === "hidden"
      || !mobilePaneIsActive()
    ) {
      if (mobileMediaStateActive) {
        mobileMediaStateActive = false;
        scheduleMobilePaneLayout();
      }
      scheduleMobileMediaState(1500);
      return;
    }

    mobileMediaStatePending = true;
    try {
      const response = await fetch(relativeEndpoint("media-state"), {
        credentials: "same-origin",
        cache: "no-store",
        redirect: "error",
      });
      if (!response.ok) {
        throw new Error(`Media state returned HTTP ${response.status}.`);
      }
      const payload = await response.json();
      const active = Boolean(payload?.active);
      if (active !== mobileMediaStateActive) {
        mobileMediaStateActive = active;
        scheduleMobilePaneLayout();
      }
    } catch (error) {
      console.warn("Maxofon: media state check failed.", error);
    } finally {
      mobileMediaStatePending = false;
      scheduleMobileMediaState();
    }
  }

  if (isMobileTouchClient) {
    scheduleMobileMediaState(250);
    document.addEventListener("visibilitychange", () => {
      scheduleMobileMediaState(100);
    });
  }

  function mobileInputEndpoint() {
    return relativeEndpoint("input");
  }

  function base64UrlToUint8Array(value) {
    const padding = "=".repeat((4 - (value.length % 4)) % 4);
    const base64 = (value + padding).replace(/-/g, "+").replace(/_/g, "/");
    const raw = atob(base64);
    return Uint8Array.from(raw, (character) => character.charCodeAt(0));
  }

  async function savePushSubscription(subscription) {
    const response = await fetch(relativeEndpoint("push/subscribe"), {
      method: "POST",
      credentials: "same-origin",
      cache: "no-store",
      redirect: "error",
      headers: {
        "Content-Type": "application/json; charset=utf-8",
      },
      body: JSON.stringify(subscription.toJSON()),
    });

    if (!response.ok) {
      throw new Error(`Push subscribe returned HTTP ${response.status}.`);
    }
  }

  function showPushButton(onClick) {
    if (!document.body || document.getElementById("maxofon-enable-push")) {
      return null;
    }

    const button = document.createElement("button");
    button.id = "maxofon-enable-push";
    button.type = "button";
    button.textContent = "Включить уведомления";
    button.style.cssText = [
      "position:fixed",
      "top:max(8px,env(safe-area-inset-top))",
      "left:50%",
      "z-index:2147483646",
      "min-height:40px",
      "max-width:calc(100vw - 24px)",
      "padding:8px 14px",
      "transform:translateX(-50%)",
      "border:1px solid rgba(255,255,255,.28)",
      "border-radius:7px",
      "background:#126fe8",
      "box-shadow:0 2px 10px rgba(0,0,0,.28)",
      "color:#fff",
      "font:600 14px system-ui,sans-serif",
      "letter-spacing:0",
      "white-space:nowrap",
    ].join(";");
    button.addEventListener("click", onClick);
    document.body.append(button);
    return button;
  }

  async function installWebPush() {
    if (
      !("serviceWorker" in navigator)
      || !("Notification" in window)
      || !("PushManager" in window)
    ) {
      return;
    }

    try {
      const registration = await navigator.serviceWorker.register(
        "./polmira-sw.js?v=20260723-push1",
        { scope: "./" },
      );
      await registration.update();

      const existing = await registration.pushManager.getSubscription();
      if (existing) {
        await savePushSubscription(existing);
        return;
      }

      let button = null;
      const enable = async () => {
        const permission = await Notification.requestPermission();

        if (permission !== "granted") {
          if (button) {
            button.textContent = "Разреши уведомления в настройках";
            button.disabled = true;
          }
          return;
        }

        if (button) {
          button.textContent = "Подключаю уведомления...";
          button.disabled = true;
        }

        try {
          const keyResponse = await fetch(relativeEndpoint("push/public-key"), {
            credentials: "same-origin",
            cache: "no-store",
            redirect: "error",
          });
          if (!keyResponse.ok) {
            throw new Error(`Push key returned HTTP ${keyResponse.status}.`);
          }

          const keyPayload = await keyResponse.json();
          const subscription = await registration.pushManager.subscribe({
            userVisibleOnly: true,
            applicationServerKey: base64UrlToUint8Array(keyPayload.publicKey),
          });
          await savePushSubscription(subscription);

          if (button) {
            button.textContent = "Уведомления включены";
            setTimeout(() => button?.remove(), 1600);
          }
        } catch (error) {
          console.error("Maxofon: Web Push setup failed.", error);
          if (button) {
            button.textContent = "Не удалось включить уведомления";
            button.disabled = false;
          }
        }
      };

      const addButton = () => {
        button = showPushButton(enable);
      };
      if (document.body) {
        addButton();
      } else {
        document.addEventListener("DOMContentLoaded", addButton, { once: true });
      }
    } catch (error) {
      console.error("Maxofon: service worker setup failed.", error);
    }
  }

  installWebPush();

  function encodeUtf8Base64(text) {
    const bytes = new TextEncoder().encode(text);
    let binary = "";
    for (let offset = 0; offset < bytes.length; offset += 0x8000) {
      binary += String.fromCharCode(
        ...bytes.subarray(offset, offset + 0x8000),
      );
    }
    return btoa(binary);
  }

  function sendMobileTextDirect(text) {
    const input = window.webrtcInput;
    if (!input || typeof input.send !== "function") {
      return false;
    }

    try {
      input.send(`MAXOFON_UTF8,${encodeUtf8Base64(text)}`);
      return true;
    } catch (error) {
      console.warn(
        "Maxofon: direct UTF-8 input unavailable, using fallback.",
        error,
      );
      return false;
    }
  }

  function sendMobileKeyDirect(keysym) {
    const input = window.webrtcInput;
    if (!input || typeof input.send !== "function") {
      return false;
    }

    try {
      input.send(`MAXOFON_KEY,${keysym}`);
      return true;
    } catch (error) {
      console.warn(
        "Maxofon: direct key input unavailable, using fallback.",
        error,
      );
      return false;
    }
  }

  async function postMobileText(text, attempt = 0) {
    if (attempt === 0 && sendMobileTextDirect(text)) {
      return;
    }

    try {
      const response = await fetch(mobileInputEndpoint(), {
        method: "POST",
        credentials: "same-origin",
        cache: "no-store",
        redirect: "error",
        headers: {
          "Content-Type": "text/plain; charset=utf-8",
        },
        body: text,
      });
      if (response.status !== 204) {
        throw new Error(`Text input returned HTTP ${response.status}.`);
      }
    } catch (error) {
      if (attempt >= 4) {
        throw error;
      }
      await new Promise((resolve) => {
        setTimeout(resolve, Math.min(250 * (attempt + 1), 1000));
      });
      await postMobileText(text, attempt + 1);
    }
  }

  function processMobileInputJobs() {
    if (mobileInputProcessing || mobileInputJobs.length === 0) {
      return mobileTextPipeline;
    }

    mobileInputProcessing = true;
    mobileTextPipeline = (async () => {
      try {
        while (mobileInputJobs.length > 0) {
          const job = mobileInputJobs.shift();
          if (job.type === "key") {
            if (!sendMobileKeyDirect(job.keysym)) {
              job.input?._guac_press?.(job.keysym);
              await new Promise((resolve) => setTimeout(resolve, 5));
              job.input?._guac_release?.(job.keysym);
            }
            continue;
          }

          try {
            await postMobileText(job.text);
          } catch (error) {
            console.error("Maxofon: UTF-8 text input failed.", error);
            try {
              job.fallback?.(job.text);
            } catch (fallbackError) {
              console.error(
                "Maxofon: fallback text input failed.",
                fallbackError,
              );
            }
          }
        }
      } finally {
        mobileInputProcessing = false;
        if (mobileInputJobs.length > 0) {
          processMobileInputJobs();
        }
      }
    })();
    return mobileTextPipeline;
  }

  function flushMobileText() {
    if (mobileTextFlushTimer !== null) {
      clearTimeout(mobileTextFlushTimer);
      mobileTextFlushTimer = null;
    }

    const text = pendingMobileText;
    const fallback = pendingMobileTextFallback;
    pendingMobileText = "";
    pendingMobileTextFallback = null;
    if (text) {
      const lastJob = mobileInputJobs[mobileInputJobs.length - 1];
      if (lastJob?.type === "text") {
        lastJob.text += text;
        lastJob.fallback = fallback || lastJob.fallback;
      } else {
        mobileInputJobs.push({ type: "text", text, fallback });
      }
    }

    return processMobileInputJobs();
  }

  function queueMobileText(text, fallback) {
    if (!text) {
      return;
    }

    pendingMobileText += text;
    pendingMobileTextFallback = fallback;
    if (mobileTextFlushTimer !== null) {
      clearTimeout(mobileTextFlushTimer);
    }

    mobileTextFlushTimer = setTimeout(flushMobileText, 12);
  }

  function queueMobileKey(input, keysym) {
    flushMobileText();
    mobileInputJobs.push({ type: "key", input, keysym });
    processMobileInputJobs();
  }

  function mobileAssistCodePoints(value) {
    return [...String(value || "")];
  }

  function placeMobileAssistCaretAtEnd(assist) {
    const end = String(assist.value || "").length;
    try {
      assist.setSelectionRange(end, end);
    } catch (error) {
      // Some iOS input modes do not expose a selectable text range.
    }
  }

  function configureMobileAssist(assist) {
    assist.type = "text";
    assist.setAttribute("inputmode", "text");
    assist.setAttribute("enterkeyhint", "send");
    assist.setAttribute("autocomplete", "off");
    assist.setAttribute("autocorrect", "on");
    assist.setAttribute("autocapitalize", "sentences");
    assist.setAttribute("spellcheck", "true");
  }

  function ensureMobileAssistState(assist) {
    configureMobileAssist(assist);
    let state = mobileAssistStates.get(assist);
    if (!state) {
      const value = String(assist.value || "") || mobileAssistSeed;
      assist.value = value;
      state = { value };
      mobileAssistStates.set(assist, state);
      placeMobileAssistCaretAtEnd(assist);
      return state;
    }

    if (!assist.value) {
      assist.value = mobileAssistSeed;
      state.value = mobileAssistSeed;
      placeMobileAssistCaretAtEnd(assist);
    }
    return state;
  }

  function setMobileAssistValue(assist, state, value) {
    assist.value = value || mobileAssistSeed;
    state.value = assist.value;
    placeMobileAssistCaretAtEnd(assist);
  }

  function trimPendingMobileTextCharacter() {
    if (!pendingMobileText) {
      return false;
    }

    const characters = mobileAssistCodePoints(pendingMobileText);
    characters.pop();
    pendingMobileText = characters.join("");
    if (!pendingMobileText && mobileTextFlushTimer !== null) {
      clearTimeout(mobileTextFlushTimer);
      mobileTextFlushTimer = null;
    }
    return true;
  }

  function queueMobileBackspaces(count) {
    let remaining = Math.max(0, Number(count) || 0);
    while (remaining > 0 && trimPendingMobileTextCharacter()) {
      remaining -= 1;
    }
    while (remaining > 0) {
      queueMobileKey(window.webrtcInput, 65288);
      remaining -= 1;
    }
  }

  function mobileAssistDiff(previousValue, currentValue) {
    const previous = mobileAssistCodePoints(previousValue);
    const current = mobileAssistCodePoints(currentValue);
    let prefixLength = 0;
    while (
      prefixLength < previous.length
      && prefixLength < current.length
      && previous[prefixLength] === current[prefixLength]
    ) {
      prefixLength += 1;
    }

    return {
      added: current.slice(prefixLength).join(""),
      removed: previous.length - prefixLength,
    };
  }

  function resetMobileAssistSentence(assist) {
    const state = ensureMobileAssistState(assist);
    setMobileAssistValue(assist, state, mobileAssistSeed);
  }

  function handleMobileAssistDeletion(event) {
    const assist = event.target;
    const state = ensureMobileAssistState(assist);
    const characters = mobileAssistCodePoints(state.value);
    const seedLength = mobileAssistCodePoints(mobileAssistSeed).length;
    let removeCount = 1;

    if (
      Number.isInteger(assist.selectionStart)
      && Number.isInteger(assist.selectionEnd)
      && assist.selectionEnd > assist.selectionStart
    ) {
      removeCount = mobileAssistCodePoints(
        state.value.slice(assist.selectionStart, assist.selectionEnd),
      ).length;
    } else if (String(event.inputType || "").includes("Word")) {
      const editable = characters.slice(seedLength);
      let wordLength = 0;
      while (editable.length > 0) {
        const character = editable.pop();
        wordLength += 1;
        if (/\s/u.test(character) && wordLength > 1) {
          break;
        }
      }
      removeCount = Math.max(1, wordLength);
    }

    const editableLength = Math.max(0, characters.length - seedLength);
    const localRemoveCount = Math.min(removeCount, editableLength);
    if (localRemoveCount > 0) {
      characters.splice(characters.length - localRemoveCount);
      setMobileAssistValue(assist, state, characters.join(""));
    } else {
      setMobileAssistValue(assist, state, state.value);
    }
    queueMobileBackspaces(removeCount);
  }

  function bridgeMobileTextInput(input) {
    if (
      !isMobileTouchClient
      || textInputBridges.has(input)
      || typeof input._typeString !== "function"
    ) {
      return;
    }

    const nativeTypeString = input._typeString.bind(input);
    input._typeString = (text) => {
      queueMobileText(String(text || ""), nativeTypeString);
    };
    textInputBridges.add(input);
    console.log("Maxofon: lossless mobile UTF-8 input enabled.");
  }

  function bridgeMobileAssistInput(input) {
    const assist = (
      input?.keyboardInputAssist
      || document.getElementById("keyboard-input-assist")
    );
    if (
      !isMobileTouchClient
      || !assist
      || mobileAssistInputBridges.has(assist)
    ) {
      return;
    }

    ensureMobileAssistState(assist);

    assist.addEventListener("beforeinput", (event) => {
      const inputType = String(event.inputType || "");
      if (inputType.startsWith("delete")) {
        event.preventDefault();
        event.stopImmediatePropagation();
        handleMobileAssistDeletion(event);
        return;
      }

      if (inputType === "insertLineBreak" || inputType === "insertParagraph") {
        event.preventDefault();
        event.stopImmediatePropagation();
        queueMobileKey(window.webrtcInput, 65293);
        resetMobileAssistSentence(assist);
      }
    }, true);

    assist.addEventListener("input", (event) => {
      const state = ensureMobileAssistState(assist);
      let currentValue = String(event.target?.value || "");
      const inputType = String(event.inputType || "");
      event.stopImmediatePropagation();

      if (inputType.startsWith("delete")) {
        const previousCharacters = mobileAssistCodePoints(state.value);
        const currentCharacters = mobileAssistCodePoints(currentValue);
        const seedLength = mobileAssistCodePoints(mobileAssistSeed).length;
        const previousEditableLength = Math.max(
          0,
          previousCharacters.length - seedLength,
        );
        const currentEditableLength = (
          currentValue.startsWith(mobileAssistSeed)
            ? Math.max(0, currentCharacters.length - seedLength)
            : 0
        );
        const removeCount = (
          previousEditableLength > 0
            ? Math.max(1, previousEditableLength - currentEditableLength)
            : 1
        );
        queueMobileBackspaces(removeCount);
        setMobileAssistValue(
          assist,
          state,
          currentValue.startsWith(mobileAssistSeed)
            ? currentValue
            : mobileAssistSeed,
        );
        return;
      }

      if (!currentValue) {
        setMobileAssistValue(assist, state, mobileAssistSeed);
        return;
      }

      let previousValue = state.value;
      if (
        previousValue === mobileAssistSeed
        && !currentValue.startsWith(mobileAssistSeed)
      ) {
        previousValue = "";
      }
      const diff = mobileAssistDiff(previousValue, currentValue);
      if (diff.removed > 0) {
        queueMobileBackspaces(diff.removed);
      }
      if (diff.added) {
        queueMobileText(diff.added);
      }

      if (mobileAssistCodePoints(currentValue).length > 512) {
        const tail = mobileAssistCodePoints(currentValue).slice(-256).join("");
        currentValue = `${mobileAssistSeed}${tail}`;
      }
      setMobileAssistValue(assist, state, currentValue);
    }, true);

    mobileAssistInputBridges.add(assist);
    console.log("Maxofon: native mobile text events use UTF-8 input.");
  }

  function releaseRemoteModifiers(input = window.webrtcInput) {
    for (const keysym of remoteModifierKeysyms) {
      input?._guac_release?.(keysym);
    }
  }

  function stopMobileAssistModifier(event) {
    if (
      !isMobileTouchClient
      || event.target?.id !== "keyboard-input-assist"
      || !mobileAssistModifierKeys.has(event.key)
    ) {
      return;
    }

    // Keep the browser default so iOS can compose uppercase and symbols, but
    // do not let Selkies forward the modifier into the remote X11 session.
    event.stopImmediatePropagation();
  }

  function stopMobileAssistPrintableKey(event) {
    if (
      !isMobileTouchClient
      || event.target?.id !== "keyboard-input-assist"
      || typeof event.key !== "string"
      || [...event.key].length !== 1
    ) {
      return;
    }

    // The resulting character arrives through the input event. Forwarding
    // this key event as well would reintroduce layout-dependent Shift bugs.
    event.stopImmediatePropagation();
  }

  window.addEventListener("keydown", stopMobileAssistModifier, true);
  window.addEventListener("keyup", stopMobileAssistModifier, true);
  window.addEventListener("keydown", stopMobileAssistPrintableKey, true);
  window.addEventListener("keyup", stopMobileAssistPrintableKey, true);

  document.addEventListener("focusin", (event) => {
    if (
      isMobileTouchClient
      && event.target?.id === "keyboard-input-assist"
    ) {
      ensureMobileAssistState(event.target);
      releaseRemoteModifiers();
    }
  }, true);

  window.addEventListener("keydown", (event) => {
    if (
      !isMobileTouchClient
      || event.target?.id !== "keyboard-input-assist"
      || (event.key !== "Enter" && event.key !== "Backspace")
    ) {
      return;
    }

    event.preventDefault();
    event.stopImmediatePropagation();

    if (event.key === "Backspace") {
      handleMobileAssistDeletion(event);
      return;
    }

    queueMobileKey(window.webrtcInput, 65293);
    resetMobileAssistSentence(event.target);
  }, true);

  function changedTouch(event, identifier) {
    for (const touch of event.changedTouches) {
      if (touch.identifier === identifier) {
        return touch;
      }
    }
    return null;
  }

  function cancelTimer(input, property) {
    if (input?.[property]) {
      clearTimeout(input[property]);
      input[property] = null;
    }
  }

  function suppressNativeGesture(input, identifier, touch, finished = false) {
    if (!input) {
      return;
    }

    cancelTimer(input, "_longPressTimer");
    cancelTimer(input, "_trackpadTapTimeout");
    input._longPressTouchIdentifier = null;
    input._trackpadLastTapTime = 0;

    const trackpadTouch = input._trackpadTouches?.get(identifier);
    if (trackpadTouch) {
      trackpadTouch.moved = true;
      trackpadTouch.lastX = touch.clientX;
      trackpadTouch.lastY = touch.clientY;
    }

    const activeTouch = input._activeTouches?.get(identifier);
    if (activeTouch) {
      activeTouch.currentX = touch.clientX;
      activeTouch.currentY = touch.clientY;
      activeTouch.longPressCompleted = true;
    }

    if (!finished) {
      return;
    }

    input._trackpadTouches?.delete(identifier);
    input._activeTouches?.delete(identifier);
    if (input._activeTouchIdentifier === identifier) {
      input._activeTouchIdentifier = null;
    }
    input._trackpadGestureMode = null;
    input._trackpadLastScrollCentroid = null;
    input._touchScrollLastCentroid = null;
    input._isTwoFingerGesture = false;

    if ((input.buttonMask & 1) !== 0) {
      input.buttonMask &= ~1;
      input._sendMouseState?.();
    }
  }

  function onTouchStart(event) {
    unlockAudio();

    if (event.touches.length !== 1 || event.changedTouches.length !== 1) {
      gesture = null;
      return;
    }

    const touch = event.changedTouches[0];
    const source = mobilePanePoint(touch.clientX, touch.clientY);
    gesture = {
      backCandidate: (
        mobilePaneIsActive()
        && mobilePaneMode === "chat"
        && touch.clientX <= 30
      ),
      backSwiping: false,
      identifier: touch.identifier,
      lastX: touch.clientX,
      startX: touch.clientX,
      startY: touch.clientY,
      lastY: touch.clientY,
      lastScrollAt: 0,
      remainder: 0,
      scrolling: false,
      source,
    };

    const input = window.webrtcInput;
    if (source && input === lastInput) {
      input.x = Math.round(source.x);
      input.y = Math.round(source.y);
      input._sendMouseState?.();
    }
  }

  function onTouchMove(event) {
    const input = window.webrtcInput;
    if (!gesture || event.touches.length !== 1 || input !== lastInput) {
      return;
    }

    const touch = changedTouch(event, gesture.identifier);
    if (!touch) {
      return;
    }

    const totalX = touch.clientX - gesture.startX;
    const totalY = touch.clientY - gesture.startY;

    if (
      gesture.backCandidate
      && !gesture.scrolling
      && totalX >= 12
      && Math.abs(totalX) >= Math.abs(totalY) * 1.2
    ) {
      gesture.backSwiping = true;
    }

    if (gesture.backSwiping) {
      event.preventDefault();
      event.stopImmediatePropagation();
      suppressNativeGesture(input, gesture.identifier, touch);
      gesture.lastX = touch.clientX;
      gesture.lastY = touch.clientY;
      return;
    }

    if (
      gesture.backCandidate
      && Math.abs(totalY) >= 12
      && Math.abs(totalY) > Math.abs(totalX)
    ) {
      gesture.backCandidate = false;
    }

    if (
      !gesture.scrolling
      && Math.abs(totalY) >= 4
      && Math.abs(totalY) >= Math.abs(totalX) * 0.8
    ) {
      gesture.scrolling = true;
    }

    if (!gesture.scrolling) {
      return;
    }

    event.preventDefault();
    event.stopImmediatePropagation();
    suppressNativeGesture(input, gesture.identifier, touch);

    gesture.remainder += touch.clientY - gesture.lastY;
    gesture.lastY = touch.clientY;

    const now = performance.now();
    const pixelsPerStep = 36;
    if (
      Math.abs(gesture.remainder) < pixelsPerStep
      || now - gesture.lastScrollAt < 28
      || typeof input._triggerMouseWheel !== "function"
    ) {
      return;
    }

    const direction = gesture.remainder < 0 ? "down" : "up";
    input._triggerMouseWheel(direction, 1);
    gesture.remainder += (
      gesture.remainder < 0 ? pixelsPerStep : -pixelsPerStep
    );
    gesture.lastScrollAt = now;
  }

  function onTouchEnd(event) {
    if (!gesture || !changedTouch(event, gesture.identifier)) {
      return;
    }

    const touch = changedTouch(event, gesture.identifier);
    const totalX = touch.clientX - gesture.startX;
    const totalY = touch.clientY - gesture.startY;

    if (gesture.backSwiping) {
      event.preventDefault();
      event.stopImmediatePropagation();
      suppressNativeGesture(
        window.webrtcInput,
        gesture.identifier,
        touch,
        true,
      );
      if (totalX >= 64) {
        returnToMobileChatList();
      }
    } else if (gesture.scrolling) {
      event.preventDefault();
      event.stopImmediatePropagation();
      suppressNativeGesture(
        window.webrtcInput,
        gesture.identifier,
        touch,
        true,
      );
    } else if (
      event.type === "touchend"
      && mobilePaneIsActive()
      && mobilePaneMode === "list"
      && Math.abs(totalX) < 12
      && Math.abs(totalY) < 12
      && gesture.source
      && gesture.source.x >= (mobilePaneLayout?.sidebarEnd || 0)
      && gesture.source.x < (mobilePaneLayout?.splitX || 0)
      && gesture.source.y >= (
        (mobilePaneLayout?.contentTop || maxWindowGeometry.contentTop) + 96
      )
    ) {
      event.preventDefault();
      event.stopImmediatePropagation();
      suppressNativeGesture(
        window.webrtcInput,
        gesture.identifier,
        touch,
        true,
      );
      sendRemoteClick(gesture.source.x, gesture.source.y);
      setTimeout(() => {
        if (mobilePaneMode === "list" && mobilePaneIsActive()) {
          setMobilePaneMode("chat", true);
        }
      }, 220);
    } else if (
      event.type === "touchend"
      && mobilePaneIsActive()
      && Math.abs(totalX) < 12
      && Math.abs(totalY) < 12
    ) {
      syncMobileKeyboardForTap(gesture.source);
    }
    gesture = null;
  }

  function detachInput() {
    if (!lastElement) {
      return;
    }

    lastElement.removeEventListener("touchstart", onTouchStart, true);
    lastElement.removeEventListener("touchmove", onTouchMove, true);
    lastElement.removeEventListener("touchend", onTouchEnd, true);
    lastElement.removeEventListener("touchcancel", onTouchEnd, true);
    lastElement = null;
    lastInput = null;
    gesture = null;
  }

  function attachInput() {
    const input = window.webrtcInput;
    const element = input?.element;
    if (!input || !element) {
      return;
    }
    if (input === lastInput && element === lastElement) {
      bridgeMobileAssistInput(input);
      scheduleMobileChatListPrime();
      return;
    }

    detachInput();
    lastInput = input;
    lastElement = element;
    bridgeMobileTextInput(input);
    bridgeMobileAssistInput(input);
    bridgeMobilePaneCoordinates(input);
    bridgeMobileCursorDetection(input);
    scheduleMobileChatListPrime();
    element.addEventListener("touchstart", onTouchStart, {
      capture: true,
      passive: false,
    });
    element.addEventListener("touchmove", onTouchMove, {
      capture: true,
      passive: false,
    });
    element.addEventListener("touchend", onTouchEnd, {
      capture: true,
      passive: false,
    });
    element.addEventListener("touchcancel", onTouchEnd, {
      capture: true,
      passive: false,
    });
    console.log("Maxofon: one-finger scrolling enabled.");
  }

  for (const eventName of ["pointerdown", "touchstart", "click", "keydown"]) {
    document.addEventListener(eventName, unlockAudio, {
      capture: true,
      passive: true,
    });
  }

  attachInput();
  nativeSetInterval(attachInput, 100);
  nativeSetInterval(scheduleMobilePaneLayout, 500);
  window.addEventListener("pagehide", detachInput, { once: true });
})();
