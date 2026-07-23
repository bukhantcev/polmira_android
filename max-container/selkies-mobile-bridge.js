(() => {
  "use strict";

  const audioContexts = new Set();
  const audioWorkerBlobs = new WeakSet();
  const audioWorkerUrls = new Set();
  const nativeSetInterval = window.setInterval.bind(window);
  const displacedStorageKey = "maxofon-primary-session-displaced";
  const pageSessionId = (
    crypto.randomUUID?.()
    || `${Date.now()}-${Math.random().toString(16).slice(2)}`
  );
  let lastInput = null;
  let lastElement = null;
  let gesture = null;
  let sessionDisplaced = sessionStorage.getItem(displacedStorageKey) === "1";

  function installAudioDecoderFallback() {
    const shouldUseFallback = (
      /iP(?:hone|ad|od)/.test(navigator.userAgent)
      || typeof window.AudioDecoder !== "function"
    );
    if (!shouldUseFallback) {
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
            "./polmira-opus-worker.js?v=20260723-mobile2",
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

  function replaceAudioContext(name, NativeAudioContext) {
    if (typeof NativeAudioContext !== "function" || NativeAudioContext.__polmiraWrapped) {
      return NativeAudioContext;
    }

    const WrappedAudioContext = new Proxy(NativeAudioContext, {
      construct(target, args) {
        const context = Reflect.construct(target, args, target);
        audioContexts.add(context);
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
