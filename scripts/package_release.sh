#!/usr/bin/env bash
set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
readonly OUTPUT_DIR="$REPO_ROOT/dist"
readonly WORK_DIR="$REPO_ROOT/.release-work"
readonly SPEC_FILE="${1:-$REPO_ROOT/release-specs/v2.1.0.json}"

fail() {
  echo "$*" >&2
  exit 1
}

[[ -f "$SPEC_FILE" ]] || fail "Release specification not found: $SPEC_FILE"

version="$(jq -er '.version' "$SPEC_FILE")"
source_commit="$(jq -er '.source_commit' "$SPEC_FILE")"
release_date="$(jq -er '.release_date' "$SPEC_FILE")"
source_date_epoch="$(jq -er '.source_date_epoch' "$SPEC_FILE")"
template_url="$(jq -er '.template.url' "$SPEC_FILE")"
template_size="$(jq -er '.template.size' "$SPEC_FILE")"
template_sha256="$(jq -er '.template.sha256' "$SPEC_FILE")"

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || \
  fail "Invalid semantic version in $SPEC_FILE: $version"
[[ "$source_commit" =~ ^[a-f0-9]{40}$ ]] || \
  fail "Invalid source commit in $SPEC_FILE"
[[ "$source_date_epoch" =~ ^[0-9]+$ ]] || \
  fail "Invalid source_date_epoch in $SPEC_FILE"
[[ "$template_sha256" =~ ^[a-f0-9]{64}$ ]] || \
  fail "Invalid template SHA-256 in $SPEC_FILE"
[[ "$template_size" =~ ^[0-9]+$ ]] || \
  fail "Invalid template size in $SPEC_FILE"

platform_count="$(jq -er '.platforms | length' "$SPEC_FILE")"
[[ "$platform_count" -eq 4 ]] || \
  fail "Release specification must define exactly four supported platforms"

rm -rf "$OUTPUT_DIR" "$WORK_DIR"
mkdir -p "$OUTPUT_DIR" "$WORK_DIR"

download() {
  local url="$1"
  local destination="$2"
  curl --fail --silent --show-error --location \
    --retry 5 --retry-all-errors --output "$destination" "$url"
}

verify_file() {
  local file_path="$1"
  local expected_size="$2"
  local expected_sha256="$3"
  local actual_size

  [[ "$expected_size" =~ ^[0-9]+$ ]] || fail "Invalid expected size for $file_path"
  [[ "$expected_sha256" =~ ^[a-f0-9]{64}$ ]] || fail "Invalid expected SHA-256 for $file_path"

  actual_size="$(wc -c < "$file_path" | tr -d ' ')"
  [[ "$actual_size" == "$expected_size" ]] || \
    fail "Size mismatch for $file_path: expected $expected_size, got $actual_size"

  printf '%s  %s\n' "$expected_sha256" "$file_path" | \
    sha256sum --check --status || fail "Checksum mismatch for $file_path"
}

validate_template_archive() {
  local archive="$1"
  local entry

  while IFS= read -r entry; do
    entry="${entry#./}"
    [[ -n "$entry" ]] || continue
    [[ "$entry" != /* ]] || fail "Template archive contains an absolute path: $entry"
    [[ ! "$entry" =~ (^|/)\.\.(/|$) ]] || \
      fail "Template archive contains parent traversal: $entry"
    [[ "$entry" == "app-template" || "$entry" == "app-template/"* ]] || \
      fail "Template archive contains an unexpected path: $entry"
  done < <(tar -tzf "$archive")

  if tar -tvzf "$archive" | awk '
    substr($1, 1, 1) == "l" || substr($1, 1, 1) == "h" { found = 1 }
    END { exit(found ? 0 : 1) }
  '; then
    fail "Template archive contains a symbolic or hard link"
  fi
}

template_archive="$WORK_DIR/templates.tgz"
download "$template_url" "$template_archive"
verify_file "$template_archive" "$template_size" "$template_sha256"
validate_template_archive "$template_archive"

manifest_path="$OUTPUT_DIR/manifest.json"
jq -n --slurpfile spec "$SPEC_FILE" '
  $spec[0] | {
    schema_version,
    version,
    source_commit,
    release_date,
    source_date_epoch,
    template,
    platforms: [.platforms[] | . + {
      archive: null,
      archive_size: null,
      archive_sha256: null
    }]
  }
' > "$manifest_path"

: > "$OUTPUT_DIR/SOURCE_SHA256SUMS"
printf '%s  %s\n' "$template_sha256" "$template_url" >> "$OUTPUT_DIR/SOURCE_SHA256SUMS"

while IFS= read -r platform_json; do
  platform="$(jq -er '.name' <<< "$platform_json")"
  binary_url="$(jq -er '.binary_url' <<< "$platform_json")"
  binary_size="$(jq -er '.binary_size' <<< "$platform_json")"
  binary_sha256="$(jq -er '.binary_sha256' <<< "$platform_json")"

  [[ "$platform" =~ ^(darwin|linux)-(arm64|x64)$ ]] || \
    fail "Unsupported platform in $SPEC_FILE: $platform"

  echo "Packaging Showpass CLI $version for $platform"

  stage_dir="$WORK_DIR/$platform"
  mkdir -p "$stage_dir/templates"

  binary_path="$stage_dir/showpass"
  download "$binary_url" "$binary_path"
  verify_file "$binary_path" "$binary_size" "$binary_sha256"
  chmod 0755 "$binary_path"

  tar -xzf "$template_archive" -C "$stage_dir/templates"
  [[ -f "$stage_dir/templates/app-template/package.json" ]] || \
    fail "Template package.json is missing for $platform"

  find "$stage_dir/templates" -type d -exec chmod 0755 {} +
  find "$stage_dir/templates" -type f -exec chmod 0644 {} +
  printf '%s\n' "$version" > "$stage_dir/VERSION"
  cp "$REPO_ROOT/NOTICE.md" "$stage_dir/NOTICE.md"
  chmod 0644 "$stage_dir/VERSION" "$stage_dir/NOTICE.md"

  archive_name="showpass-${version}-${platform}.tar.gz"
  archive_path="$OUTPUT_DIR/$archive_name"
  (
    cd "$stage_dir"
    tar \
      --format=gnu \
      --sort=name \
      --mtime="@${source_date_epoch}" \
      --owner=0 \
      --group=0 \
      --numeric-owner \
      -cf - NOTICE.md VERSION showpass templates | gzip -n -9 > "$archive_path"
  )

  archive_sha256="$(sha256sum "$archive_path" | awk '{print $1}')"
  archive_size="$(wc -c < "$archive_path" | tr -d ' ')"

  jq \
    --arg platform "$platform" \
    --arg archive "$archive_name" \
    --arg archive_sha256 "$archive_sha256" \
    --argjson archive_size "$archive_size" \
    '(.platforms[] | select(.name == $platform)) += {
      archive: $archive,
      archive_size: $archive_size,
      archive_sha256: $archive_sha256
    }' \
    "$manifest_path" > "$manifest_path.tmp"
  mv "$manifest_path.tmp" "$manifest_path"

  printf '%s  %s\n' "$binary_sha256" "$binary_url" >> "$OUTPUT_DIR/SOURCE_SHA256SUMS"
done < <(jq -c '.platforms[]' "$SPEC_FILE")

(
  cd "$OUTPUT_DIR"
  sha256sum showpass-*.tar.gz | sort -k2 > SHA256SUMS
  sort -k2 -o SOURCE_SHA256SUMS SOURCE_SHA256SUMS
)

cat > "$OUTPUT_DIR/RELEASE_NOTES.md" <<EOF
## Showpass CLI ${version}

Supported platforms:

- macOS ARM64 and x86-64
- Linux ARM64 and x86-64

Each archive contains the standalone Showpass CLI executable and the project
templates required by \`showpass init\`.

### Homebrew

\`\`\`bash
brew install showpass/tap/showpass
\`\`\`

### Debian / Ubuntu

Download the \`.deb\` for your architecture from this release, then install it
with \`sudo apt install ./showpass_<version>-1_<architecture>.deb\`.

### Fedora / RHEL

Download the \`.rpm\` for your architecture from this release, then install it
with \`sudo dnf install ./showpass-<version>-1.<architecture>.rpm\`.

The release was imported from the public Showpass distribution published on
${release_date} and corresponds to private source commit \`${source_commit}\`.
See the attached \`SHA256SUMS\`, \`LINUX_PACKAGES_SHA256SUMS\`,
\`SOURCE_SHA256SUMS\`, and \`manifest.json\` files for integrity and provenance.
EOF

echo "Release artifacts written to $OUTPUT_DIR"
