package clienttests

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/redis/go-redis/v9"
	"github.com/stretchr/testify/assert"
)

func TestSetExpiration(t *testing.T) {
	explicitProtocols(t, func(t *testing.T, protocol int) {
		for _, option := range []string{"EX", "PX", "EXAT", "PXAT"} {
			t.Run(option, func(t *testing.T) {
				f := newFixture(t, protocol, fixtureOptions{})
				client := f.client(t, clientOptions{})
				var reply string
				var err error
				switch option {
				case "EX":
					reply, err = client.Set(f.ctx, "expiring", "value", 2*time.Second).Result()
				case "PX":
					reply, err = client.Set(f.ctx, "expiring", "value", 1500*time.Millisecond).Result()
				case "EXAT":
					reply, err = client.SetArgs(f.ctx, "expiring", "value", redis.SetArgs{ExpireAt: time.Now().Add(3 * time.Second)}).Result()
				case "PXAT":
					reply, err = client.Do(f.ctx, "SET", "expiring", "value", "PXAT", time.Now().Add(1500*time.Millisecond).UnixMilli()).Text()
				}
				if !assert.NoError(t, err) || !assert.Equal(t, "OK", reply) {
					return
				}
				value, err := client.Get(f.ctx, "expiring").Result()
				if !assert.NoError(t, err) || !assert.Equal(t, "value", value) {
					return
				}
				assert.NoError(t, waitForMissing(f.ctx, client, "expiring", "value"))
			})
		}
	})
}

func TestSetKeepsExpiration(t *testing.T) {
	explicitProtocols(t, func(t *testing.T, protocol int) {
		f := newFixture(t, protocol, fixtureOptions{})
		client := f.client(t, clientOptions{})
		if !assert.NoError(t, client.Set(f.ctx, "key", "old", 1500*time.Millisecond).Err()) {
			return
		}
		value, err := client.Get(f.ctx, "key").Result()
		if !assert.NoError(t, err) || !assert.Equal(t, "old", value) {
			return
		}
		reply, err := client.SetArgs(f.ctx, "key", "new", redis.SetArgs{KeepTTL: true}).Result()
		if !assert.NoError(t, err) || !assert.Equal(t, "OK", reply) {
			return
		}
		value, err = client.Get(f.ctx, "key").Result()
		if !assert.NoError(t, err) || !assert.Equal(t, "new", value) {
			return
		}
		assert.NoError(t, waitForMissing(f.ctx, client, "key", "new"))
	})
}

func TestSetClearsExpiration(t *testing.T) {
	explicitProtocols(t, func(t *testing.T, protocol int) {
		f := newFixture(t, protocol, fixtureOptions{})
		client := f.client(t, clientOptions{})
		oldDeadline := time.Now().Add(1500 * time.Millisecond)
		if !assert.NoError(t, client.Do(f.ctx, "SET", "key", "old", "PXAT", oldDeadline.UnixMilli()).Err()) {
			return
		}
		value, err := client.Get(f.ctx, "key").Result()
		if !assert.NoError(t, err) || !assert.Equal(t, "old", value) {
			return
		}
		if !assert.NoError(t, client.Set(f.ctx, "key", "new", 0).Err()) {
			return
		}
		err = poll(f.ctx, 5*time.Second, func(ctx context.Context) (bool, error) {
			value, err := client.Get(ctx, "key").Result()
			if err != nil {
				return false, err
			}
			if value != "new" {
				return false, fmt.Errorf("overwrite value: %q, want new", value)
			}
			return time.Now().After(oldDeadline.Add(250 * time.Millisecond)), nil
		})
		if !assert.NoError(t, err) {
			return
		}
		value, err = client.Get(f.ctx, "key").Result()
		assert.NoError(t, err)
		assert.Equal(t, "new", value)
	})
}

func waitForMissing(ctx context.Context, client *redis.Client, key, expected string) error {
	return poll(ctx, 5*time.Second, func(ctx context.Context) (bool, error) {
		value, err := client.Get(ctx, key).Result()
		if errors.Is(err, redis.Nil) {
			return true, nil
		}
		if err != nil {
			return false, err
		}
		if value != expected {
			return false, fmt.Errorf("expiring value: %q, want %q", value, expected)
		}
		return false, nil
	})
}
