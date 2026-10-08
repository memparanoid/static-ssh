# ============================================================================
# Fully-static (musl) OpenSSH.
#
# Produces statically-linked `sshd`, `sshd-session`, `sshd-auth`, `ssh-keygen`,
# `ssh`, `ssh-keysign` and `scp` with zero dynamic dependencies, from pinned
# openssh-portable source. The binaries run on any Linux of the same
# architecture regardless of what libc, OpenSSL or loader that host has.
#
# NATIVE ONLY. Build this for the architecture you are running on. Building it
# under qemu-user emulation does not work: OpenSSH's configure compiles and
# runs test programs to decide what the platform supports, and under emulation
# those answers are wrong and not even stable between runs — two identical
# runs failed at two different checks (a missing `ssize_t`, and OpenSSL headers
# reported as not matching their own library). CI builds each architecture on
# its own runner for this reason.
#
# Why not `apk add openssh`: that binary links against Alpine's musl loader and
# libcrypto, so it only runs inside an Alpine filesystem.
#
# Why musl and not glibc: a static glibc build silently loses NSS. musl parses
# /etc/passwd itself, and asks nscd first only when a daemon answers on
# /var/run/nscd/socket.
#
# Since 9.8 sshd is not one binary: it execs `sshd-session`, and since 10.0
# `sshd-auth` as well. Both are runtime-configurable (`SshdSessionPath`,
# `SshdAuthPath`), so the three can be installed side by side under any
# directory and pointed at from a generated sshd_config. An older version
# builds neither, and refuses both keywords.
#
# Build, with a line of `versions`:
#   docker build --build-arg OPENSSH_VERSION=10.5p1 \
#     --build-arg OPENSSH_SHA256=d44d28a8… --output type=local,dest=out .
#
# To add a version: take the tarball's SHA256 from the release notes at
# https://www.openssh.com/releasenotes.html (base64 there, hex here) and add
# the line to `versions`.
# ============================================================================

FROM alpine:3.23@sha256:fd791d74b68913cbb027c6546007b3f0d3bc45125f797758156952bc2d6daf40 AS build

# --- version + source SHA256 (the integrity anchor), from `versions` -------
# No defaults: a build that forgot one fails here instead of producing a
# version nobody asked for.
ARG OPENSSH_VERSION
ARG OPENSSH_SHA256
RUN test -n "${OPENSSH_VERSION}" && test -n "${OPENSSH_SHA256}"

# zlib comes from Alpine as a static archive, so it is not built here. It is
# pinned by the image digest above, same as the compiler.
RUN apk add --no-cache \
      build-base linux-headers pkgconf \
      zlib-dev zlib-static \
      curl file

WORKDIR /src

# Into a directory of our own rather than the one the tarball names: 10.0p2's
# tarball unpacks to a directory that is not called openssh-10.0p2.
#
# --without-openssl: OpenSSH's own ed25519, curve25519, chacha20-poly1305 and
#   hybrid key exchanges. Before 9.9, configure refuses any OpenSSL it does not
#   list, 3.5 included, and nothing ed25519 needs comes from it. No RSA, no
#   ECDSA.
# CFLAGS: -fpermissive turns back into warnings what GCC 14 made errors in C,
#   which code older than 9.9 trips (`implicit declaration of function
#   'vsnprintf'` in 9.0p1, an incompatible pointer to `connect` in 9.8p1), and
#   -std=gnu17 keeps a compiler that defaults to C23 from reading it as C23.
#   `-g -O2` are autoconf's defaults, which a CFLAGS given replaces.
# --with-privsep-user=root: the privsep fork does not drop to an unprivileged
#   uid, so sshd needs no `sshd` entry in passwd. Callers that run it in a
#   namespace with their own user database do not have to declare one.
# --with-privsep-path=/var/empty: an absolute path the caller must provide,
#   owned by root and not writable by anyone else.
# install-nokeys: no host keys are generated here. Every caller makes its own.
RUN curl -fsSLO "https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-${OPENSSH_VERSION}.tar.gz" \
 && echo "${OPENSSH_SHA256}  openssh-${OPENSSH_VERSION}.tar.gz" | sha256sum -c - \
 && mkdir openssh \
 && tar xzf "openssh-${OPENSSH_VERSION}.tar.gz" --strip-components=1 -C openssh \
 && cd openssh \
 && ./configure CFLAGS="-g -O2 -std=gnu17 -fpermissive" LDFLAGS="-static" \
      --prefix=/usr \
      --disable-strip \
      --without-openssl \
      --with-privsep-user=root \
      --with-privsep-path=/var/empty \
 && make -j"$(nproc)" \
 && mkdir -p /out \
 && for binary in sshd ssh-keygen ssh ssh-keysign scp; do \
      strip "$binary" && cp "$binary" "/out/$binary"; \
    done \
 && for binary in sshd-session sshd-auth; do \
      if [ -e "$binary" ]; then strip "$binary" && cp "$binary" "/out/$binary"; fi; \
    done

# --- fail the build unless every binary is genuinely static ----------------
# `file` reports musl's default as 'static-pie linked', which the 'static'
# match covers; a dynamic binary says 'dynamically linked'. The case prints
# what it found, so a failure names the link mode instead of just exiting.
RUN for binary in /out/*; do \
      kind=$(file -b "$binary"); \
      case "$kind" in \
        *static*) echo "$binary: $kind" ;; \
        *) echo "not static: $binary: $kind" >&2; exit 1 ;; \
      esac; \
    done

# --- fail the build unless every binary sshd execs was shipped ------------
# Which of the two a version has is read from the binaries themselves: the path
# one was compiled to exec is in whichever execs it. Without this a version that
# has one and did not ship it would pass, and fail only at its first connection.
RUN for binary in sshd-session sshd-auth; do \
      if cat /out/* | grep -q "/usr/libexec/$binary" && [ ! -e "/out/$binary" ]; then \
        echo "sshd execs $binary, and it was not shipped" >&2; exit 1; \
      fi; \
    done

# The build is native, so the binaries run here, and the release sshd prints is
# the cheapest proof the static link produced something executable rather than
# merely well-formed. The exit status is not asked: 9.0's sshd has no `-V`, and
# prints the release in its usage and exits 1. The portable suffix is not asked
# either: 9.2's `-V` prints `OpenSSH_9.2,` where its usage prints `9.2p1`.
RUN /out/sshd -V 2>&1 | grep -E "^OpenSSH_${OPENSSH_VERSION%p*}(p[0-9]+)?,"

# --- export just the binaries (--output type=local) ------------------------
FROM scratch AS export
COPY --from=build /out/ /
