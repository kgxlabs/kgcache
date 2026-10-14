package clienttests

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/redis/go-redis/v9"
	"github.com/stretchr/testify/assert"
)

func TestLiveClientListings(t *testing.T) {
	explicitProtocols(t, func(t *testing.T, protocol int) {
		f := newFixture(t, protocol, fixtureOptions{})
		caller := f.client(t, clientOptions{})
		callerConn := dedicatedConn(t, caller)

		peerProtocol := 5 - protocol
		peer := f.client(t, clientOptions{
			db:             1,
			protocol:       peerProtocol,
			identitySuffix: "peer",
		})
		peerConn := dedicatedConn(t, peer)

		observer := f.client(t, clientOptions{identitySuffix: "observer"})
		observerConn := dedicatedConn(t, observer)

		if !assert.NoError(t, peerConn.ClientSetInfo(f.ctx, redis.WithLibraryVersion("peer-version")).Err()) {
			return
		}

		expected := make(map[uint64]map[string]string)
		var peerID uint64

		for _, entry := range []struct {
			conn           *redis.Conn
			db, protocol   int
			label, version string
		}{
			{callerConn, 0, protocol, "go-redis(,go1.26.9)", "9.22.0"},
			{peerConn, 1, peerProtocol, "go-redis(peer,go1.26.9)", "peer-version"},
			{observerConn, 0, protocol, "go-redis(observer,go1.26.9)", "9.22.0"},
		} {
			info, err := entry.conn.ClientInfo(f.ctx).Result()
			if !assert.NoError(t, err) || !assert.Positive(t, info.ID) {
				return
			}

			id := uint64(info.ID)
			expected[id] = map[string]string{
				"db":       fmt.Sprint(entry.db),
				"resp":     fmt.Sprint(entry.protocol),
				"lib-name": entry.label,
				"lib-ver":  entry.version,
			}
			if entry.conn == peerConn {
				peerID = id
			}
		}
		if !assert.Len(t, expected, 3, "connections need distinct IDs") {
			return
		}

		text, err := callerConn.ClientList(f.ctx).Result()
		if !assert.NoError(t, err) {
			return
		}

		rows, err := parseReport(text)
		if !assert.NoError(t, err) || !assert.Len(t, rows, 3) {
			return
		}

		for i, row := range rows {
			if i > 0 {
				assert.Greater(t, row.id, rows[i-1].id, "ascending client IDs")
			}

			fields, ok := expected[row.id]
			if !assert.True(t, ok, "unexpected client ID %d", row.id) {
				return
			}

			for field, value := range fields {
				assert.Equal(t, value, row.fields[field], field)
			}
		}

		if !assert.NoError(t, peerConn.Close()) || !assert.NoError(t, peer.Close()) {
			return
		}

		var remaining []report
		err = poll(f.ctx, 5*time.Second, func(ctx context.Context) (bool, error) {
			text, err := callerConn.ClientList(ctx).Result()
			if err != nil {
				return false, err
			}

			remaining, err = parseReport(text)
			if err != nil {
				return false, err
			}

			for _, row := range remaining {
				if row.id == peerID {
					return false, nil
				}
			}

			return true, nil
		})
		if !assert.NoError(t, err) || !assert.Len(t, remaining, 2) {
			return
		}

		for _, row := range remaining {
			assert.NotEqual(t, peerID, row.id)
			assert.Contains(t, expected, row.id)
		}

		pong, err := callerConn.Ping(f.ctx).Result()
		assert.NoError(t, err)
		assert.Equal(t, "PONG", pong)
	})
}
