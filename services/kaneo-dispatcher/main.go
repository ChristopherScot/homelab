package main

// THIS FILE IS YOURS. Nothing regenerates it - `homelabctl regen` writes
// only api/ and the lockfile, and `init` skips existing files.
//
// Two things it expects from server.go, which is also yours:
//
//   - handler() (http.Handler, error).
//   - the returned handler serves /metrics and the path in `probes.path`;
//     otherwise the pod fails as a scrape target and never becomes ready.
//
// What is NOT yours, because something rewrites it:
//
//   deploy/*.yaml           `homelabctl render`, from config.yaml
//   config.schema.json      `homelabctl init`, a copy of a constant

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

// version is stamped by CI with -ldflags.
var version = "dev"

func main() {
	// Every line carries who emitted it: Alloy adds pod/namespace labels
	// in Loki, but a line copied into a ticket or terminal arrives without
	// them.
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, nil)).With(
		"service", "kaneo-dispatcher",
		"team", "me-myself-and-i",
		"version", version,
	))

	h, drain, err := handler()
	if err != nil {
		slog.Error("building handler", "err", err)
		os.Exit(1)
	}

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	// govulncheck flags the missing ReadHeaderTimeout specifically; the
	// rest bound the Slowloris shape.
	srv := &http.Server{
		Addr:              "0.0.0.0:" + port,
		Handler:           h,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	// Draining inside terminationGracePeriodSeconds is what makes a
	// rollout invisible to callers.
	idle := make(chan struct{})
	go func() {
		sig := make(chan os.Signal, 1)
		signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT)
		<-sig
		slog.Info("shutting down")
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		if err := srv.Shutdown(ctx); err != nil {
			slog.Error("shutdown", "err", err)
		}
		// Shutdown waits for handlers, which answer in microseconds; the
		// work they accepted is still running. A lookup, probe or launch
		// is bounded in seconds and fits inside the grace period. A cold
		// wake is bounded in minutes and does not: it is abandoned here,
		// deliberately, and the sweep finds the card.
		drained := make(chan struct{})
		go func() { drain(); close(drained) }()
		select {
		case <-drained:
		case <-ctx.Done():
			slog.Warn("shutdown: in-flight dispatch abandoned; the sweep will find it")
		}
		close(idle)
	}()

	slog.Info("started", "addr", ":"+port)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		slog.Error("server stopped", "err", err)
		os.Exit(1)
	}
	<-idle
}
