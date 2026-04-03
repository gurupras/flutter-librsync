Pod::Spec.new do |s|
  s.name             = 'flutter_librsync'
  s.version          = '0.0.1'
  s.summary          = 'Flutter FFI plugin wrapping librsync-go for macOS.'
  s.description      = 'Provides rsync signature, delta and patch operations via dart:ffi.'
  s.homepage         = 'https://github.com/gurupras/flutter-librsync'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'gurupras' => 'gurupras@example.com' }
  s.source           = { :path => '.' }

  s.platform         = :osx, '10.15'
  s.swift_version    = '5.0'
  s.dependency 'FlutterMacOS'

  # Build the universal dylib before CocoaPods links it.
  s.prepare_command  = <<-CMD
    set -e
    PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
    if ! command -v make >/dev/null 2>&1; then
      echo "WARNING: make not found; skipping Go macOS build."
      exit 0
    fi
    make -C "$PLUGIN_ROOT" macos
  CMD

  # Universal (arm64 + amd64) dynamic library produced by `make macos`
  s.vendored_libraries = '../prebuilt/macos/libflutter_librsync.dylib'

  s.source_files     = 'Classes/**/*'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
  }
end
