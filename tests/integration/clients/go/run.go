// Run selects the committed Go client profiles without changing their pins.
package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
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

var stableVersion = regexp.MustCompile(`^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$`)
var identifier = regexp.MustCompile(`^[a-z][a-z0-9.-]*$`)

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "Go client profiles:", err)
		var child *exec.ExitError
		if errors.As(err, &child) && child.ExitCode() > 0 {
			os.Exit(child.ExitCode())
		}
		os.Exit(1)
	}
}

func run(args []string) error {
	if len(args) == 0 {
		return errors.New("usage: run.go list|validate|deps|test [--profile ID | --library NAME] [-- test arguments]")
	}
	action := args[0]
	if action != "list" && action != "validate" && action != "deps" && action != "test" {
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
	root := filepath.Dir(filepath.Dir(source))
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
	if action == "test" {
		for _, row := range selected {
			if row.suite.Status == "planned" {
				return fmt.Errorf("%s: suite %s is planned; no client scenarios exist yet", row.ID, row.suite.ID)
			}
		}
		return errors.New("client execution requires the actual Go scenario implementation")
	}
	if err := validateRuntime(selected); err != nil {
		return err
	}
	for _, row := range selected {
		if action == "deps" {
			if err := goRun(row.dir, "mod", "download", "all"); err != nil {
				return fmt.Errorf("%s: download dependencies: %w", row.ID, err)
			}
		}
		if err := goRun(row.dir, "mod", "verify"); err != nil {
			return fmt.Errorf("%s: verify dependencies: %w", row.ID, err)
		}
		if err := validateResolvedVersions(root, row); err != nil {
			return fmt.Errorf("%s: %w", row.ID, err)
		}
		fmt.Printf("%s: locked dependencies validated (%s suite)\n", row.ID, row.suite.Status)
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
		if (s.Language != "go" && s.Language != "node") || !identifier.MatchString(s.Library) || !identifier.MatchString(s.APIGeneration) || s.Package == "" {
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
		if !stableVersion.MatchString(version) || !stableVersion.MatchString(p.RuntimeVersion) || (s.Language == "node" && !stableVersion.MatchString(p.PackageManagerVersion)) {
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
		if p.DependencyDir != s.SuiteDir {
			return nil, fmt.Errorf("%s: separate dependency workspaces require the step 04 runner", p.ID)
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
	for name, version := range map[string]string{"go": row.RuntimeVersion, row.suite.Package: row.ClientVersion, "github.com/stretchr/testify": "v1.11.1"} {
		pin := regexp.MustCompile(`(?m)^\s*` + regexp.QuoteMeta(name) + `\s+` + regexp.QuoteMeta(version) + `\s*(?://[^\n]*)?$`)
		if !pin.Match(manifest) {
			return fmt.Errorf("go.mod must pin %s %s", name, version)
		}
	}
	return nil
}

func goCommand(dir string, args ...string) *exec.Cmd {
	command := os.Getenv("GO")
	if command == "" {
		command = "go"
	}
	cmd := exec.Command(command, args...)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(), "GOTOOLCHAIN=local", "GOWORK=off")
	return cmd
}

func goRun(dir string, args ...string) error {
	cmd := goCommand(dir, args...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	return cmd.Run()
}

func validateRuntime(rows []selection) error {
	version := rows[0].RuntimeVersion
	for _, row := range rows {
		if row.RuntimeVersion != version {
			return errors.New("selected profiles require different Go versions; invoke each --profile separately with its pinned runtime")
		}
	}
	actual, err := goCommand("", "env", "GOVERSION").Output()
	if err != nil {
		return fmt.Errorf("read Go runtime: %w", err)
	}
	if strings.TrimSpace(string(actual)) != "go"+version {
		return fmt.Errorf("selected profiles require Go %s; installed runtime is %s (set GO to the pinned executable)", version, strings.TrimSpace(string(actual)))
	}
	return nil
}

func validateResolvedVersions(root string, row selection) error {
	output, err := goCommand(row.dir, "list", "-mod=readonly", "-m", "-json", row.suite.Package, "github.com/stretchr/testify", "kgcache.test/clientharness").Output()
	if err != nil {
		var child *exec.ExitError
		if errors.As(err, &child) {
			return fmt.Errorf("resolve modules: %s: %w", strings.TrimSpace(string(child.Stderr)), err)
		}
		return fmt.Errorf("resolve modules: %w", err)
	}
	decoder := json.NewDecoder(strings.NewReader(string(output)))
	expected := map[string]string{row.suite.Package: row.ClientVersion, "github.com/stretchr/testify": "v1.11.1", "kgcache.test/clientharness": "v0.0.0"}
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
