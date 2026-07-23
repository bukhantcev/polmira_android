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
                                    legacy_blocked = getattr(
                                        self,
                                        '_maxofon_legacy_clients_blocked',
                                        True,
                                    )
                                    if (
                                        maxofon_client_id in revoked_ids
                                        or (
                                            not maxofon_client_id
                                            and legacy_blocked
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
                                        self._maxofon_legacy_clients_blocked = True

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

SELKIES_PATH.write_text(source, encoding="utf-8")
