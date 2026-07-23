#!/usr/bin/with-contenv bash
set -euo pipefail

python3 - <<'PY'
import json
import os
from pathlib import Path

manifest_path = Path("/usr/share/selkies/web/manifest.json")
index_path = Path("/usr/share/selkies/web/index.html")
bridge_source_path = Path("/usr/share/selkies/www/polmira-mobile.js")
bridge_web_path = Path("/usr/share/selkies/web/polmira-mobile.js")
opus_worker_source_path = Path("/usr/share/selkies/www/polmira-opus-worker.js")
opus_worker_web_path = Path("/usr/share/selkies/web/polmira-opus-worker.js")
opus_decoder_source_path = Path("/usr/share/selkies/www/opus-decoder.min.js")
opus_decoder_web_path = Path("/usr/share/selkies/web/opus-decoder.min.js")
subfolder = os.environ.get("SUBFOLDER", "/")

if not subfolder.startswith("/"):
    subfolder = f"/{subfolder}"
if not subfolder.endswith("/"):
    subfolder = f"{subfolder}/"

if bridge_source_path.exists():
    bridge_web_path.write_bytes(bridge_source_path.read_bytes())
if opus_worker_source_path.exists():
    opus_worker_web_path.write_bytes(opus_worker_source_path.read_bytes())
if opus_decoder_source_path.exists():
    opus_decoder_web_path.write_bytes(opus_decoder_source_path.read_bytes())

if manifest_path.exists():
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest.update(
        {
            "id": subfolder,
            "scope": subfolder,
            "start_url": subfolder,
            "name": "Maxofon",
            "short_name": "Maxofon",
            "orientation": "landscape",
            "display": "fullscreen",
            "icons": [
                {
                    "src": "icon.png",
                    "type": "image/png",
                    "sizes": "1024x1024",
                    "purpose": "any maskable",
                }
            ],
        }
    )
    manifest_path.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )

if index_path.exists():
    html = index_path.read_text(encoding="utf-8")
    if "<title>" not in html:
        html = html.replace("<head>", "<head><title>Maxofon</title>", 1)
    bridge_tag = '<script src="./polmira-mobile.js?v=20260723-mobile4"></script>'
    if bridge_tag not in html:
        html = html.replace(
            '<script type="module"',
            f'{bridge_tag}<script type="module"',
            1,
        )
    if html != index_path.read_text(encoding="utf-8"):
        index_path.write_text(html, encoding="utf-8")
PY
