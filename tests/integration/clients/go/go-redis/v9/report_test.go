package clienttests

import (
	"fmt"
	"strconv"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
)

var reportFields = []string{
	"id", "addr", "laddr", "fd", "age", "idle", "db", "cmd", "resp", "lib-name", "lib-ver",
	"tot-net-in", "tot-net-out", "tot-cmds", "name", "sub", "psub", "ssub", "watch", "multi", "multi-mem", "redir",
}

type report struct {
	fields   map[string]string
	id       uint64
	counters map[string]uint64
}

func TestReportParserRejectsMalformedContracts(t *testing.T) {
	valid := "id=18446744073709551615 addr=127.0.0.1:1 laddr=127.0.0.1:2 fd=0 age=0 idle=0 db=0 cmd=ping resp=3 lib-name=go lib-ver=9 tot-net-in=0 tot-net-out=0 tot-cmds=0 name= sub=0 psub=0 ssub=0 watch=0 multi=-1 multi-mem=0 redir=-1\n"
	rows, err := parseReport(valid)
	if !assert.NoError(t, err) || !assert.Len(t, rows, 1) {
		return
	}
	assert.Equal(t, ^uint64(0), rows[0].id)
	for _, text := range []string{
		strings.TrimSuffix(valid, "\n"),
		strings.Replace(valid, "addr=127.0.0.1:1 laddr=127.0.0.1:2", "laddr=127.0.0.1:2 addr=127.0.0.1:1", 1),
		strings.Replace(valid, " sub=0", "", 1),
		strings.Replace(valid, "tot-cmds=0", "tot-cmds=-1", 1),
		strings.Replace(valid, "18446744073709551615", "18446744073709551616", 1),
	} {
		_, err := parseReport(text)
		assert.Error(t, err)
	}
}

func parseReport(text string) ([]report, error) {
	if !strings.HasSuffix(text, "\n") || text == "\n" {
		return nil, fmt.Errorf("CLIENT report must contain rows ending with LF")
	}
	var rows []report
	for _, line := range strings.Split(strings.TrimSuffix(text, "\n"), "\n") {
		tokens := strings.Split(line, " ")
		if len(tokens) != len(reportFields) {
			return nil, fmt.Errorf("CLIENT report expected 22 fields, got %d", len(tokens))
		}
		for i, token := range tokens {
			field, _, ok := strings.Cut(token, "=")
			if !ok || field != reportFields[i] {
				return nil, fmt.Errorf("CLIENT report field %d: expected %s, got %s", i, reportFields[i], field)
			}
		}
		row := report{fields: make(map[string]string), counters: make(map[string]uint64)}
		for _, token := range tokens {
			field, value, _ := strings.Cut(token, "=")
			row.fields[field] = value
		}
		var err error
		row.id, err = unsignedDecimal(row.fields["id"])
		if err != nil {
			return nil, fmt.Errorf("CLIENT report id: %w", err)
		}
		for _, field := range []string{"age", "idle", "tot-net-in", "tot-net-out", "tot-cmds"} {
			row.counters[field], err = unsignedDecimal(row.fields[field])
			if err != nil {
				return nil, fmt.Errorf("CLIENT report %s: %w", field, err)
			}
		}
		rows = append(rows, row)
	}
	return rows, nil
}

func unsignedDecimal(text string) (uint64, error) {
	value, err := strconv.ParseUint(text, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("unsigned decimal %q: %w", text, err)
	}
	if strconv.FormatUint(value, 10) != text {
		return 0, fmt.Errorf("noncanonical unsigned decimal %q", text)
	}
	return value, nil
}
