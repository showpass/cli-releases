#!/usr/bin/env bash
set -euo pipefail

readonly DEFAULT_BASE_URL="https://showpass-live.s3.us-west-2.amazonaws.com/releases/cli"
readonly BASE_URL="${BASE_URL:-$DEFAULT_BASE_URL}"
readonly OUTPUT_DIR="${OUTPUT_DIR:-$PWD/dist}"
readonly WORK_DIR="${WORK_DIR:-$PWD/.release-work}"

required_vars=(
  VERSION
  DARWIN_ARM64_SHA256
  DARWIN_X64_SHA256
  LINUX_ARM64_SHA256
  LINUX_X64_SHA256
  TEMPLATE_SHA256
)

for var_name in "${required_vars[@]}"; do
  if [[ -z "${!var_name:-}" ]]; then
    echo "Missing required environment variable: $var_name" >&2
    exit 1
  fi
done

version="${VERSION#v}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
  echo "Invalid semantic version: $VERSION" >&2
  exit 1
fi

for checksum in \
  "$DARWIN_ARM64_SHA256" \
  "$DARWIN_X64_SHA256" \
  "$LINUX_ARM64_SHA256" \
  "$LINUX_X64_SHA256" \
  "$TEMPLATE_SHA256"; do
  if [[ ! "$checksum" =~ ^[a-f0-9]{64}$ ]]; then
    echo "Invalid SHA-256 value: $checksum" >&2
    exit 1
  fi
done

validate_child_directory() {
  local directory="$1"
  local label="$2"

  if [[ "$directory" != "$PWD/"* || "$directory" == "$PWD" || "$directory" == "$PWD/" ]]; then
    echo "$label must be a child directory inside the repository checkout" >&2
    exit 1
  fi
}

validate_child_directory "$OUTPUT_DIR" OUTPUT_DIR
validate_child_directory "$WORK_DIR" WORK_DIR

if [[ "$OUTPUT_DIR" == "$WORK_DIR" ]]; then
  echo "OUTPUT_DIR and WORK_DIR must be different directories" >&2
  exit 1
fi

rm -rf "$OUTPUT_DIR" "$WORK_DIR"
mkdir -p "$OUTPUT_DIR" "$WORK_DIR"

declare -A binary_checksums=(
  [darwin-arm64]="$DARWIN_ARM64_SHA256"
  [darwin-x64]="$DARWIN_X64_SHA256"
  [linux-arm64]="$LINUX_ARM64_SHA256"
  [linux-x64]="$LINUX_X64_SHA256"
)

platforms=(darwin-arm64 darwin-x64 linux-arm64 linux-x64)

download() {
  local url="$1"
  local destination="$2"
  curl --fail --silent --show-error --location \
    --retry 5 --retry-all-errors --output "$destination" "$url"
}

verify() {
  local expected="$1"
  local file_path="$2"
  printf '%s  %s\n' "$expected" "$file_path" | sha256sum --check --status
}

manifest_path="$OUTPUT_DIR/manifest.json"
jq -n \
  --arg version "$version" \
  --arg source_base_url "$BASE_URL" \
  --arg template_sha256 "$TEMPLATE_SHA256" \
  '{
    version: $version,
    source_base_url: $source_base_url,
    template_sha256: $template_sha256,
    platforms: []
  }' > "$manifest_path"

for platform in "${platforms[@]}"; do
  echo "Packaging Showpass CLI $version for $platform"

  stage_dir="$WORK_DIR/$platform"
  mkdir -p "$stage_dir/templates"

  binary_url="${BASE_URL%/}/$platform/showpass"
  template_url="${BASE_URL%/}/$platform/templates.tgz"
  binary_path="$stage_dir/showpass"
  template_archive="$WORK_DIR/$platform-templates.tgz"

  download "$binary_url" "$binary_path"
  verify "${binary_checksums[$platform]}" "$binary_path"
  chmod 0755 "$binary_path"

  download "$template_url" "$template_archive"
  verify "$TEMPLATE_SHA256" "$template_archive"
  tar -xzf "$template_archive" -C "$stage_dir/templates"

  printf '%s\n' "$version" > "$stage_dir/VERSION"

  archive_name="showpass-${version}-${platform}.tar.gz"
  archive_path="$OUTPUT_DIR/$archive_name"
  (
    cd "$stage_dir"
    tar \
      --sort=name \
      --mtime='UTC 1970-01-01' \
      --owner=0 \
      --group=0 \
      --numeric-owner \
      -cf - VERSION showpass templates | gzip -n -9 > "$archive_path"
  )

  archive_sha256="$(sha256sum "$archive_path" | awk '{print $1}')"
  archive_size="$(wc -c < "$archive_path" | tr -d ' ')"

  jq \
    --arg name "$platform" \
    --arg binary_url "$binary_url" \
    --arg binary_sha256 "${binary_checksums[$platform]}" \
    --arg template_url "$template_url" \
    --arg archive "$archive_name" \
    --arg archive_sha256 "$archive_sha256" \
    --argjson archive_size "$archive_size" \
    '.platforms += [{
      name: $name,
      binary_url: $binary_url,
      binary_sha256: $binary_sha256,
      template_url: $template_url,
      archive: $archive,
      archive_sha256: $archive_sha256,
      archive_size: $archive_size
    }]' \
    "$manifest_path" > "$manifest_path.tmp"
  mv "$manifest_path.tmp" "$manifest_path"
done

(
  cd "$OUTPUT_DIR"
  sha256sum showpass-*.tar.gz | sort -k2 > SHA256SUMS
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

See [SHA256SUMS](./SHA256SUMS) and [manifest.json](./manifest.json) for release
integrity and provenance.
EOF

echo "Release artifacts written to $OUTPUT_DIR"
