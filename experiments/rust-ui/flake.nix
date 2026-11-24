{
  description = "appring experiments: toolchain for the Rust UI spikes (iced, cxx-qt, egui, egui-layershell) on Wayland";

  inputs.nixpkgs.url = "nixpkgs";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
    in
    {
      devShells.${system}.default = pkgs.mkShell {
        name = "rust-ui-spikes";
        nativeBuildInputs = with pkgs; [
          rustc
          cargo
          pkg-config
          cmake
          # tools/gallery.sh
          sway
          grim
        ];
        buildInputs = with pkgs; [
          # Wayland + the bits every spike's window needs
          wayland
          wayland-protocols
          libxkbcommon
          libGL
          vulkan-loader
          fontconfig
          freetype
          # cxx-qt: Qt 6 + QML + LayerShellQt. qt6.env merges the split
          # per-module nixpkgs outputs (qtbase, qtdeclarative, qtwayland)
          # into one prefix so qmake/qt-build-utils can find every module's
          # .prl file from one place -- qtbase's own qmake alone only knows
          # about qtbase's own lib dir ("Could not find a prl path for Qt
          # module: Qml", qt-build-utils 0.10.0, checked).
          (qt6.env "rust-ui-spikes-qt" [ qt6.qtbase qt6.qtdeclarative qt6.qtwayland ])
          kdePackages.layer-shell-qt
        ];
        # So cxx-qt-build/qt-build-utils find Qt's qmake/cmake config, and the
        # wayland-shell-integration + QML plugins are on their search paths.
        QT_QPA_PLATFORM = "wayland";
        shellHook = ''
          export QML2_IMPORT_PATH="${pkgs.kdePackages.layer-shell-qt}/lib/qt-6/qml:$QML2_IMPORT_PATH"
          export QT_PLUGIN_PATH="${pkgs.kdePackages.layer-shell-qt}/lib/qt-6/plugins:${pkgs.qt6.qtbase}/lib/qt-6/plugins:$QT_PLUGIN_PATH"
          # winit/egui (and xkbcommon-dl) dlopen() libwayland-client and
          # libxkbcommon by soname at runtime rather than linking them
          # normally, so nix's usual RPATH patching doesn't help -- without
          # this on LD_LIBRARY_PATH they fail at startup with
          # `WaylandError(Connection(NoWaylandLib))` (checked).
          export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath [ pkgs.wayland pkgs.libxkbcommon pkgs.libGL pkgs.vulkan-loader ]}:$LD_LIBRARY_PATH"
          echo "rust-ui-spikes dev shell: rustc $(rustc --version), $(qmake6 -query QT_VERSION 2>/dev/null || echo 'qt6')"
        '';
      };
    };
}
