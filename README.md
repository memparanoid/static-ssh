# static-ssh

Statically linked OpenSSH binaries for Linux `amd64` and `arm64`, built from
pinned upstream source in GitHub Actions.

Each release ships `sshd`, `sshd-session`, `sshd-auth`, `ssh-keygen` and `ssh`.
They have no dynamic dependencies: they run on any Linux of the same
architecture regardless of its libc, OpenSSL or loader.

## Why

To make the observed behaviour of an ssh connection a function of the
connection alone. When the client and the server come from whatever the host
distribution installed, a refused connection cannot be told apart from a
misconfigured one — the exit code and the message both vary by version, so
neither can be asserted on. Pinning both ends fixes that surface.

The binaries are also useful anywhere OpenSSH has to run without being
installed: a namespace, a scratch container, a minimal image.

## What is pinned

| | |
|---|---|
| OpenSSH | `10.5p1`, source tarball verified against a hardcoded SHA256 |
| Build image | `alpine:3.23`, by digest |
| openssl, zlib | Alpine's static archives, pinned by that same digest |

The compiler, the libraries and the source are all fixed by those three pins.
Nothing is downloaded unpinned at build time.

## Build configuration

```
./configure LDFLAGS="-static" \
  --prefix=/usr \
  --disable-strip \
  --with-privsep-user=root \
  --with-privsep-path=/var/empty
```

`--with-privsep-user=root` means the privsep fork does not drop to an
unprivileged uid, so sshd needs no `sshd` entry in `/etc/passwd`. Callers that
run it inside a namespace with their own user database do not have to declare
one. It also means privilege separation provides no isolation here — this is a
build for controlled environments, not a hardened deployment.

`--with-privsep-path=/var/empty` must exist at runtime, be owned by root and
not be writable by anyone else. sshd refuses to start otherwise.

No host keys are generated (`install-nokeys`). No `moduli` is shipped, so
`diffie-hellman-group-exchange-*` is unavailable; the modern default
(`curve25519-sha256`) does not need it.

## Three binaries, not one

Since 9.8 `sshd` execs `sshd-session` for each connection, and since 10.x
`sshd-session` execs `sshd-auth`. Both paths are configuration keywords, not
compiled-in locations:

```
SshdSessionPath  /wherever/sshd-session
SshdAuthPath     /wherever/sshd-auth
```

`sshd` validates both at startup — `stat` plus the execute bit — and exits with
`"<path> does not exist or is not executable"`. A wrong path fails at start,
not at the first connection. `sshd-session` receives the already-parsed
configuration over a file descriptor, so it never re-reads the file and never
searches `PATH`.

## Native builds only

Do not build this under qemu-user emulation. OpenSSH's `configure` decides what
the platform supports by compiling and running test programs, and under
emulation those answers are wrong and not stable between runs: two identical
runs failed at two different checks, one reporting a missing `ssize_t` and the
other reporting OpenSSL headers as not matching their own library. CI builds
each architecture on its own runner.

## Verifying a download

Every release publishes a `SHA256SUMS` and a `.sha256` next to each tarball.

```sh
sha256sum -c openssh-static-amd64.tar.gz.sha256
```

Tags are never moved. A given tag's assets are the ones it was published with,
so a recorded SHA256 stays meaningful.

## License

The build scripts here are MIT. OpenSSH itself is distributed under its own
license, which is included in its source tarball.