module kgcache.test/go-redis/v9

go 1.26.9

require (
	github.com/redis/go-redis/v9 v9.22.0
	github.com/stretchr/testify v1.11.1
	kgcache.test/clientharness v0.0.0
)

require (
	github.com/cespare/xxhash/v2 v2.3.0 // indirect
	github.com/davecgh/go-spew v1.1.1 // indirect
	github.com/pmezard/go-difflib v1.0.0 // indirect
	go.uber.org/atomic v1.11.0 // indirect
	golang.org/x/sys v0.30.0 // indirect
	gopkg.in/yaml.v3 v3.0.1 // indirect
)

replace kgcache.test/clientharness => ../../harness
