# LibSignalClient ships as a CocoaPod (libsignal has no root SPM package). The
# checksum pins Signal's prebuilt libsignal_ffi archive for this exact tag —
# computed from https://build-artifacts.signal.org/libraries/libsignal-client-ios-build-v0.86.5.tar.gz.
# Keep the tag in lockstep with libsignal-android in klic-mobile-android.
ENV['LIBSIGNAL_FFI_PREBUILD_CHECKSUM'] ||= 'a3df979aa39b307ac4ef0f3fd59536daab5d6b3f8257c7aefe5f0470625f2582'

platform :ios, '17.0'

target 'Klic' do
  use_frameworks!
  pod 'LibSignalClient', git: 'https://github.com/signalapp/libsignal.git', tag: 'v0.86.5'
end
