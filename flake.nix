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
          # A desktop on Linux: GTK and SDL windows, and sound through
          # PipeWire, PulseAudio or ALSA. (macOS gets Cocoa and CoreAudio
          # without asking.)
          sdlSupport = pkgs.stdenv.hostPlatform.isLinux;
          gtkSupport = pkgs.stdenv.hostPlatform.isLinux;
          pipewireSupport = pkgs.stdenv.hostPlatform.isLinux;
          pulseSupport = pkgs.stdenv.hostPlatform.isLinux;
          alsaSupport = pkgs.stdenv.hostPlatform.isLinux;
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

      # chumby-emu: the machine as a desktop app, with its Qt control panel.
      chumby-emu =
        pkgs: qemu:
        let
          python = pkgs.python3.withPackages (ps: [ ps.pyside6 ]);
        in
        pkgs.stdenvNoCC.mkDerivation {
          pname = "chumby-emu";
          inherit (qemu) version;
          src = lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.unions [
              ./chumby-emu
              ./frontend
            ];
          };
          nativeBuildInputs = [ pkgs.makeWrapper ];
          installPhase = ''
            mkdir -p $out/share/chumby-emu $out/bin
            cp -r chumby-emu frontend $out/share/chumby-emu/
            makeWrapper ${python}/bin/python3 $out/bin/chumby-emu \
              --add-flags $out/share/chumby-emu/chumby-emu \
              --add-flags "--qemu ${qemu}/bin/qemu-system-arm" \
              --prefix PATH : ${pkgs.qemu-utils}/bin
          '';
          meta = {
            description = "The Chumby Classic as a desktop app (QEMU and a Qt control panel)";
            mainProgram = "chumby-emu";
            license = lib.licenses.gpl2Plus;
          };
        };
    in
    {
      packages = forAll (pkgs: rec {
        default = qemu-chumby pkgs;
        qemu = default;
        emu = chumby-emu pkgs default;
      });

      apps = forAll (pkgs: {
        emu = {
          type = "app";
          program = "${self.packages.${pkgs.stdenv.hostPlatform.system}.emu}/bin/chumby-emu";
        };
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
