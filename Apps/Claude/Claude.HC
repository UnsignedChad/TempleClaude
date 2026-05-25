/*
  Claude.HC -- the new Oracle.

  TempleOS talks to Claude through COM1. A host-side bridge daemon
  catches the bytes coming off QEMU's emulated serial port, forwards
  the prompt to the Anthropic API, and streams the response back
  byte by byte. From TempleOS's perspective this is just a serial
  device that happens to be wise.

  Wire format (binary, host-side framing):
    [1 byte type] [4 bytes length, little-endian] [length bytes payload]

  Types:
    0x01 ASK  -- TempleOS -> bridge,   payload = UTF-8 prompt
    0x02 TOK  -- bridge   -> TempleOS, payload = streaming text chunk
    0x03 END  -- bridge   -> TempleOS, payload empty (response complete)
    0x04 ERR  -- bridge   -> TempleOS, payload = UTF-8 error string
    0x05 PNG  -- either direction,     payload empty (liveness)

  Terry's Doc/Comm.HC supplies the UART driver; we include it once.
  RS232 'no longer exists' in 2017 hardware terms, but QEMU happily
  emulates a 16550 at 0x3F8, which is what we need.
*/

#include "::/Doc/Comm.HC"

#define CLAUDE_COM_PORT  1
#define CLAUDE_BAUD      115200

#define CLAUDE_FRAME_ASK 0x01
#define CLAUDE_FRAME_TOK 0x02
#define CLAUDE_FRAME_END 0x03
#define CLAUDE_FRAME_ERR 0x04
#define CLAUDE_FRAME_PNG 0x05

Bool claude_initialized=FALSE;

public U0 ClaudeInit()
{//Bring COM1 up at 115200 8N1. Idempotent.
  if (claude_initialized) return;
  CommInit8n1(CLAUDE_COM_PORT,CLAUDE_BAUD);
  claude_initialized=TRUE;
}

I64 ClaudeRxByteBlocking()
{//Pull one byte out of the RX FIFO, yielding the task while waiting.
  I64 b=0;
  while (!FifoU8Rem(comm_ports[CLAUDE_COM_PORT].RX_fifo,&b))
    Yield;
  return b & 0xFF;
}

U0 ClaudeTxFrame(U8 type,U8 *payload,I64 len)
{//Send one framed message out COM1.
  U8 hdr[5];
  hdr[0]=type;
  hdr[1]= len      & 0xFF;
  hdr[2]=(len>>8 ) & 0xFF;
  hdr[3]=(len>>16) & 0xFF;
  hdr[4]=(len>>24) & 0xFF;
  CommPutBlk(CLAUDE_COM_PORT,hdr,5);
  if (len>0)
    CommPutBlk(CLAUDE_COM_PORT,payload,len);
}

U8 ClaudeRxFrameHeader(I64 *_len)
{//Read [type][len], return type and *_len.
  U8 type=ClaudeRxByteBlocking;
  I64 b0=ClaudeRxByteBlocking;
  I64 b1=ClaudeRxByteBlocking;
  I64 b2=ClaudeRxByteBlocking;
  I64 b3=ClaudeRxByteBlocking;
  *_len = b0 | (b1<<8) | (b2<<16) | (b3<<24);
  return type;
}

public U0 ClaudeChat(U8 *prompt)
{//Send prompt, stream the response straight to the current window.
  U8 type,*chunk;
  I64 len,i,b;
  ClaudeInit;
  if (!prompt) return;
  ClaudeTxFrame(CLAUDE_FRAME_ASK,prompt,StrLen(prompt));
  while (TRUE) {
    type=ClaudeRxFrameHeader(&len);
    switch (type) {
      case CLAUDE_FRAME_TOK:
        // Stream tokens straight out. Reading byte-at-a-time so the
        // text appears the same way Claude generates it.
        for (i=0;i<len;i++) {
          b=ClaudeRxByteBlocking;
          '' b;
        }
        break;
      case CLAUDE_FRAME_END:
        '' '\n';
        return;
      case CLAUDE_FRAME_ERR:
        chunk=MAlloc(len+1);
        for (i=0;i<len;i++) chunk[i]=ClaudeRxByteBlocking;
        chunk[len]=0;
        "$$RED$$\n[claude error] %s$$FG$$\n",chunk;
        Free(chunk);
        return;
      default:
        // Unknown frame -- drain payload and keep going. Bridge bug
        // shouldn't wedge the kernel.
        for (i=0;i<len;i++) ClaudeRxByteBlocking;
        break;
    }
  }
}

public U0 ClaudeAsk()
{//Interactive: prompt the user, ship the question, stream the answer.
  U8 *q;
  ClaudeInit;
  "\n$$LTBLUE$$Ask Claude:$$FG$$ ";
  q=GetStr;
  if (!q || !*q) {
    if (q) Free(q);
    return;
  }
  "\n";
  ClaudeChat(q);
  Free(q);
}

public U0 ClaudeOracle()
{//Drop-in replacement for PopUpOracle: ask Claude for a verse/insight
 //instead of pulling a random Bible n-gram.
  ClaudeChat("Speak as an oracle. One short, cryptic sentence of wisdom. No preface.");
}
