Pod::Spec.new do |s|
  s.name             = 'flutter_librsync'
  s.version          = '0.0.1'
  s.summary          = 'Flutter FFI plugin wrapping librsync-go for iOS.'
  s.description      = 'Provides rsync signature, delta and patch operations via dart:ffi.'
  s.homepage         = 'https://github.com/gurupras/flutter-librsync'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'gurupras' => 'gurupras@example.com' }
  s.source           = { :path => '.' }

  s.platform         = :ios, '13.0'
  s.swift_version    = '5.0'
  s.dependency 'Flutter'

  # Build the static Go library before CocoaPods links it.
  # The Makefile is idempotent (skips rebuild when the .a is up to date).
  s.prepare_command  = <<-CMD
    set -e
    PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
    if ! command -v make >/dev/null 2>&1; then
      echo "WARNING: make not found; skipping Go iOS build."
      exit 0
    fi
    make -C "$PLUGIN_ROOT" ios
  CMD

  # The static archive produced by `make ios`
  s.vendored_libraries = '../prebuilt/ios/libflutter_librsync.a'

  # No Objective-C/Swift source files – everything is in the static lib.
  # CocoaPods requires at least one source file; use an empty placeholder.
  s.source_files     = 'Classes/**/*'
  # Create placeholder so the glob is not empty (CocoaPods requirement).


  s.pod_target_xcconfig = {
    'DEFINES_MODULE'                     => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    # The static library contains Go runtime symbols; tell the linker to allow
    # duplicate symbols from the Go runtime across compilation units.
    'OTHER_LDFLAGS'                      => '-Wl,-allow_stack_execute',
  }
end
