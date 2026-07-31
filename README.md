# Showpass CLI releases

This is the official public distribution repository for the Showpass CLI.
It contains immutable, versioned release archives and package-manager metadata;
the application source is maintained separately.

## Install

### Homebrew

```bash
brew install showpass/tap/showpass
```

After the tap has been added once, upgrades and reinstalls can use the short
formula name:

```bash
brew upgrade showpass
```

### Direct installer

```bash
curl -fsSL "https://www.showpass.com/install.sh" | bash
```

The current supported platforms are macOS and Linux on ARM64 and x86-64.
Windows is not supported by the current CLI release.

## Verify a download

Every GitHub release contains a `SHA256SUMS` file. Download the archive and the
checksum file from the same release, then verify it before extracting:

```bash
shasum -a 256 -c SHA256SUMS
```

Linux users can substitute `sha256sum -c SHA256SUMS`.

Each archive contains both the `showpass` executable and the project templates
required by `showpass init`.

## Documentation

- [CLI overview](https://dev.showpass.com/cli/01-overview)
- [Commands reference](https://dev.showpass.com/cli/02-commands)
- [Private Organizer API overview](https://dev.showpass.com/api/10-private-api-overview)

Never include a Showpass API token in an issue, log, or bug report.

## Release provenance

Release archives are imported from Showpass's public production distribution,
verified against explicit expected checksums, and repackaged deterministically.
The release `manifest.json` records the source URL and both source and archive
checksums for every supported platform.

## Licensing

This repository does not grant an open-source license for the Showpass CLI
binary. See [NOTICE.md](NOTICE.md) for distribution details.
