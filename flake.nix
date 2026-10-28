# SPDX-License-Identifier: GPL-2.0-or-later
{
  description = "QEMU machine for the Chumby Classic (Freescale i.MX21)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      lib = nixpkgs.lib;
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
      forAll = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # The pinned release, shared with ./build: key=value lines.
      release = lib.listToAttrs (
        map (
          line:
          let
            m = builtins.match "([a-z0-9]+)=(.*)" line;
          in
          lib.nameValuePair (builtins.elemAt m 0) (builtins.elemAt m 1)
        ) (lib.filter (l: l != "") (lib.splitString "\n" (builtins.readFile ./qemu-release)))
      );

      patches = map (p: ./patches + "/${p}") (
        lib.sort lib.lessThan (
          lib.filter (lib.hasSuffix ".patch") (lib.attrNames (builtins.readDir ./patches))
        )
      );

      qemu-chumby =
        pkgs:
        (pkgs.qemu.override {
          minimal = true;
          vncSupport = true;
          sdlSupport = pkgs.stdenv.hostPlatform.isLinux;
          openGLSupport = false;
          hostCpuTargets = [ "arm-softmmu" ];
        }).overrideAttrs
          (old: {
            pname = "qemu-chumby";
            inherit (release) version;
            src = pkgs.fetchurl {
              inherit (release) url sha256;
            };
            # nixpkgs' own patches are for the same release.
            patches = (old.patches or [ ]) ++ patches;
            # The minimal build leaves out pixman, which the display, VNC
            # and screendump need.
            buildInputs = old.buildInputs ++ [ pkgs.pixman ];
            doCheck = false;
            postInstall = ''
              install -m 755 ${./chumby-ctl} $out/bin/chumby-ctl
            '';
            meta = old.meta // {
              description = "QEMU with the chumby-classic machine (Freescale i.MX21)";
              mainProgram = "qemu-system-arm";
            };
          });
    in
    {
      packages = forAll (pkgs: rec {
        default = qemu-chumby pkgs;
        qemu = default;
      });

      # For ./build: nix develop, then ./build.
      devShells = forAll (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            python3
            ninja
            pkg-config
            glib
            pixman
            libpng
            zlib
            curl
          ];
        };
      });
    };
}
