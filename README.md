# TempleClaude

TempleOS with Claude wired in as the new Oracle. The TempleOS source tree
is preserved verbatim from the [cia-foundation snapshot][snap]; everything
new lives under `Apps/Claude/`, `bridge/`, plus a `run.sh` at the root.

[snap]: https://github.com/cia-foundation/TempleOS

```
                    +-------------------+        +------------------+
  HolyC prompt  --> | Apps/Claude/      |  COM1  | bridge/          |
  ClaudeAsk;        |   Claude.HC       |  <-->  |   claude_bridge  |
                    +-------------------+ serial +--------+---------+
                              ^                           |
                              |                           | HTTPS
                              | tokens stream             v
                              |                  +------------------+
                              +------------------+ Anthropic API    |
                                                 +------------------+
```

## How it works

TempleOS has no networking by design. It does, however, have a 16550 UART
driver Terry shipped in `Doc/Comm.HC` and then commented out of the boot
path (`RS232 serial ports no longer exist`). They do in QEMU. We use COM1
as the divine intermediary.

A length-prefixed binary protocol moves over the wire:

```
[1 byte type] [4 bytes length, little-endian] [payload]
```

Types: `ASK` (out), `TOK` (in, streaming), `END` (in), `ERR` (in),
`PNG` (either, liveness). See [Claude.HC](Apps/Claude/Claude.HC) and
[claude_bridge.py](bridge/claude_bridge.py) for the canonical
implementations.

The host bridge binds a Unix domain socket, QEMU connects to it as the
backend for `-serial`, and the bridge forwards prompts to the Anthropic
`messages.stream` API. Streamed text comes back token by token, which
TempleOS prints to the current window the same way Claude generated it.

## Setup

You need: VirtualBox 7.x, `xorriso`, `python3 >= 3.10`, `curl`.
(QEMU works in theory but its SeaBIOS chokes on Terry's RedSea ISO El
Torito record. VBox is Terry's own dev target so it Just Works.)

```bash
export ANTHROPIC_API_KEY=sk-ant-...
./run.sh setup       # fetch TempleOS.ISO, create VM + blank disk
./run.sh run         # boot the live ISO. Hit y at the seed prompt, run
                     # SysIns onto a partition (it ends up at C: or D:),
                     # then Shutdown; from the HolyC prompt.
./run.sh flip        # detach install ISO so subsequent boots use the disk
./run.sh inject      # copy Claude.HC + auto-load Once.HC into /Home on
                     # the installed VDI (needs sudo for qemu-nbd)
./run.sh run         # done. boot, see banner, type ClaudeAsk;
```

After the one-time `inject`, every boot auto-loads the Claude client.
You'll see a green "TempleClaude ready" banner and just need to type
`ClaudeAsk;` (or `ClaudeOracle;`).

The TempleOS ISO is fetched from `www.templeos.org/Downloads/TempleOS.ISO`
and SHA-1-verified against the value pinned in `run.sh`. Override via
`TEMPLE_ISO_URL` / `TEMPLE_ISO_SHA1` if you need a different source.

Other subcommands: `payload` (rebuild T: ISO), `bridge` (just the host
daemon), `headless` (no GUI), `poweroff`, `destroy`.

## Talking to Claude

Once TempleOS is up, mount the payload drive and load the client:

```holyc
Cd("T:/Apps/Claude");
#include "Load";
ClaudeAsk;
```

`ClaudeAsk` prompts you for a question and streams the answer. `ClaudeChat`
takes a string directly. `ClaudeOracle` asks Claude for one cryptic
sentence -- a drop-in for Terry's `PopUpOracle`.

```holyc
ClaudeChat("In one HolyC line, draw a sprite.");
```

## Layout

```
Apps/Claude/
  Claude.HC        UART setup, frame I/O, ClaudeAsk/ClaudeChat/ClaudeOracle
  Load.HC          entry point: #includes Claude.HC
bridge/
  claude_bridge.py async unix-socket server, frames <-> anthropic.messages.stream
  requirements.txt anthropic SDK pin
run.sh             setup / install / run / live / payload / bridge
Makefile           thin wrapper over run.sh
```

Everything else in the repo is unmodified TempleOS V5.03.

## Tuning

The bridge reads three env vars:

| var                   | default              | meaning                          |
|-----------------------|----------------------|----------------------------------|
| `ANTHROPIC_API_KEY`   | (required)           | your API key                     |
| `CLAUDE_MODEL`        | `claude-opus-4-7`    | any current Claude model id      |
| `CLAUDE_MAX_TOKENS`   | `1024`               | response cap                     |
| `TEMPLECLAUDE_SOCK`   | `/tmp/templeclaude.sock` | QEMU <-> bridge socket path  |

The system prompt is tuned for TempleOS's 80-column 16-color text grid:
plain ASCII, no markdown, no em-dashes, lines under 72 cols, HolyC for
code. Edit `SYSTEM_PROMPT` in `claude_bridge.py` to taste.

## Notes

- TempleOS's 8x8 font covers only code points 0-255, so the bridge strips
  anything that doesn't fit ASCII. Non-ASCII bytes come through as `?`.
- Baud rate is pinned at 115200. The "Sleep(10)" in Terry's CommPutChar
  is left intact -- without it serial echoes stutter under emulation.
- The COM1 wire is one task only. Two HolyC tasks calling ClaudeAsk
  concurrently would interleave frames; don't do that.
- Cooperative multitasking means the receive loop yields between bytes.
  Big responses still feel snappy because the UART IRQ buffers in
  `comm_ports[1].RX_fifo` ahead of the reader.

