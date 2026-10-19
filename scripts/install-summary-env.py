#!/usr/bin/env python3
"""Install only summary API configuration outside the signed application bundle."""
from pathlib import Path
import os
import tempfile

source = Path(__file__).resolve().parent.parent / ".env"
if source.exists():
    names = {
        "MODEL_PROVIDER", "ZHIZENGZENG_OPENAI_API_KEY", "OPENAI_BASE_URL", "OPENAI_MODEL",
        "CHAT_COMPLETIONS_MAX_TOKENS", "CHAT_COMPLETIONS_MAX_CONCURRENT_REQUESTS",
        "CHAT_COMPLETIONS_REQUESTS_PER_SECOND", "CHAT_COMPLETIONS_INSECURE_TLS",
    }
    lines = []
    for raw in source.read_text().splitlines():
        line = raw.strip()
        if line.startswith("export "):
            line = line[7:]
        if "=" in line and line.split("=", 1)[0].strip() in names:
            lines.append(line)
    if lines:
        destination = Path.home() / "Library/Application Support/StreamTranslate/Configuration/.env"
        destination.parent.mkdir(parents=True, exist_ok=True)
        os.chmod(destination.parent, 0o700)
        descriptor, temporary = tempfile.mkstemp(prefix=".env-", dir=destination.parent)
        try:
            with os.fdopen(descriptor, "w") as output:
                output.write("# Summary only. Not included in the app bundle or repository.\n")
                output.write("\n".join(lines) + "\n")
            os.chmod(temporary, 0o600)
            os.replace(temporary, destination)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
        print("Installed private summary environment (mode 600, outside app bundle).")
