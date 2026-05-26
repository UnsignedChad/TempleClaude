/*
  Once.HC -- TempleClaude per-boot user script.

  Lives at /Home/Once.HC so it overrides the stock root-level version.
  Preserves Terry's Tip of the Day, then pulls in our Claude client
  and prints a one-line banner telling the user how to invoke it.

  Originally adapted from TempleOS V5.03 /Once.HC; the BOOT_SRC_DVD
  case is gutted because TempleClaude is always a post-install boot
  and we don't want the "Install onto hard drive?" prompt nagging.
*/

U0 Tmp()
{
  OnceExe;
  switch (sys_boot_src.u16[0]) {
    case BOOT_SRC_ROM:
      "Continue booting hard drive ";
      if (YorN) {
        DocBottom;
        ExeFile("C:/Home/Once");
      }
      break;
    case BOOT_SRC_DVD:
      // intentionally empty -- TempleClaude doesn't run from live CD.
      break;
    case BOOT_SRC_RAM:
    case BOOT_SRC_HARDDRV:
      "$$PURPLE$$$$TX+CX,\"Tip of the Day\"$$$$FG$$\n";
      TipOfDay;
      break;
  }
}

Tmp;

// TempleClaude auto-load. Compiles Claude.HC into the user task and
// brings COM1 up at 115200 8N1.
#include "Claude"
ClaudeInit;

"\n";
"$$LTGREEN$$$$TX+CX,\"TempleClaude ready.\"$$$$FG$$\n";
"Type $$LTCYAN$$ClaudeAsk;$$FG$$ to talk to Claude.\n";
"Type $$LTCYAN$$ClaudeOracle;$$FG$$ for a cryptic one-liner.\n\n";
