#!/usr/bin/env python3
"""
claude_bridge.py -- the divine intermediary.

Speaks the binary framing protocol that /Home/Claude.HC speaks on one side,
and the Anthropic Messages API on the other. VBox creates a Unix domain
socket as its COM1 backend (UART server mode); we connect to it as a
client and read/write frames.

Frame layout (must match Claude.HC):
  [1 byte type] [4 bytes length, LE] [payload]

Types:
  0x01 ASK   prompt text (in)
  0x02 TOK   streaming text chunk (out)
  0x03 END   response complete, empty payload (out)
  0x04 ERR   error string (out)
  0x05 PNG   liveness, empty (either)

ANTHROPIC_API_KEY must be set. Default model is claude-opus-4-7;
override with CLAUDE_MODEL.

Reconnect loop: if VBox is down or the VM is rebooting, we keep retrying
the socket every second. The VM can come and go without restarting us.
"""

import asyncio
import os
import struct
import sys
from pathlib import Path

try:
    import anthropic
except ImportError:
    sys.stderr.write("missing dep: pip install anthropic\n")
    sys.exit(1)


SOCK_PATH = os.environ.get("TEMPLECLAUDE_SOCK", "/tmp/templeclaude.sock")
MODEL     = os.environ.get("CLAUDE_MODEL", "claude-opus-4-7")
MAX_TOKENS = int(os.environ.get("CLAUDE_MAX_TOKENS", "1024"))

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


async def serve_once(client, reader, writer):
    """Handle frames over one socket connection until peer closes."""
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


async def main():
    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        sys.stderr.write("ANTHROPIC_API_KEY not set\n")
        sys.exit(2)

    client = anthropic.AsyncAnthropic(api_key=api_key)
    log(f"target={SOCK_PATH} model={MODEL}")

    while True:
        if not Path(SOCK_PATH).exists():
            # VM isn't running yet -- VBox creates the socket at VM start.
            await asyncio.sleep(1)
            continue
        try:
            reader, writer = await asyncio.open_unix_connection(SOCK_PATH)
        except (ConnectionRefusedError, FileNotFoundError, OSError) as e:
            await asyncio.sleep(1)
            continue
        log("connected to VM")
        try:
            await serve_once(client, reader, writer)
        except asyncio.IncompleteReadError:
            log("VM closed connection")
        except Exception as e:
            log(f"session error: {type(e).__name__}: {e}")
        finally:
            writer.close()
            try:
                await writer.wait_closed()
            except Exception:
                pass
        # back to top of loop, retry connect


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
