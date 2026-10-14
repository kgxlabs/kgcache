package clienttests

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"kgcache.test/clientharness"
)

func TestHandshake(t *testing.T) {
	for _, protocol := range []int{2, 3, 0} {
		name, expected := fmt.Sprintf("RESP%d", protocol), protocol
		if protocol == 0 {
			name, expected = "default", 3
		}
		t.Run(name, func(t *testing.T) {
			f := newFixture(t, protocol, fixtureOptions{})
			client := f.client(t, clientOptions{})
			conn := dedicatedConn(t, client)
			pong, err := conn.Ping(f.ctx).Result()
			if !assert.NoError(t, err) {
				return
			}
			if !assert.Equal(t, "PONG", pong) {
				return
			}

			info, err := conn.ClientInfo(f.ctx).Result()
			if !assert.NoError(t, err) {
				return
			}
			assert.Equal(t, expected, info.Resp)
			assert.Equal(t, "go-redis(,go1.26.9)", info.LibName)
			assert.Equal(t, "9.22.0", info.LibVer)
		})
	}
}

func TestClientCleanupAfterAssertion(t *testing.T) {
	marker := filepath.Join(t.TempDir(), "fixture-directory")
	ctx, cancel := context.WithTimeout(t.Context(), 15*time.Second)
	defer cancel()
	executable, err := os.Executable()
	if !assert.NoError(t, err) {
		return
	}
	cmd := exec.CommandContext(ctx, executable, "-test.run=^TestClientAssertionCleanupHelper$")
	cmd.Env = append(os.Environ(), "KGCACHE_GO_ASSERT_HELPER="+marker)
	output, err := cmd.CombinedOutput()
	if !assert.Error(t, err) {
		return
	}
	var exit *exec.ExitError
	if !assert.ErrorAs(t, err, &exit) {
		return
	}
	assert.Equal(t, 1, exit.ExitCode())
	assert.Contains(t, string(output), "intentional assertion failure")
	assert.Contains(t, string(output), "process and log drainers joined")
	data, err := os.ReadFile(marker)
	if !assert.NoError(t, err) {
		return
	}
	_, err = os.Stat(string(data))
	assert.True(t, os.IsNotExist(err), "fixture directory retained: %v", err)
}

func TestClientAssertionCleanupHelper(t *testing.T) {
	marker := os.Getenv("KGCACHE_GO_ASSERT_HELPER")
	if marker == "" {
		t.Skip("subprocess check only")
	}
	f := newFixture(t, 3, fixtureOptions{Options: clientharness.Options{Quiet: true, DisableArtifacts: true}})
	if err := os.WriteFile(marker, []byte(f.server.DataDir()), 0600); err != nil {
		t.Fatal(err)
	}
	client := f.client(t, clientOptions{})
	conn := dedicatedConn(t, client)
	pong, err := conn.Ping(f.ctx).Result()
	if !assert.NoError(t, err) {
		return
	}
	t.Cleanup(func() {
		// Registered last to exercise explicit closure as well as idempotent owners.
		assert.NoError(t, conn.Close())
		assert.NoError(t, client.Close())
		assert.NoError(t, f.server.Stop())
		t.Log("process and log drainers joined")
	})
	assert.Equal(t, "intentional assertion failure", pong)
}
