package clienttests

import (
	"testing"

	"github.com/redis/go-redis/v9"
	"github.com/stretchr/testify/assert"
)

func TestStrings(t *testing.T) {
	explicitProtocols(t, func(t *testing.T, protocol int) {
		f := newFixture(t, protocol, fixtureOptions{})
		client := f.client(t, clientOptions{})

		size, err := client.DBSize(f.ctx).Result()
		if !assert.NoError(t, err) {
			return
		}
		assert.Zero(t, size)

		for _, text := range []string{"hello\r\nworld", ""} {
			reply, err := client.Echo(f.ctx, text).Result()
			if !assert.NoError(t, err) {
				return
			}
			assert.Equal(t, text, reply)
		}

		missing, err := client.Get(f.ctx, "missing").Result()
		assert.ErrorIs(t, err, redis.Nil)
		assert.Empty(t, missing)

		for _, row := range []struct{ key, value string }{
			{"key", "value"},
			{"", ""},
		} {
			reply, err := client.Set(f.ctx, row.key, row.value, 0).Result()
			if !assert.NoError(t, err) || !assert.Equal(t, "OK", reply) {
				return
			}

			value, err := client.Get(f.ctx, row.key).Result()
			if !assert.NoError(t, err) {
				return
			}
			assert.Equal(t, row.value, value)
		}

		size, err = client.DBSize(f.ctx).Result()
		if !assert.NoError(t, err) {
			return
		}
		assert.Equal(t, int64(2), size)

		deleted, err := client.Del(f.ctx, "key", "", "missing").Result()
		if !assert.NoError(t, err) {
			return
		}
		assert.Equal(t, int64(2), deleted)

		deleted, err = client.Del(f.ctx, "key", "missing").Result()
		if !assert.NoError(t, err) {
			return
		}
		assert.Zero(t, deleted)

		size, err = client.DBSize(f.ctx).Result()
		assert.NoError(t, err)
		assert.Zero(t, size)
	})
}

func TestBinaryStrings(t *testing.T) {
	explicitProtocols(t, func(t *testing.T, protocol int) {
		f := newFixture(t, protocol, fixtureOptions{})
		client := f.client(t, clientOptions{})
		key := string([]byte{0, 255, 13, 10, 128, '='})
		value := []byte{255, 0, 128, 13, 10, 195, 40}
		echo, err := client.Echo(f.ctx, string(value)).Bytes()
		if !assert.NoError(t, err) {
			return
		}
		assert.Equal(t, value, echo)

		reply, err := client.Set(f.ctx, key, value, 0).Result()
		if !assert.NoError(t, err) || !assert.Equal(t, "OK", reply) {
			return
		}

		actual, err := client.Get(f.ctx, key).Bytes()
		if !assert.NoError(t, err) {
			return
		}
		assert.Equal(t, value, actual)

		reply, err = client.Set(f.ctx, "", []byte{}, 0).Result()
		if !assert.NoError(t, err) || !assert.Equal(t, "OK", reply) {
			return
		}

		actual, err = client.Get(f.ctx, "").Bytes()
		if !assert.NoError(t, err) {
			return
		}
		assert.Equal(t, []byte{}, actual)

		_, err = client.Get(f.ctx, "missing").Bytes()
		assert.ErrorIs(t, err, redis.Nil)

		deleted, err := client.Del(f.ctx, key).Result()
		assert.NoError(t, err)
		assert.Equal(t, int64(1), deleted)
	})
}
