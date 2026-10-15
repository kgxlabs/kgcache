// Run selects the committed Go client profiles without changing their pins.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"syscall"
	"time"
)

type suite struct {
	ID            string `json:"id"`
	Language      string `json:"language"`
	Library       string `json:"library"`
	APIGeneration string `json:"apiGeneration"`
	Package       string `json:"package"`
	SuiteDir      string `json:"suiteDir"`
	Status        string `json:"status"`
}

type profile struct {
	ID                      string `json:"id"`
	SuiteID                 string `json:"suiteId"`
	ClientVersion           string `json:"clientVersion"`
	RuntimeVersion          string `json:"runtimeVersion"`
	PackageManagerVersion   string `json:"packageManagerVersion,omitempty"`
	DependencyDir           string `json:"dependencyDir"`
	Protocols               []int  `json:"protocols"`
	ExpectedDefaultProtocol int    `json:"expectedDefaultProtocol"`
	CI                      string `json:"ci"`
}

type registry struct {
	SchemaVersion int       `json:"schemaVersion"`
	Suites        []suite   `json:"suites"`
	Profiles      []profile `json:"profiles"`
}

type selection struct {
	profile
	suite suite
	dir   string
}

var (
	stableVersion = regexp.MustCompile(`^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$`)
	identifier    = regexp.MustCompile(`^[a-z][a-z0-9.-]*$`)
	nativeCase    = regexp.MustCompile(`/(RESP[23]|default)(/|$)`)
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	err := run(ctx, os.Args[1:])
	stop()

	if err != nil {
		fmt.Fprintln(os.Stderr, "Go client profiles:", err)
		var child *exec.ExitError
		if errors.As(err, &child) && child.ExitCode() > 0 {
			os.Exit(child.ExitCode())
		}

		os.Exit(1)
	}
}

func run(ctx context.Context, args []string) error {
	if len(args) == 0 {
		return errors.New("usage: run.go list|validate|deps|check|fmt|test [--profile ID | --library NAME] [-- test arguments]")
	}

	action := args[0]

	switch action {
	case "list", "validate", "deps", "check", "fmt", "test":
	default:
		return fmt.Errorf("unknown action %q", action)
	}

	flags := flag.NewFlagSet("Go client profiles", flag.ContinueOnError)
	profileID := flags.String("profile", "", "select one registered profile")
	library := flags.String("library", "", "filter required profiles by library")
	if err := flags.Parse(args[1:]); err != nil {
		return err
	}

	if action != "test" && flags.NArg() != 0 {
		return errors.New("test arguments are only allowed with test")
	}

	_, source, _, ok := runtime.Caller(0)
	if !ok {
		return errors.New("cannot locate the client registry")
	}

	root, err := filepath.EvalSymlinks(filepath.Dir(filepath.Dir(source)))
	if err != nil {
		return fmt.Errorf("resolve registry root: %w", err)
	}
	matrix, err := loadRegistry(root)
	if err != nil {
		return err
	}

	selected, err := selectProfiles(root, matrix, *profileID, *library)
	if err != nil {
		return err
	}

	for _, row := range selected {
		if err := validateManifest(row); err != nil {
			return fmt.Errorf("%s: %w", row.ID, err)
		}
	}

	if action == "list" {
		for _, row := range selected {
			fmt.Printf("%s  %s  %s  Go %s  %s\n", row.ID, row.suite.ID, row.suite.Status, row.RuntimeVersion, row.CI)
		}

		return nil
	}

	if err := validateRuntime(ctx, selected); err != nil {
		return err
	}

	if action == "check" || action == "fmt" {
		return checkCode(ctx, root, selected, action == "fmt")
	}

	var focused []string
	if action == "test" {
		focused, err = splitArguments(os.Getenv("GO_TEST_ARGS"))
		if err != nil {
			return err
		}

		focused = append(focused, flags.Args()...)
		if err := validateTestArguments(focused); err != nil {
			return err
		}
		if err := resolveTestPaths(); err != nil {
			return err
		}
		if err := goRun(ctx, filepath.Join(root, "go"), "test", "-count=1", "-timeout=30s", "run.go", "run_test.go"); err != nil {
			return fmt.Errorf("Go launcher checks: %w", err)
		}
	}

	for _, row := range selected {
		if action == "test" && row.suite.Status != "ready" {
			return fmt.Errorf("%s: client suite is still planned", row.ID)
		}

		err := withProfileWorkspace(ctx, root, row, func(workspace string, active selection) error {
			if action == "deps" || action == "test" {
				if err := goRun(ctx, active.dir, "mod", "download", "all"); err != nil {
					return fmt.Errorf("download dependencies: %w", err)
				}
			}
			if err := goRun(ctx, active.dir, "mod", "verify"); err != nil {
				return fmt.Errorf("verify dependencies: %w", err)
			}
			if err := validateResolvedVersions(ctx, workspace, active); err != nil {
				return err
			}

			if action == "test" {
				harness := selection{
					profile: profile{ID: active.ID + "-harness"},
					dir:     filepath.Join(workspace, "go", "harness"),
				}
				if err := runNativeTests(ctx, harness, nil, false); err != nil {
					return fmt.Errorf("shared Go fixture checks: %w", err)
				}

				return runNativeTests(ctx, active, focused, true)
			}

			fmt.Printf("%s: locked dependencies validated (%s suite)\n", active.ID, active.suite.Status)

			return nil
		})
		if err != nil {
			return fmt.Errorf("%s: %w", row.ID, err)
		}
	}

	return nil
}

func withProfileWorkspace(ctx context.Context, root string, row selection, run func(string, selection) error) (err error) {
	if err := ctx.Err(); err != nil {
		return err
	}

	workspace, err := os.MkdirTemp("", "kgcache-"+row.ID+"-")
	if err != nil {
		return fmt.Errorf("create dependency workspace: %w", err)
	}
	defer func() { err = errors.Join(err, os.RemoveAll(workspace)) }()

	canonical, err := filepath.EvalSymlinks(workspace)
	if err != nil {
		return fmt.Errorf("resolve dependency workspace: %w", err)
	}
	workspace = canonical

	fmt.Printf("%s: isolated workspace: %s\n", row.ID, workspace)
	active := row
	active.dir = filepath.Join(workspace, filepath.FromSlash(row.suite.SuiteDir))

	for _, relative := range []string{row.suite.SuiteDir, "go/harness"} {
		if err := copyTree(ctx, filepath.Join(root, filepath.FromSlash(relative)), filepath.Join(workspace, filepath.FromSlash(relative))); err != nil {
			return fmt.Errorf("copy %s: %w", relative, err)
		}
	}

	for _, name := range []string{"go.mod", "go.sum", ".go-version"} {
		if err := copyFile(filepath.Join(row.dir, name), filepath.Join(active.dir, name)); err != nil {
			return fmt.Errorf("overlay %s: %w", name, err)
		}
	}
	if err := ctx.Err(); err != nil {
		return err
	}

	return run(workspace, active)
}

func copyTree(ctx context.Context, source, destination string) error {
	return filepath.WalkDir(source, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if err := ctx.Err(); err != nil {
			return err
		}

		if entry.IsDir() {
			switch entry.Name() {
			case "profiles", "node_modules", ".git", ".zig-cache", "zig-out", ".workspaces", "coverage", "dist", "build", "test-artifacts":
				return filepath.SkipDir
			}
		}

		relative, err := filepath.Rel(source, path)
		if err != nil {
			return err
		}

		target := filepath.Join(destination, relative)
		if entry.IsDir() {
			return os.MkdirAll(target, 0755)
		}

		return copyFile(path, target)
	})
}

func copyFile(source, destination string) error {
	info, err := os.Lstat(source)
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() {
		return fmt.Errorf("source must be a regular file: %s", source)
	}

	input, err := os.Open(source)
	if err != nil {
		return err
	}
	defer input.Close()

	output, err := os.OpenFile(destination, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, info.Mode().Perm())
	if err != nil {
		return err
	}

	_, err = io.Copy(output, input)

	return errors.Join(err, output.Close())
}

func runNativeTests(parent context.Context, row selection, focused []string, requireClientCases bool) error {
	fmt.Printf("%s: native tests\n", row.ID)
	args := append([]string{"test", "-timeout=5m"}, focused...)
	args = append(args, "-json", "-mod=readonly", "-count=1", "./...")
	ctx, cancel := context.WithTimeout(parent, 5*time.Minute)
	defer cancel()

	cmd := goCommand(ctx, row.dir, args...)
	cmd.Env = append(cmd.Env, "KGCACHE_CLIENT_PROFILE="+row.ID)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.WaitDelay = 5 * time.Second
	output, err := cmd.StdoutPipe()
	if err != nil {
		return fmt.Errorf("%s: capture native output: %w", row.ID, err)
	}

	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("%s: start native tests: %w", row.ID, err)
	}

	// The whole native process group is owned, including fixture children.
	watchDone := make(chan struct{})
	watchJoined := make(chan struct{})
	go func() {
		defer close(watchJoined)

		select {
		case <-ctx.Done():
			syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)

			select {
			case <-watchDone:
			case <-time.After(5 * time.Second):
				syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
			}
		case <-watchDone:
		}
	}()

	decoder := json.NewDecoder(output)
	passed := make(map[string]bool)
	parents := make(map[string]bool)
	var transcript []byte
	var decodeErr error

	for {
		var event struct {
			Action, Test, Output string
		}
		if err := decoder.Decode(&event); err != nil {
			if err != io.EOF {
				decodeErr = fmt.Errorf("decode native test event: %w", err)
				syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
			}

			break
		}

		fmt.Print(event.Output)
		transcript = append(transcript, event.Output...)
		if len(transcript) > 64*1024 {
			transcript = append([]byte(nil), transcript[len(transcript)-64*1024:]...)
		}

		if event.Action == "run" {
			if index := strings.LastIndex(event.Test, "/"); index >= 0 {
				parents[event.Test[:index]] = true
			}
		}

		if event.Action == "pass" && nativeCase.MatchString(event.Test) {
			passed[event.Test] = true
		}
	}

	waitErr := cmd.Wait()
	close(watchDone)
	<-watchJoined
	groupErr := reapNativeGroup(cmd.Process.Pid)
	if ctx.Err() != nil {
		waitErr = errors.Join(waitErr, fmt.Errorf("native suite cancelled: %w", ctx.Err()))
	}

	err = errors.Join(decodeErr, waitErr, groupErr)
	executed := 0

	for name := range passed {
		if !parents[name] {
			executed++
		}
	}

	if err == nil && requireClientCases && executed == 0 {
		err = errors.New("zero executed client cases (fixture checks do not count)")
	}

	if err != nil {
		if root := os.Getenv("KGCACHE_TEST_ARTIFACT_DIR"); root != "" {
			if reportErr := os.MkdirAll(root, 0700); reportErr != nil {
				err = errors.Join(err, reportErr)
			} else {
				reportErr := os.WriteFile(filepath.Join(root, row.ID+"-native.log"), transcript, 0600)
				err = errors.Join(err, reportErr)
			}
		}

		return fmt.Errorf("%s: native tests: %w", row.ID, err)
	}

	if requireClientCases {
		fmt.Printf("%s: %d client cases executed\n", row.ID, executed)
	}

	return nil
}

func reapNativeGroup(pid int) error {
	if err := syscall.Kill(-pid, 0); errors.Is(err, syscall.ESRCH) {
		return nil
	}

	err := errors.New("native tests retained a process group after exit")
	syscall.Kill(-pid, syscall.SIGTERM)
	deadline := time.Now().Add(5 * time.Second)

	for time.Now().Before(deadline) {
		if errors.Is(syscall.Kill(-pid, 0), syscall.ESRCH) {
			return err
		}

		time.Sleep(10 * time.Millisecond)
	}

	syscall.Kill(-pid, syscall.SIGKILL)

	return err
}

func splitArguments(input string) ([]string, error) {
	var args []string
	var word strings.Builder
	var quote rune
	escaped, started := false, false

	for _, char := range input {
		switch {
		case escaped:
			word.WriteRune(char)
			escaped = false
		case char == '\\' && quote != '\'':
			escaped, started = true, true
		case quote != 0:
			if char == quote {
				quote = 0
			} else {
				word.WriteRune(char)
			}
		case char == '\'' || char == '"':
			quote, started = char, true
		case char == ' ' || char == '\t' || char == '\n':
			if started {
				args = append(args, word.String())
				word.Reset()
				started = false
			}
		default:
			word.WriteRune(char)
			started = true
		}
	}

	if escaped || quote != 0 {
		return nil, errors.New("GO_TEST_ARGS contains an unfinished escape or quote")
	}

	if started {
		args = append(args, word.String())
	}

	return args, nil
}

func validateTestArguments(args []string) error {
	flags := flag.NewFlagSet("native Go test arguments", flag.ContinueOnError)

	for _, name := range []string{"run", "skip", "shuffle", "cpu"} {
		flags.String(name, "", "native test option")
	}

	for _, name := range []string{"v", "race", "short", "failfast", "cover"} {
		flags.Bool(name, false, "native test option")
	}

	flags.Int("parallel", 1, "test parallelism")
	timeout := flags.Duration("timeout", 5*time.Minute, "native test timeout")
	if err := flags.Parse(args); err != nil {
		return err
	}

	if flags.NArg() != 0 || *timeout <= 0 || *timeout > 5*time.Minute {
		return errors.New("test arguments must be supported native flags, with a timeout between 0 and 5m")
	}

	return nil
}

func resolveTestPaths() error {
	bin := os.Getenv("KGCACHE_BIN")
	info, err := os.Stat(bin)
	if !filepath.IsAbs(bin) || err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0111 == 0 {
		return errors.New("KGCACHE_BIN must be an absolute regular executable path")
	}

	if root := os.Getenv("KGCACHE_TEST_ARTIFACT_DIR"); root != "" {
		absolute, err := filepath.Abs(root)
		if err != nil {
			return fmt.Errorf("resolve artifact root: %w", err)
		}

		return os.Setenv("KGCACHE_TEST_ARTIFACT_DIR", absolute)
	}

	return nil
}

func loadRegistry(root string) (registry, error) {
	var matrix registry
	file, err := os.Open(filepath.Join(root, "matrix.json"))
	if err != nil {
		return matrix, fmt.Errorf("open registry: %w", err)
	}

	defer file.Close()

	decoder := json.NewDecoder(file)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&matrix); err != nil {
		return matrix, fmt.Errorf("parse registry: %w", err)
	}

	if err := decoder.Decode(new(any)); err != io.EOF {
		return matrix, errors.New("registry must contain one JSON object")
	}

	if matrix.SchemaVersion != 1 || len(matrix.Suites) == 0 || len(matrix.Profiles) == 0 {
		return matrix, errors.New("registry requires schemaVersion 1, suites, and profiles")
	}

	suites := make(map[string]suite)

	for _, s := range matrix.Suites {
		if _, exists := suites[s.ID]; exists || !identifier.MatchString(s.ID) {
			return matrix, fmt.Errorf("invalid or duplicate suite ID %q", s.ID)
		}

		validLanguage := s.Language == "go" || s.Language == "node"
		validNames := identifier.MatchString(s.Library) && identifier.MatchString(s.APIGeneration)
		if !validLanguage || !validNames || s.Package == "" {
			return matrix, fmt.Errorf("%s: invalid language, library, API generation, or package", s.ID)
		}

		if s.Status != "planned" && s.Status != "ready" {
			return matrix, fmt.Errorf("%s: status must be planned or ready", s.ID)
		}

		if s.SuiteDir != s.Language+"/"+s.Library+"/"+s.APIGeneration {
			return matrix, fmt.Errorf("%s: suiteDir must match language/library/API generation", s.ID)
		}

		if _, err := registryDir(root, s.SuiteDir); err != nil {
			return matrix, fmt.Errorf("%s: %w", s.ID, err)
		}

		suites[s.ID] = s
	}

	ids := make(map[string]bool)

	for _, p := range matrix.Profiles {
		s, exists := suites[p.SuiteID]
		if ids[p.ID] || !identifier.MatchString(p.ID) || !exists {
			return matrix, fmt.Errorf("%q: invalid/duplicate profile ID or unknown suite %q", p.ID, p.SuiteID)
		}

		ids[p.ID] = true

		version := p.ClientVersion
		if s.Language == "go" {
			if !strings.HasPrefix(version, "v") {
				return matrix, fmt.Errorf("%s: Go client version requires a v prefix", p.ID)
			}

			version = strings.TrimPrefix(version, "v")
		}

		validVersions := stableVersion.MatchString(version) && stableVersion.MatchString(p.RuntimeVersion)
		validNPM := s.Language != "node" || stableVersion.MatchString(p.PackageManagerVersion)
		if !validVersions || !validNPM {
			return matrix, fmt.Errorf("%s: versions must be exact stable pins", p.ID)
		}

		if p.CI != "required" && p.CI != "advisory" {
			return matrix, fmt.Errorf("%s: ci must be required or advisory", p.ID)
		}

		protocols := make(map[int]bool)

		for _, protocol := range p.Protocols {
			if (protocol != 2 && protocol != 3) || protocols[protocol] {
				return matrix, fmt.Errorf("%s: protocols must contain distinct RESP2/RESP3 values", p.ID)
			}

			protocols[protocol] = true
		}

		if !protocols[p.ExpectedDefaultProtocol] {
			return matrix, fmt.Errorf("%s: expected default must be a declared protocol", p.ID)
		}

		if p.DependencyDir != s.SuiteDir && !strings.HasPrefix(p.DependencyDir, s.SuiteDir+"/profiles/") {
			return matrix, fmt.Errorf("%s: dependencyDir must belong to its suite", p.ID)
		}

		if _, err := registryDir(root, p.DependencyDir); err != nil {
			return matrix, fmt.Errorf("%s: %w", p.ID, err)
		}
	}

	return matrix, nil
}

func selectProfiles(root string, matrix registry, profileID, library string) ([]selection, error) {
	if profileID != "" && library != "" {
		return nil, errors.New("--profile and --library cannot be combined")
	}

	suites := make(map[string]suite)

	for _, s := range matrix.Suites {
		suites[s.ID] = s
	}

	var selected []selection

	for _, p := range matrix.Profiles {
		s := suites[p.SuiteID]
		if profileID != "" {
			if p.ID != profileID {
				continue
			}

			if s.Language != "go" {
				return nil, fmt.Errorf("%s belongs to %s, not Go", p.ID, s.Language)
			}
		} else if s.Language != "go" || p.CI != "required" || (library != "" && s.Library != library) {
			continue
		}

		dir, err := registryDir(root, p.DependencyDir)
		if err != nil {
			return nil, err
		}

		selected = append(selected, selection{profile: p, suite: s, dir: dir})
	}

	if len(selected) == 0 {
		return nil, fmt.Errorf("no Go profiles match profile=%q library=%q", profileID, library)
	}

	return selected, nil
}

func validateManifest(row selection) error {
	for _, name := range []string{"go.mod", "go.sum", ".go-version"} {
		info, err := os.Stat(filepath.Join(row.dir, name))
		if err != nil || !info.Mode().IsRegular() || info.Size() == 0 {
			return fmt.Errorf("missing or empty %s", name)
		}
	}

	version, err := os.ReadFile(filepath.Join(row.dir, ".go-version"))
	if err != nil {
		return err
	}

	if strings.TrimSpace(string(version)) != row.RuntimeVersion {
		return errors.New(".go-version does not match runtimeVersion")
	}

	manifest, err := os.ReadFile(filepath.Join(row.dir, "go.mod"))
	if err != nil {
		return err
	}

	pins := map[string]string{
		"go":                          row.RuntimeVersion,
		row.suite.Package:             row.ClientVersion,
		"github.com/stretchr/testify": "v1.11.1",
	}

	for name, version := range pins {
		pin := regexp.MustCompile(`(?m)^\s*` + regexp.QuoteMeta(name) + `\s+` + regexp.QuoteMeta(version) + `\s*(?://[^\n]*)?$`)
		if !pin.Match(manifest) {
			return fmt.Errorf("go.mod must pin %s %s", name, version)
		}
	}

	return nil
}

func validateRuntime(ctx context.Context, rows []selection) error {
	version := rows[0].RuntimeVersion

	for _, row := range rows {
		if row.RuntimeVersion != version {
			return errors.New("selected profiles require different Go versions; invoke each --profile separately with its pinned runtime")
		}
	}

	actual, err := goCommand(ctx, "", "env", "GOVERSION").Output()
	if err != nil {
		return fmt.Errorf("read Go runtime: %w", err)
	}

	installedVersion := strings.TrimSpace(string(actual))
	if installedVersion != "go"+version {
		return fmt.Errorf("selected profiles require Go %s; installed runtime is %s (set GO to the pinned executable)", version, installedVersion)
	}

	return nil
}

func checkCode(ctx context.Context, root string, rows []selection, format bool) error {
	goroot, err := goCommand(ctx, "", "env", "GOROOT").Output()
	if err != nil {
		return fmt.Errorf("locate pinned formatter: %w", err)
	}

	mode := "-l"
	if format {
		mode = "-w"
	}

	gofmtPath := filepath.Join(strings.TrimSpace(string(goroot)), "bin", "gofmt")
	cmd := exec.Command(gofmtPath, mode, filepath.Join(root, "go"))
	cmd.Stderr = os.Stderr
	output, err := cmd.Output()
	if err != nil {
		return fmt.Errorf("format Go sources: %w", err)
	}

	if !format && len(output) != 0 {
		return fmt.Errorf("run make fmt-go for:\n%s", output)
	}

	if format {
		return nil
	}

	if err := goRun(ctx, filepath.Join(root, "go"), "vet", "run.go", "run_test.go"); err != nil {
		return fmt.Errorf("vet launcher: %w", err)
	}

	if err := goRun(ctx, filepath.Join(root, "go", "harness"), "vet", "-mod=readonly", "./..."); err != nil {
		return fmt.Errorf("vet harness: %w", err)
	}

	for _, row := range rows {
		err := withProfileWorkspace(ctx, root, row, func(_ string, active selection) error {
			return goRun(ctx, active.dir, "vet", "-mod=readonly", "./...")
		})
		if err != nil {
			return fmt.Errorf("%s: vet suite: %w", row.ID, err)
		}
	}

	return nil
}

func goRun(ctx context.Context, dir string, args ...string) error {
	cmd := goCommand(ctx, dir, args...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr

	err := cmd.Run()
	if cmd.Process != nil {
		err = errors.Join(err, reapNativeGroup(cmd.Process.Pid))
	}

	return err
}

func validateResolvedVersions(ctx context.Context, root string, row selection) error {
	cmd := goCommand(ctx, row.dir, "list", "-mod=readonly", "-m", "-json",
		row.suite.Package, "github.com/stretchr/testify", "kgcache.test/clientharness")
	output, err := cmd.Output()
	if err != nil {
		var child *exec.ExitError
		if errors.As(err, &child) {
			return fmt.Errorf("resolve modules: %s: %w", strings.TrimSpace(string(child.Stderr)), err)
		}

		return fmt.Errorf("resolve modules: %w", err)
	}

	decoder := json.NewDecoder(strings.NewReader(string(output)))
	expected := map[string]string{
		row.suite.Package:             row.ClientVersion,
		"github.com/stretchr/testify": "v1.11.1",
		"kgcache.test/clientharness":  "v0.0.0",
	}

	for decoder.More() {
		var module struct {
			Path, Version string
			Replace       *struct{ Dir string }
		}
		if err := decoder.Decode(&module); err != nil {
			return fmt.Errorf("parse resolved module: %w", err)
		}

		version, exists := expected[module.Path]
		if !exists || module.Version != version {
			return fmt.Errorf("unexpected resolved module %s %s", module.Path, module.Version)
		}

		if module.Path == "kgcache.test/clientharness" {
			harness, err := registryDir(root, "go/harness")
			if err != nil {
				return err
			}

			if module.Replace == nil || filepath.Clean(module.Replace.Dir) != harness {
				return errors.New("clientharness must use the local go/harness module")
			}
		} else if module.Replace != nil {
			return fmt.Errorf("%s must use its published pinned module, without replace", module.Path)
		}

		delete(expected, module.Path)
	}

	if len(expected) != 0 {
		return errors.New("resolved module output omitted required dependencies")
	}

	return nil
}

func registryDir(root, relative string) (string, error) {
	if relative == "" || filepath.IsAbs(relative) || filepath.ToSlash(filepath.Clean(relative)) != relative {
		return "", fmt.Errorf("invalid registry directory %q", relative)
	}

	dir, err := filepath.EvalSymlinks(filepath.Join(root, relative))
	if err != nil {
		return "", fmt.Errorf("resolve directory %q: %w", relative, err)
	}

	if !strings.HasPrefix(dir, root+string(os.PathSeparator)) {
		return "", fmt.Errorf("directory %q leaves the registry root", relative)
	}

	info, err := os.Stat(dir)
	if err != nil || !info.IsDir() {
		return "", fmt.Errorf("%q must be a directory", relative)
	}

	return dir, nil
}

func goCommand(ctx context.Context, dir string, args ...string) *exec.Cmd {
	command := os.Getenv("GO")
	if command == "" {
		command = "go"
	}

	if resolved, err := exec.LookPath(command); err == nil {
		if absolute, err := filepath.Abs(resolved); err == nil {
			command = absolute
		}
	}

	cmd := exec.CommandContext(ctx, command, args...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error {
		err := syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
		if errors.Is(err, syscall.ESRCH) {
			return os.ErrProcessDone
		}

		return err
	}
	cmd.WaitDelay = 5 * time.Second
	cmd.Dir = dir
	cmd.Env = append(os.Environ(), "GOTOOLCHAIN=local", "GOWORK=off")

	return cmd
}
