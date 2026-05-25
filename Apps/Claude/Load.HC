/* Boot loader for the Claude app. Cd into here, pull in Claude.HC. */
#exe {Cd(__DIR__);};
#include "Claude"
#exe {Cd("..");};

"$$LTGREEN$$Claude loaded.$$FG$$ Try: $$LTCYAN$$ClaudeAsk;$$FG$$ or $$LTCYAN$$ClaudeOracle;$$FG$$\n";
