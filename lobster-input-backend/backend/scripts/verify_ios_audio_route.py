import argparse
import os
import wave
from pathlib import Path

import httpx


def create_silence_wav(path: Path) -> None:
    sample_rate = 16000
    duration_sec = 1
    frame_count = sample_rate * duration_sec
    with wave.open(str(path), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(sample_rate)
        wav.writeframes(b"\x00\x00" * frame_count)


def post_audio(base_url: str, token: str, operation: str, selected_text: str | None, wav_path: Path) -> httpx.Response:
    with wav_path.open("rb") as audio_file:
        files = {"file": ("ios-route-check.wav", audio_file, "audio/wav")}
        data = {"operation": operation}
        if selected_text:
            data["selected_text"] = selected_text
        return httpx.post(
            f"{base_url.rstrip('/')}/api/v1/audio/ios/process",
            headers={"Authorization": f"Bearer {token}", "X-Client-Platform": "ios"},
            data=data,
            files=files,
            timeout=120,
        )


def main() -> None:
    parser = argparse.ArgumentParser(description="Verify iOS audio route operation gates.")
    parser.add_argument("--base-url", default=os.getenv("LOBSTER_BASE_URL", "http://localhost:8000"))
    parser.add_argument("--token", default=os.getenv("LOBSTER_TOKEN"))
    parser.add_argument("--audio", type=Path, default=None)
    args = parser.parse_args()

    if not args.token:
        raise SystemExit("Missing token. Set LOBSTER_TOKEN or pass --token.")

    wav_path = args.audio or Path("/tmp/lobster-ios-route-check.wav")
    if args.audio is None:
        create_silence_wav(wav_path)

    for operation, selected_text in (("transcribe", None), ("rewrite", "这是一段需要改写的文本")):
        response = post_audio(args.base_url, args.token, operation, selected_text, wav_path)
        print(operation, response.status_code, response.text[:300])
        response.raise_for_status()

    response = post_audio(args.base_url, args.token, "agent", None, wav_path)
    print("agent", response.status_code, response.text[:300])
    if response.status_code != 400:
        raise SystemExit("Expected iOS agent operation to be rejected with 400.")


if __name__ == "__main__":
    main()
