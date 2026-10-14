package clienttests

import (
	"fmt"
	"testing"

	"github.com/redis/go-redis/v9"
	"github.com/stretchr/testify/assert"
)

func TestCallerReports(t *testing.T) {
	for _, protocol := range []int{2, 3, 0} {
		name, expected := fmt.Sprintf("RESP%d", protocol), protocol
		if protocol == 0 {
			name, expected = "default", 3
		}
		t.Run(name, func(t *testing.T) {
			f := newFixture(t, protocol, fixtureOptions{})
			client := f.client(t, clientOptions{})
			conn := dedicatedConn(t, client)
			if !assert.NoError(t, conn.Ping(f.ctx).Err()) {
				return
			}
			// Query HELLO without renegotiating the native connection's protocol.
			helloCmd := redis.NewMapStringInterfaceCmd(f.ctx, "HELLO")
			if !assert.NoError(t, conn.Process(f.ctx, helloCmd)) {
				return
			}
			hello, err := helloCmd.Result()
			if !assert.NoError(t, err) {
				return
			}
			assert.Equal(t, "kgcache", hello["server"])
			assert.Equal(t, int64(expected), hello["proto"])
			assert.Equal(t, "standalone", hello["mode"])
			assert.Equal(t, "master", hello["role"])
			assert.Equal(t, []interface{}{}, hello["modules"])
			helloID, ok := hello["id"].(int64)
			if !assert.True(t, ok, "native HELLO id type: %T", hello["id"]) || !assert.Positive(t, helloID) {
				return
			}

			text, err := conn.Do(f.ctx, "CLIENT", "INFO").Text()
			if !assert.NoError(t, err) {
				return
			}
			rows, err := parseReport(text)
			if !assert.NoError(t, err) || !assert.Len(t, rows, 1) {
				return
			}
			row := rows[0]
			assert.Equal(t, uint64(helloID), row.id)
			for field, value := range map[string]string{
				"laddr": f.server.Address(), "db": "0", "cmd": "client|info", "resp": fmt.Sprint(expected),
				"lib-name": "go-redis(,go1.26.9)", "lib-ver": "9.22.0", "name": "",
				"sub": "0", "psub": "0", "ssub": "0", "watch": "0", "multi": "-1", "multi-mem": "0", "redir": "-1",
			} {
				assert.Equal(t, value, row.fields[field], field)
			}
			assert.Regexp(t, `^127\.0\.0\.1:[1-9][0-9]*$`, row.fields["addr"])
			_, err = unsignedDecimal(row.fields["fd"])
			assert.NoError(t, err)
			assert.GreaterOrEqual(t, row.counters["age"], row.counters["idle"])
			for _, field := range []string{"tot-net-in", "tot-net-out", "tot-cmds"} {
				assert.Positive(t, row.counters[field], field)
			}
			native, err := conn.ClientInfo(f.ctx).Result()
			if !assert.NoError(t, err) {
				return
			}
			assert.Equal(t, row.id, uint64(native.ID))
			assert.Equal(t, expected, native.Resp)
			assert.Equal(t, row.fields["lib-name"], native.LibName)
			assert.Equal(t, row.fields["lib-ver"], native.LibVer)

			if !assert.NoError(t, conn.ClientSetInfo(f.ctx, redis.WithLibraryName("retained-name")).Err()) {
				return
			}
			if !assert.NoError(t, conn.ClientSetInfo(f.ctx, redis.WithLibraryVersion("9.8.7")).Err()) {
				return
			}
			if !assert.NoError(t, conn.Ping(f.ctx).Err()) {
				return
			}
			text, err = conn.Do(f.ctx, "CLIENT", "INFO").Text()
			if !assert.NoError(t, err) {
				return
			}
			retained, err := parseReport(text)
			if !assert.NoError(t, err) || !assert.Len(t, retained, 1) {
				return
			}
			assert.Equal(t, row.id, retained[0].id)
			assert.Equal(t, "go-redis(retained-name,go1.26.9)", retained[0].fields["lib-name"])
			assert.Equal(t, "9.8.7", retained[0].fields["lib-ver"])
			assert.Greater(t, retained[0].counters["tot-cmds"], row.counters["tot-cmds"])
		})
	}
}
