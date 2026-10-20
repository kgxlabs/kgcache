// Smoke checks an endpoint owned by the caller.
package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"net"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/redis/go-redis/v9"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()

	if err := run(ctx, os.Args[1:]); err != nil {
		fmt.Fprintf(os.Stderr, "Go endpoint smoke: %.1000s\n", err)
		os.Exit(1)
	}

	fmt.Printf("go-redis %s: default, RESP2, RESP3 passed\n", redis.Version())
}

func run(ctx context.Context, args []string) error {
	if len(args) != 2 || args[0] == "" {
		return errors.New("usage: smoke HOST PORT")
	}

	port, err := strconv.Atoi(args[1])
	if err != nil || port < 1 || port > 65535 {
		return errors.New("port must be an integer from 1 to 65535")
	}

	for _, protocol := range []int{0, 2, 3} {
		if err := check(ctx, net.JoinHostPort(args[0], args[1]), protocol); err != nil {
			return fmt.Errorf("protocol %d: %w", protocol, err)
		}
	}

	return nil
}

func check(ctx context.Context, address string, protocol int) (err error) {
	client := redis.NewClient(&redis.Options{
		Addr:                  address,
		Protocol:              protocol,
		DB:                    0,
		MaxRetries:            -1,
		DialTimeout:           2 * time.Second,
		ReadTimeout:           2 * time.Second,
		WriteTimeout:          2 * time.Second,
		PoolTimeout:           2 * time.Second,
		PoolSize:              1,
		MaxActiveConns:        1,
		ContextTimeoutEnabled: true,
	})
	defer func() { err = errors.Join(err, client.Close()) }()

	conn := client.Conn()
	defer func() { err = errors.Join(err, conn.Close()) }()

	pong, err := conn.Ping(ctx).Result()
	if err != nil {
		return fmt.Errorf("PING: %w", err)
	}

	if pong != "PONG" {
		return fmt.Errorf("PING returned %q", pong)
	}

	info, err := conn.ClientInfo(ctx).Result()
	if err != nil {
		return err
	}
	expected := protocol
	if expected == 0 {
		expected = 3
	}

	if info.Resp != expected {
		return fmt.Errorf("handshake selected RESP%d, want RESP%d", info.Resp, expected)
	}

	var random [12]byte
	if _, err := rand.Read(random[:]); err != nil {
		return err
	}

	key := fmt.Sprintf("kgcache-smoke:go:%x", random)
	defer func() {
		cleanup, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		err = errors.Join(err, conn.Del(cleanup, key).Err())
	}()

	value := []byte{'b', 0, 255, '\r', '\n', 'v'}
	if err := conn.Set(ctx, key, value, 0).Err(); err != nil {
		return err
	}

	actual, err := conn.Get(ctx, key).Bytes()
	if err != nil {
		return fmt.Errorf("binary GET: %w", err)
	}

	if !bytes.Equal(actual, value) {
		return errors.New("binary SET/GET mismatch")
	}

	pipe := conn.Pipeline()
	firstSet := pipe.Set(ctx, key, "first", 0)
	firstGet := pipe.Get(ctx, key)
	secondSet := pipe.Set(ctx, key, "second", 0)
	secondGet := pipe.Get(ctx, key)
	commands, err := pipe.Exec(ctx)
	if err != nil {
		return err
	}
	if len(commands) != 4 || commands[0] != firstSet || commands[1] != firstGet ||
		commands[2] != secondSet || commands[3] != secondGet ||
		firstSet.Val() != "OK" || firstGet.Val() != "first" ||
		secondSet.Val() != "OK" || secondGet.Val() != "second" {
		return errors.New("pipeline replies were not in order")
	}

	var commandError redis.Error
	if err := conn.Do(ctx, "GET").Err(); !errors.As(err, &commandError) {
		return fmt.Errorf("expected a command error, got %v", err)
	}

	pong, err = conn.Ping(ctx).Result()
	if err != nil {
		return fmt.Errorf("PING after command error: %w", err)
	}

	if pong != "PONG" {
		return fmt.Errorf("PING after command error returned %q", pong)
	}

	after, err := conn.ClientInfo(ctx).Result()
	if err != nil {
		return err
	}

	if after.ID != info.ID {
		return errors.New("command error replaced the connection")
	}

	return nil
}
