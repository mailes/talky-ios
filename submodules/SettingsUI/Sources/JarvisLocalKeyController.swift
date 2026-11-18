import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext
import AlertUI

// Device-local provider configuration. Everything on this screen stays on the
// device: the key is validated against the provider from here and then written
// to the encrypted, account-isolated key store. No value here is ever sent to
// Talky. Mirrors the Android JarvisLocalKeyActivity.

private func jarvisLocalKeyText(_ strings: PresentationStrings, _ en: String, _ zh: String) -> String {
    return strings.baseLanguageCode.hasPrefix("zh") ? zh : en
}

func jarvisLocalProviderName(_ provider: JarvisLocalProvider, _ strings: PresentationStrings) -> String {
    switch provider {
    case .openai: return "OpenAI"
    case .deepseek: return "DeepSeek"
    case .anthropic: return "Anthropic"
    case .gemini: return "Gemini"
    case .custom: return jarvisLocalKeyText(strings, "Custom", "自定义")
    }
}

private enum JarvisLocalKeySection: Int32 {
    case provider
    case endpoint
    case credential
    case models
}

private enum JarvisLocalKeyEntry: ItemListNodeEntry {
    case providerHeader(String)
    case providerPreset(title: String, label: String)
    case providerFormat(title: String, label: String)
    case providerWarning(String)
    case endpointHeader(String)
    case endpointInput(placeholder: String, value: String)
    case endpointInfo(text: String, warning: Bool)
    case credentialHeader(String)
    case credentialKey(placeholder: String, value: String)
    case credentialInfo(String)
    case modelsHeader(String)
    case model(index: Int32, title: String, checked: Bool)
    case modelAdd(String)
    case modelsEmpty(String)
    case modelsHint(String)
    case footer(String)

    var section: ItemListSectionId {
        switch self {
        case .providerHeader, .providerPreset, .providerFormat, .providerWarning:
            return JarvisLocalKeySection.provider.rawValue
        case .endpointHeader, .endpointInput, .endpointInfo:
            return JarvisLocalKeySection.endpoint.rawValue
        case .credentialHeader, .credentialKey, .credentialInfo:
            return JarvisLocalKeySection.credential.rawValue
        case .modelsHeader, .model, .modelAdd, .modelsEmpty, .modelsHint, .footer:
            return JarvisLocalKeySection.models.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .providerHeader: return 0
        case .providerPreset: return 1
        case .providerFormat: return 2
        case .providerWarning: return 3
        case .endpointHeader: return 10
        case .endpointInput: return 11
        case .endpointInfo: return 12
        case .credentialHeader: return 20
        case .credentialKey: return 21
        case .credentialInfo: return 22
        case .modelsHeader: return 30
        case let .model(index, _, _): return 40 + index
        case .modelAdd: return 100
        // Appended before "Add model" (100): ids must stay increasing in the
        // order the entries are emitted, or ItemListControllerNode asserts.
        case .modelsEmpty: return 99
        case .modelsHint: return 102
        case .footer: return 110
        }
    }

    static func <(lhs: JarvisLocalKeyEntry, rhs: JarvisLocalKeyEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! JarvisLocalKeyModel
        switch self {
        case let .providerHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .providerPreset(title, label):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, label: label, labelStyle: .text, sectionId: self.section, style: .blocks, disclosureStyle: .arrow, action: {
                arguments.presentProviderPicker()
            })
        case let .providerFormat(title, label):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, label: label, labelStyle: .text, sectionId: self.section, style: .blocks, disclosureStyle: .arrow, action: {
                arguments.presentFormatPicker()
            })
        case let .providerWarning(text):
            return ItemListTextItem(presentationData: presentationData, text: .markdown(text), sectionId: self.section)
        case let .endpointHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .endpointInput(placeholder, value):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(), text: value, placeholder: placeholder, type: .regular(capitalization: false, autocorrection: false), returnKeyType: .next, clearType: .always, maxLength: JarvisLocalCredential.maxBaseUrlLength, sectionId: self.section, textUpdated: { value in
                arguments.updateBaseUrl(value)
            }, action: {
                // Return moves on; only the key field (or Done) saves.
            })
        case let .endpointInfo(text, warning):
            if warning {
                let attributed = NSAttributedString(
                    string: text,
                    font: Font.regular(presentationData.fontSize.itemListBaseHeaderFontSize),
                    textColor: presentationData.theme.list.itemDestructiveColor
                )
                return ItemListTextItem(presentationData: presentationData, text: .custom(context: arguments.context, string: attributed), sectionId: self.section)
            }
            return ItemListTextItem(presentationData: presentationData, text: .markdown(text), sectionId: self.section)
        case let .credentialHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .credentialKey(placeholder, value):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(), text: value, placeholder: placeholder, type: .password, returnKeyType: .done, textContentType: .oneTimeCode, clearType: .always, maxLength: 4096, sectionId: self.section, textUpdated: { value in
                arguments.updateKey(value)
            }, action: {
                arguments.save()
            })
        case let .credentialInfo(text):
            return ItemListTextItem(presentationData: presentationData, text: .markdown(text), sectionId: self.section)
        case let .modelsHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .model(_, title, checked):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: title, style: .left, checked: checked, zeroSeparatorInsets: false, sectionId: self.section, action: {
                arguments.selectModel(title)
            }, deleteAction: {
                arguments.confirmRemoveModel(title)
            })
        case let .modelAdd(text):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: text, kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.presentAddModelDialog()
            })
        case let .modelsEmpty(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .modelsHint(text):
            return ItemListTextItem(presentationData: presentationData, text: .markdown(text), sectionId: self.section)
        case let .footer(text):
            return ItemListTextItem(presentationData: presentationData, text: .markdown(text), sectionId: self.section)
        }
    }
}

private struct JarvisLocalKeyState: Equatable {
    var provider: JarvisLocalProvider
    var format: JarvisLocalFormat
    var baseUrl: String
    var models: [String]
    var selectedModel: String
    var key: String
    var hasSavedKey: Bool
    var saving: Bool
}

private final class JarvisLocalKeyModel {
    let context: AccountContext
    let state: ValuePromise<JarvisLocalKeyState>
    weak var controller: ItemListController?

    private let existing: JarvisLocalCredential?
    private let accountId: Int64
    private let keyStore: JarvisLocalKeyStore?
    private let client = JarvisLocalModelClient()
    private let onSaved: (JarvisLocalCredential) -> Void
    private var current: JarvisLocalKeyState

    init(context: AccountContext, existing: JarvisLocalCredential?, onSaved: @escaping (JarvisLocalCredential) -> Void) {
        self.context = context
        self.existing = existing
        self.accountId = context.account.id.int64
        self.keyStore = try? JarvisLocalKeyStore(userId: context.account.peerId.id._internalGetInt64Value())
        self.onSaved = onSaved
        if let existing = existing {
            self.current = JarvisLocalKeyState(
                provider: existing.provider,
                format: existing.format,
                baseUrl: existing.baseUrl,
                models: existing.models,
                selectedModel: existing.model,
                key: "",
                hasSavedKey: true,
                saving: false
            )
        } else {
            let provider = JarvisLocalProvider.openai
            self.current = JarvisLocalKeyState(
                provider: provider,
                format: provider.format,
                baseUrl: provider.baseUrl,
                models: [provider.defaultModel],
                selectedModel: provider.defaultModel,
                key: "",
                hasSavedKey: false,
                saving: false
            )
        }
        self.state = ValuePromise(self.current)
    }

    private var strings: PresentationStrings {
        return self.context.sharedContext.currentPresentationData.with { $0 }.strings
    }

    private var presentationData: PresentationData {
        return self.context.sharedContext.currentPresentationData.with { $0 }
    }

    private func localized(_ en: String, _ zh: String) -> String {
        return jarvisLocalKeyText(self.strings, en, zh)
    }

    private func stillCurrent() -> Bool {
        return self.context.account.id.int64 == self.accountId
    }

    private func update(_ transform: (inout JarvisLocalKeyState) -> Void) {
        guard self.stillCurrent() else { return }
        transform(&self.current)
        self.state.set(self.current)
    }

    private func showAlert(title: String, text: String) {
        guard let controller = self.controller, self.stillCurrent() else { return }
        controller.present(textAlertController(context: self.context, title: title, text: text, actions: [
            TextAlertAction(type: .defaultAction, title: self.localized("OK", "好"), action: {})
        ]), in: .window(.root))
    }

    // MARK: - Editing

    func presentProviderPicker() {
        guard let controller = self.controller else { return }
        let actionSheet = ActionSheetController(presentationData: self.presentationData)
        var items: [ActionSheetItem] = [
            ActionSheetTextItem(title: self.localized("Choose a preset", "选择预设"))
        ]
        for provider in JarvisLocalProvider.allCases {
            items.append(ActionSheetButtonItem(
                title: jarvisLocalProviderName(provider, self.strings),
                color: .accent,
                font: provider == self.current.provider ? .bold : .default,
                action: { [weak self, weak actionSheet] in
                    actionSheet?.dismissAnimated()
                    self?.selectProvider(provider)
                }
            ))
        }
        items.append(ActionSheetButtonItem(title: self.localized("Cancel", "取消"), color: .accent, font: .bold, action: { [weak actionSheet] in
            actionSheet?.dismissAnimated()
        }))
        actionSheet.setItemGroups([ActionSheetItemGroup(items: items)])
        controller.present(actionSheet, in: .window(.root))
    }

    private func selectProvider(_ provider: JarvisLocalProvider) {
        guard provider != self.current.provider else { return }
        self.update { state in
            state.provider = provider
            state.format = provider.format
            if provider == .custom {
                // A custom endpoint starts blank; stale preset values would
                // otherwise be saved under the wrong provider.
                state.baseUrl = ""
                state.models = []
                state.selectedModel = ""
            } else {
                state.baseUrl = provider.baseUrl
                state.models = [provider.defaultModel]
                state.selectedModel = provider.defaultModel
            }
        }
    }

    func presentFormatPicker() {
        guard let controller = self.controller else { return }
        let actionSheet = ActionSheetController(presentationData: self.presentationData)
        var items: [ActionSheetItem] = [
            ActionSheetTextItem(title: self.localized("API format", "API 格式"))
        ]
        for format in JarvisLocalFormat.allCases {
            items.append(ActionSheetButtonItem(
                title: format.label,
                color: .accent,
                font: format == self.current.format ? .bold : .default,
                action: { [weak self, weak actionSheet] in
                    actionSheet?.dismissAnimated()
                    self?.update { $0.format = format }
                }
            ))
        }
        items.append(ActionSheetButtonItem(title: self.localized("Cancel", "取消"), color: .accent, font: .bold, action: { [weak actionSheet] in
            actionSheet?.dismissAnimated()
        }))
        actionSheet.setItemGroups([ActionSheetItemGroup(items: items)])
        controller.present(actionSheet, in: .window(.root))
    }

    func updateBaseUrl(_ value: String) {
        self.update { state in
            state.baseUrl = value
        }
    }

    func updateKey(_ value: String) {
        self.update { state in
            state.key = value
        }
    }

    func selectModel(_ model: String) {
        self.update { state in
            if state.models.contains(model) {
                state.selectedModel = model
            }
        }
    }

    func confirmRemoveModel(_ model: String) {
        guard let controller = self.controller else { return }
        let alert = textAlertController(context: self.context, title: self.localized("Remove model?", "删除模型？"), text: model, actions: [
            TextAlertAction(type: .genericAction, title: self.localized("Cancel", "取消"), action: {}),
            TextAlertAction(type: .destructiveAction, title: self.localized("Remove", "删除"), action: { [weak self] in
                self?.removeModel(model)
            })
        ])
        controller.present(alert, in: .window(.root))
    }

    private func removeModel(_ model: String) {
        self.update { state in
            state.models.removeAll(where: { $0 == model })
            if state.selectedModel == model {
                state.selectedModel = state.models.first ?? ""
            }
        }
    }

    func presentAddModelDialog() {
        guard let controller = self.controller else { return }
        guard self.current.models.count < JarvisLocalCredential.maxModels else {
            self.showAlert(title: self.localized("Local key", "本机 Key"), text: self.localized("You can add at most \(JarvisLocalCredential.maxModels) models.", "最多只能添加 \(JarvisLocalCredential.maxModels) 个模型。"))
            return
        }
        let alert = UIAlertController(
            title: self.localized("Add model", "添加模型"),
            message: nil,
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.placeholder = self.localized("e.g. gpt-4o-mini", "例如 gpt-4o-mini")
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: self.localized("Cancel", "取消"), style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: self.localized("Add", "添加"), style: .default, handler: { [weak self, weak alert] _ in
            guard let self, let alert else { return }
            let value = (alert.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.utf8.count <= JarvisLocalCredential.maxModelLength else { return }
            self.update { state in
                if let existing = state.models.first(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) {
                    state.selectedModel = existing
                } else {
                    state.models.append(value)
                    state.selectedModel = value
                }
            }
        }))
        controller.present(alert, animated: true, completion: nil)
    }

    // MARK: - Saving

    func save() {
        guard !self.current.saving else { return }
        let state = self.current
        if state.models.isEmpty || state.selectedModel.isEmpty {
            self.showAlert(title: self.localized("Local key", "本机 Key"), text: self.localized("Add at least one model.", "请至少添加一个模型。"))
            return
        }
        if !state.hasSavedKey && state.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.showAlert(title: self.localized("Local key", "本机 Key"), text: self.localized("Enter an API key.", "请填写 API Key。"))
            return
        }
        let credential: JarvisLocalCredential
        do {
            if let existing = self.existing, state.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                credential = try existing.updating(provider: state.provider, format: state.format, baseUrl: state.baseUrl, models: state.models, model: state.selectedModel)
            } else {
                credential = try JarvisLocalCredential(provider: state.provider, format: state.format, baseUrl: state.baseUrl, models: state.models, model: state.selectedModel, key: state.key)
            }
        } catch {
            self.showAlert(
                title: self.localized("Local key", "本机 Key"),
                text: self.localized("Check the Base URL, the API key and at least one model name.", "请检查 Base URL、API Key 和模型名是否填写正确。")
            )
            return
        }
        guard let keyStore = self.keyStore else {
            self.showAlert(title: self.localized("Local key", "本机 Key"), text: self.localized("Secure storage is unavailable on this device.", "此设备的安全存储不可用。"))
            return
        }
        self.update { $0.saving = true }
        do {
            try self.client.validate(credential: credential) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self, self.stillCurrent() else { return }
                    switch result {
                    case .success:
                        do {
                            try keyStore.save(credential)
                        } catch {
                            self.update { $0.saving = false }
                            self.showAlert(title: self.localized("Local key", "本机 Key"), text: self.localized("The key could not be saved in secure storage.", "Key 无法写入安全存储。"))
                            return
                        }
                        if let navigationController = self.controller?.navigationController {
                            navigationController.popViewController(animated: true)
                        } else {
                            self.controller?.dismiss(animated: true)
                        }
                        // Let the pop settle before the settings page offers to
                        // switch the account's model source. The closure itself
                        // outlives this controller.
                        let onSaved = self.onSaved
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            onSaved(credential)
                        }
                    case let .failure(error):
                        self.update { $0.saving = false }
                        self.showAlert(title: self.localized("Key rejected", "Key 被拒绝"), text: self.localizedMessage(for: error))
                    }
                }
            }
        } catch {
            self.update { $0.saving = false }
            self.showAlert(
                title: self.localized("Local key", "本机 Key"),
                text: self.localized("Check the Base URL, the API key and at least one model name.", "请检查 Base URL、API Key 和模型名是否填写正确。")
            )
        }
    }

    private func localizedMessage(for error: JarvisLocalModelError) -> String {
        switch error {
        case .providerRejected:
            return self.localized("The provider rejected this key or model. Check the API key and the model name.", "服务商拒绝了该 Key 或模型，请核对 API Key 与模型名。")
        case .rateLimited:
            return self.localized("The provider is rate-limiting this key. Try again later.", "供应商对该 Key 限流，请稍后再试。")
        case .invalidConfiguration:
            return self.localized("Enter a Base URL, an API key and at least one model.", "请填写 Base URL、API Key 和至少一个模型。")
        case .invalidResponse, .credentialUnavailable, .unavailable:
            return self.localized("The key could not be verified. Check the Base URL, the API format and your connection.", "无法验证 Key，请检查 Base URL、API 格式和网络连接。")
        }
    }

    // MARK: - Entries

    func entries() -> [JarvisLocalKeyEntry] {
        let state = self.current
        var entries: [JarvisLocalKeyEntry] = []

        entries.append(.providerHeader(self.localized("Provider", "供应商")))
        entries.append(.providerPreset(
            title: self.localized("Preset", "预设"),
            label: jarvisLocalProviderName(state.provider, self.strings)
        ))
        entries.append(.providerFormat(title: self.localized("API format", "API 格式"), label: state.format.label))
        if state.provider != .custom && state.format != state.provider.format {
            entries.append(.providerWarning(self.localized(
                "This API format does not match the preset. Check that the Base URL speaks it.",
                "该 API 格式与预设不一致，请确认 Base URL 支持这种格式。"
            )))
        }

        entries.append(.endpointHeader(self.localized("Base URL", "Base URL")))
        entries.append(.endpointInput(placeholder: "https://api.example.com/v1", value: state.baseUrl))
        let cleartext = state.baseUrl.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("http://")
        entries.append(.endpointInfo(
            text: cleartext
                ? self.localized("This Base URL uses plain HTTP. The key travels unencrypted on the network; use HTTPS unless you control the whole path.", "该 Base URL 使用明文 HTTP，Key 会在网络上明文传输。除非整条链路都由你控制，否则请使用 HTTPS。")
                : self.localized("The Base URL is where this device sends requests. Change it to use a gateway or a proxy; it must speak the API format chosen above.", "Base URL 是这台设备发送请求的地址，可改成网关或代理；它需要与上方选择的 API 格式匹配。"),
            warning: cleartext
        ))

        entries.append(.credentialHeader(self.localized("Credential", "凭据")))
        entries.append(.credentialKey(
            placeholder: state.hasSavedKey
                ? self.localized("Leave empty to keep the saved key", "留空则保留已保存的 Key")
                : self.localized("API key", "API Key"),
            value: state.key
        ))
        entries.append(.credentialInfo(self.localized(
            "The key is encrypted on this device and sent only to the Base URL above.",
            "Key 加密保存在本机，只会发送到上面的 Base URL。"
        )))

        entries.append(.modelsHeader(self.localized("Models", "模型")))
        for (index, model) in state.models.enumerated() {
            entries.append(.model(index: Int32(index), title: model, checked: model == state.selectedModel))
        }
        if state.models.isEmpty {
            entries.append(.modelsEmpty(self.localized("Add at least one model to continue.", "至少添加一个模型才能保存。")))
        }
        entries.append(.modelAdd(self.localized("Add model", "添加模型")))
        entries.append(.modelsHint(self.localized(
            "The selected model is used for /ask on this device. Tap a model to select it, swipe left to remove it.",
            "本机 /ask 使用选中的模型。点击模型选中，左滑删除。"
        )))

        entries.append(.footer(self.localized(
            "Stored only on this device, encrypted with the iOS Keychain, and never sent to Talky. Settings apply to this account on this device only.",
            "只保存在这台设备，使用 iOS Keychain 加密，不会发往 Talky。配置只对当前账号、当前设备生效。"
        )))
        return entries
    }
}

public func jarvisLocalKeyController(context: AccountContext, existing: JarvisLocalCredential?, onSaved: @escaping (JarvisLocalCredential) -> Void) -> ViewController {
    let model = JarvisLocalKeyModel(context: context, existing: existing, onSaved: onSaved)
    let signal = combineLatest(queue: .mainQueue(),
        context.sharedContext.presentationData,
        model.state.get()
    )
    |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let saving = state.saving
        let rightNavigationButton = saving
            ? ItemListNavigationButton(content: .none, style: .activity, enabled: true, action: {})
            : ItemListNavigationButton(content: .text(jarvisLocalKeyText(presentationData.strings, "Done", "完成")), style: .bold, enabled: true, action: {
                model.save()
            })
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(jarvisLocalKeyText(presentationData.strings, "Local key", "本机 Key")),
            leftNavigationButton: nil,
            rightNavigationButton: rightNavigationButton,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: model.entries(),
            style: .blocks,
            animateChanges: true
        )
        return (controllerState, (listState, model))
    }
    let controller = ItemListController(context: context, state: signal)
    controller.navigationPresentation = .modal
    model.controller = controller
    return controller
}
