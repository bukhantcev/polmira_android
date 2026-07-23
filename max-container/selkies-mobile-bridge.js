(() => {
  "use strict";

  const audioContexts = new Set();
  let lastInput = null;
  let lastElement = null;
  let gesture = null;

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

  function markNativeGestureAsMoved(input, identifier, touch) {
    const nativeTouch = input?._trackpadTouches?.get(identifier);
    if (!nativeTouch) {
      return;
    }

    nativeTouch.moved = true;
    nativeTouch.lastX = touch.clientX;
    nativeTouch.lastY = touch.clientY;
    input._trackpadLastTapTime = 0;
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
    markNativeGestureAsMoved(input, gesture.identifier, touch);

    gesture.remainder += touch.clientY - gesture.lastY;
    gesture.lastY = touch.clientY;

    const pixelsPerStep = 5;
    const steps = Math.min(8, Math.floor(Math.abs(gesture.remainder) / pixelsPerStep));
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
      markNativeGestureAsMoved(window.webrtcInput, gesture.identifier, touch);
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

  setInterval(attachInput, 500);
  window.addEventListener("pagehide", detachInput, { once: true });
})();
