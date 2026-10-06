#!/usr/bin/env bash
set -euo pipefail

# Build a relocatable PostgreSQL runtime with pgvector and pg_trgm. System and
# Homebrew prefixes are intentionally never copied into a release bundle.
postgres_version="${CODMES_POSTGRES_VERSION:-16.15}"
postgres_sha256="${CODMES_POSTGRES_SHA256:-c1575341fa7bd40f5274ea465b34390f4dc64cdd0770af327005caaeb9f6b7ed}"
pgvector_version="${CODMES_PGVECTOR_VERSION:-0.8.6}"
pgvector_commit="${CODMES_PGVECTOR_COMMIT:-8ee86c96f0fd72390f890aa8a336fda6d3ab4c6c}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
manager_root="$(cd "$script_dir/.." && pwd)"
platform="$(uname -s | tr '[:upper:]' '[:lower:]')"
architecture="$(uname -m)"
output_root="${1:-$manager_root/builds/native-runtime/$platform-$architecture/postgres}"

case "$platform" in
  darwin|linux) ;;
  *) echo "This source builder currently supports macOS and Linux; got $platform" >&2; exit 1 ;;
esac

if [ -e "$output_root" ]; then
  echo "Output already exists; choose a new empty path: $output_root" >&2
  exit 1
fi

build_root="$(mktemp -d "${TMPDIR:-/tmp}/codmes-postgres.XXXXXX")"
cleanup() { rm -rf "$build_root"; }
trap cleanup EXIT
mkdir -p "$output_root" "$(dirname "$output_root")/licenses"

jobs="${CODMES_BUILD_JOBS:-}"
if [ -z "$jobs" ]; then
  jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)"
fi

verify_sha256() {
  local expected="$1" file="$2" actual
  if command -v shasum >/dev/null 2>&1; then
    actual="$(shasum -a 256 "$file" | awk '{print $1}')"
  else
    actual="$(sha256sum "$file" | awk '{print $1}')"
  fi
  if [ "$actual" != "$expected" ]; then
    echo "SHA-256 mismatch for $file" >&2
    exit 1
  fi
}

archive="$build_root/postgresql.tar.bz2"
curl --fail --location --silent --show-error \
  "https://ftp.postgresql.org/pub/source/v$postgres_version/postgresql-$postgres_version.tar.bz2" \
  --output "$archive"
verify_sha256 "$postgres_sha256" "$archive"
tar -xjf "$archive" -C "$build_root"

pushd "$build_root/postgresql-$postgres_version" >/dev/null
./configure \
  --prefix="$output_root" \
  --disable-nls \
  --without-icu \
  --without-readline \
  --without-zlib
make -j"$jobs"
make install
make -C contrib/pg_trgm -j"$jobs"
make -C contrib/pg_trgm install
cp COPYRIGHT "$(dirname "$output_root")/licenses/PostgreSQL.txt"
popd >/dev/null

git clone --quiet https://github.com/pgvector/pgvector.git "$build_root/pgvector"
pushd "$build_root/pgvector" >/dev/null
git checkout --quiet "$pgvector_commit"
if [ "$(git describe --tags --exact-match)" != "v$pgvector_version" ]; then
  echo "pgvector commit does not match v$pgvector_version" >&2
  exit 1
fi
make OPTFLAGS="" PG_CONFIG="$output_root/bin/pg_config" -j"$jobs"
make OPTFLAGS="" PG_CONFIG="$output_root/bin/pg_config" install
cp LICENSE "$(dirname "$output_root")/licenses/pgvector.txt"
popd >/dev/null

"$output_root/bin/postgres" --version
test -f "$output_root/share/extension/vector.control"
test -f "$output_root/share/extension/pg_trgm.control"
echo "CODMES_MANAGER_POSTGRES_ROOT=$output_root"
