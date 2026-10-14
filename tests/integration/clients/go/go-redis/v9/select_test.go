package clienttests

import (
	"testing"

	"github.com/redis/go-redis/v9"
	"github.com/stretchr/testify/assert"
	"kgcache.test/clientharness"
)

func TestInitialDatabase(t *testing.T) {
	explicitProtocols(t, func(t *testing.T, protocol int) {
		f := newFixture(t, protocol, clientharness.Options{})
		db1 := f.client(t, clientOptions{db: 1})
		db0 := f.client(t, clientOptions{})
		if !assert.NoError(t, db1.Set(f.ctx, "shared-key", "one", 0).Err()) {
			return
		}
		_, err := db0.Get(f.ctx, "shared-key").Result()
		if !assert.ErrorIs(t, err, redis.Nil) {
			return
		}
		if !assert.NoError(t, db0.Set(f.ctx, "shared-key", "zero", 0).Err()) {
			return
		}
		for _, row := range []struct {
			client *redis.Client
			db     int
			value  string
		}{{db0, 0, "zero"}, {db1, 1, "one"}} {
			value, err := row.client.Get(f.ctx, "shared-key").Result()
			if !assert.NoError(t, err) {
				return
			}
			assert.Equal(t, row.value, value)
			info, err := row.client.ClientInfo(f.ctx).Result()
			if !assert.NoError(t, err) {
				return
			}
			assert.Equal(t, row.db, info.DB)
		}
	})
}

func TestSelectPreservesConnectionState(t *testing.T) {
	explicitProtocols(t, func(t *testing.T, protocol int) {
		f := newFixture(t, protocol, clientharness.Options{})
		client := f.client(t, clientOptions{})
		peer := f.client(t, clientOptions{})
		conn := dedicatedConn(t, client)
		if !assert.NoError(t, conn.Set(f.ctx, "key", "zero", 0).Err()) {
			return
		}
		reply, err := conn.Select(f.ctx, 1).Result()
		if !assert.NoError(t, err) || !assert.Equal(t, "OK", reply) {
			return
		}
		_, err = conn.Get(f.ctx, "key").Result()
		if !assert.ErrorIs(t, err, redis.Nil) {
			return
		}
		if !assert.NoError(t, conn.Set(f.ctx, "key", "one", 0).Err()) {
			return
		}
		var commandErr redis.Error
		err = conn.Select(f.ctx, 2).Err()
		if !assert.ErrorAs(t, err, &commandErr) {
			return
		}
		assert.Regexp(t, `(?i)DB|database`, err.Error())
		value, err := conn.Get(f.ctx, "key").Result()
		if !assert.NoError(t, err) {
			return
		}
		assert.Equal(t, "one", value)
		info, err := conn.ClientInfo(f.ctx).Result()
		if !assert.NoError(t, err) {
			return
		}
		assert.Equal(t, 1, info.DB)

		value, err = peer.Get(f.ctx, "key").Result()
		if !assert.NoError(t, err) {
			return
		}
		assert.Equal(t, "zero", value)
		if !assert.NoError(t, conn.Select(f.ctx, 0).Err()) {
			return
		}
		value, err = conn.Get(f.ctx, "key").Result()
		assert.NoError(t, err)
		assert.Equal(t, "zero", value)
	})
}
