package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestProfileWorkspaceOverlayAndCleanup(t *testing.T) {
	for _, fail := range []bool{false, true} {
		t.Run(map[bool]string{false: "success", true: "failure"}[fail], func(t *testing.T) {
			root, row := workspaceFixture(t)
			var created string
			failure := errors.New("native verification failed")

			err := withProfileWorkspace(t.Context(), root, row, func(workspace string, active selection) error {
				created = workspace
				for name, expected := range map[string]string{
					"go.mod":         "selected module",
					"go.sum":         "selected sums",
					".go-version":    "1.26.9",
					"client_test.go": "scenario source",
				} {
					data, err := os.ReadFile(filepath.Join(active.dir, name))
					if err != nil || string(data) != expected {
						t.Fatalf("workspace %s: %q, %v", name, data, err)
					}
				}

				for _, name := range []string{"profiles", "node_modules", "coverage", "dist"} {
					if _, err := os.Stat(filepath.Join(active.dir, name)); !os.IsNotExist(err) {
						t.Fatalf("copied excluded directory %s: %v", name, err)
					}
				}
				if _, err := os.Stat(filepath.Join(active.dir, "..", "..", "harness", "server.go")); err != nil {
					t.Fatalf("local fixture path changed: %v", err)
				}

				if fail {
					return failure
				}

				return nil
			})
			if (fail && !errors.Is(err, failure)) || (!fail && err != nil) {
				t.Fatalf("workspace result: %v", err)
			}
			if _, err := os.Stat(created); !os.IsNotExist(err) {
				t.Fatalf("workspace retained after return: %v", err)
			}

			data, err := os.ReadFile(filepath.Join(root, row.suite.SuiteDir, "go.mod"))
			if err != nil || string(data) != "baseline module" {
				t.Fatalf("baseline changed: %q, %v", data, err)
			}
		})
	}
}

func TestProfileWorkspaceRejectsLinksAndCancelledWork(t *testing.T) {
	root, row := workspaceFixture(t)
	tmp := filepath.Join(t.TempDir(), "workspaces with spaces")
	if err := os.Mkdir(tmp, 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("TMPDIR", tmp)

	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	err := withProfileWorkspace(ctx, root, row, func(string, selection) error {
		t.Fatal("cancelled workspace executed its body")
		return nil
	})
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled workspace: %v", err)
	}

	link := filepath.Join(root, row.suite.SuiteDir, "linked.go")
	if err := os.Symlink(filepath.Join(root, "go", "harness", "server.go"), link); err != nil {
		t.Fatal(err)
	}

	err = withProfileWorkspace(t.Context(), root, row, func(string, selection) error {
		t.Fatal("workspace accepted a source link")
		return nil
	})
	if err == nil || !strings.Contains(err.Error(), "regular file") {
		t.Fatalf("linked source: %v", err)
	}

	entries, err := os.ReadDir(tmp)
	if err != nil || len(entries) != 0 {
		t.Fatalf("failed construction retained workspaces: %v, %v", entries, err)
	}
}

func workspaceFixture(t *testing.T) (string, selection) {
	t.Helper()

	root := filepath.Join(t.TempDir(), "client source with spaces")
	row := selection{
		profile: profile{ID: "go-fixture-1.0.1"},
		suite:   suite{SuiteDir: "go/fixture/v1"},
		dir:     filepath.Join(root, "go", "fixture", "v1", "profiles", "go-fixture-1.0.1"),
	}

	for relative, contents := range map[string]string{
		"go/harness/server.go":                                "shared fixture",
		"go/fixture/v1/client_test.go":                        "scenario source",
		"go/fixture/v1/go.mod":                                "baseline module",
		"go/fixture/v1/go.sum":                                "baseline sums",
		"go/fixture/v1/.go-version":                           "1.26.9",
		"go/fixture/v1/profiles/go-fixture-1.0.1/go.mod":      "selected module",
		"go/fixture/v1/profiles/go-fixture-1.0.1/go.sum":      "selected sums",
		"go/fixture/v1/profiles/go-fixture-1.0.1/.go-version": "1.26.9",
		"go/fixture/v1/node_modules/ignored":                  "generated",
		"go/fixture/v1/coverage/ignored":                      "generated",
		"go/fixture/v1/dist/ignored":                          "generated",
	} {
		path := filepath.Join(root, filepath.FromSlash(relative))
		if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(contents), 0600); err != nil {
			t.Fatal(err)
		}
	}

	return root, row
}
