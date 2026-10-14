package clienttests

import (
	"context"
	"errors"
	"fmt"
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

func newFixture(t *testing.T, protocol int, options clientharness.Options) *fixture {
	t.Helper()
	timeout := 45 * time.Second
	if options.ExtraConfig != "" {
		timeout = 60 * time.Second
	}
	ctx, cancel := context.WithTimeout(t.Context(), timeout)
	t.Cleanup(cancel)
	options.FailureLabel = fmt.Sprintf("go-redis-v9.22.0-RESP%d-%s", protocol, t.Name())
	server, err := clientharness.New(options)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		stopErr := server.Stop()
		if stopErr != nil {
			t.Error(stopErr)
		}
		if t.Failed() {
			cause := errors.Join(fmt.Errorf("%s: assertion or cleanup failed (see native test output)", t.Name()), stopErr)
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

func (f *fixture) client(t *testing.T, db int) *redis.Client {
	t.Helper()
	client := redis.NewClient(&redis.Options{
		Addr:                  f.server.Address(),
		Protocol:              f.protocol,
		DB:                    db,
		MaxRetries:            -1,
		PoolSize:              1,
		MaxActiveConns:        1,
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
