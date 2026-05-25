#!/usr/bin/env python3
"""
claude_bridge.py -- the divine intermediary.

Speaks the binary framing protocol that Apps/Claude/Claude.HC speaks,
on one side, and the Anthropic Messages API on the other. QEMU pipes
TempleOS's emulated COM1 into a Unix socket we listen on; we read
ASK frames off it, hit the API in streaming mode, and ship TOK
chunks back as they arrive, terminated by an END frame.

Frame layout (must match Claude.HC):
  [1 byte type] [4 bytes length, LE] [payload]

Types:
  0x01 ASK   prompt text (in)
  0x02 TOK   streaming text chunk (out)
  0x03 END   response complete, empty payload (out)
  0x04 ERR   error string (out)
  0x05 PNG   liveness, empty (either)

ANTHROPIC_API_KEY must be set in the env. Default model is
claude-opus-4-7 -- override with CLAUDE_MODEL.
"""

import asyncio
import os
import struct
import sys
import json
from pathlib import Path

try:
    import anthropic
except ImportError:
    sys.stderr.write("missing dep: pip install anthropic\n")
    sys.exit(1)


SOCK_PATH = os.environ.get("TEMPLECLAUDE_SOCK", "/tmp/templeclaude.sock")
MODEL     = os.environ.get("CLAUDE_MODEL", "claude-opus-4-7")
MAX_TOKENS = int(os.environ.get("CLAUDE_MAX_TOKENS", "1024"))

# System prompt is tuned for TempleOS's 80-col 16-color text grid.
# Short lines, no markdown, no code fences, no em-dashes.
SYSTEM_PROMPT = (
    "You are speaking through the COM1 serial port of TempleOS, "
    "Terry Davis's 16-color 640x480 operating system, to a user "
    "sitting at a HolyC prompt. Respond in plain text only. No "
    "markdown, no code fences, no emoji, no em-dashes. Keep lines "
    "under 72 columns. Be concise -- every token costs serial baud. "
    "If you write code, write HolyC."
)

FRAME_ASK = 0x01
FRAME_TOK = 0x02
FRAME_END = 0x03
FRAME_ERR = 0x04
FRAME_PNG = 0x05


def log(msg):
    sys.stderr.write(f"[bridge] {msg}\n")
    sys.stderr.flush()


async def read_frame(reader):
    hdr = await reader.readexactly(5)
    ftype = hdr[0]
    flen  = struct.unpack("<I", hdr[1:5])[0]
    payload = await reader.readexactly(flen) if flen else b""
    return ftype, payload


async def write_frame(writer, ftype, payload=b""):
    writer.write(bytes([ftype]) + struct.pack("<I", len(payload)) + payload)
    await writer.drain()


async def stream_claude(client, prompt, writer):
    """Hit the Anthropic API in streaming mode, push TOK frames as text arrives."""
    try:
        async with client.messages.stream(
            model=MODEL,
            max_tokens=MAX_TOKENS,
            system=SYSTEM_PROMPT,
            messages=[{"role": "user", "content": prompt}],
        ) as stream:
            async for chunk in stream.text_stream:
                if not chunk:
                    continue
                # ASCII-only -- TempleOS's font is a custom 8x8 bitmap that
                # only covers code points 0-255. Strip anything that won't
                # render rather than ship mojibake.
                data = chunk.encode("ascii", "replace")
                await write_frame(writer, FRAME_TOK, data)
        await write_frame(writer, FRAME_END)
    except anthropic.APIError as e:
        msg = f"api: {e}"
        log(msg)
        await write_frame(writer, FRAME_ERR, msg.encode("ascii", "replace")[:512])
    except Exception as e:
        msg = f"bridge: {type(e).__name__}: {e}"
        log(msg)
        await write_frame(writer, FRAME_ERR, msg.encode("ascii", "replace")[:512])


async def handle_client(reader, writer, client):
    peer = writer.get_extra_info("peername") or writer.get_extra_info("sockname")
    log(f"templeos connected ({peer})")
    try:
        while True:
            ftype, payload = await read_frame(reader)
            if ftype == FRAME_ASK:
                prompt = payload.decode("utf-8", "replace")
                log(f"ASK [{len(prompt)} chars]: {prompt[:80]!r}")
                await stream_claude(client, prompt, writer)
            elif ftype == FRAME_PNG:
                await write_frame(writer, FRAME_PNG)
            else:
                log(f"unknown frame type {ftype:#x}, ignoring")
    except asyncio.IncompleteReadError:
        log("templeos disconnected")
    except Exception as e:
        log(f"handler error: {type(e).__name__}: {e}")
    finally:
        writer.close()
        try:
            await writer.wait_closed()
        except Exception:
            pass


async def main():
    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        sys.stderr.write("ANTHROPIC_API_KEY not set\n")
        sys.exit(2)

    # Clean up stale socket if a previous run left one.
    sock = Path(SOCK_PATH)
    if sock.exists():
        sock.unlink()

    client = anthropic.AsyncAnthropic(api_key=api_key)

    server = await asyncio.start_unix_server(
        lambda r, w: handle_client(r, w, client),
        path=str(sock),
    )
    os.chmod(sock, 0o666)
    log(f"listening on {sock} | model={MODEL}")

    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
