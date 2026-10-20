package main

import (
	"context"
	"net"
	"testing"
	"time"

	"kgcache.test/clientharness"
)

func TestExternalEndpoint(t *testing.T) {
	server, err := clientharness.New(clientharness.Options{})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := server.Cleanup(); err != nil {
			t.Error(err)
		}
	})
	ctx, cancel := context.WithTimeout(t.Context(), 15*time.Second)
	defer cancel()
	if err := server.Start(ctx); err != nil {
		t.Fatal(err)
	}
	host, port, err := net.SplitHostPort(server.Address())
	if err != nil {
		t.Fatal(err)
	}
	if err := run(ctx, []string{host, port}); err != nil {
		t.Fatal(err)
	}
	if err := server.Stop(); err != nil {
		t.Fatal(err)
	}
	if err := run(ctx, []string{host, port}); err == nil {
		t.Fatal("unavailable endpoint passed")
	}
}

func TestIncorrectEndpoint(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	joined := make(chan struct{})
	go func() {
		defer close(joined)
		conn, err := listener.Accept()
		if err == nil {
			conn.SetDeadline(time.Now().Add(time.Second))
			conn.Write([]byte("HTTP/1.1 400 Bad Request\r\n\r\n"))
			conn.Close()
		}
	}()
	host, port, err := net.SplitHostPort(listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(t.Context(), 3*time.Second)
	defer cancel()
	if err := run(ctx, []string{host, port}); err == nil {
		t.Fatal("incorrect endpoint passed")
	}
	listener.Close()
	<-joined
}
