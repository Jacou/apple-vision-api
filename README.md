# apple-vision-api

An OpenAI-compatible HTTP server that exposes Apple's on-device Foundation Models
(Apple Intelligence) with image understanding — running entirely on your Mac, with
zero cloud dependency.

```
you / any app  ──HTTP──▶  apple-vision-api (this)  ──▶  FoundationModels framework
                                                        (on-device, ~3B params, Apple Silicon)
```

Built in Swift using only Apple frameworks (`FoundationModels`, `Network`,
`ImageIO`) — no third-party dependencies, no servers to install, one ~200-line file.

## What it is (and isn't)

This is **not** a vision model. It wraps Apple's on-device **Foundation Model** — a
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
use a proper vision model (Qwen-VL, GPT, Gemini, …) — this is the cheap fast lane,
not the deep lane.

## Requirements

- macOS 26 or later (developed and tested on macOS 27)
- An Apple Silicon Mac with **Apple Intelligence enabled**
  (System Settings → Apple Intelligence & Siri → on)
- Xcode / Command Line Tools with Swift 6.x

> The `FoundationModels` framework only initializes when Apple Intelligence is
> enabled on the machine. Without it the server runs but requests will fail.

## Build & run

```sh
git clone https://github.com/Jacou/apple-vision-api
cd apple-vision-api
swift build -c release

# run it (port is the first CLI argument, default 8099)
./.build/release/apple_vision_api 8099
```

The server binds `0.0.0.0:<port>`. It's single-purpose: no auth, no TLS —
run it on a trusted network only.

### Endpoints

| Endpoint | Method | Description |
|---|---|---|
| `/v1/chat/completions` | POST | OpenAI-compatible chat (text + image) |
| `/v1/models` | GET | Lists `apple-foundation-vision` |
| `/health` | GET | Liveness check |

### Images

Images are supplied the standard OpenAI way, in two flavors:

- **Data URI** (works from any machine on your network):
  `"url": "data:image/jpeg;base64,/<base64>"`
- **Local file path** (works from the same Mac that runs the server):
  `"url": "/Users/you/photo.jpg"`

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

From any OpenAI SDK (e.g. Python):

```python
from openai import OpenAI

client = OpenAI(base_url="http://192.168.1.76:8099/v1", api_key="unused")

resp = client.chat.completions.create(
    model="apple-foundation-vision",
    messages=[{
        "role": "user",
        "content": [
            {"type": "text", "text": "What is shown in this image?"},
            {"type": "image_url",
             "image_url": {"url": "data:image/jpeg;base64," + b64}},
        ],
    }],
)
print(resp.choices[0].message.content)
```

## Run it as a launchd service

`examples/com.example.apple-vision-api.plist` is a template. Copy it to
`~/Library/LaunchAgents/`, point the binary path and log files at your install,
then:

```sh
launchctl load ~/Library/LaunchAgents/com.example.apple-vision-api.plist
launchctl list | grep apple-vision-api   # verify
```

`KeepAlive` restarts it if it ever dies; `RunAtLoad` starts it at login.

## Design notes

- **One file, no dependencies.** The HTTP layer is a small hand-rolled parser on
  `Network.framework` (`NWListener`/`NWConnection`) — chosen deliberately so the
  package has zero external deps and compiles in seconds.
- **Stateful per connection.** Each connection keeps a small request buffer
  (`ConnState`) until headers + body are complete, then dispatches.
- **Images are single.** The latest `image_url` in the conversation is used;
  earlier ones are ignored.
- **Usage fields are zeroed.** Token accounting isn't exposed by the framework,
  so `usage` is reported as 0 — don't bill against it.

## Limitations

- Single image per request; no video, no multi-image context.
- No streaming (SSE) — responses are returned whole.
- No authentication or TLS (trusted-network use only).
- `temperature`, `top_p`, and other sampling params are accepted but ignored.
- Concurrency: requests are handled in parallel tasks, but the on-device model is
  the bottleneck — don't hammer it.

## License

[MIT](LICENSE) — do whatever you want, no warranty.
