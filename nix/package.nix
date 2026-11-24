# appring as a package: the app (a Quickshell root) in share/appring, the `appring`
# command, the desktop entry and the icons. The version is set here; a release
# (`just release VERSION`) checks it against the CHANGELOG.
{
  lib,
  stdenvNoCC,
  bash,
  quickshell,
  util-linux,
}:
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "appring";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../appring
      ../assets/icons/linux
      ./appring.sh
      ./com.mirql.appring.desktop
    ];
  };

  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/share/appring $out/bin $out/share/applications $out/share/icons
    cp -r appring $out/share/appring/
    cp -r assets/icons/linux/hicolor $out/share/icons/
    install -m 644 nix/com.mirql.appring.desktop $out/share/applications/
    substitute nix/appring.sh $out/bin/appring \
      --subst-var-by bash ${bash} \
      --subst-var-by quickshell ${quickshell} \
      --subst-var-by flock ${util-linux} \
      --subst-var-by out $out \
      --subst-var-by version ${finalAttrs.version}
    chmod +x $out/bin/appring
    runHook postInstall
  '';

  meta = {
    description = "A radial menu for the desktop: hold a key, point, release to run";
    homepage = "https://github.com/mirql/appring";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "appring";
  };
})
