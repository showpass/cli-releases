#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C
export TZ=UTC
umask 022

readonly REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
readonly SPEC_FILE="${1:-$REPO_ROOT/release-specs/v2.1.0.json}"
readonly ARCHIVE_DIR="${2:-$REPO_ROOT/dist}"
readonly OUTPUT_DIR="${3:-$REPO_ROOT/dist}"
readonly MANIFEST_FILE="$ARCHIVE_DIR/manifest.json"
readonly NFPM_CONFIG="$REPO_ROOT/packaging/linux/nfpm.yaml"
readonly WRAPPER_FILE="$REPO_ROOT/packaging/linux/showpass-wrapper"

readonly NFPM_VERSION="2.47.0"
readonly NFPM_DARWIN_ARM64_SHA256="e8c9d1d9ac218eeed479375143dc46b8d51a2b8dbba8e2f9f15ecc8faa2e404b"
readonly NFPM_DARWIN_X86_64_SHA256="2b04108f8757313dde92ed729560845aadfb7782887eb6988a5dd96f9c146861"
readonly NFPM_LINUX_ARM64_SHA256="1c0f5f2999b9a974bfb04fdb0cc3306096de530ac5dbb25d739cc5f5219c919c"
readonly NFPM_LINUX_X86_64_SHA256="0660ca602b2d2d2ae4781a06c692b3eeb9d437ffea05b831d76e41f4a3188783"

WORK_DIR=""

fail() {
  echo "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
    rm -rf "$WORK_DIR"
  fi
}

trap cleanup EXIT

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command is missing: $1"
}

sha256_file() {
  local file_path="$1"

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file_path" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file_path" | awk '{print $1}'
  else
    fail "A SHA-256 tool is required (sha256sum or shasum)"
  fi
}

file_size() {
  wc -c < "$1" | tr -d ' '
}

verify_file() {
  local file_path="$1"
  local expected_size="$2"
  local expected_sha256="$3"
  local actual_size
  local actual_sha256

  [[ -f "$file_path" && ! -L "$file_path" ]] || \
    fail "Expected a regular file: $file_path"
  [[ "$expected_size" =~ ^[0-9]+$ ]] || \
    fail "Invalid expected size for $file_path"
  [[ "$expected_sha256" =~ ^[a-f0-9]{64}$ ]] || \
    fail "Invalid expected SHA-256 for $file_path"

  actual_size="$(file_size "$file_path")"
  [[ "$actual_size" == "$expected_size" ]] || \
    fail "Size mismatch for $file_path: expected $expected_size, got $actual_size"

  actual_sha256="$(sha256_file "$file_path")"
  [[ "$actual_sha256" == "$expected_sha256" ]] || \
    fail "Checksum mismatch for $file_path"
}

verify_checksum() {
  local file_path="$1"
  local expected_sha256="$2"
  local actual_sha256

  [[ "$expected_sha256" =~ ^[a-f0-9]{64}$ ]] || \
    fail "Invalid expected SHA-256 for $file_path"
  actual_sha256="$(sha256_file "$file_path")"
  [[ "$actual_sha256" == "$expected_sha256" ]] || \
    fail "Checksum mismatch for $file_path"
}

download() {
  local url="$1"
  local destination="$2"

  curl --fail --silent --show-error --location \
    --retry 5 --retry-all-errors --output "$destination" "$url"
}

validate_release_archive() {
  local archive="$1"
  local entry
  local entry_count=0

  while IFS= read -r entry; do
    entry="${entry#./}"
    [[ -n "$entry" ]] || continue
    entry_count=$((entry_count + 1))

    [[ "$entry" != /* ]] || \
      fail "Release archive contains an absolute path: $entry"
    [[ ! "$entry" =~ (^|/)\.\.(/|$) ]] || \
      fail "Release archive contains parent traversal: $entry"

    case "$entry" in
      NOTICE.md|VERSION|showpass|templates|templates/|templates/app-template|templates/app-template/*)
        ;;
      *)
        fail "Release archive contains an unexpected path: $entry"
        ;;
    esac
  done < <(tar -tzf "$archive")

  [[ "$entry_count" -gt 0 ]] || fail "Release archive is empty: $archive"

  if tar -tvzf "$archive" | awk '
    {
      type = substr($1, 1, 1)
      if (type != "-" && type != "d") {
        found = 1
      }
    }
    END { exit(found ? 0 : 1) }
  '; then
    fail "Release archive contains a link or another special file: $archive"
  fi
}

touch_tree() {
  local root="$1"
  local epoch="$2"
  local timestamp

  if timestamp="$(date -u -d "@$epoch" '+%Y%m%d%H%M.%S' 2>/dev/null)"; then
    :
  else
    timestamp="$(date -u -r "$epoch" '+%Y%m%d%H%M.%S')"
  fi

  [[ "$timestamp" =~ ^[0-9]{12}\.[0-9]{2}$ ]] || \
    fail "Could not convert source_date_epoch to a touch timestamp"

  find "$root" -type f -exec touch -t "$timestamp" {} +
  find "$root" -depth -type d -exec touch -t "$timestamp" {} +
}

install_nfpm() {
  local host_os
  local host_arch
  local asset
  local expected_sha256
  local archive
  local tool_dir
  local nfpm_bin
  local version_output

  host_os="$(uname -s)"
  host_arch="$(uname -m)"

  case "$host_os-$host_arch" in
    Darwin-arm64|Darwin-aarch64)
      asset="nfpm_${NFPM_VERSION}_Darwin_arm64.tar.gz"
      expected_sha256="$NFPM_DARWIN_ARM64_SHA256"
      ;;
    Darwin-x86_64|Darwin-amd64)
      asset="nfpm_${NFPM_VERSION}_Darwin_x86_64.tar.gz"
      expected_sha256="$NFPM_DARWIN_X86_64_SHA256"
      ;;
    Linux-arm64|Linux-aarch64)
      asset="nfpm_${NFPM_VERSION}_Linux_arm64.tar.gz"
      expected_sha256="$NFPM_LINUX_ARM64_SHA256"
      ;;
    Linux-x86_64|Linux-amd64)
      asset="nfpm_${NFPM_VERSION}_Linux_x86_64.tar.gz"
      expected_sha256="$NFPM_LINUX_X86_64_SHA256"
      ;;
    *)
      fail "nFPM is not pinned for this build host: $host_os $host_arch"
      ;;
  esac

  archive="$WORK_DIR/$asset"
  tool_dir="$WORK_DIR/nfpm"
  nfpm_bin="$tool_dir/nfpm"

  download \
    "https://github.com/goreleaser/nfpm/releases/download/v${NFPM_VERSION}/${asset}" \
    "$archive"
  verify_checksum "$archive" "$expected_sha256"

  mkdir -p "$tool_dir"
  tar -xzf "$archive" -C "$tool_dir" nfpm
  [[ -f "$nfpm_bin" && ! -L "$nfpm_bin" ]] || \
    fail "Pinned nFPM archive did not contain the expected executable"
  chmod 0755 "$nfpm_bin"

  version_output="$("$nfpm_bin" --version)"
  grep -Fq "GitVersion:    ${NFPM_VERSION}" <<< "$version_output" || \
    fail "Downloaded nFPM did not report version $NFPM_VERSION"

  printf '%s\n' "$nfpm_bin"
}

for command_name in awk curl date find grep jq tar tr uname wc; do
  require_command "$command_name"
done

[[ -f "$SPEC_FILE" ]] || fail "Release specification not found: $SPEC_FILE"
[[ -f "$MANIFEST_FILE" ]] || fail "Release manifest not found: $MANIFEST_FILE"
[[ -f "$NFPM_CONFIG" ]] || fail "nFPM configuration not found: $NFPM_CONFIG"
[[ -f "$WRAPPER_FILE" ]] || fail "Showpass wrapper not found: $WRAPPER_FILE"

version="$(jq -er '.version' "$SPEC_FILE")"
source_commit="$(jq -er '.source_commit' "$SPEC_FILE")"
release_date="$(jq -er '.release_date' "$SPEC_FILE")"
source_date_epoch="$(jq -er '.source_date_epoch' "$SPEC_FILE")"

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || \
  fail "Invalid semantic version in $SPEC_FILE: $version"
[[ "$source_commit" =~ ^[a-f0-9]{40}$ ]] || \
  fail "Invalid source commit in $SPEC_FILE"
[[ "$source_date_epoch" =~ ^[0-9]+$ ]] || \
  fail "Invalid source_date_epoch in $SPEC_FILE"

[[ "$(jq -er '.version' "$MANIFEST_FILE")" == "$version" ]] || \
  fail "Release manifest version does not match $SPEC_FILE"
[[ "$(jq -er '.source_commit' "$MANIFEST_FILE")" == "$source_commit" ]] || \
  fail "Release manifest source commit does not match $SPEC_FILE"
[[ "$(jq -er '.release_date' "$MANIFEST_FILE")" == "$release_date" ]] || \
  fail "Release manifest release date does not match $SPEC_FILE"
[[ "$(jq -er '.source_date_epoch' "$MANIFEST_FILE")" == "$source_date_epoch" ]] || \
  fail "Release manifest source date epoch does not match $SPEC_FILE"

linux_platform_count="$(jq -er '[.platforms[] | select(.name == "linux-x64" or .name == "linux-arm64")] | length' "$MANIFEST_FILE")"
[[ "$linux_platform_count" -eq 2 ]] || \
  fail "Release manifest must contain exactly one linux-x64 and one linux-arm64 archive"

mkdir -p "$OUTPUT_DIR"
temp_root="${TMPDIR:-/tmp}"
temp_root="${temp_root%/}"
WORK_DIR="$(mktemp -d "$temp_root/showpass-linux-packages.XXXXXX")"
readonly WORK_DIR
readonly NFPM_BIN="$(install_nfpm)"

declare -a built_packages=()

for platform in linux-x64 linux-arm64; do
  case "$platform" in
    linux-x64)
      nfpm_arch="amd64"
      deb_arch="amd64"
      rpm_arch="x86_64"
      ;;
    linux-arm64)
      nfpm_arch="arm64"
      deb_arch="arm64"
      rpm_arch="aarch64"
      ;;
  esac

  platform_json="$(jq -ec --arg platform "$platform" '
    [.platforms[] | select(.name == $platform)] |
    if length == 1 then .[0] else error("platform must appear exactly once") end
  ' "$MANIFEST_FILE")"
  archive_name="$(jq -er '.archive' <<< "$platform_json")"
  archive_size="$(jq -er '.archive_size' <<< "$platform_json")"
  archive_sha256="$(jq -er '.archive_sha256' <<< "$platform_json")"
  expected_archive_name="showpass-${version}-${platform}.tar.gz"

  [[ "$archive_name" == "$expected_archive_name" ]] || \
    fail "Unexpected archive name for $platform: $archive_name"

  archive_path="$ARCHIVE_DIR/$archive_name"
  verify_file "$archive_path" "$archive_size" "$archive_sha256"
  validate_release_archive "$archive_path"

  extract_dir="$WORK_DIR/extract-$platform"
  stage_dir="$WORK_DIR/stage-$platform"
  package_dir="$WORK_DIR/packages"
  mkdir -p \
    "$extract_dir" \
    "$stage_dir/usr/bin" \
    "$stage_dir/usr/lib/showpass" \
    "$stage_dir/usr/share/showpass/templates" \
    "$stage_dir/usr/share/doc/showpass" \
    "$package_dir"

  tar -xzf "$archive_path" -C "$extract_dir"

  [[ -f "$extract_dir/showpass" && ! -L "$extract_dir/showpass" ]] || \
    fail "Showpass executable is missing from $archive_name"
  [[ -f "$extract_dir/templates/app-template/package.json" ]] || \
    fail "Showpass app template is missing from $archive_name"
  [[ -f "$extract_dir/VERSION" && ! -L "$extract_dir/VERSION" ]] || \
    fail "VERSION is missing from $archive_name"
  [[ "$(< "$extract_dir/VERSION")" == "$version" ]] || \
    fail "VERSION in $archive_name does not match $version"
  [[ -f "$extract_dir/NOTICE.md" && ! -L "$extract_dir/NOTICE.md" ]] || \
    fail "NOTICE.md is missing from $archive_name"

  cp -p "$WRAPPER_FILE" "$stage_dir/usr/bin/showpass"
  cp -p "$extract_dir/showpass" "$stage_dir/usr/lib/showpass/showpass"
  cp -Rp "$extract_dir/templates/app-template" \
    "$stage_dir/usr/share/showpass/templates/app-template"
  cp -p "$extract_dir/VERSION" "$stage_dir/usr/share/showpass/VERSION"
  cp -p "$extract_dir/NOTICE.md" "$stage_dir/usr/share/doc/showpass/NOTICE.md"

  find "$stage_dir" -type d -exec chmod 0755 {} +
  find "$stage_dir/usr/share/showpass/templates" -type f -exec chmod 0644 {} +
  chmod 0755 \
    "$stage_dir/usr/bin/showpass" \
    "$stage_dir/usr/lib/showpass/showpass"
  chmod 0644 \
    "$stage_dir/usr/share/showpass/VERSION" \
    "$stage_dir/usr/share/doc/showpass/NOTICE.md"
  touch_tree "$stage_dir" "$source_date_epoch"

  deb_name="showpass_${version}-1_${deb_arch}.deb"
  rpm_name="showpass-${version}-1.${rpm_arch}.rpm"
  deb_path="$package_dir/$deb_name"
  rpm_path="$package_dir/$rpm_name"

  [[ ! -e "$OUTPUT_DIR/$deb_name" ]] || \
    fail "Refusing to overwrite existing package: $OUTPUT_DIR/$deb_name"
  [[ ! -e "$OUTPUT_DIR/$rpm_name" ]] || \
    fail "Refusing to overwrite existing package: $OUTPUT_DIR/$rpm_name"

  echo "Packaging Showpass CLI $version for $platform as deb and rpm"

  SHOWPASS_ARCH="$nfpm_arch" \
  SHOWPASS_VERSION="$version" \
  SHOWPASS_STAGE="$stage_dir" \
  SOURCE_DATE_EPOCH="$source_date_epoch" \
    "$NFPM_BIN" package \
      --config "$NFPM_CONFIG" \
      --packager deb \
      --target "$deb_path"

  SHOWPASS_ARCH="$nfpm_arch" \
  SHOWPASS_VERSION="$version" \
  SHOWPASS_STAGE="$stage_dir" \
  SOURCE_DATE_EPOCH="$source_date_epoch" \
    "$NFPM_BIN" package \
      --config "$NFPM_CONFIG" \
      --packager rpm \
      --target "$rpm_path"

  [[ -s "$deb_path" ]] || fail "nFPM did not create $deb_name"
  [[ -s "$rpm_path" ]] || fail "nFPM did not create $rpm_name"
  built_packages+=("$deb_path" "$rpm_path")
done

checksum_name="LINUX_PACKAGES_SHA256SUMS"
checksum_path="$WORK_DIR/packages/$checksum_name"
[[ ! -e "$OUTPUT_DIR/$checksum_name" ]] || \
  fail "Refusing to overwrite existing checksum file: $OUTPUT_DIR/$checksum_name"

for package_path in "${built_packages[@]}"; do
  printf '%s  %s\n' \
    "$(sha256_file "$package_path")" \
    "$(basename "$package_path")" >> "$checksum_path"
done

for package_path in "${built_packages[@]}"; do
  mv "$package_path" "$OUTPUT_DIR/$(basename "$package_path")"
done
mv "$checksum_path" "$OUTPUT_DIR/$checksum_name"

echo "Linux packages written to $OUTPUT_DIR"
