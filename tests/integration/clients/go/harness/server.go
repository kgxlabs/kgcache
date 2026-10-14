// Package clientharness owns server processes for native client tests.
package clientharness

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const logLimit = 16 * 1024

// Options configures process startup without any client library dependency.
type Options struct {
	Executable     string
	ExtraArgs      []string
	ExtraConfig    string
	StartupTimeout time.Duration
	StopTimeout    time.Duration
	ArtifactDir    string
	FailureLabel   string
	Quiet          bool
}

// Server owns its child and temporary directory across stop/start cycles.
// Lifecycle methods must be called serially by the owner.
type Server struct {
	options    Options
	dir        string
	address    string
	config     string
	cmd        *exec.Cmd
	done       chan struct{}
	exitErr    error
	stdout     boundedLog
	stderr     boundedLog
	cleaned    bool
	reason     string
	failure    error
	reported   bool
	exitStatus string
}

type boundedLog struct {
	mu   sync.Mutex
	data []byte
}

// New acquires the data directory. Register Cleanup immediately on success.
func New(options Options) (*Server, error) {
	if options.StartupTimeout == 0 {
		options.StartupTimeout = 5 * time.Second
	}
	if options.StopTimeout == 0 {
		options.StopTimeout = 5 * time.Second
	}
	if options.StartupTimeout < 0 || options.StopTimeout < 0 {
		return nil, errors.New("fixture timeouts must be positive")
	}

	dir, err := os.MkdirTemp("", "kgcache-go-")
	if err != nil {
		return nil, fmt.Errorf("create data directory: %w", err)
	}

	return &Server{options: options, dir: dir, reason: "not started"}, nil
}

// Start waits for READY using a deadline separate from the child's lifetime.
func (s *Server) Start(ctx context.Context) (err error) {
	defer func() {
		if err != nil {
			s.failure = errors.Join(s.failure, err)
		}
	}()
	if s.cleaned || s.cmd != nil {
		return errors.New("fixture is cleaned or already running")
	}
	if err := ctx.Err(); err != nil {
		return fmt.Errorf("start server: %w", err)
	}
	bin := s.options.Executable
	if bin == "" {
		bin = os.Getenv("KGCACHE_BIN")
	}
	if !filepath.IsAbs(bin) {
		return errors.New("KGCACHE_BIN must be an absolute executable path")
	}
	info, err := os.Stat(bin)
	if err != nil {
		return fmt.Errorf("validate KGCACHE_BIN: %w", err)
	}
	if !info.Mode().IsRegular() || info.Mode().Perm()&0111 == 0 {
		return errors.New("KGCACHE_BIN must be a regular executable file")
	}

	port := "0"
	if s.address != "" {
		_, port, err = net.SplitHostPort(s.address)
		if err != nil {
			return fmt.Errorf("read restart endpoint: %w", err)
		}
	}
	s.config = fmt.Sprintf("bind 127.0.0.1\nport %s\nreuse-address yes\ncron-interval-ms 20\ndatabases 2\nsave \"\"\nappendonly no\ndbfilename state.kgc\nappenddirname aof\nappendfilename appendonly.aof\n%s\n", port, s.options.ExtraConfig)
	configPath := filepath.Join(s.dir, "kgcache.conf")
	if err := os.WriteFile(configPath, []byte(s.config), 0600); err != nil {
		return fmt.Errorf("write config: %w", err)
	}

	readyRead, readyWrite, err := os.Pipe()
	if err != nil {
		return fmt.Errorf("create READY pipe: %w", err)
	}
	defer readyRead.Close()
	defer readyWrite.Close()

	args := append([]string{}, s.options.ExtraArgs...)
	args = append(args, configPath, "--ready-fd", "3")
	cmd := exec.Command(bin, args...)
	cmd.Dir = s.dir
	cmd.ExtraFiles = []*os.File{readyWrite}
	cmd.Stdout, cmd.Stderr = &s.stdout, &s.stderr
	// Wait also joins the continuous log drainers, even for inherited pipes.
	cmd.WaitDelay = time.Second
	s.stdout.reset()
	s.stderr.reset()
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("spawn server: %w", err)
	}
	s.cmd, s.done, s.exitErr = cmd, make(chan struct{}), nil
	s.exitStatus = ""
	s.reason = "running"
	readyWrite.Close()
	go func() {
		s.exitErr = cmd.Wait()
		s.exitStatus = cmd.ProcessState.String()
		close(s.done)
	}()
	defer func() {
		if err != nil {
			s.reason = "startup failure"
			err = errors.Join(err, s.killAndWait())
		}
	}()

	type readyResult struct {
		line string
		err  error
	}
	ready := make(chan readyResult, 1)
	readerDone := make(chan struct{})
	go func() {
		defer close(readerDone)
		line, err := bufio.NewReader(io.LimitReader(readyRead, 129)).ReadString('\n')
		ready <- readyResult{line, err}
	}()
	defer func() {
		readyRead.Close()
		<-readerDone
	}()

	startup, cancel := context.WithTimeout(ctx, s.options.StartupTimeout)
	defer cancel()
	select {
	case <-startup.Done():
		return fmt.Errorf("wait for READY: %w", startup.Err())
	case <-s.done:
		return fmt.Errorf("server exited before READY: %v", s.exitErr)
	case result := <-ready:
		if result.err != nil {
			return fmt.Errorf("read READY: %w", result.err)
		}
		address, err := parseReady(result.line)
		if err != nil {
			return err
		}
		if s.address != "" && address != s.address {
			return fmt.Errorf("restart changed endpoint from %s to %s", s.address, address)
		}
		if err := startup.Err(); err != nil {
			return fmt.Errorf("startup cancelled after READY: %w", err)
		}
		select {
		case <-s.done:
			return fmt.Errorf("server exited during READY: %v", s.exitErr)
		default:
		}
		s.address = address
	}

	return nil
}

// Stop sends SIGTERM and reaps the child. Forced termination returns an error.
func (s *Server) Stop() (err error) {
	defer func() {
		if err != nil {
			s.failure = errors.Join(s.failure, err)
		}
	}()
	if s.cmd == nil {
		return nil
	}
	s.reason = "SIGTERM"
	if err := s.cmd.Process.Signal(syscall.SIGTERM); err != nil && !errors.Is(err, os.ErrProcessDone) {
		return errors.Join(fmt.Errorf("signal server: %w", err), s.killAndWait())
	}

	timer := time.NewTimer(s.options.StopTimeout)
	defer timer.Stop()
	select {
	case <-s.done:
		s.cmd = nil
		if s.exitErr != nil {
			return fmt.Errorf("unclean server exit: %w", s.exitErr)
		}
		return nil
	case <-timer.C:
		s.reason = "forced SIGKILL"
		return errors.Join(errors.New("server stop deadline exceeded, forced SIGKILL"), s.killAndWait())
	}
}

// Cleanup tries every owned resource and is safe to call repeatedly.
func (s *Server) Cleanup() error {
	if s.cleaned {
		return nil
	}
	err := s.Stop()
	if s.failure != nil {
		err = errors.Join(err, s.RetainFailure(s.failure))
	}
	err = errors.Join(err, os.RemoveAll(s.dir))
	s.cleaned = true
	return err
}

// Address is the current endpoint, preserved on restart.
func (s *Server) Address() string { return s.address }

// DataDir contains the config and persistence files.
func (s *Server) DataDir() string { return s.dir }

// RetainFailure writes bounded evidence after Stop and before Cleanup.
// Processes are always reaped before evidence is retained.
func (s *Server) RetainFailure(cause error) error {
	if s.reported {
		return nil
	}
	if s.cmd != nil {
		return errors.New("stop server before retaining failure evidence")
	}
	s.reported = true
	label := s.options.FailureLabel
	if label == "" {
		label = "go-harness"
	}
	causeText := bounded([]byte(cause.Error()))
	if !s.options.Quiet {
		fmt.Fprintf(os.Stderr, "%s: %s\nstdout:\n%s\nstderr:\n%s\n", label, causeText, s.stdout.bytes(), s.stderr.bytes())
	}
	root := s.options.ArtifactDir
	if root == "" {
		root = os.Getenv("KGCACHE_TEST_ARTIFACT_DIR")
	}
	if root == "" {
		return nil
	}
	if err := os.MkdirAll(root, 0700); err != nil {
		return fmt.Errorf("create artifact root: %w", err)
	}
	label = regexp.MustCompile(`[^a-zA-Z0-9.-]`).ReplaceAllString(label, "_")
	if len(label) > 120 {
		label = label[:120]
	}
	destination, err := os.MkdirTemp(root, label+"-")
	if err != nil {
		return fmt.Errorf("create failure bundle: %w", err)
	}
	files, err := persistenceListing(s.dir)
	if err != nil {
		return fmt.Errorf("list persistence evidence: %w", err)
	}
	evidence := struct {
		Label, Cause, Address, ExitStatus, TerminationReason string
		Files                                                []fileEvidence
	}{label, string(causeText), s.address, s.exitStatus, s.reason, files}
	metadata, err := json.MarshalIndent(evidence, "", "  ")
	if err != nil {
		return fmt.Errorf("encode failure evidence: %w", err)
	}
	for name, data := range map[string][]byte{
		"failure.json": metadata,
		"kgcache.conf": bounded([]byte(s.config)),
		"stdout.log":   s.stdout.bytes(),
		"stderr.log":   s.stderr.bytes(),
	} {
		if err := os.WriteFile(filepath.Join(destination, name), data, 0600); err != nil {
			return fmt.Errorf("write %s: %w", name, err)
		}
	}
	return nil
}

type fileEvidence struct {
	Path   string
	Bytes  int64
	SHA256 string `json:",omitempty"`
}

func persistenceListing(root string) ([]fileEvidence, error) {
	var files []fileEvidence
	budget := int64(1024 * 1024)
	entries := 0
	err := filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		entries++
		if entries > 64 {
			return filepath.SkipAll
		}
		if path == root || entry.IsDir() {
			return nil
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		relative, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		file := fileEvidence{Path: relative, Bytes: info.Size()}
		if info.Mode().IsRegular() && info.Size() <= budget {
			data, err := os.ReadFile(path)
			if err != nil {
				return err
			}
			file.SHA256 = fmt.Sprintf("%x", sha256.Sum256(data))
			budget -= int64(len(data))
		}
		files = append(files, file)
		return nil
	})
	return files, err
}

func bounded(data []byte) []byte {
	if len(data) > logLimit {
		return data[:logLimit]
	}
	return data
}

func (s *Server) killAndWait() error {
	if s.cmd == nil {
		return nil
	}
	err := s.cmd.Process.Kill()
	if errors.Is(err, os.ErrProcessDone) {
		err = nil
	}
	<-s.done
	s.cmd = nil
	return err
}

func parseReady(line string) (string, error) {
	parts := strings.Split(strings.TrimSuffix(line, "\n"), " ")
	if len(line) > 128 || !strings.HasSuffix(line, "\n") || len(parts) != 3 || parts[0] != "READY" || parts[1] != "127.0.0.1" {
		return "", fmt.Errorf("malformed READY record %q", line)
	}
	port, err := strconv.Atoi(parts[2])
	if err != nil || port < 1 || port > 65535 || strconv.Itoa(port) != parts[2] {
		return "", fmt.Errorf("invalid READY port %q", parts[2])
	}
	return net.JoinHostPort(parts[1], parts[2]), nil
}

func (b *boundedLog) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	n := len(p)
	remaining := logLimit - len(b.data)
	if len(p) > remaining {
		p = p[:remaining]
	}
	b.data = append(b.data, p...)
	return n, nil
}

func (b *boundedLog) reset() {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.data = nil
}

func (b *boundedLog) bytes() []byte {
	b.mu.Lock()
	defer b.mu.Unlock()
	return append([]byte(nil), b.data...)
}
