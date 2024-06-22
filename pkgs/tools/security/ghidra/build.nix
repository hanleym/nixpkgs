{
  stdenv,
  fetchFromGitHub,
  lib,
  callPackage,
  gradle_7,
  perl,
  makeBinaryWrapper,
  openjdk17,
  unzip,
  makeDesktopItem,
  copyDesktopItems,
  desktopToDarwinBundle,
  xcbuild,
  protobuf,
  ghidra-extensions,
  python3,
  python3Packages,
}:

let
  pkg_path = "$out/lib/ghidra";
  pname = "ghidra";
  version = "11.1.1";

  releaseName = "NIX";
  distroPrefix = "ghidra_${version}_${releaseName}";
  src = fetchFromGitHub {
    owner = "NationalSecurityAgency";
    repo = "Ghidra";
    rev = "Ghidra_${version}_build";
    hash = "sha256-t96FcAK3JwO66dOf4OhpOfU8CQfAczfF61Cg7m+B3fA=";
    # populate values that require us to use git. By doing this in postFetch we
    # can delete .git afterwards and maintain better reproducibility of the src.
    leaveDotGit = true;
    postFetch = ''
      cd "$out"
      git rev-parse HEAD > $out/COMMIT
      # 1970-Jan-01
      date -u -d "@$(git log -1 --pretty=%ct)" "+%Y-%b-%d" > $out/SOURCE_DATE_EPOCH
      # 19700101
      date -u -d "@$(git log -1 --pretty=%ct)" "+%Y%m%d" > $out/SOURCE_DATE_EPOCH_SHORT
      find "$out" -name .git -print0 | xargs -0 rm -rf
    '';
  };

  gradle = gradle_7;

  patches = [
    # Use our own protoc binary instead of the prebuilt one
    ./0001-Use-protobuf-gradle-plugin.patch

    # Override installation directory to allow loading extensions
    ./0002-Load-nix-extensions.patch

    # Remove build dates from output filenames for easier reference
    ./0003-Remove-build-datestamp.patch
  ];

  postPatch = ''
    # Set name of release (eg. PUBLIC, DEV, etc.)
    sed -i -e 's/application\.release\.name=.*/application.release.name=${releaseName}/' Ghidra/application.properties

    # Set build date and git revision
    echo "application.build.date=$(cat SOURCE_DATE_EPOCH)" >> Ghidra/application.properties
    echo "application.build.date.short=$(cat SOURCE_DATE_EPOCH_SHORT)" >> Ghidra/application.properties
    echo "application.revision.ghidra=$(cat COMMIT)" >> Ghidra/application.properties

    # Tells ghidra to use our own protoc binary instead of the prebuilt one.
    cat >>Ghidra/Debug/Debugger-gadp/build.gradle <<HERE
    protobuf {
      protoc {
        path = '${protobuf}/bin/protoc'
      }
    }
    HERE
  '';

  # Adds a gradle step that downloads all the dependencies to the gradle cache.
  addResolveStep = ''
        cat >>build.gradle <<HERE
    task resolveDependencies {
      doLast {
        project.rootProject.allprojects.each { subProject ->
          subProject.buildscript.configurations.each { configuration ->
            resolveConfiguration(subProject, configuration, "buildscript config \''${configuration.name}")
          }
          subProject.configurations.each { configuration ->
            resolveConfiguration(subProject, configuration, "config \''${configuration.name}")
          }
        }
      }
    }
    void resolveConfiguration(subProject, configuration, name) {
      if (configuration.canBeResolved) {
        logger.info("Resolving project {} {}", subProject.name, name)
        configuration.resolve()
      }
    }
    HERE
  '';

  # fake build to pre-download deps into fixed-output derivation
  # Taken from mindustry derivation.
  deps = stdenv.mkDerivation {
    pname = "${pname}-deps";
    inherit version src patches;

    postPatch = addResolveStep;

    nativeBuildInputs = [
      gradle
      perl
    ] ++ lib.optional stdenv.isDarwin xcbuild;
    buildPhase = ''
      runHook preBuild
      export HOME="$NIX_BUILD_TOP/home"
      mkdir -p "$HOME"
      export JAVA_TOOL_OPTIONS="-Duser.home='$HOME'"
      export GRADLE_USER_HOME="$HOME/.gradle"

      # First, fetch the static dependencies.
      gradle --no-daemon --info -Dorg.gradle.java.home=${openjdk17} -I gradle/support/fetchDependencies.gradle init

      # Then, fetch the maven dependencies.
      gradle --no-daemon --info -Dorg.gradle.java.home=${openjdk17} resolveDependencies
      runHook postBuild
    '';
    # perl code mavenizes pathes (com.squareup.okio/okio/1.13.0/a9283170b7305c8d92d25aff02a6ab7e45d06cbe/okio-1.13.0.jar -> com/squareup/okio/okio/1.13.0/okio-1.13.0.jar)
    installPhase = ''
      runHook preInstall
      find $GRADLE_USER_HOME/caches/modules-2 -type f -regex '.*\.\(jar\|pom\)' \
        | perl -pe 's#(.*/([^/]+)/([^/]+)/([^/]+)/[0-9a-f]{30,40}/([^/\s]+))$# ($x = $2) =~ tr|\.|/|; "install -Dm444 $1 \$out/maven/$x/$3/$4/$5" #e' \
        | sh
      cp -r dependencies $out/dependencies
      runHook postInstall
    '';
    outputHashAlgo = "sha256";
    outputHashMode = "recursive";
    outputHash = "sha256-66gL4UFlBUo2JIEOXoF6tFvXtBdEX4b2MeSrV1b6Vg4=";
  };
in
stdenv.mkDerivation (finalAttrs: {
  inherit
    pname
    version
    src
    patches
    postPatch
    ;

  # Don't create .orig files if the patch isn't an exact match.
  patchFlags = [
    "--no-backup-if-mismatch"
    "-p1"
  ];

  desktopItems = [
    (makeDesktopItem {
      name = "ghidra";
      exec = "ghidra";
      icon = "ghidra";
      desktopName = "Ghidra";
      genericName = "Ghidra Software Reverse Engineering Suite";
      categories = [ "Development" ];
      terminal = false;
    })
  ];

  nativeBuildInputs =
    [
      gradle
      unzip
      makeBinaryWrapper
      copyDesktopItems
      protobuf
      python3
      python3Packages.pip
    ]
    ++ lib.optionals stdenv.isDarwin [
      xcbuild
      desktopToDarwinBundle
    ];

  dontStrip = true;

  __darwinAllowLocalNetworking = true;

  buildPhase = ''
    runHook preBuild
    export HOME="$NIX_BUILD_TOP/home"
    mkdir -p "$HOME"
    export JAVA_TOOL_OPTIONS="-Duser.home='$HOME'"

    ln -s ${deps}/dependencies dependencies

    sed -i "s#mavenLocal()#mavenLocal(); maven { url '${deps}/maven' }#g" build.gradle

    gradle --offline --no-daemon --info -Dorg.gradle.java.home=${openjdk17} buildGhidra
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p "${pkg_path}" "$out/share/applications"

    ZIP=build/dist/$(ls build/dist)
    echo $ZIP
    unzip $ZIP -d ${pkg_path}
    f=("${pkg_path}"/*)
    mv "${pkg_path}"/*/* "${pkg_path}"
    rmdir "''${f[@]}"

    for f in Ghidra/Framework/Gui/src/main/resources/images/GhidraIcon*.png; do
      res=$(basename "$f" ".png" | cut -d"_" -f3 | cut -c11-)
      install -Dm444 "$f" "$out/share/icons/hicolor/''${res}x''${res}/apps/ghidra.png"
    done;
    # improved macOS icon support
    install -Dm444 Ghidra/Framework/Gui/src/main/resources/images/GhidraIcon64.png $out/share/icons/hicolor/32x32@2/apps/ghidra.png

    runHook postInstall
  '';

  postFixup = ''
    mkdir -p "$out/bin"
    ln -s "${pkg_path}/ghidraRun" "$out/bin/ghidra"
    wrapProgram "${pkg_path}/support/launch.sh" \
      --set-default NIX_GHIDRAHOME "${pkg_path}/Ghidra" \
      --prefix PATH : ${lib.makeBinPath [ openjdk17 ]}
  '';

  passthru = {
    inherit releaseName distroPrefix;
    inherit (ghidra-extensions.override { ghidra = finalAttrs.finalPackage; })
      buildGhidraExtension
      buildGhidraScripts
      ;

    withExtensions = callPackage ./with-extensions.nix { ghidra = finalAttrs.finalPackage; };
  };

  meta = with lib; {
    changelog = "https://htmlpreview.github.io/?https://github.com/NationalSecurityAgency/ghidra/blob/Ghidra_${finalAttrs.version}_build/Ghidra/Configurations/Public_Release/src/global/docs/ChangeHistory.html";
    description = "Software reverse engineering (SRE) suite of tools";
    mainProgram = "ghidra";
    homepage = "https://ghidra-sre.org/";
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
      "x86_64-darwin"
      "aarch64-darwin"
    ];
    sourceProvenance = with sourceTypes; [
      fromSource
      binaryBytecode # deps
    ];
    license = licenses.asl20;
    maintainers = with maintainers; [
      roblabla
      vringar
    ];
    broken = stdenv.isDarwin && stdenv.isx86_64;
  };
})
