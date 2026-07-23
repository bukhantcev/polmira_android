(() => {
  "use strict";

  const audioContexts = new Set();
  const audioWorkerBlobs = new WeakSet();
  const audioWorkerUrls = new Set();
  const boostedAudioOutputs = new WeakMap();
  const textInputBridges = new WeakSet();
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
  const pageSessionId = (
    crypto.randomUUID?.()
    || `${Date.now()}-${Math.random().toString(16).slice(2)}`
  );
  let lastInput = null;
  let lastElement = null;
  let gesture = null;
  let pendingMobileText = "";
  let pendingMobileTextFallback = null;
  let mobileTextFlushTimer = null;
  let mobileTextPipeline = Promise.resolve();
  let sessionDisplaced = sessionStorage.getItem(displacedStorageKey) === "1";
  let hiddenAt = 0;

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

  function relativeEndpoint(path) {
    const endpoint = new URL(path, window.location.href);
    endpoint.search = "";
    endpoint.hash = "";
    return endpoint.href;
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

  async function postMobileText(text, attempt = 0) {
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

  function flushMobileText() {
    if (mobileTextFlushTimer !== null) {
      clearTimeout(mobileTextFlushTimer);
      mobileTextFlushTimer = null;
    }

    const text = pendingMobileText;
    const fallback = pendingMobileTextFallback;
    pendingMobileText = "";
    pendingMobileTextFallback = null;
    if (!text) {
      return mobileTextPipeline;
    }

    mobileTextPipeline = mobileTextPipeline.then(async () => {
      try {
        await postMobileText(text);
      } catch (error) {
        console.error("Maxofon: UTF-8 text input failed.", error);
        fallback?.(text);
      }
    });
    return mobileTextPipeline;
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

    const completesFragment = /[\s!?.,;:…]$/u.test(text);
    mobileTextFlushTimer = setTimeout(
      flushMobileText,
      completesFragment ? 0 : 50,
    );
  }

  function queueMobileKey(input, keysym) {
    flushMobileText();
    mobileTextPipeline = mobileTextPipeline.then(async () => {
      input?._guac_press?.(keysym);
      await new Promise((resolve) => setTimeout(resolve, 5));
      input?._guac_release?.(keysym);
    });
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

  document.addEventListener("keydown", (event) => {
    if (
      !isMobileTouchClient
      || event.target?.id !== "keyboard-input-assist"
      || (event.key !== "Enter" && event.key !== "Backspace")
    ) {
      return;
    }

    event.preventDefault();
    event.stopImmediatePropagation();

    if (event.key === "Backspace" && pendingMobileText) {
      const characters = [...pendingMobileText];
      characters.pop();
      pendingMobileText = characters.join("");
      if (!pendingMobileText && mobileTextFlushTimer !== null) {
        clearTimeout(mobileTextFlushTimer);
        mobileTextFlushTimer = null;
      }
      return;
    }

    queueMobileKey(
      window.webrtcInput,
      event.key === "Enter" ? 65293 : 65288,
    );
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
    gesture = {
      identifier: touch.identifier,
      startX: touch.clientX,
      startY: touch.clientY,
      lastY: touch.clientY,
      remainder: 0,
      scrolling: false,
    };
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

    const pixelsPerStep = 12;
    const steps = Math.min(
      3,
      Math.floor(Math.abs(gesture.remainder) / pixelsPerStep),
    );
    if (steps < 1 || typeof input._triggerMouseWheel !== "function") {
      return;
    }

    input._triggerMouseWheel(gesture.remainder < 0 ? "down" : "up", steps);
    gesture.remainder %= pixelsPerStep;
  }

  function onTouchEnd(event) {
    if (!gesture || !changedTouch(event, gesture.identifier)) {
      return;
    }

    if (gesture.scrolling) {
      const touch = changedTouch(event, gesture.identifier);
      event.preventDefault();
      event.stopImmediatePropagation();
      suppressNativeGesture(
        window.webrtcInput,
        gesture.identifier,
        touch,
        true,
      );
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
    if (!input || !element || (input === lastInput && element === lastElement)) {
      return;
    }

    detachInput();
    lastInput = input;
    lastElement = element;
    bridgeMobileTextInput(input);
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

  nativeSetInterval(attachInput, 500);
  window.addEventListener("pagehide", detachInput, { once: true });
})();
