# kaneo-dispatcher
#
# Include Makefile.local for service-specific setup; it survives regenerate.

SHELL := /bin/bash
.DEFAULT_GOAL := help

PORT ?= 8080
export PORT

.PHONY: help
help:
	@echo "kaneo-dispatcher"
	@echo
	@echo "  make build      compile"
	@echo "  make test       NewClient guard, vet and tests (what CI runs)"
	@echo "  make run        run it on :$(PORT)"
	@echo "  make regen      regenerate code derived from the spec"
	@echo "  make clean      remove build output"
ifneq (,$(wildcard Makefile.local))
	@$(MAKE) --no-print-directory help-local 2>/dev/null || true
endif

# `go build ./...` compiles every package and throws the binary away, so
# -o and the package are load-bearing.
.PHONY: build
build:
	go build -o kaneo-dispatcher .

# The grep refuses ogen's api.NewClient; its message says why. It
# matches api.NewClient( as a whole token, so otherapi.NewClient(
# passes, in any .go file, comments included; skips every directory
# named api because that is where NewClient is defined; and lets an
# aliased import slip past. Only "no match" passes: a grep that could
# not run is not a check that found nothing.
#
# -race matches CI.
.PHONY: test
test:
	@grep -rnE --include='*.go' --exclude-dir=api '(^|[^[:alnum:]_])api\.NewClient\(' . ; \
	case $$? in \
		1) ;; \
		0) echo "api.NewClient is ogen's constructor: no timeout, no retries. Call api.New(url, \"<your service's name>\") instead." >&2; exit 1 ;; \
		*) echo "api.NewClient guard: grep could not run (needs grep -rE with --include and --exclude-dir)" >&2; exit 1 ;; \
	esac
	go vet ./...
	go test -race ./...

.PHONY: run
run:
	go run .

.PHONY: regen
regen:
	@command -v homelabctl >/dev/null || { \
		echo "homelabctl not found - https://github.com/ChristopherScot/homelabctl"; exit 1; }
	@homelabctl regen

.PHONY: clean
clean:
	go clean
	rm -f kaneo-dispatcher

-include Makefile.local
