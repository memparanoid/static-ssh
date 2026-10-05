# static-ssh

Statically linked OpenSSH binaries for Linux `amd64` and `arm64`, built from
pinned upstream source in GitHub Actions, for every version in
[`versions`](versions).

Each release is one version and ships `sshd`, `ssh-keygen` and `ssh`, plus
`sshd-session` from 9.8 and `sshd-auth` from 10.0. They have no dynamic
dependencies: they run on any Linux of the same architecture regardless of its
libc, OpenSSL or loader.

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
| OpenSSH | every line of `versions`: a version and its source tarball's SHA256, taken from the [release notes](https://www.openssh.com/releasenotes.html) |
| Build image | `alpine:3.23`, by digest |
| zlib | Alpine's static archive, pinned by that same digest |

The compiler, the libraries and the source are all fixed by those three pins.
Nothing is downloaded unpinned at build time.

## Build configuration

```
./configure LDFLAGS="-static" \
  --prefix=/usr \
  --disable-strip \
  --without-openssl \
  --with-privsep-user=root \
  --with-privsep-path=/var/empty
```

`--without-openssl` leaves OpenSSH on its own ed25519, curve25519,
chacha20-poly1305 and hybrid key exchanges: no RSA and no ECDSA. Before 9.9,
configure refuses any OpenSSL version it does not list, so this is also what
lets one recipe build every version.

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

Since 9.8 `sshd` execs `sshd-session` for each connection, and since 10.0
`sshd-session` execs `sshd-auth`. Before those versions the binaries do not
exist and the keywords below are unknown, which sshd treats as fatal. Both
paths are configuration keywords, not compiled-in locations:

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

## Releases

A push to `main` builds every version on both architectures and publishes one
release per version, tagged `<version>-<recipe>`: `recipe` is the first twelve
hex digits of the Dockerfile's SHA256. A tag that already exists is not
published again, so the same recipe never republishes, and a changed recipe
publishes every version under new tags beside the old ones.

Pull requests build and publish nothing.

## Verifying a download

Every release publishes a `SHA256SUMS`, also in its notes, and a `.sha256` next
to each tarball.

```sh
sha256sum -c openssh-10.5p1-static-amd64.tar.gz.sha256
```

Tags are never moved. A given tag's assets are the ones it was published with,
so a recorded SHA256 stays meaningful.

## License

The build scripts here are MIT. OpenSSH itself is distributed under its own
license, which is included in its source tarball.