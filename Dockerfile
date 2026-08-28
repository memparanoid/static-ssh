# ============================================================================
# Fully-static (musl) OpenSSH.
#
# Produces statically-linked `sshd`, `sshd-session`, `sshd-auth`, `ssh-keygen`
# and `ssh` with zero dynamic dependencies, from pinned openssh-portable
# source. The binaries run on any Linux of the same architecture regardless of
# what libc, OpenSSL or loader that host has.
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
# /etc/passwd itself, which also means this sshd never consults nscd.
#
# Since 9.8 sshd is not one binary: it execs `sshd-session`, and since 10.x
# `sshd-auth` as well. Both are runtime-configurable (`SshdSessionPath`,
# `SshdAuthPath`), so the three can be installed side by side under any
# directory and pointed at from a generated sshd_config.
#
# Build:
#   docker build --output type=local,dest=out .
#
# On a version bump: fetch the tarball, `sha256sum` it, verify against the
# openssh-unix-announce release announcement (and, if you have the release key,
# the detached .asc next to the tarball), and update OPENSSH_SHA256 below.
# ============================================================================

FROM alpine:3.23@sha256:fd791d74b68913cbb027c6546007b3f0d3bc45125f797758156952bc2d6daf40 AS build

# --- pinned version + source SHA256 (the integrity anchor) -----------------
ARG OPENSSH_VERSION=10.5p1
ARG OPENSSH_SHA256=d44d28a839ea9daf969cc69150fde59910b2b39361dad81a3bd6cbd19218db11

# openssl and zlib come from Alpine as static archives, so neither is built
# here. They are pinned by the image digest above, same as the compiler.
RUN apk add --no-cache \
      build-base linux-headers pkgconf \
      openssl-dev openssl-libs-static \
      zlib-dev zlib-static \
      curl file

WORKDIR /src

# --with-privsep-user=root: the privsep fork does not drop to an unprivileged
#   uid, so sshd needs no `sshd` entry in passwd. Callers that run it in a
#   namespace with their own user database do not have to declare one.
# --with-privsep-path=/var/empty: an absolute path the caller must provide,
#   owned by root and not writable by anyone else.
# install-nokeys: no host keys are generated here. Every caller makes its own.
RUN curl -fsSLO "https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-${OPENSSH_VERSION}.tar.gz" \
 && echo "${OPENSSH_SHA256}  openssh-${OPENSSH_VERSION}.tar.gz" | sha256sum -c - \
 && tar xzf "openssh-${OPENSSH_VERSION}.tar.gz" \
 && cd "openssh-${OPENSSH_VERSION}" \
 && ./configure LDFLAGS="-static" \
      --prefix=/usr \
      --disable-strip \
      --with-privsep-user=root \
      --with-privsep-path=/var/empty \
 && make -j"$(nproc)" \
 && mkdir -p /out \
 && for binary in sshd sshd-session sshd-auth ssh-keygen ssh; do \
      strip "$binary" && cp "$binary" "/out/$binary"; \
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

# The build is native, so the binaries run here. `sshd -V` prints the release
# and exits 0, which is the cheapest proof the static link produced something
# executable rather than merely well-formed.
RUN /out/sshd -V

# --- export just the binaries (--output type=local) ------------------------
FROM scratch AS export
COPY --from=build /out/ /
