package clienttests

import (
	"context"
	"testing"
	"time"

	"github.com/redis/go-redis/v9"
	"github.com/stretchr/testify/assert"
	"kgcache.test/clientharness"
)

func TestRecoveryAfterServerRestart(t *testing.T) {
	explicitProtocols(t, func(t *testing.T, protocol int) {
		f := newFixture(t, protocol, fixtureOptions{})
		client := f.client(t, clientOptions{db: 1, identitySuffix: "recovery", recovery: true})
		if !assert.NoError(t, client.Ping(f.ctx).Err()) {
			return
		}

		address := f.server.Address()
		if !assert.NoError(t, f.server.Stop()) {
			return
		}

		err := client.Ping(f.ctx).Err()
		if !assert.Error(t, err, "the original client must observe the outage") {
			return
		}
		t.Logf("expected downtime failure: %v", err)

		if !assert.NoError(t, f.server.Start(f.ctx)) || !assert.Equal(t, address, f.server.Address()) {
			return
		}

		attempts := 0
		err = poll(f.ctx, 5*time.Second, func(ctx context.Context) (bool, error) {
			attempts++
			pong, err := client.Ping(ctx).Result()
			if err != nil {
				t.Logf("recovery attempt %d: %v", attempts, err)
				if attempts == 10 {
					return false, err
				}

				return false, nil
			}

			return pong == "PONG", nil
		})
		if !assert.NoError(t, err, "original client recovery after %d attempts", attempts) {
			return
		}

		conn := dedicatedConn(t, client)
		info, err := conn.ClientInfo(f.ctx).Result()
		if !assert.NoError(t, err) {
			return
		}
		assert.Equal(t, 1, info.DB)
		assert.Equal(t, protocol, info.Resp)
		assert.Equal(t, libraryName("recovery"), info.LibName)
		assert.Equal(t, redis.Version(), info.LibVer)

		reply, err := conn.Set(f.ctx, "after-restart", "recovered", 0).Result()
		if !assert.NoError(t, err) || !assert.Equal(t, "OK", reply) {
			return
		}

		value, err := conn.Get(f.ctx, "after-restart").Result()
		assert.NoError(t, err)
		assert.Equal(t, "recovered", value)

		observer := f.client(t, clientOptions{})
		_, err = observer.Get(f.ctx, "after-restart").Result()
		assert.ErrorIs(t, err, redis.Nil)
	})
}

func TestSetupAfterEndpointChange(t *testing.T) {
	explicitProtocols(t, func(t *testing.T, protocol int) {
		f := newFixture(t, protocol, fixtureOptions{
			Options: clientharness.Options{NewPortOnRestart: true},
		})
		oldClient := f.client(t, clientOptions{})
		if !assert.NoError(t, oldClient.Ping(f.ctx).Err()) {
			return
		}

		address, directory := f.server.Address(), f.server.DataDir()
		if !assert.NoError(t, oldClient.Close()) || !assert.NoError(t, f.server.Stop()) {
			return
		}
		if !assert.NoError(t, f.server.Start(f.ctx)) {
			return
		}
		assert.NotEqual(t, address, f.server.Address())
		assert.Equal(t, directory, f.server.DataDir())

		client := f.client(t, clientOptions{db: 1})
		conn := dedicatedConn(t, client)
		reply, err := conn.Set(f.ctx, "new-endpoint", "current-address", 0).Result()
		if !assert.NoError(t, err) || !assert.Equal(t, "OK", reply) {
			return
		}

		value, err := conn.Get(f.ctx, "new-endpoint").Result()
		assert.NoError(t, err)
		assert.Equal(t, "current-address", value)

		info, err := conn.ClientInfo(f.ctx).Result()
		if !assert.NoError(t, err) {
			return
		}
		assert.Equal(t, f.server.Address(), info.LAddr)
		assert.Equal(t, protocol, info.Resp)
		assert.Equal(t, 1, info.DB)
	})
}

func TestShutdownWithIdleClients(t *testing.T) {
	explicitProtocols(t, func(t *testing.T, protocol int) {
		f := newFixture(t, protocol, fixtureOptions{})
		client := f.client(t, clientOptions{db: 1, identitySuffix: "pool", poolSize: 3})
		connections := holdPoolConnections(t, f, client, 3)
		poolConnectionIDs(t, f, connections)

		for _, conn := range connections {
			if !assert.NoError(t, conn.Close()) {
				return
			}
		}
		if !assert.EqualValues(t, 3, client.PoolStats().IdleConns) {
			return
		}

		dedicatedClient := f.client(t, clientOptions{})
		conn := dedicatedConn(t, dedicatedClient)
		if !assert.NoError(t, conn.Ping(f.ctx).Err()) {
			return
		}

		assert.NoError(t, f.server.Stop(), "stop with idle pool and dedicated connection still open")

		// Cleanup owners remain registered if stop or explicit closure fails.
		assert.NoError(t, conn.Close())
		assert.NoError(t, dedicatedClient.Close())
		assert.NoError(t, client.Close())
	})
}
