#!/usr/bin/env python3

import os
from pathlib import Path


SELKIES_PATH = Path(
    os.environ.get(
        "SELKIES_PATH",
        "/lsiopy/lib/python3.12/site-packages/selkies/selkies.py",
    )
)


def replace_once(source: str, old: str, new: str) -> str:
    count = source.count(old)
    if count != 1:
        raise RuntimeError(
            f"Expected one Selkies patch target, found {count}: {old[:80]!r}"
        )
    return source.replace(old, new, 1)


source = SELKIES_PATH.read_text(encoding="utf-8")

if 'message.startswith("MAXOFON_UTF8,")' in source:
    if 'message.startswith("MAXOFON_KEY,")' not in source:
        source = replace_once(
            source,
            """                    elif message.startswith("MAXOFON_UTF8,"):
""",
            """                    elif message.startswith("MAXOFON_KEY,"):
                        perms = client_permissions.get(websocket)
                        role = perms.get("role") if perms else "viewer"
                        display_state = self.display_clients.get("primary")
                        if (
                            client_display_id != "primary"
                            or role != "controller"
                            or not display_state
                            or display_state.get("ws") is not websocket
                        ):
                            data_logger.warning(
                                "Blocked key input from a non-primary controller."
                            )
                            continue

                        try:
                            keysym = int(message.split(",", 1)[1])
                            if keysym not in (65288, 65293, 65307):
                                raise ValueError("key input is not allowed")
                            if not self.input_handler:
                                raise RuntimeError("input handler is unavailable")

                            await self.input_handler.on_message(
                                f"kd,{keysym}",
                                client_display_id,
                            )
                            await asyncio.sleep(0.015)
                            await self.input_handler.on_message(
                                f"ku,{keysym}",
                                client_display_id,
                            )
                        except Exception as input_error:
                            data_logger.error(
                                f"Failed to inject Maxofon key input: "
                                f"{input_error}"
                            )

                    elif message.startswith("MAXOFON_UTF8,"):
""",
        )
        SELKIES_PATH.write_text(source, encoding="utf-8")
    raise SystemExit(0)

source = replace_once(
    source,
    """    async def ws_handler(self, websocket):
        if self.is_secure_mode:
            await config_gate.wait()

            query_params = urllib.parse.parse_qs(urllib.parse.urlparse(websocket.request.path).query)
""",
    """    async def ws_handler(self, websocket):
        query_params = urllib.parse.parse_qs(
            urllib.parse.urlparse(websocket.request.path).query
        )
        maxofon_client_id = query_params.get('maxofon_client', [None])[0]
        if maxofon_client_id and (
            len(maxofon_client_id) > 128
            or not re.fullmatch(r'[A-Za-z0-9._-]+', maxofon_client_id)
        ):
            maxofon_client_id = None

        if self.is_secure_mode:
            await config_gate.wait()

""",
)

source = replace_once(
    source,
    """                            if display_id in ['primary', 'display2']:
                                existing_client_info = self.display_clients.get(display_id)
""",
    """                            if display_id in ['primary', 'display2']:
                                if display_id == 'primary':
                                    revoked_ids = getattr(
                                        self,
                                        '_maxofon_revoked_client_ids',
                                        set(),
                                    )
                                    self._maxofon_revoked_client_ids = revoked_ids
                                    unidentified_clients_blocked = getattr(
                                        self,
                                        '_maxofon_unidentified_clients_blocked',
                                        True,
                                    )
                                    if (
                                        maxofon_client_id in revoked_ids
                                        or (
                                            not maxofon_client_id
                                            and unidentified_clients_blocked
                                        )
                                    ):
                                        data_logger.warning(
                                            "Rejecting a superseded primary browser session."
                                        )
                                        try:
                                            await websocket.send(
                                                "KILL Primary session superseded"
                                            )
                                            await websocket.close(
                                                code=4009,
                                                reason="Primary session superseded",
                                            )
                                        except websockets.ConnectionClosed:
                                            pass
                                        return
                                    if maxofon_client_id:
                                        self._maxofon_unidentified_clients_blocked = True

                                existing_client_info = self.display_clients.get(display_id)
""",
)

source = replace_once(
    source,
    """                                    if old_ws and old_ws is not websocket and old_ws.state == websockets.protocol.State.OPEN:
                                        kill_reason = f"a new {display_id} client connected connection killed"
""",
    """                                    if old_ws and old_ws is not websocket and old_ws.state == websockets.protocol.State.OPEN:
                                        if display_id == 'primary':
                                            old_client_id = existing_client_info.get(
                                                'maxofon_client_id'
                                            )
                                            if (
                                                old_client_id
                                                and old_client_id != maxofon_client_id
                                            ):
                                                revoked_ids.add(old_client_id)
                                                if len(revoked_ids) > 64:
                                                    revoked_ids.pop()
                                        kill_reason = f"a new {display_id} client connected connection killed"
""",
)

source = replace_once(
    source,
    """                                    'ws': websocket, 
                                    'width': 0, 'height': 0, 'position': 'right',
""",
    """                                    'ws': websocket,
                                    'maxofon_client_id': maxofon_client_id,
                                    'width': 0, 'height': 0, 'position': 'right',
""",
)

source = replace_once(
    source,
    """                                display_state = self.display_clients[display_id]
                                display_state['ws'] = websocket
                                display_state['video_active'] = True
""",
    """                                display_state = self.display_clients[display_id]
                                display_state['ws'] = websocket
                                display_state['maxofon_client_id'] = maxofon_client_id
                                display_state['video_active'] = True
""",
)

source = replace_once(
    source,
    """    if data_server_instance:
        server_is_manual, _ = data_server_instance.cli_args.is_manual_resolution_mode
        if server_is_manual:
            logger_gst_app_resize.warning(
                f"Client attempted to resize to {res_str} but server is in manual resolution mode. Request ignored."
            )
            return
""",
    """    if data_server_instance:
        server_is_manual, _ = data_server_instance.cli_args.is_manual_resolution_mode
        if server_is_manual:
            logger_gst_app_resize.info(
                f"Maxofon client resize overrides the configured startup resolution: {res_str}."
            )
""",
)

source = replace_once(
    source,
    """            new_dpi = sanitize_value("scaling_dpi", settings.get("scaling_dpi"))
""",
    """            # Keep the Linux desktop at one logical pixel per output pixel.
            # Mobile Safari reports its device-pixel-ratio as DPI, which otherwise
            # makes Wayland expose a tiny logical desktop (for example 426x573).
            new_dpi = 96
""",
)

source = replace_once(
    source,
    """                    elif message.startswith("cmd,"):
""",
    """                    elif message.startswith("MAXOFON_KEY,"):
                        perms = client_permissions.get(websocket)
                        role = perms.get("role") if perms else "viewer"
                        display_state = self.display_clients.get("primary")
                        if (
                            client_display_id != "primary"
                            or role != "controller"
                            or not display_state
                            or display_state.get("ws") is not websocket
                        ):
                            data_logger.warning(
                                "Blocked key input from a non-primary controller."
                            )
                            continue

                        try:
                            keysym = int(message.split(",", 1)[1])
                            if keysym not in (65288, 65293, 65307):
                                raise ValueError("key input is not allowed")
                            if not self.input_handler:
                                raise RuntimeError("input handler is unavailable")

                            await self.input_handler.on_message(
                                f"kd,{keysym}",
                                client_display_id,
                            )
                            await asyncio.sleep(0.015)
                            await self.input_handler.on_message(
                                f"ku,{keysym}",
                                client_display_id,
                            )
                        except Exception as input_error:
                            data_logger.error(
                                f"Failed to inject Maxofon key input: "
                                f"{input_error}"
                            )

                    elif message.startswith("MAXOFON_UTF8,"):
                        perms = client_permissions.get(websocket)
                        role = perms.get("role") if perms else "viewer"
                        display_state = self.display_clients.get("primary")
                        if (
                            client_display_id != "primary"
                            or role != "controller"
                            or not display_state
                            or display_state.get("ws") is not websocket
                        ):
                            data_logger.warning(
                                "Blocked UTF-8 input from a non-primary controller."
                            )
                            continue

                        try:
                            encoded_text = message.split(",", 1)[1]
                            if len(encoded_text) > 8192:
                                raise ValueError("encoded input is too large")
                            text_bytes = base64.b64decode(
                                encoded_text,
                                validate=True,
                            )
                            if not text_bytes or len(text_bytes) > 4096:
                                raise ValueError("decoded input has invalid size")
                            text = text_bytes.decode("utf-8")
                            if "\\x00" in text:
                                raise ValueError("decoded input contains NUL")

                            if not self.input_handler:
                                raise RuntimeError("input handler is unavailable")
                            if not await self.input_handler.write_clipboard(text):
                                raise RuntimeError("clipboard write failed")

                            for key_message in (
                                "kd,65507",
                                "kd,118",
                                "ku,118",
                                "ku,65507",
                            ):
                                await self.input_handler.on_message(
                                    key_message,
                                    client_display_id,
                                )
                        except Exception as input_error:
                            data_logger.error(
                                f"Failed to inject Maxofon UTF-8 input: "
                                f"{input_error}"
                            )

                    elif message.startswith("cmd,"):
""",
)

SELKIES_PATH.write_text(source, encoding="utf-8")
