package clientharness

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestServerStartStopRestart(t *testing.T) {
	s := newTestServer(t, Options{})
	if err := s.Start(context.Background()); err != nil {
		t.Fatal(err)
	}
	address, pid := s.Address(), s.cmd.Process.Pid
	if address == "" {
		t.Fatal("missing READY address")
	}
	marker := filepath.Join(s.DataDir(), "marker")
	if err := os.WriteFile(marker, []byte("preserved"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := s.Stop(); err != nil {
		t.Fatal(err)
	}
	assertReaped(t, s, pid)
	if err := s.Start(context.Background()); err != nil {
		t.Fatal(err)
	}
	if s.Address() != address {
		t.Fatalf("restart address: %s, want %s", s.Address(), address)
	}
	data, err := os.ReadFile(marker)
	if err != nil || string(data) != "preserved" {
		t.Fatalf("restart lost data: %q, %v", data, err)
	}
	if err := s.Cleanup(); err != nil {
		t.Fatal(err)
	}
	if err := s.Cleanup(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(s.DataDir()); !os.IsNotExist(err) {
		t.Fatalf("cleanup retained directory: %v", err)
	}
}

func TestServersHaveSeparatePortsAndDirectories(t *testing.T) {
	first, second := newTestServer(t, Options{}), newTestServer(t, Options{})
	for _, s := range []*Server{first, second} {
		if err := s.Start(context.Background()); err != nil {
			t.Fatal(err)
		}
	}
	if first.Address() == second.Address() || first.DataDir() == second.DataDir() {
		t.Fatal("fixtures shared an endpoint or directory")
	}
}

func TestServerRejectedStartup(t *testing.T) {
	s := newTestServer(t, Options{ExtraConfig: "unknown-fixture-directive yes", Quiet: true})
	if err := s.Start(context.Background()); err == nil {
		t.Fatal("invalid config accepted")
	}
	assertReaped(t, s, 0)
	if len(s.stderr.bytes()) == 0 {
		t.Fatal("rejected config omitted diagnostics")
	}
	for range 2 {
		if err := s.Cleanup(); err != nil {
			t.Fatal(err)
		}
	}
}

func TestServerReadinessFailures(t *testing.T) {
	for _, mode := range []string{"malformed", "eof", "partial", "early-exit", "bad-host", "bad-port", "oversized"} {
		t.Run(mode, func(t *testing.T) {
			s := newTestServer(t, helperOptions(t, mode))
			if err := s.Start(context.Background()); err == nil {
				t.Fatal("bad readiness accepted")
			}
			assertReaped(t, s, 0)
			if err := s.Cleanup(); err != nil {
				t.Fatal(err)
			}
			if err := s.Cleanup(); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestServerSplitReadinessAndContinuousBoundedLogs(t *testing.T) {
	s := newTestServer(t, helperOptions(t, "split-logs"))
	if err := s.Start(context.Background()); err != nil {
		t.Fatal(err)
	}
	if s.Address() != "127.0.0.1:12345" {
		t.Fatalf("split READY address: %s", s.Address())
	}
	if err := s.Stop(); err != nil {
		t.Fatal(err)
	}
	assertReaped(t, s, 0)
	if len(s.stdout.bytes()) != logLimit || len(s.stderr.bytes()) != logLimit {
		t.Fatal("logs were not bounded and continuously drained")
	}
}

func TestServerStartupDeadlineAndCancellation(t *testing.T) {
	for _, mode := range []string{"deadline", "cancellation", "already-cancelled"} {
		t.Run(mode, func(t *testing.T) {
			options := helperOptions(t, "blocked")
			options.StartupTimeout = 100 * time.Millisecond
			s := newTestServer(t, options)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			want := context.DeadlineExceeded
			if mode == "cancellation" {
				timer := time.AfterFunc(50*time.Millisecond, cancel)
				defer timer.Stop()
				want = context.Canceled
			} else if mode == "already-cancelled" {
				cancel()
				want = context.Canceled
			}

			err := s.Start(ctx)
			if !errors.Is(err, want) {
				t.Fatalf("startup error: %v, want %v", err, want)
			}
			if mode != "already-cancelled" {
				assertReaped(t, s, 0)
			} else if s.cmd != nil || s.done != nil {
				t.Fatal("cancelled startup acquired a child")
			}
		})
	}
}

func TestServerPartialAcquisition(t *testing.T) {
	for _, mode := range []string{"relative", "missing", "directory", "not-executable", "spawn", "config"} {
		t.Run(mode, func(t *testing.T) {
			options := Options{Quiet: true}
			s := newTestServer(t, options)
			switch mode {
			case "relative":
				s.options.Executable = "relative/kgcache"
			case "missing":
				s.options.Executable = filepath.Join(t.TempDir(), "missing")
			case "directory":
				s.options.Executable = t.TempDir()
			case "not-executable", "spawn":
				file := filepath.Join(t.TempDir(), "invalid-binary")
				perm := os.FileMode(0600)
				if mode == "spawn" {
					perm = 0700
				}
				if err := os.WriteFile(file, []byte("invalid executable"), perm); err != nil {
					t.Fatal(err)
				}
				s.options.Executable = file
			case "config":
				if err := os.Mkdir(filepath.Join(s.DataDir(), "kgcache.conf"), 0700); err != nil {
					t.Fatal(err)
				}
			}
			if err := s.Start(context.Background()); err == nil {
				t.Fatal("partial startup unexpectedly succeeded")
			}
			if s.cmd != nil {
				t.Fatal("partial acquisition left a child")
			}
			for range 2 {
				if err := s.Cleanup(); err != nil {
					t.Fatal(err)
				}
			}
			if _, err := os.Stat(s.DataDir()); !os.IsNotExist(err) {
				t.Fatalf("partial acquisition retained directory: %v", err)
			}
		})
	}
}

func TestServerForcedStopFailsAndRetainsEvidence(t *testing.T) {
	options := helperOptions(t, "stubborn")
	options.StopTimeout = 100 * time.Millisecond
	options.ArtifactDir = t.TempDir()
	options.FailureLabel = "go-harness-forced-stop"
	s := newTestServer(t, options)
	if err := s.Start(context.Background()); err != nil {
		t.Fatal(err)
	}
	started := time.Now()
	if err := s.Stop(); err == nil || !strings.Contains(err.Error(), "forced SIGKILL") {
		t.Fatalf("forced stop did not fail: %v", err)
	}
	if time.Since(started) > 3*time.Second {
		t.Fatal("forced stop exceeded cleanup bound")
	}
	assertReaped(t, s, 0)
	if err := s.Cleanup(); err != nil {
		t.Fatal(err)
	}
	bundles, err := os.ReadDir(options.ArtifactDir)
	if err != nil || len(bundles) != 1 {
		t.Fatalf("failure bundles: %v, %v", bundles, err)
	}
	dir := filepath.Join(options.ArtifactDir, bundles[0].Name())
	for _, name := range []string{"kgcache.conf", "stdout.log", "stderr.log", "failure.json"} {
		data, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil || len(data) > 32*1024 {
			t.Fatalf("bounded evidence %s: %v, %d bytes", name, err, len(data))
		}
		if name == "failure.json" && (!strings.Contains(string(data), "forced SIGKILL") || !strings.Contains(string(data), "signal: killed")) {
			t.Fatalf("missing termination evidence: %s", data)
		}
	}
}

func TestServerRejectsChangedRestartEndpoint(t *testing.T) {
	s := newTestServer(t, helperOptions(t, "split-logs"))
	s.address = "127.0.0.1:23456"
	if err := s.Start(context.Background()); err == nil || !strings.Contains(err.Error(), "restart changed endpoint") {
		t.Fatalf("restart error: %v", err)
	}
	assertReaped(t, s, 0)
}

// TestFixtureHelper is a child process, never a background assertion goroutine.
func TestFixtureHelper(t *testing.T) {
	index := -1
	for i, arg := range os.Args {
		if arg == "--fixture-helper" {
			index = i
			break
		}
	}
	if index < 0 {
		return
	}
	mode := os.Args[index+1]
	ready := os.NewFile(3, "ready")
	terminated := make(chan os.Signal, 1)
	signal.Notify(terminated, syscall.SIGTERM)
	if mode == "stubborn" {
		signal.Ignore(syscall.SIGTERM)
	}

	switch mode {
	case "early-exit":
		os.Exit(23)
	case "blocked":
	case "eof":
		ready.Close()
	case "partial":
		fmt.Fprint(ready, "READY 127.0.0.1 12345")
		ready.Close()
	case "malformed":
		fmt.Fprintln(ready, "not a READY record")
	case "bad-host":
		fmt.Fprintln(ready, "READY 0.0.0.0 12345")
	case "bad-port":
		fmt.Fprintln(ready, "READY 127.0.0.1 0")
	case "oversized":
		fmt.Fprint(ready, strings.Repeat("x", 256))
	case "split-logs":
		io.WriteString(os.Stdout, strings.Repeat("o", 2*logLimit))
		io.WriteString(os.Stderr, strings.Repeat("e", 2*logLimit))
		for _, piece := range []string{"REA", "DY 127.", "0.0.1 12345", "\n"} {
			fmt.Fprint(ready, piece)
			time.Sleep(5 * time.Millisecond)
		}
		ready.Close()
	case "stubborn":
		fmt.Fprintln(ready, "READY 127.0.0.1 12345")
		ready.Close()
	default:
		os.Exit(24)
	}
	<-terminated
	os.Exit(0)
}

func helperOptions(t *testing.T, mode string) Options {
	t.Helper()
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	return Options{
		Executable:     executable,
		ExtraArgs:      []string{"-test.run=^TestFixtureHelper$", "--", "--fixture-helper", mode},
		StartupTimeout: 3 * time.Second,
		Quiet:          true,
	}
}

func newTestServer(t *testing.T, options Options) *Server {
	t.Helper()
	if options.Quiet && options.ArtifactDir == "" {
		options.DisableArtifacts = true
	}
	s, err := New(options)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := s.Cleanup(); err != nil {
			t.Error(err)
		}
	})
	return s
}

func assertReaped(t *testing.T, s *Server, pid int) {
	t.Helper()
	if s.cmd != nil {
		t.Fatalf("child %d still owned", pid)
	}
	select {
	case <-s.done:
	default:
		t.Fatalf("child %d and its log drainers were not joined", pid)
	}
}
