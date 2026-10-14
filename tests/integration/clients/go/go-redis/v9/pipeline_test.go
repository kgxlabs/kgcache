package clienttests

import (
	"testing"

	"github.com/redis/go-redis/v9"
	"github.com/stretchr/testify/assert"
)

func TestPipelineOrderedReplies(t *testing.T) {
	explicitProtocols(t, func(t *testing.T, protocol int) {
		f := newFixture(t, protocol, fixtureOptions{})
		client := f.client(t, clientOptions{})

		pipe := client.Pipeline()
		firstSet := pipe.Set(f.ctx, "a", "first", 0)
		firstGet := pipe.Get(f.ctx, "a")
		missing := pipe.Get(f.ctx, "missing")
		secondSet := pipe.Set(f.ctx, "b", "second", 0)
		deleted := pipe.Del(f.ctx, "a")
		removed := pipe.Get(f.ctx, "a")
		size := pipe.DBSize(f.ctx)
		echo := pipe.Echo(f.ctx, "tail")
		ping := pipe.Ping(f.ctx)

		queued := []redis.Cmder{firstSet, firstGet, missing, secondSet, deleted, removed, size, echo, ping}

		commands, err := pipe.Exec(f.ctx)
		if !assert.ErrorIs(t, err, redis.Nil) || !assert.Len(t, commands, len(queued)) {
			return
		}

		for i, command := range commands {
			assert.Same(t, queued[i], command, "reply position %d", i)

			if i == 2 || i == 5 {
				assert.ErrorIs(t, command.Err(), redis.Nil)
			} else {
				assert.NoError(t, command.Err())
			}
		}
		assert.Equal(t, "OK", firstSet.Val())
		assert.Equal(t, "first", firstGet.Val())
		assert.Empty(t, missing.Val())
		assert.Equal(t, "OK", secondSet.Val())
		assert.Equal(t, int64(1), deleted.Val())
		assert.Empty(t, removed.Val())
		assert.Equal(t, int64(1), size.Val())
		assert.Equal(t, "tail", echo.Val())
		assert.Equal(t, "PONG", ping.Val())

		value, err := client.Get(f.ctx, "b").Result()
		if !assert.NoError(t, err) {
			return
		}
		assert.Equal(t, "second", value)

		pong, err := client.Ping(f.ctx).Result()
		assert.NoError(t, err)
		assert.Equal(t, "PONG", pong)
	})
}

func TestCommandErrorsAndPipelineRecovery(t *testing.T) {
	explicitProtocols(t, func(t *testing.T, protocol int) {
		f := newFixture(t, protocol, fixtureOptions{})
		client := f.client(t, clientOptions{})
		conn := dedicatedConn(t, client)

		info, err := conn.ClientInfo(f.ctx).Result()
		if !assert.NoError(t, err) || !assert.Positive(t, info.ID) {
			return
		}

		pipe := conn.Pipeline()
		before := pipe.Set(f.ctx, "key", "value", 0)
		rejected := pipe.Do(f.ctx, "GET")
		after := pipe.Get(f.ctx, "key")
		ping := pipe.Ping(f.ctx)

		commands, err := pipe.Exec(f.ctx)
		var commandErr redis.Error
		if !assert.ErrorAs(t, err, &commandErr) || !assert.Len(t, commands, 4) {
			return
		}
		assert.Equal(t, rejected.Err(), err)
		assert.ErrorAs(t, rejected.Err(), &commandErr)
		assert.Contains(t, err.Error(), "wrong number of arguments")

		for i, command := range []redis.Cmder{before, rejected, after, ping} {
			assert.Same(t, command, commands[i], "reply position %d", i)

			if i != 1 {
				assert.NoError(t, command.Err())
			}
		}
		assert.Equal(t, "OK", before.Val())
		assert.Equal(t, "value", after.Val())
		assert.Equal(t, "PONG", ping.Val())

		for _, args := range [][]interface{}{{"SET", "invalid", "value", "EX", "0"}, {"INFO"}} {
			err := conn.Do(f.ctx, args...).Err()
			if !assert.ErrorAs(t, err, &commandErr) {
				return
			}
			assert.Contains(t, err.Error(), "ERR")

			pong, err := conn.Ping(f.ctx).Result()
			if !assert.NoError(t, err) || !assert.Equal(t, "PONG", pong) {
				return
			}
		}

		current, err := conn.ClientInfo(f.ctx).Result()
		assert.NoError(t, err)

		if err == nil {
			assert.Equal(t, info.ID, current.ID, "ordinary errors retain the same physical connection")
		}
	})
}
