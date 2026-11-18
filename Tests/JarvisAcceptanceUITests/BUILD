load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_ui_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")

# Reuses (or creates) the simulator named "BAZEL_TEST_iPhone 18 Pro_27.0".
# Keep that simulator signed in to the Jarvis test account: clone it from the
# hand-driven simulator before running these tests.
ios_test_runner(
    name = "JarvisAcceptanceUITestRunner",
    device_type = "iPhone 18 Pro",
    os_version = "27.0",
)

swift_library(
    name = "JarvisAppUITestsLib",
    testonly = True,
    srcs = glob(["*.swift"]),
    module_name = "JarvisAppUITestsLib",
)

ios_ui_test(
    name = "JarvisAppUITests",
    env = {"REUSE_GLOBAL_SIMULATOR": "1"},
    minimum_os_version = "15.0",
    runner = ":JarvisAcceptanceUITestRunner",
    size = "large",
    tags = ["manual"],
    test_host = "//Telegram",
    deps = [":JarvisAppUITestsLib"],
    visibility = ["//Tests:__subpackages__"],
)
