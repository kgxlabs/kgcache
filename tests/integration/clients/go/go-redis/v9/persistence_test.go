package clienttests

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/redis/go-redis/v9"
	"github.com/stretchr/testify/assert"
	"kgcache.test/clientharness"
)

func TestSaveReload(t *testing.T) {
	explicitProtocols(t, func(t *testing.T, protocol int) {
		f := newFixture(t, protocol, fixtureOptions{scenarioTimeout: 60 * time.Second})
		original := f.client(t, clientOptions{})
		originalDB1 := f.client(t, clientOptions{db: 1})
		key := string([]byte{0, 255, 128})
		value := []byte{255, 128, 0, 13, 10}

		for _, row := range []struct {
			client *redis.Client
			key    string
			value  interface{}
		}{
			{original, "text", "saved text"},
			{original, key, value},
			{originalDB1, "text", "saved DB 1"},
		} {
			if !assert.NoError(t, row.client.Set(f.ctx, row.key, row.value, 0).Err()) {
				return
			}
		}

		reply, err := original.Do(f.ctx, "SAVE").Text()
		if !assert.NoError(t, err) || !assert.Equal(t, "OK", reply) {
			return
		}

		snapshot := filepath.Join(f.server.DataDir(), "state.kgc")
		info, err := os.Stat(snapshot)
		if !assert.NoError(t, err) || !assert.Positive(t, info.Size()) {
			return
		}
		if !assert.NoError(t, originalDB1.Close()) || !assert.NoError(t, original.Close()) {
			return
		}

		address := f.server.Address()
		if !assert.NoError(t, f.server.Stop()) {
			return
		}

		_, err = os.Stat(snapshot)
		if !assert.NoError(t, err) || !assert.NoError(t, f.server.Start(f.ctx)) {
			return
		}
		assert.Equal(t, address, f.server.Address())

		restored := f.client(t, clientOptions{})
		restoredDB1 := f.client(t, clientOptions{db: 1})
		assert.NotSame(t, original, restored)

		text, err := restored.Get(f.ctx, "text").Result()
		if !assert.NoError(t, err) {
			return
		}
		assert.Equal(t, "saved text", text)

		text, err = restoredDB1.Get(f.ctx, "text").Result()
		if !assert.NoError(t, err) {
			return
		}
		assert.Equal(t, "saved DB 1", text)

		binary, err := restored.Get(f.ctx, key).Bytes()
		if !assert.NoError(t, err) {
			return
		}
		assert.Equal(t, value, binary)

		_, err = restored.Get(f.ctx, "missing").Result()
		assert.ErrorIs(t, err, redis.Nil)
	})
}

func TestBackgroundPersistenceReplies(t *testing.T) {
	explicitProtocols(t, func(t *testing.T, protocol int) {
		for _, row := range []struct {
			command, config, reply string
		}{
			{"BGSAVE", "", `^Background saving (started|scheduled)$`},
			{
				"BGREWRITEAOF",
				"appendonly yes\nappendfsync always\n",
				`^Background append only file rewriting (started|scheduled)$`,
			},
		} {
			t.Run(row.command, func(t *testing.T) {
				f := newFixture(t, protocol, fixtureOptions{
					Options:         clientharness.Options{ExtraConfig: row.config},
					scenarioTimeout: 60 * time.Second,
				})
				client := f.client(t, clientOptions{})

				if !assert.NoError(t, client.Set(f.ctx, "key", "persisted value", 0).Err()) {
					return
				}

				reply, err := client.Do(f.ctx, row.command).Text()
				if !assert.NoError(t, err) || !assert.Regexp(t, row.reply, reply) {
					return
				}

				pong, err := client.Ping(f.ctx).Result()
				assert.NoError(t, err)
				assert.Equal(t, "PONG", pong)
			})
		}
	})
}
