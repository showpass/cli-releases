{
  description = "Showpass CLI binary releases";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { nixpkgs, ... }:
    let
      version = "2.1.0";
      releaseBase = "https://github.com/showpass/cli-releases/releases/download/v${version}";

      assets = {
        aarch64-darwin = {
          platform = "darwin-arm64";
          hash = "sha256-wPfnqxNWlZ9VZBSpeFcqg46uqfQaPLqhf4wjIl3hUC8=";
        };
        x86_64-darwin = {
          platform = "darwin-x64";
          hash = "sha256-UPf6MVc2na82FwYxFZ24Beq/bvNYiG2DPIrz7721NxE=";
        };
        aarch64-linux = {
          platform = "linux-arm64";
          hash = "sha256-ICzIMGJkkmwmcWHC0i3bWjErAYQr6QJSDp7dS18qd1k=";
        };
        x86_64-linux = {
          platform = "linux-x64";
          hash = "sha256-Z569NKSAZdskKNVJqxh/LkC19XkDVCYXf9BVgxi3Uak=";
        };
      };

      forAllSystems = nixpkgs.lib.genAttrs (builtins.attrNames assets);

      mkShowpass = system:
        let
          pkgs = import nixpkgs { inherit system; };
          asset = assets.${system};
        in
        pkgs.stdenvNoCC.mkDerivation {
          pname = "showpass";
          inherit version;

          src = pkgs.fetchurl {
            url = "${releaseBase}/showpass-${version}-${asset.platform}.tar.gz";
            inherit (asset) hash;
          };

          # Release archives intentionally contain several top-level entries.
          sourceRoot = ".";
          strictDeps = true;
          dontBuild = true;
          dontStrip = true;

          nativeBuildInputs =
            [ pkgs.makeWrapper ]
            ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [
              pkgs.autoPatchelfHook
            ];

          buildInputs = pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [
            pkgs.glibc
          ];

          installPhase = ''
            runHook preInstall

            install -Dm755 showpass "$out/libexec/showpass"
            mkdir -p "$out/share/showpass"
            cp -R templates "$out/share/showpass/templates"

            mkdir -p "$out/bin"

            makeWrapper "$out/libexec/showpass" "$out/bin/showpass" \
              --set SHOWPASS_TEMPLATE_DIR \
              "$out/share/showpass/templates/app-template"

            runHook postInstall
          '';

          doInstallCheck = true;
          installCheckPhase = ''
            runHook preInstallCheck

            test "$("$out/bin/showpass" --version)" = "${version}"
            test -f "$out/share/showpass/templates/app-template/package.json"

            runHook postInstallCheck
          '';

          meta = {
            description = "Build and manage event websites connected to Showpass";
            homepage = "https://dev.showpass.com/cli/01-overview";
            mainProgram = "showpass";
            platforms = builtins.attrNames assets;
            sourceProvenance = [ pkgs.lib.sourceTypes.binaryNativeCode ];
          };
        };
    in
    {
      packages = forAllSystems (system:
        let
          showpass = mkShowpass system;
        in
        {
          inherit showpass;
          default = showpass;
        });
    };
}
