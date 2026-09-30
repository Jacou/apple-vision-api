# Changelog

## 0.2.0

### Breaking changes

- The server now listens on **127.0.0.1** by default. Pass `--host 0.0.0.0` to accept
  connections from other machines, ideally with `--api-key`.
- Image file paths in `image_url` are **refused by default**. Send images as `data:`
  URIs, or start the server with `--allow-local-files` (honoured only for clients on
  the same Mac).

### Security fixes

- Any client that could reach the port could make the server read image files from
  its disk (and have the model transcribe them) by passing a file path as `image_url`.
- A request with a negative `Content-Length` crashed the server.
- Every request body, images included, was kept in memory forever (about 1 MB leaked
  per image request).
- Request bodies had no size limit; they are now capped (25 MB by default).

### Fixes

- `system`/`developer` messages are passed to the model as instructions (they were ignored).
- Earlier conversation turns, including assistant replies, are now given to the model.
- Replies containing tabs, carriage returns or other control characters no longer produce invalid JSON.
- Invalid requests return `400` in OpenAI's error format instead of `500`.
- An image that can't be decoded returns `400` instead of silently being dropped.
- Query strings no longer break routing; wrong methods return `405`.
- A request whose client half-closes the connection right after sending is no longer dropped.
- Requirements now match the code: macOS 27.

### Added

- Streaming (`"stream": true`) as Server-Sent Events, with optional `stream_options.include_usage`.
- `temperature` and `max_tokens` / `max_completion_tokens` are passed to the model.
- Real token counts in `usage`.
- Optional API key (`--api-key` or `APPLE_VISION_API_KEY`).
- `/health` reports whether Apple Intelligence is available (`503` with a reason when not).
- Apple's guardrail, context-size and rate-limit errors map to `400`/`429`/`503`.
- Request timeout, connection limit, per-request log line.
- Unit tests (`swift test`), runnable without Apple Intelligence.

## 0.1.0

- Initial release.
