{
  lib,
  stdenv,
  fetchFromGitHub,
  gradle,
  jdk17_headless,
  graalvmPackages,
  dbus,
  bluez,
  zlib,
  depsFile ? ./deps.json,
  depsUpdateTask ? "nixDownloadDeps :mobileapp:libpebble3:nixResolveJvmDependencies",
}:

let
  mobileAppSrc = fetchFromGitHub {
    owner = "jplexer";
    repo = "libpebble3";
    rev = "b5cb8cb6dc0f27d21244fe77b93629455f13c64e";
    hash = "sha256-h6lR2gy2BTMCeOww3Snp99UfH+TqiPyBHrTKzYbZhPo=";
  };
  graalvm = graalvmPackages.graalvm-ce;
in
stdenv.mkDerivation (finalAttrs: {
  pname = "libpebble3d";
  version = "2.0-35dea0c";

  src = fetchFromGitHub {
    owner = "abranson";
    repo = "rockpool";
    rev = "35dea0ccb5318a65db447fe31b5fdd56d6844135";
    hash = "sha256-bHiy7WfFArjv7T0Q0rhaLfVjLXVJLwFrpEUKy3EJ/Rw=";
  };

  patches = [ ./jvm-only.patch ];

  postUnpack = ''
    cp -R ${mobileAppSrc}/. $sourceRoot/libpebble3d/mobileapp/
    chmod -R u+w $sourceRoot/libpebble3d/mobileapp
  '';

  nativeBuildInputs = [
    gradle
    jdk17_headless
    graalvm
    dbus
    bluez
  ];

  buildInputs = [ zlib ];

  mitmCache = gradle.fetchDeps {
    pkg = finalAttrs.finalPackage;
    data = depsFile;
    useBwrap = false;
  };

  gradleBuildTask = "jvmDist";
  gradleUpdateTask = depsUpdateTask;
  gradleFlags = [ "-Dorg.gradle.java.home=${jdk17_headless}" ];
  JAVA_HOME = jdk17_headless;
  enableParallelBuilding = false;
  enableParallelUpdating = false;

  preBuild = ''
    cd libpebble3d/daemon
  '';

  postBuild = ''
    runtime_cp=$(find build/jvmDist/libs -name '*.jar' -print | sort | tr '\n' ':')

    export DBUS_SYSTEM_BUS_ADDRESS="$(${dbus}/bin/dbus-daemon --session --fork --print-address)"
    export DBUS_SESSION_BUS_ADDRESS="$(${dbus}/bin/dbus-daemon --session --fork --print-address)"
    ${bluez}/libexec/bluetooth/bluetoothd --nodetach >/dev/null 2>&1 &

    agent_dir=$TMPDIR/native-image-agent
    mkdir -p "$agent_dir"
    timeout 45 env LIBPEBBLE3D_AUTOCONNECT=1 LIBPEBBLE3D_TRACE_HTTP=1 \
      ${graalvm}/bin/java -Djava.net.preferIPv4Stack=true \
      -agentlib:native-image-agent=config-output-dir="$agent_dir" \
      -cp "$runtime_cp" io.rebble.libpebblecommon.Daemon \
      >$TMPDIR/trace-run.log 2>&1 || true

    if [ ! -s "$agent_dir/reachability-metadata.json" ]; then
      tail -n 30 $TMPDIR/trace-run.log >&2 || true
      echo "libpebble3d native-image tracing produced no metadata" >&2
      exit 1
    fi

    mkdir -p native-out
    ${graalvm}/bin/native-image \
      -H:ConfigurationFileDirectories="$agent_dir" \
      -H:ReflectionConfigurationFiles=../reflect-config.json \
      -H:ResourceConfigurationFiles=../resource-config.json \
      -H:JNIConfigurationFiles=../jni-config.json \
      -H:DynamicProxyConfigurationFiles=../proxy-config.json \
      -H:NumberOfThreads="$NIX_BUILD_CORES" \
      -J-XX:MaxRAMPercentage=75 \
      -cp "$runtime_cp" \
      -o native-out/libpebble3d \
      --no-fallback \
      --enable-url-protocols=http,https \
      -march=armv8-a \
      -Ob \
      -H:+ReportExceptionStackTraces \
      io.rebble.libpebblecommon.Daemon
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin $out/libexec/libpebble3d
    cp native-out/* $out/libexec/libpebble3d/
    ln -s ../libexec/libpebble3d/libpebble3d $out/bin/libpebble3d
    runHook postInstall
  '';

  meta = {
    description = "Native Linux Pebble companion daemon";
    homepage = "https://github.com/abranson/rockpool/tree/35dea0c/libpebble3d";
    license = with lib.licenses; [ gpl3Plus asl20 ];
    mainProgram = "libpebble3d";
    platforms = [ "aarch64-linux" ];
  };
})
