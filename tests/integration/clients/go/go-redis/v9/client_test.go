package clienttests

import (
	"context"
	"errors"
	"fmt"
	"os"
	"runtime"
	"testing"
	"time"

	"github.com/redis/go-redis/v9"
	"kgcache.test/clientharness"
)

type fixture struct {
	server   *clientharness.Server
	ctx      context.Context
	protocol int
}

type clientOptions struct {
	db             int
	protocol       int
	identitySuffix string
	poolSize       int
	recovery       bool
}

type fixtureOptions struct {
	clientharness.Options
	scenarioTimeout time.Duration
}

func newFixture(t *testing.T, protocol int, options fixtureOptions) *fixture {
	t.Helper()

	timeout := options.scenarioTimeout
	if timeout == 0 {
		timeout = 45 * time.Second
	}

	ctx, cancel := context.WithTimeout(t.Context(), timeout)
	t.Cleanup(cancel)

	protocolName := fmt.Sprintf("RESP%d", protocol)
	if protocol == 0 {
		protocolName = "RESPdefault"
	}

	profile := os.Getenv("KGCACHE_CLIENT_PROFILE")
	if profile == "" {
		profile = "go-redis-v" + redis.Version()
	}
	options.FailureLabel = fmt.Sprintf("%s-%s-%s", profile, protocolName, t.Name())
	server, err := clientharness.New(options.Options)
	if err != nil {
		t.Fatal(err)
	}

	t.Cleanup(func() {
		stopErr := server.Stop()
		if stopErr != nil {
			t.Error(stopErr)
		}

		if t.Failed() {
			cause := errors.Join(
				fmt.Errorf("%s: assertion or cleanup failed (see native test output)", t.Name()),
				stopErr,
			)
			if err := server.RetainFailure(cause); err != nil {
				t.Error(err)
			}
		}

		if err := server.Cleanup(); err != nil {
			t.Error(err)
		}
	})

	if err := server.Start(ctx); err != nil {
		t.Fatal(err)
	}

	return &fixture{server: server, ctx: ctx, protocol: protocol}
}

func (f *fixture) client(t *testing.T, options clientOptions) *redis.Client {
	t.Helper()

	protocol := f.protocol
	if options.protocol != 0 {
		protocol = options.protocol
	}

	poolSize := options.poolSize
	if poolSize == 0 {
		poolSize = 1
	}

	var idleTimeout time.Duration
	if poolSize > 1 {
		idleTimeout = time.Minute
	}

	maxRetries := -1
	if options.recovery {
		maxRetries = 2
	}

	client := redis.NewClient(&redis.Options{
		Addr:                  f.server.Address(),
		Protocol:              protocol,
		DB:                    options.db,
		IdentitySuffix:        options.identitySuffix,
		MaxRetries:            maxRetries,
		MinRetryBackoff:       20 * time.Millisecond,
		MaxRetryBackoff:       100 * time.Millisecond,
		PoolSize:              poolSize,
		MaxActiveConns:        poolSize,
		ConnMaxIdleTime:       idleTimeout,
		DialTimeout:           3 * time.Second,
		ReadTimeout:           3 * time.Second,
		WriteTimeout:          3 * time.Second,
		PoolTimeout:           3 * time.Second,
		ContextTimeoutEnabled: true,
	})
	t.Cleanup(func() {
		if err := client.Close(); err != nil && !errors.Is(err, redis.ErrClosed) {
			t.Error("close client:", err)
		}
	})

	return client
}

func dedicatedConn(t *testing.T, client *redis.Client) *redis.Conn {
	t.Helper()

	conn := client.Conn()
	t.Cleanup(func() {
		if err := conn.Close(); err != nil && !errors.Is(err, redis.ErrClosed) {
			t.Error("close dedicated connection:", err)
		}
	})

	return conn
}

func explicitProtocols(t *testing.T, body func(t *testing.T, protocol int)) {
	t.Helper()

	for _, protocol := range []int{2, 3} {
		t.Run(fmt.Sprintf("RESP%d", protocol), func(t *testing.T) {
			body(t, protocol)
		})
	}
}

func poll(ctx context.Context, timeout time.Duration, observe func(context.Context) (bool, error)) error {
	deadline, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	for {
		if err := deadline.Err(); err != nil {
			return fmt.Errorf("poll observable state: %w", err)
		}

		matched, err := observe(deadline)
		if err != nil {
			return fmt.Errorf("poll observation: %w", err)
		}

		if matched {
			return nil
		}

		timer := time.NewTimer(20 * time.Millisecond)

		select {
		case <-deadline.Done():
			timer.Stop()

			return fmt.Errorf("poll observable state: %w", deadline.Err())
		case <-timer.C:
		}
	}
}

func libraryName(suffix string) string {
	return fmt.Sprintf("go-redis(%s,%s)", suffix, runtime.Version())
}
