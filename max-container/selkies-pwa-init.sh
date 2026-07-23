#!/usr/bin/with-contenv bash
set -euo pipefail

python3 - <<'PY'
import json
import os
from pathlib import Path

manifest_path = Path("/usr/share/selkies/web/manifest.json")
index_path = Path("/usr/share/selkies/web/index.html")
subfolder = os.environ.get("SUBFOLDER", "/")

if not subfolder.startswith("/"):
    subfolder = f"/{subfolder}"
if not subfolder.endswith("/"):
    subfolder = f"{subfolder}/"

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
        index_path.write_text(html, encoding="utf-8")
PY
