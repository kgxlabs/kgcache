package clienttests

import (
	"testing"

	"github.com/redis/go-redis/v9"
	"github.com/stretchr/testify/assert"
)

func TestConditionalSet(t *testing.T) {
	cases := []struct {
		name              string
		exists            bool
		mode              string
		get               bool
		reply, stored     string
		nilReply, missing bool
	}{
		{
			name:   "NX_inserts",
			mode:   "NX",
			reply:  "OK",
			stored: "new",
		},
		{
			name:     "NX_skips",
			exists:   true,
			mode:     "NX",
			nilReply: true,
			stored:   "old",
		},
		{
			name:     "XX_skips",
			mode:     "XX",
			nilReply: true,
			missing:  true,
		},
		{
			name:   "XX_replaces",
			exists: true,
			mode:   "XX",
			reply:  "OK",
			stored: "new",
		},
		{
			name:     "GET_inserts",
			get:      true,
			nilReply: true,
			stored:   "new",
		},
		{
			name:   "GET_replaces",
			exists: true,
			get:    true,
			reply:  "old",
			stored: "new",
		},
		{
			name:     "NX_GET_inserts",
			mode:     "NX",
			get:      true,
			nilReply: true,
			stored:   "new",
		},
		{
			name:   "NX_GET_skips",
			exists: true,
			mode:   "NX",
			get:    true,
			reply:  "old",
			stored: "old",
		},
		{
			name:     "XX_GET_skips",
			mode:     "XX",
			get:      true,
			nilReply: true,
			missing:  true,
		},
		{
			name:   "XX_GET_replaces",
			exists: true,
			mode:   "XX",
			get:    true,
			reply:  "old",
			stored: "new",
		},
	}

	explicitProtocols(t, func(t *testing.T, protocol int) {
		for _, row := range cases {
			t.Run(row.name, func(t *testing.T) {
				f := newFixture(t, protocol, fixtureOptions{})
				client := f.client(t, clientOptions{})

				if row.exists && !assert.NoError(t, client.Set(f.ctx, "key", "old", 0).Err()) {
					return
				}

				reply, err := client.SetArgs(f.ctx, "key", "new", redis.SetArgs{
					Mode: row.mode,
					Get:  row.get,
				}).Result()
				if row.nilReply {
					if !assert.ErrorIs(t, err, redis.Nil) {
						return
					}
				} else if !assert.NoError(t, err) {
					return
				}
				assert.Equal(t, row.reply, reply)

				stored, err := client.Get(f.ctx, "key").Result()
				if row.missing {
					assert.ErrorIs(t, err, redis.Nil)
				} else {
					assert.NoError(t, err)
				}
				assert.Equal(t, row.stored, stored)
			})
		}
	})
}

func TestConditionalSetBooleanResults(t *testing.T) {
	explicitProtocols(t, func(t *testing.T, protocol int) {
		f := newFixture(t, protocol, fixtureOptions{})
		client := f.client(t, clientOptions{})

		applied, err := client.SetNX(f.ctx, "key", "first", 0).Result()
		if !assert.NoError(t, err) || !assert.True(t, applied) {
			return
		}

		applied, err = client.SetNX(f.ctx, "key", "skipped", 0).Result()
		if !assert.NoError(t, err) || !assert.False(t, applied) {
			return
		}

		value, err := client.Get(f.ctx, "key").Result()
		if !assert.NoError(t, err) || !assert.Equal(t, "first", value) {
			return
		}

		applied, err = client.SetXX(f.ctx, "missing", "skipped", 0).Result()
		if !assert.NoError(t, err) || !assert.False(t, applied) {
			return
		}

		_, err = client.Get(f.ctx, "missing").Result()
		if !assert.ErrorIs(t, err, redis.Nil) {
			return
		}

		applied, err = client.SetXX(f.ctx, "key", "replacement", 0).Result()
		if !assert.NoError(t, err) || !assert.True(t, applied) {
			return
		}

		value, err = client.Get(f.ctx, "key").Result()
		assert.NoError(t, err)
		assert.Equal(t, "replacement", value)
	})
}
