# TempleClaude -- top-level convenience targets.
# All real work lives in run.sh; this is just shorthand.

.PHONY: setup install payload bridge run live clean help

help:
	@echo "TempleClaude make targets:"
	@echo "  setup     fetch TempleOS.ISO, build payload, create blank disk"
	@echo "  install   interactive TempleOS install into dist/templeos.qcow2"
	@echo "  payload   rebuild dist/claude_payload.iso from Apps/Claude/*"
	@echo "  bridge    run only the host bridge (foreground)"
	@echo "  run       boot installed HDD + payload + bridge"
	@echo "  live      boot live TempleOS ISO + payload + bridge (no install)"
	@echo "  clean     remove dist/"

setup:   ; ./run.sh setup
install: ; ./run.sh install
payload: ; ./run.sh payload
bridge:  ; ./run.sh bridge
run:     ; ./run.sh run
live:    ; ./run.sh live
clean:   ; rm -rf dist
