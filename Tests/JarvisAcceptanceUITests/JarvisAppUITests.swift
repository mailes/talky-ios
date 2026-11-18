import XCTest

/// Drives the real app (as UI test host) through the Jarvis acceptance points.
/// Expects the reused simulator to be signed in to the Jarvis test account.
/// A mock OpenAI-compatible provider is expected at http://127.0.0.1:8765/v1
/// (tests/JarvisAcceptanceUITests documents it; see the verification report).
final class JarvisAppUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
    }

    private func dump(_ title: String) {
        print("=====\(title)=====")
        print(app.debugDescription)
        print("=====END \(title)=====")
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func launchApp() {
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 120), "app did not reach foreground")
    }

    private func openChat(_ labelPrefix: String) {
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", labelPrefix)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 60), "chat row '\(labelPrefix)' not found")
        row.tap()
        sleep(3)
    }

    private func sendMessage(_ text: String) {
        let composer = app.textViews.firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "composer not found")
        composer.tap()
        sleep(1)
        self.clearComposerDraft(composer)
        composer.typeText(text)
        sleep(1)
        let send = app.buttons.matching(NSPredicate(format: "label IN {'Send', '发送'}")).firstMatch
        XCTAssertTrue(send.waitForExistence(timeout: 5), "send button not found")
        send.tap()
    }

    /// Repeated runs leave a saved draft in the chat composer; a draft that
    /// grows makes the field's accessibility label change mid-type, which
    /// makes the query miss it. Start every send from an empty field.
    private func clearComposerDraft(_ composer: XCUIElement) {
        // `value` is not reliable for Telegram's text view, so try the
        // select-all path unconditionally and then verify.
        composer.press(forDuration: 1.2)
        let selectAll = app.menuItems["Select All"]
        if selectAll.waitForExistence(timeout: 3) {
            selectAll.tap()
            usleep(400_000)
            composer.typeText(XCUIKeyboardKey.delete.rawValue)
            usleep(400_000)
        }
        var remaining = (composer.value as? String) ?? ""
        var attempts = 0
        while !remaining.isEmpty, attempts < 10 {
            print("composer draft still present: \(remaining.count) chars")
            composer.tap()
            composer.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: min(remaining.count, 200)))
            usleep(400_000)
            remaining = (composer.value as? String) ?? ""
            attempts += 1
        }
        print("composer draft after clear: \(remaining.count) chars")
    }

    /// Each keystroke re-emits the editor state, so fast synthetic typing loses
    /// characters; type one character at a time.
    private func typeSlowly(_ field: XCUIElement, _ text: String) {
        for character in text {
            field.typeText(String(character))
            usleep(60_000)
        }
    }

    private func openJarvisSettings() {
        openChat("Jarvis")
        sendMessage("/setkey")
        sleep(5)
    }

    /// A saved key opens an action sheet first; pick the replace action.
    private func openLocalKeyEditor() {
        let localKey = app.buttons["Local key"]
        XCTAssertTrue(localKey.waitForExistence(timeout: 10), "local key row missing")
        localKey.tap()
        sleep(2)
        if app.buttons["Replace local key"].waitForExistence(timeout: 6) {
            app.buttons["Replace local key"].tap()
            sleep(2)
        }
    }

    /// Action-sheet taps occasionally land before the sheet settles; verify
    /// the row value and retry once.
    private func selectPreset(_ name: String) {
        let row = app.buttons["Preset"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "provider preset row missing")
        for _ in 0 ..< 2 {
            row.tap()
            let item = app.buttons[name]
            if item.waitForExistence(timeout: 5) {
                item.tap()
            }
            sleep(2)
            if (row.value as? String) == name {
                return
            }
        }
        XCTFail("preset \(name) not selected")
    }

    /// The keyboard's return key is also labelled "Done" and sits off the
    /// bottom of the screen; the editor's own Done is the top-most one.
    private func tapEditorDone() {
        let doneButtons = app.buttons.matching(NSPredicate(format: "label == 'Done'"))
        for index in 0 ..< doneButtons.count {
            let candidate = doneButtons.element(boundBy: index)
            if candidate.frame.minY < 200 {
                candidate.tap()
                return
            }
        }
        XCTFail("editor Done button not found")
    }

    func testMockKeyAndAsk() throws {
        launchApp()
        openJarvisSettings()
        openLocalKeyEditor()

        let presetRow = app.buttons["Preset"]
        XCTAssertTrue(presetRow.waitForExistence(timeout: 10), "provider preset row missing")
        presetRow.tap()
        sleep(1)
        app.buttons["Custom"].tap()
        sleep(2)

        // Add the mock model first: the button sits below where the keyboard
        // covers the list.
        let addModel = app.buttons["Add model"]
        XCTAssertTrue(addModel.waitForExistence(timeout: 5), "add model missing")
        addModel.tap()
        sleep(1)
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "add model alert missing")
        let modelField = alert.textFields.firstMatch
        XCTAssertTrue(modelField.waitForExistence(timeout: 3), "model field missing")
        modelField.typeText("mock")
        alert.buttons["Add"].tap()
        sleep(2)

        let urlField = app.textFields.firstMatch
        XCTAssertTrue(urlField.waitForExistence(timeout: 5), "base URL field missing")
        if app.buttons["Clear text"].exists {
            app.buttons["Clear text"].tap()
            sleep(1)
        }
        urlField.tap()
        sleep(1)
        typeSlowly(urlField, "http://127.0.0.1:8765/v1")
        sleep(1)
        print("base url field: \(String(describing: urlField.value))")

        let keyField = app.secureTextFields.firstMatch
        XCTAssertTrue(keyField.waitForExistence(timeout: 5), "key field missing")
        let placeholder = keyField.placeholderValue ?? ""
        if placeholder.contains("Leave empty") {
            print("keeping the saved key")
        } else {
            keyField.tap()
            sleep(1)
            typeSlowly(keyField, "mock-key")
            sleep(1)
        }
        attachScreenshot("15-mock-editor")

        // The keyboard's return key is also labelled "Done" and sits off the
        // bottom of the screen; the editor's own Done is the top-most one.
        tapEditorDone()
        sleep(5)
        dump("AFTER-SAVE")
        attachScreenshot("16-after-save")

        if app.buttons["Not now"].waitForExistence(timeout: 3) {
            app.buttons["Not now"].tap()
            sleep(3)
        }
        attachScreenshot("17-settings-configured")
        let configuredRow = app.buttons["Local key"]
        print("local key row exists: \(configuredRow.exists) value: \(String(describing: configuredRow.exists ? configuredRow.value : nil))")

        // /ask uses the device key: the mock answer carries Markdown and a
        // citation marker that must survive rendering.
        app.buttons["Close"].firstMatch.tap()
        sleep(2)
        app.terminate()
        launchApp()
        openChat("Chasing Light")
        sendMessage("/ask Reply with exactly this and nothing else: **HELLO** and `code`")
        sleep(3)
        attachScreenshot("18-ask-loading")
        // The answer arrives as a chat bubble; the bubble exposes its text so
        // the test can read the Markdown result without scraping the canvas.
        let answer = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'jarvis-answer-1'")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 90), "answer did not finish")
        sleep(2)
        dump("ASK-ANSWER")
        attachScreenshot("19-ask-transcript")
        let answerLabel = answer.label
        print("answer label: \(answerLabel)")
        print("raw markdown marker visible: \(answerLabel.contains("**HELLO**"))")
        print("citation preserved: \(answerLabel.contains("[channel:13:1]"))")
        print("nav buttons: \(app.navigationBars.buttons.allElementsBoundByIndex.map { $0.label })")
        XCTAssertTrue(answerLabel.contains("[channel:13:1]"), "citation missing from answer bubble")
        XCTAssertTrue(answerLabel.contains("HELLO"), "answer text missing")

        attachScreenshot("20-source-bubbles")

        // The source bubbles show the real chat messages below the answer;
        // tapping one must return to the chat at that message.
        // Drag on the transcript itself: `swipeUp` on the application lands
        // on the composer and never moves the list.
        let dragStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.70))
        let dragEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.20))
        for _ in 0 ..< 3 {
            dragStart.press(forDuration: 0.05, thenDragTo: dragEnd)
            usleep(400_000)
        }
        let sourceBubbles = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'jarvis-source-'"))
        XCTAssertTrue(sourceBubbles.firstMatch.waitForExistence(timeout: 10), "source bubble missing")
        // `isHittable` is unreliable for these rows (it accepted one below
        // the screen); pick one whose frame sits between the navigation bar
        // and the composer.
        var tappedSource = false
        for index in 0 ..< sourceBubbles.count {
            let candidate = sourceBubbles.element(boundBy: index)
            let frame = candidate.frame
            if frame.minY >= 140.0, frame.maxY <= 740.0, frame.minX >= 0.0, frame.maxX <= app.frame.width {
                candidate.tap()
                tappedSource = true
                break
            }
        }
        XCTAssertTrue(tappedSource, "no source bubble on screen to tap")
        // The chat composer is a text view; the Ask page only has a text
        // field, so its appearance means the pop happened.
        let backInChat = app.textViews.firstMatch.waitForExistence(timeout: 10)
        attachScreenshot("21-source-jump")
        XCTAssertTrue(backInChat, "tapping a source did not return to the chat")

        // Cancelling while loading must drop the late answer without crashing.
        app.terminate()
        launchApp()
        openChat("Chasing Light")
        sendMessage("/ask Tell me a long story about this chat")
        sleep(2)
        let cancel = app.buttons["jarvis-ask-send"]
        if cancel.waitForExistence(timeout: 10), cancel.label == "Cancel" {
            cancel.tap()
            sleep(10)
        }
        attachScreenshot("22-ask-cancelled")
        XCTAssertTrue(app.staticTexts["Cancelled."].waitForExistence(timeout: 10), "cancelled state missing")
    }

    /// The Ask page keeps a chat transcript and a bottom composer: a second
    /// question appends a second turn instead of replacing the first answer.
    func testAskFollowUp() throws {
        launchApp()
        openChat("Chasing Light")
        sendMessage("/ask Reply with exactly this and nothing else: **HELLO** and `code`")

        let firstAnswer = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'jarvis-answer-1'")).firstMatch
        XCTAssertTrue(firstAnswer.waitForExistence(timeout: 90), "first answer did not finish")
        attachScreenshot("32-ask-before-followup")

        let input = app.textFields["jarvis-ask-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10), "composer input missing")
        input.tap()
        sleep(1)
        typeSlowly(input, "Second question")
        sleep(1)
        let send = app.buttons["jarvis-ask-send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5), "send button missing")
        XCTAssertEqual(send.label, "Send")
        send.tap()

        let secondAnswer = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'jarvis-answer-2'")).firstMatch
        let deadline = Date().addingTimeInterval(90)
        while !secondAnswer.exists && Date() < deadline {
            usleep(500_000)
        }
        attachScreenshot("33-ask-followup")
        XCTAssertTrue(secondAnswer.exists, "follow-up answer did not append")
    }

    /// Preset Anthropic, then switch the API format to OpenAI: the editor
    /// must warn that the format no longer matches the preset. Nothing is
    /// saved, so the stored mock key stays untouched.
    func testFormatMismatch() throws {
        launchApp()
        openJarvisSettings()
        openLocalKeyEditor()

        app.buttons["Preset"].tap()
        sleep(1)
        app.buttons["Anthropic"].tap()
        sleep(2)
        app.buttons["API format"].tap()
        sleep(1)
        app.buttons["OpenAI Chat Completions"].tap()
        sleep(2)
        attachScreenshot("23-format-mismatch")
        dump("FORMAT-MISMATCH")
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'does not match the preset'")).firstMatch.waitForExistence(timeout: 5),
            "format mismatch warning missing"
        )
    }

    /// A cleartext Base URL must show the red http warning. The editor
    /// already holds the mock credential, so no action sheet is involved.
    func testCleartextWarning() throws {
        launchApp()
        openJarvisSettings()
        openLocalKeyEditor()

        let urlField = app.textFields.firstMatch
        XCTAssertTrue(urlField.waitForExistence(timeout: 5), "base URL field missing")
        urlField.tap()
        sleep(1)
        let clear = app.buttons["Clear text"]
        if clear.waitForExistence(timeout: 3) {
            clear.tap()
            sleep(1)
        }
        typeSlowly(urlField, "http://example.com/v1")
        sleep(2)
        attachScreenshot("24-http-warning")
        dump("HTTP-WARNING")
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'uses plain HTTP'")).firstMatch.waitForExistence(timeout: 5),
            "cleartext warning missing"
        )
    }

    /// Choosing Anthropic and then Custom clears the models (selecting the
    /// current preset is a no-op); saving must refuse before any request.
    func testEmptyModelAlert() throws {
        launchApp()
        openJarvisSettings()
        openLocalKeyEditor()

        selectPreset("Anthropic")
        selectPreset("Custom")
        tapEditorDone()
        sleep(3)
        attachScreenshot("25-empty-model-alert")
        dump("EMPTY-MODEL")
        XCTAssertTrue(app.staticTexts["Add at least one model."].waitForExistence(timeout: 5), "empty model alert missing")
    }

    /// Read-only walkthrough: settings overview, the source picker (the
    /// current entry is bold) and the provider presets.
    func testSettingsOverview() throws {
        launchApp()
        openJarvisSettings()
        attachScreenshot("26-settings")

        openLocalKeyEditor()
        attachScreenshot("28-editor")
        app.buttons["Preset"].tap()
        sleep(2)
        attachScreenshot("29-preset-picker")

        // Relaunch so no action sheet has to be dismissed; the source picker
        // is the last capture.
        app.terminate()
        launchApp()
        openJarvisSettings()
        let source = app.buttons["Current source"]
        XCTAssertTrue(source.waitForExistence(timeout: 10), "current source row missing")
        source.tap()
        sleep(2)
        attachScreenshot("27-mode-picker")
        dump("MODE-PICKER")
    }

    /// Run with the simulator already in dark appearance.
    func testSettingsDark() throws {
        launchApp()
        openJarvisSettings()
        attachScreenshot("30-settings-dark")

        let source = app.buttons["Current source"]
        XCTAssertTrue(source.waitForExistence(timeout: 10), "current source row missing")
        source.tap()
        sleep(1)
        attachScreenshot("31-mode-picker-dark")
        dump("MODE-PICKER")
    }

    /// Overview request failure: the usage section is omitted and the chat
    /// list explains that it could not be loaded. The failure is injected
    /// with a launch argument because reaching it for real needs the whole
    /// simulator offline; the rendered state is the same.
    func testSettingsOverviewUnavailable() throws {
        app.launchArguments = ["-jarvis-overview-fail"]
        launchApp()
        openJarvisSettings()
        sleep(2)
        let footer = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Could not load your authorized chats'")).firstMatch
        for _ in 0 ..< 6 where !footer.exists {
            app.swipeUp()
            usleep(500_000)
        }
        XCTAssertTrue(footer.waitForExistence(timeout: 5), "overview failure footer missing")
        attachScreenshot("35-settings-overview-unavailable")
        dump("OVERVIEW-UNAVAILABLE")
    }

    /// Diagnostic: dumps the main screen and the Settings tab so the language
    /// switch can be driven by real labels.
    func testDumpSettingsTab() throws {
        launchApp()
        sleep(3)
        dump("ROOT")
        let tab = app.tabBars.buttons["Settings"].exists ? app.tabBars.buttons["Settings"] : app.buttons["Settings"]
        if tab.waitForExistence(timeout: 10) {
            tab.tap()
            sleep(3)
        }
        dump("SETTINGS-TAB")
    }

    /// Finds a row by any of its labels, scrolling only when it is not already
    /// on screen. Swipes wait for the app to go idle and are slow on this
    /// screen, so keep the budget small.
    private func findButton(_ labels: [String], maxSwipes: Int = 2) -> XCUIElement? {
        func visibleButton() -> XCUIElement? {
            for label in labels {
                let button = app.buttons[label]
                // List rows exist in the tree while off screen; only a
                // hittable row is actually tappable.
                if button.exists && button.isHittable {
                    return button
                }
            }
            return nil
        }
        if let button = visibleButton() {
            return button
        }
        for _ in 0 ..< maxSwipes {
            app.swipeUp()
            if let button = visibleButton() {
                return button
            }
        }
        return nil
    }

    /// Run after saving a hosted key by hand: verifies the server reports it
    /// configured, then deletes it and checks the row returns to unconfigured.
    func testHostedKeyVerifyAndDelete() throws {
        launchApp()
        sleep(2)
        openJarvisSettings()
        sleep(3)

        let configured = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Hosted key' AND (label CONTAINS 'Configured' OR value CONTAINS 'Configured')")).firstMatch
        guard configured.waitForExistence(timeout: 10) else {
            XCTFail("hosted key is not configured; save it first")
            return
        }
        attachScreenshot("41-hosted-key-saved")

        configured.tap()
        sleep(2)
        let deleteAction = app.buttons["Delete hosted key"]
        XCTAssertTrue(deleteAction.waitForExistence(timeout: 5), "delete action missing")
        deleteAction.tap()
        sleep(2)
        let confirm = app.buttons.matching(NSPredicate(format: "label == 'Delete'")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "delete confirmation missing")
        confirm.tap()
        sleep(6)

        let notConfigured = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Hosted key' AND (label CONTAINS 'Not configured' OR value CONTAINS 'Not configured')")).firstMatch
        XCTAssertTrue(notConfigured.waitForExistence(timeout: 15), "hosted key row still configured after delete")
        attachScreenshot("42-hosted-key-deleted")

        // Deleting does not change the account's model source; put it back to
        // the platform service so the account is left in a working state.
        let source = app.buttons["Current source"]
        if source.waitForExistence(timeout: 5) {
            source.tap()
            sleep(2)
            let platform = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Platform model'")).firstMatch
            if platform.waitForExistence(timeout: 5) {
                platform.tap()
                sleep(5)
            }
        }
        attachScreenshot("43-source-back-to-platform")
    }

    /// Captures the model-source action sheet while the app is in Chinese, so
    /// the two-line option layout (title + explanation) can be checked.
    func testChineseModePicker() throws {
        launchApp()
        sleep(2)
        openChat("Jarvis")
        sendMessage("/setkey")
        sleep(6)
        let source = app.buttons["当前来源"].exists ? app.buttons["当前来源"] : app.buttons["Current source"]
        XCTAssertTrue(source.waitForExistence(timeout: 10), "current source row missing")
        source.tap()
        sleep(2)
        attachScreenshot("40-mode-picker-chinese")
        dump("MODE-PICKER-CHINESE")
    }

    /// Run while the app is in Simplified Chinese: captures the translated
    /// Jarvis settings, then restores English for the shared simulator.
    func testChineseScreensThenRestoreEnglish() throws {
        launchApp()
        sleep(2)
        // The app may reopen on the Settings tab; get back to the chat list.
        let chatsTab = app.buttons["Chats"].exists ? app.buttons["Chats"] : app.buttons["聊天"]
        if chatsTab.exists {
            chatsTab.tap()
            sleep(2)
        }
        openChat("Jarvis")
        sendMessage("/setkey")
        sleep(6)

        let localKey = app.buttons["本机 Key"]
        if localKey.waitForExistence(timeout: 5) {
            attachScreenshot("37-jarvis-settings-chinese")
            localKey.tap()
            sleep(3)
            attachScreenshot("38-local-key-editor-chinese")
            app.terminate()
            launchApp()
            sleep(2)
        } else {
            // The app is already in English; nothing to capture or restore.
            return
        }

        let settingsTab = findButton(["Settings", "设置"]) ?? app.buttons["设置"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 20), "settings tab not found")
        settingsTab.tap()
        sleep(3)

        guard let languageRow = findButton(["Language", "语言"]) else {
            XCTFail("language row not found")
            return
        }
        languageRow.tap()
        sleep(3)

        let englishPredicate = NSPredicate(format: "label CONTAINS 'English' OR value CONTAINS 'English'")
        var english = app.buttons.matching(englishPredicate).firstMatch
        if !english.exists || !english.isHittable {
            app.swipeDown()
            sleep(1)
            english = app.buttons.matching(englishPredicate).firstMatch
        }
        XCTAssertTrue(english.waitForExistence(timeout: 10), "English entry missing")
        english.tap()
        sleep(10)
        app.terminate()
        launchApp()
        sleep(3)
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 20), "app did not return to English")
        attachScreenshot("39-language-restored-english")
    }
}
