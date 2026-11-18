# Jarvis acceptance UI tests (iOS)

Page-level acceptance checks for the Jarvis settings screen, the local-key
editor and `/ask`. The tests drive the real app as UI-test host, so they need a
simulator that is already signed in to the Jarvis test account.

## Prerequisites

- Xcode with the iOS simulator runtime used by `ios_test_runner` in `BUILD`
  (`iPhone 18 Pro`, iOS 27.0).
- A booted or shut-down simulator named `BAZEL_TEST_iPhone 18 Pro_27.0`
  (`REUSE_GLOBAL_SIMULATOR` in `BUILD` makes rules_apple reuse it instead of
  deleting it, which would drop the login).
- The mock provider on loopback:

```bash
python3 Tests/JarvisAcceptanceUITests/mock_provider.py
```

- One test account state:
  - `testLocalKeyEditor` needs no local key; it only browses presets.
  - `testMockKeyAndAsk` saves `http://127.0.0.1:8765/v1` with model `mock` and
    a throwaway key into the simulator Keychain. Re-running it is fine: the
    editor falls back to "Replace local key" and keeps the stored key when the
    credential field is left empty.
  - `testAsk` expects no usable local key for the `fm` chat.

## Running

```bash
python3 build-system/Make/Make.py --overrideXcodeVersion \
  --cacheDir "$HOME/talky-ios-bazel-cache" test \
  --configurationPath build-system/talky-configuration.local.json \
  --xcodeManagedCodesigning \
  --target //Tests/JarvisAcceptanceUITests:JarvisAppUITests \
  --testFilter JarvisAppUITests/testMockKeyAndAsk
```

Available filters: `testSettingsOverview`, `testMockKeyAndAsk`,
`testAskFollowUp`, `testFormatMismatch`, `testCleartextWarning`,
`testEmptyModelAlert`. `testSettingsDark` needs the simulator switched to dark
appearance first (`xcrun simctl ui <udid> appearance dark`).

The Ask page is a chat transcript: question, answer and sources are message
bubbles. The composer field is `jarvis-ask-input`; its send/cancel control is
`jarvis-ask-send` and its label is `Send` or `Cancel`. Question, answer and
source bubbles expose `jarvis-question-<turn>`, `jarvis-answer-<turn>` and
`jarvis-source-<id>` identifiers. The transcript scrolls to the newest answer,
so the sources sit below it: drag on the transcript before tapping a source.
Tapping a source pops the Ask page back to the chat and jumps to that message.
`testAskFollowUp` sends a second question from the composer.

## Screenshots

Each test attaches `NN-name` screenshots. Export them from the result bundle:

```bash
cp -R bazel-testlogs/Tests/JarvisAcceptanceUITests/JarvisAppUITests/test.outputs/test.xcresult /tmp/jarvis-xcresult
chmod -R u+w /tmp/jarvis-xcresult
xcrun xcresulttool export attachments --path /tmp/jarvis-xcresult --output-path /tmp/jarvis-shots
```

`manifest.json` maps exported file names to the readable attachment names.

## Hints

- **Stale test runner:** xcodebuild may keep the previously installed runner
  app when the test bundle version is unchanged, so edits to the test code can
  silently be ignored. If a change does not take effect, uninstall the runner
  and rerun:

```bash
xcrun simctl uninstall <udid> com.apple.test.JarvisAppUITests-Runner
```

- `bazel test --test_filter` accepts one exact test name; a regex is treated
  as a literal and runs 0 tests.
- Text fields re-emit the editor state per keystroke, so `typeText` with a
  whole string drops characters. Type one character at a time.
- The keyboard return key is also labelled `Done`; the editor's own Done is
  the candidate with `frame.minY < 200`.
- Opening an action sheet while the keyboard is up puts the sheet behind the
  keyboard. Dismiss the keyboard first, or avoid opening the sheet.
- An action sheet's `Cancel` can be reported as existing but not hittable
  (it sits in an overlay window). Prefer terminating and relaunching the app
  over dismissing sheets in tests.
