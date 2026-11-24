{
  description = "appring macOS spike: appring's QML ring in a plain Qt window (no Quickshell)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = {nixpkgs, ...}: let
    systems = ["aarch64-darwin" "x86_64-darwin" "x86_64-linux" "aarch64-linux"];
    forAll = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
  in {
    packages = forAll (pkgs: {
      default = pkgs.stdenv.mkDerivation {
        pname = "appring-spike";
        version = "0";
        # this folder, and appring's own QML from the repo (unchanged)
        src = pkgs.lib.fileset.toSource {
          root = ../..;
          fileset = pkgs.lib.fileset.unions [./. ../../appring];
        };
        sourceRoot = "source/experiments/macos-qt";
        nativeBuildInputs = [pkgs.cmake pkgs.qt6.wrapQtAppsHook];
        buildInputs = [pkgs.qt6.qtbase pkgs.qt6.qtdeclarative pkgs.qt6.qtsvg];
        # the Papirus icon theme as it ships (only image files; its package is
        # marked Linux-only, its source is not)
        cmakeFlags = ["-DSPIKE_ICONS=${pkgs.papirus-icon-theme.src}"];
        postInstall = ''
          share=$out/share/appring-spike
          mkdir -p $share/appring
          cp -r ../shim ../Spike.qml $share/
          # appring's drawing files, as they are; a qmldir so plain Qt knows
          # the module and its two singletons
          cp ../../../appring/{RingLayer,Ring,Theme,Settings}.qml $share/appring/
          cat > $share/appring/qmldir <<QMLDIR
          module appring
          singleton Theme 1.0 Theme.qml
          singleton Settings 1.0 Settings.qml
          RingLayer 1.0 RingLayer.qml
          Ring 1.0 Ring.qml
          QMLDIR
          sed -i 's/^ *//' $share/appring/qmldir
        '';
      };
    });
  };
}
