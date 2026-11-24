{
  description = "appring: a radial menu for the desktop. Hold a key, point, release to run.";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = {nixpkgs, ...}: let
    # The ring runs on Quickshell, which is Linux (Wayland) only for now.
    systems = ["x86_64-linux" "aarch64-linux"];
    forAll = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
  in {
    # The app, the `appring` command, the desktop entry and the icons (nix/package.nix).
    packages = forAll (pkgs: rec {
      appring = pkgs.callPackage ./nix/package.nix {};
      default = appring;
    });

    # `nix develop`: everything the justfile needs, the off-screen tests included.
    devShells = forAll (pkgs: {
      default = pkgs.mkShell {
        packages = [
          pkgs.just
          pkgs.gitleaks
          pkgs.quickshell
          pkgs.desktop-file-utils # desktop-file-validate: nix/com.mirql.appring.desktop
          # the off-screen tests (tools/gallery.sh)
          pkgs.sway
          pkgs.grim
          pkgs.wtype
          pkgs.dbus
          (pkgs.python3.withPackages (ps: [ps.pywayland]))
        ];
        RING_GALLERY_WLR_PROTOCOLS = "${pkgs.wlr-protocols}/share/wlr-protocols";
        RING_GALLERY_WAYLAND_XML = "${pkgs.wayland-scanner.out}/share/wayland/wayland.xml";
        RING_GALLERY_FONTS = pkgs.lib.concatStringsSep ":" [
          "${pkgs.nerd-fonts.jetbrains-mono}"
          "${pkgs.dejavu_fonts}"
          "${pkgs.noto-fonts-color-emoji}"
        ];
        RING_GALLERY_ICONS = "${pkgs.papirus-icon-theme}";
      };
    });

    formatter = forAll (pkgs: pkgs.alejandra);
  };
}
