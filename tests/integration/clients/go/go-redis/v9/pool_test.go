package clienttests

import (
	"context"
	"fmt"
	"io"
	"net"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/redis/go-redis/v9"
	"github.com/stretchr/testify/assert"
)

func TestPoolExpansionAndIdleReuse(t *testing.T) {
	explicitProtocols(t, func(t *testing.T, protocol int) {
		f := newFixture(t, protocol, fixtureOptions{})
		client := f.client(t, clientOptions{db: 1, identitySuffix: "pool", poolSize: 3})
		connections := holdPoolConnections(t, f, client, 3)
		original := poolConnectionIDs(t, f, connections)
		assert.EqualValues(t, 3, client.PoolStats().TotalConns)

		for _, conn := range connections {
			if !assert.NoError(t, conn.Close()) {
				return
			}
		}

		err := poll(f.ctx, 3*time.Second, func(context.Context) (bool, error) {
			return client.PoolStats().IdleConns == 3, nil
		})
		if !assert.NoError(t, err) {
			return
		}

		reused := holdPoolConnections(t, f, client, 3)
		assert.ElementsMatch(t, original, poolConnectionIDs(t, f, reused))

		for i, conn := range reused {
			key, value := fmt.Sprintf("reused:%d", i), fmt.Sprintf("value:%d", i)
			reply, err := conn.Set(f.ctx, key, value, 0).Result()
			if !assert.NoError(t, err) || !assert.Equal(t, "OK", reply) {
				return
			}

			actual, err := conn.Get(f.ctx, key).Result()
			if !assert.NoError(t, err) {
				return
			}
			assert.Equal(t, value, actual)
		}
	})
}

func TestConcurrentCommandResults(t *testing.T) {
	explicitProtocols(t, func(t *testing.T, protocol int) {
		f := newFixture(t, protocol, fixtureOptions{})
		client := f.client(t, clientOptions{poolSize: 3})
		values := []string{
			strings.Repeat("alpha:", 64),
			strings.Repeat("bravo:", 64),
			strings.Repeat("charlie:", 64),
			strings.Repeat("delta:", 64),
		}
		if !assert.NoError(t, client.Set(f.ctx, "shared", values[0], 0).Err()) {
			return
		}

		ctx, cancel := context.WithCancel(f.ctx)
		defer cancel()

		start := make(chan struct{})
		results := make(chan error, len(values))
		var workers sync.WaitGroup

		for worker := range values {
			workers.Go(func() {
				<-start
				err := concurrentWorker(ctx, client, worker, values)
				if err != nil {
					cancel()
				}

				results <- err
			})
		}
		close(start)
		workers.Wait()
		close(results)

		for err := range results {
			assert.NoError(t, err)
		}

		pong, err := client.Ping(f.ctx).Result()
		assert.NoError(t, err)
		assert.Equal(t, "PONG", pong)
	})
}

func TestMalformedPeerIsolation(t *testing.T) {
	explicitProtocols(t, func(t *testing.T, protocol int) {
		f := newFixture(t, protocol, fixtureOptions{})
		client := f.client(t, clientOptions{db: 1, identitySuffix: "pool", poolSize: 3})
		connections := holdPoolConnections(t, f, client, 3)
		original := poolConnectionIDs(t, f, connections)

		raw, err := (&net.Dialer{Timeout: 3 * time.Second}).DialContext(f.ctx, "tcp", f.server.Address())
		if !assert.NoError(t, err) {
			return
		}
		t.Cleanup(func() { raw.Close() })

		if !assert.NoError(t, raw.SetDeadline(time.Now().Add(3*time.Second))) {
			return
		}
		if _, err := io.WriteString(raw, "*1\r\n:42\r\n"); !assert.NoError(t, err) {
			return
		}

		reply, err := io.ReadAll(io.LimitReader(raw, 1024))
		if !assert.NoError(t, err) {
			return
		}
		assert.Equal(t, "-ERR protocol error: invalid RESP type\r\n", string(reply))
		assert.NoError(t, raw.Close())

		for i, conn := range connections {
			pong, err := conn.Ping(f.ctx).Result()
			if !assert.NoError(t, err) || !assert.Equal(t, "PONG", pong) {
				return
			}

			key, value := fmt.Sprintf("healthy:%d", i), fmt.Sprintf("intact:%d", i)
			if !assert.NoError(t, conn.Set(f.ctx, key, value, 0).Err()) {
				return
			}

			actual, err := conn.Get(f.ctx, key).Result()
			if !assert.NoError(t, err) {
				return
			}
			assert.Equal(t, value, actual)
		}

		assert.Equal(t, original, poolConnectionIDs(t, f, connections))
	})
}

func holdPoolConnections(t *testing.T, f *fixture, client *redis.Client, count int) []*redis.Conn {
	t.Helper()

	connections := make([]*redis.Conn, 0, count)

	for range count {
		conn := dedicatedConn(t, client)
		if !assert.NoError(t, conn.Ping(f.ctx).Err()) {
			t.FailNow()
		}

		connections = append(connections, conn)
	}

	return connections
}

func poolConnectionIDs(t *testing.T, f *fixture, connections []*redis.Conn) []int64 {
	t.Helper()

	ids := make([]int64, 0, len(connections))

	for _, conn := range connections {
		info, err := conn.ClientInfo(f.ctx).Result()
		if !assert.NoError(t, err) {
			t.FailNow()
		}

		assert.Positive(t, info.ID)
		assert.NotContains(t, ids, info.ID, "held connections must have distinct IDs")
		assert.Equal(t, 1, info.DB)
		assert.Equal(t, f.protocol, info.Resp)
		assert.Equal(t, libraryName("pool"), info.LibName)
		assert.Equal(t, redis.Version(), info.LibVer)
		ids = append(ids, info.ID)
	}

	return ids
}

func concurrentWorker(ctx context.Context, client *redis.Client, worker int, values []string) error {
	key := fmt.Sprintf("worker:%d", worker)

	for iteration := range 12 {
		expected := fmt.Sprintf("%d:%d:%s", worker, iteration, values[worker])
		reply, err := client.Set(ctx, key, expected, 0).Result()
		if err != nil {
			return fmt.Errorf("worker %d iteration %d SET: %w", worker, iteration, err)
		}
		if reply != "OK" {
			return fmt.Errorf("worker %d iteration %d SET returned %q", worker, iteration, reply)
		}

		actual, err := client.Get(ctx, key).Result()
		if err != nil {
			return fmt.Errorf("worker %d iteration %d GET: %w", worker, iteration, err)
		}
		if actual != expected {
			return fmt.Errorf("worker %d iteration %d GET returned %q, want %q", worker, iteration, actual, expected)
		}

		if err := client.Set(ctx, "shared", values[worker], 0).Err(); err != nil {
			return fmt.Errorf("worker %d iteration %d shared SET: %w", worker, iteration, err)
		}

		shared, err := client.Get(ctx, "shared").Result()
		if err != nil {
			return fmt.Errorf("worker %d iteration %d shared GET: %w", worker, iteration, err)
		}
		if !slices.Contains(values, shared) {
			return fmt.Errorf("worker %d iteration %d shared GET returned torn value %q", worker, iteration, shared)
		}
	}

	return nil
}
