# apple-vision-api

An OpenAI-compatible HTTP server for Apple's on-device Foundation Model (Apple
Intelligence), **with image input**, running entirely on your Mac with no cloud dependency.

> Not to be confused with Apple's *Vision* framework (OCR, face and barcode detection).
> This server sends your images and prompts to Apple's on-device language model.

```
you / any app  ──HTTP──▶  apple-vision-api (this)  ──▶  FoundationModels framework
                                                        (on-device, ~3B params, Apple Silicon)
```

Built in Swift using only Apple frameworks (`FoundationModels`, `Network`, `ImageIO`).
No third-party dependencies and nothing else to install.

## What it is (and isn't)

This is **not** a vision model. It wraps Apple's on-device **Foundation Model**, a
~3B-parameter general-purpose LLM that accepts images as attachments. Apple itself
describes this model as *"optimized for specific tasks like summarization, extraction,
and classification, and is not suitable for world knowledge or advanced reasoning."*

Treat it as what it is: a **fast, free, fully private on-device multimodal endpoint**
for lightweight tasks.

### Set your expectations

Measured on a Mac mini (M4, macOS 27):

| Task | Latency | Notes |
|---|---|---|
| Text-only question | ~0.4 s | Simple, but not a reasoning engine |
| Image → short description | ~0.8–1.3 s | One image per request |
| Image → extraction / classification | ~1 s | The sweet spot |

**Good at:** short answers, labeling/categorizing images, extracting simple
structured facts from a single image, private/low-latency triage (e.g. camera
frames, receipt/doc snapshots), anything where "fast, local, free" beats "smart".

**Weak at:** complex scene understanding (it will miscount people, miss background
details, and confidently describe the wrong thing), multi-image reasoning, math and
other reasoning tasks, long-form generation, world knowledge. In our testing it
described a photo of four hikers in the Alps as "a young woman in front of a
colorful wall" and got 27 × 43 wrong. If your task needs real visual reasoning,
use a proper vision model (Qwen-VL, GPT, Gemini, …): this is the cheap fast lane,
not the deep lane.

## Requirements

- macOS 27 or later
- An Apple Silicon Mac with **Apple Intelligence enabled**
  (System Settings → Apple Intelligence & Siri → on)
- Xcode 27 / Swift 6.4

If Apple Intelligence is off or the model is still downloading, the server starts
anyway: `/health` returns `503` with the reason, and chat requests return `503`
until it's ready.

## Build & run

```sh
git clone https://github.com/Jacou/apple-vision-api
cd apple-vision-api
swift build -c release
./.build/release/apple_vision_api            # http://127.0.0.1:8099, this Mac only
```

### Options

```
--host <address>       address to listen on (default 127.0.0.1, this Mac only;
                       use 0.0.0.0 to accept connections from your network)
--port <number>        port to listen on (default 8099; a bare number also works)
--api-key <key>        require "Authorization: Bearer <key>" on /v1 endpoints
                       (or set APPLE_VISION_API_KEY)
--allow-local-files    accept image_url file paths, from clients on this Mac only
--max-body-mb <n>      largest accepted request body, in MB (default 25)
```

To serve other machines on your network, set a key:

```sh
APPLE_VISION_API_KEY=$(openssl rand -hex 24) ./.build/release/apple_vision_api --host 0.0.0.0
```

## Security

- **Listens on 127.0.0.1 by default.** Use `--host 0.0.0.0` to open it to your
  network, and set an API key when you do. The server warns at startup if you don't.
- **API key.** With `--api-key`, `/v1/*` requires `Authorization: Bearer <key>`.
  `/health` stays open for monitoring. The key is compared in constant time.
- **No local file access by default.** Image file paths are refused unless you pass
  `--allow-local-files`, and even then only for clients connecting from the same Mac.
  Otherwise anyone who can reach the port could make the server read and transcribe
  images on its disk.
- **Bounded requests.** Bodies over `--max-body-mb` get `413`, invalid lengths `400`,
  oversized headers `431`, clients that don't finish sending within 60 s `408`, and
  more than 32 simultaneous connections `503`.
- **No TLS.** Put it behind a reverse proxy if traffic leaves a trusted network.

## Endpoints

| Endpoint | Method | Description |
|---|---|---|
| `/v1/chat/completions` | POST | OpenAI-compatible chat (text + image), streaming or not |
| `/v1/models` | GET | Lists `apple-foundation-vision` |
| `/health` | GET | `200` when the model is ready, `503` with the reason when it isn't |

`/chat/completions` and `/models` without the `/v1` prefix work too.

### Supported request fields

| Field | Support |
|---|---|
| `messages` | `system`/`developer` messages become the model's instructions. `user`, `assistant` and `tool` turns are replayed as a short transcript before the latest user message, since each request starts a fresh on-device session. |
| Image parts | `image_url` with a base64 `data:` URI (JPEG, PNG, HEIC, GIF, TIFF, WebP). The latest image in the conversation is used. Remote `http(s)` URLs are not fetched. |
| `stream` | Server-Sent Events in OpenAI's chunk format, ending with `data: [DONE]`. `stream_options.include_usage` adds a final usage chunk. |
| `temperature` | Passed to the model (0–2). |
| `max_tokens` / `max_completion_tokens` | Passed to the model as the response token limit. |
| `n` | Only `1`. |
| Tools, `response_format`, logprobs | Not supported. |

Responses include real token counts in `usage`, as reported by the framework.

Errors use OpenAI's format (`{"error": {"message", "type", "code", "param"}}`) with
meaningful statuses: `400` for invalid requests, context overflow or content blocked
by Apple's guardrails, `401` for a missing or wrong key, `403` for disabled file paths,
`429` when the model is busy, and `503` when it's unavailable.

## Usage examples

Text only:

```sh
curl http://127.0.0.1:8099/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"apple-foundation-vision",
       "messages":[{"role":"user","content":"What is the capital of France? Answer in one word."}]}'
```

With an image:

```sh
B64=$(base64 -i photo.jpg)
curl http://127.0.0.1:8099/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d "{\"model\":\"apple-foundation-vision\",
       \"messages\":[{\"role\":\"user\",\"content\":[
         {\"type\":\"text\",\"text\":\"Describe this photo in one sentence.\"},
         {\"type\":\"image_url\",\"image_url\":{\"url\":\"data:image/jpeg;base64,$B64\"}}
       ]}]}"
```

From any OpenAI SDK (e.g. Python), including streaming:

```python
from openai import OpenAI

client = OpenAI(base_url="http://192.168.1.76:8099/v1", api_key="your-key")

stream = client.chat.completions.create(
    model="apple-foundation-vision",
    stream=True,
    messages=[
        {"role": "system", "content": "Answer in one short sentence."},
        {"role": "user", "content": [
            {"type": "text", "text": "What is shown in this image?"},
            {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64," + b64}},
        ]},
    ],
)
for chunk in stream:
    if chunk.choices:
        print(chunk.choices[0].delta.content or "", end="")
```

## Run it as a launchd service

`examples/com.example.apple-vision-api.plist` is a template. Copy it to
`~/Library/LaunchAgents/`, point the binary path and log files at your install,
set your API key, then:

```sh
launchctl load ~/Library/LaunchAgents/com.example.apple-vision-api.plist
launchctl list | grep apple-vision-api   # verify
```

`KeepAlive` restarts it if it ever dies; `RunAtLoad` starts it at login.

## Development

```sh
swift build
swift test
```

The HTTP parsing, OpenAI request/response handling and routing live in the
`AppleVisionAPICore` library, which doesn't depend on `FoundationModels`; the tests
run it against a fake model, so they pass on Macs without Apple Intelligence.
The `apple_vision_api` executable adds the network listener and the real model.

## Limitations

- Single image per request (the latest one); no video, no multi-image context.
- The on-device model is small (see "Set your expectations").
- Conversation history is replayed as text, so long conversations hit the model's
  context window sooner than you might expect (you get a `400` when they do).

## License

[MIT](LICENSE): do whatever you want, no warranty.
