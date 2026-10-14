module kgcache.test/go-redis/v9

go 1.26.9

require (
	github.com/redis/go-redis/v9 v9.22.0
	github.com/stretchr/testify v1.11.1
	kgcache.test/clientharness v0.0.0
)

replace kgcache.test/clientharness => ../../harness
