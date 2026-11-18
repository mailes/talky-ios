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

// Jarvis is a first-class assistant, so its settings are reached from the
// @jarvis profile page and from the /setkey command. Both entries open this
// one controller; the command arrives with the key section already on screen.
//
// The account mode (platform / hosted / local) is server state. The local key
// is device state. The page keeps them visibly separate: changing the mode
// never moves a key, and saving or deleting a key never silently changes the
// mode.

private func jarvisText(_ strings: PresentationStrings, _ en: String, _ zh: String) -> String {
    return strings.baseLanguageCode.hasPrefix("zh") ? zh : en
}

public enum JarvisSettingsFocus: Equatable {
    case overview
    case keys
}

private final class JarvisDeviceKeyItemTag: ItemListItemTag {
    func isEqual(to other: ItemListItemTag) -> Bool {
        return other is JarvisDeviceKeyItemTag
    }
}

private enum JarvisSettingsSection: Int32 {
    case mode
    case device
    case hosted
    case usage
    case chats
    case capabilities
}

private enum JarvisSettingsEntry: ItemListNodeEntry {
    case modeHeader
    case modeValue(JarvisModelMode, String)
    case modeFooter(String)
    case deviceHeader
    case deviceKey(String, String)
    case deviceFooter(String)
    case hostedHeader
    case hostedKey(String, String)
    case hostedDelete(String)
    case hostedFooter(String)
    case usageHeader
    case usageValue(index: Int32, title: String, label: String)
    case usageFooter(String)
    case chatsHeader
    case chat(index: Int32, title: String, peerId: Int64, left: Bool)
    case chatAdd(String)
    case chatsFooter(String)
    case capabilitiesHeader
    case capabilitiesText(String)

    var section: ItemListSectionId {
        switch self {
        case .modeHeader, .modeValue, .modeFooter: return JarvisSettingsSection.mode.rawValue
        case .deviceHeader, .deviceKey, .deviceFooter: return JarvisSettingsSection.device.rawValue
        case .hostedHeader, .hostedKey, .hostedDelete, .hostedFooter: return JarvisSettingsSection.hosted.rawValue
        case .usageHeader, .usageValue, .usageFooter: return JarvisSettingsSection.usage.rawValue
        case .chatsHeader, .chat, .chatAdd, .chatsFooter: return JarvisSettingsSection.chats.rawValue
        case .capabilitiesHeader, .capabilitiesText: return JarvisSettingsSection.capabilities.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .modeHeader: return 0
        case .modeValue: return 1
        case .modeFooter: return 2
        case .deviceHeader: return 10
        case .deviceKey: return 11
        case .deviceFooter: return 12
        case .hostedHeader: return 20
        case .hostedKey: return 21
        case .hostedDelete: return 22
        case .hostedFooter: return 23
        case .usageHeader: return 24
        case let .usageValue(index, _, _): return 25 + index
        case .usageFooter: return 27
        case .chatsHeader: return 30
        case let .chat(index, _, _, _): return 100 + index
        case .chatAdd: return 200
        case .chatsFooter: return 201
        case .capabilitiesHeader: return 300
        case .capabilitiesText: return 301
        }
    }

    static func <(lhs: JarvisSettingsEntry, rhs: JarvisSettingsEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! JarvisSettingsModel
        switch self {
        case .modeHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: jarvisText(presentationData.strings, "Model source", "模型来源"), sectionId: self.section)
        case let .modeValue(_, label):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: PresentationResourcesSettings.aiTools, title: jarvisText(presentationData.strings, "Current source", "当前来源"), label: label, labelStyle: .text, sectionId: self.section, style: .blocks, disclosureStyle: .arrow, action: {
                arguments.presentModePicker()
            })
        case let .modeFooter(text):
            return ItemListTextItem(presentationData: presentationData, text: .markdown(text), sectionId: self.section)
        case .deviceHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: jarvisText(presentationData.strings, "This device", "本设备"), sectionId: self.section)
        case let .deviceKey(title, label):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: PresentationResourcesSettings.passkeys, title: title, label: label, labelStyle: .text, sectionId: self.section, style: .blocks, disclosureStyle: .arrow, action: {
                arguments.presentDeviceKeyFlow()
            }, tag: JarvisDeviceKeyItemTag())
        case let .deviceFooter(text):
            return ItemListTextItem(presentationData: presentationData, text: .markdown(text), sectionId: self.section)
        case .hostedHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: jarvisText(presentationData.strings, "Hosted key", "托管 Key"), sectionId: self.section)
        case let .hostedKey(title, label):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: PresentationResourcesSettings.bot, title: title, label: label, labelStyle: .text, sectionId: self.section, style: .blocks, disclosureStyle: .arrow, action: {
                arguments.presentHostedKeyFlow()
            })
        case let .hostedDelete(title):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: .destructive, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.confirmDeleteHostedKey()
            })
        case let .hostedFooter(text):
            return ItemListTextItem(presentationData: presentationData, text: .markdown(text), sectionId: self.section)
        case .usageHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: jarvisText(presentationData.strings, "Usage today", "今日用量"), sectionId: self.section)
        case let .usageValue(index, title, label):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: index == 0 ? PresentationResourcesSettings.chatHistory : PresentationResourcesSettings.stats, title: title, label: label, labelStyle: .text, sectionId: self.section, style: .blocks, disclosureStyle: .none, action: nil)
        case let .usageFooter(text):
            return ItemListTextItem(presentationData: presentationData, text: .markdown(text), sectionId: self.section)
        case .chatsHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: jarvisText(presentationData.strings, "Authorized chats", "已授权会话"), sectionId: self.section)
        case let .chat(_, title, peerId, left):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: PresentationResourcesSettings.channels, title: title, label: left ? jarvisText(presentationData.strings, "Left", "已离开") : "", labelStyle: .text, sectionId: self.section, style: .blocks, disclosureStyle: .arrow, action: {
                arguments.confirmRevoke(peerId: peerId, title: title)
            })
        case let .chatAdd(title):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: PresentationResourcesSettings.groups, title: title, label: "", labelStyle: .text, sectionId: self.section, style: .blocks, disclosureStyle: .none, action: {
                arguments.presentAvailableChats()
            })
        case let .chatsFooter(text):
            return ItemListTextItem(presentationData: presentationData, text: .markdown(text), sectionId: self.section)
        case .capabilitiesHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: jarvisText(presentationData.strings, "What this source can do", "该来源支持的能力"), sectionId: self.section)
        case let .capabilitiesText(text):
            return ItemListTextItem(presentationData: presentationData, text: .markdown(text), sectionId: self.section)
        }
    }
}

private struct JarvisSettingsState: Equatable {
    var loading = true
    var origin: URL?
    var configuration: JarvisModelConfiguration?
    var capabilities: JarvisModelCapabilities?
    var overview: JarvisOverview?
    var overviewUnavailable = false
    var deviceKey: JarvisLocalCredential?
    var deviceKeyUnavailable = false
    var errorText: String?
}

// The page model owns the transport and the local key store. Every async
// result is bound to the account it was started for: if the account changes
// before the answer arrives, the result is dropped instead of painted onto
// the new account's settings.
private final class JarvisSettingsModel {
    let context: AccountContext
    let state: ValuePromise<JarvisSettingsState>
    weak var controller: ItemListController?

    private let userId: Int64
    private let manage = JarvisManageClient()
    private let keyStore: JarvisLocalKeyStore?
    private var current = JarvisSettingsState()
    private var accountId: Int64

    init(context: AccountContext) {
        self.context = context
        self.userId = context.account.peerId.id._internalGetInt64Value()
        self.accountId = context.account.id.int64
        self.keyStore = try? JarvisLocalKeyStore(userId: self.userId)
        self.state = ValuePromise(self.current)
    }

    private var strings: PresentationStrings {
        return self.context.sharedContext.currentPresentationData.with { $0 }.strings
    }

    private func localized(_ en: String, _ zh: String) -> String {
        return jarvisText(self.strings, en, zh)
    }

    private var presentationData: PresentationData {
        return self.context.sharedContext.currentPresentationData.with { $0 }
    }

    private func stillCurrent() -> Bool {
        return self.context.account.id.int64 == self.accountId
    }

    private func update(_ transform: (inout JarvisSettingsState) -> Void) {
        guard self.stillCurrent() else { return }
        transform(&self.current)
        self.state.set(self.current)
    }

    func load() {
        let configuration = self.context.currentAppConfiguration.with { $0 }
        guard let rawOrigin = configuration.data?["jarvis_manage_origin"] as? String,
              let origin = JarvisManageRequest.trustedOrigin(rawOrigin) else {
            self.update {
                $0.loading = false
                $0.origin = nil
                $0.errorText = self.localized(
                    "Jarvis management is not configured on this server.",
                    "此服务器没有配置 Jarvis 管理地址。"
                )
            }
            return
        }
        if let keyStore = self.keyStore {
            do {
                self.current.deviceKey = try keyStore.load()
            } catch {
                self.current.deviceKey = nil
                self.current.deviceKeyUnavailable = true
            }
        }
        self.update {
            $0.origin = origin
            $0.loading = true
            $0.errorText = nil
            $0.overviewUnavailable = false
        }
        self.fetchConfiguration(origin: origin)
        self.fetchCapabilities(origin: origin)
        self.fetchOverview(origin: origin)
    }

    private func withTicket(_ completion: @escaping (String?) -> Void) {
        let _ = (self.context.account.network.jarvisSessionTicket(userId: self.userId)
        |> take(1)
        |> deliverOnMainQueue).start(next: { ticket in
            completion(ticket)
        })
    }

    private func fetchConfiguration(origin: URL) {
        self.withTicket { [weak self] ticket in
            guard let self, let ticket else { return }
            do {
                let request = try JarvisManageRequest.configuration(origin: origin, ticket: ticket)
                self.manage.perform(request, as: JarvisModelConfiguration.self) { result in
                    DispatchQueue.main.async {
                        guard self.stillCurrent() else { return }
                        switch result {
                        case let .success(configuration):
                            self.update {
                                $0.loading = false
                                $0.configuration = configuration
                                $0.errorText = nil
                            }
                        case let .failure(error):
                            self.update {
                                $0.loading = false
                                $0.errorText = self.message(for: error)
                            }
                        }
                    }
                }
            } catch {
                self.update {
                    $0.loading = false
                    $0.errorText = self.localized("Jarvis settings are unavailable.", "Jarvis 设置暂时不可用。")
                }
            }
        }
    }

    private func fetchCapabilities(origin: URL) {
        self.withTicket { [weak self] ticket in
            guard let self, let ticket else { return }
            do {
                let request = try JarvisManageRequest.capabilities(origin: origin, ticket: ticket)
                self.manage.perform(request, as: JarvisModelCapabilities.self) { result in
                    DispatchQueue.main.async {
                        guard self.stillCurrent() else { return }
                        if case let .success(capabilities) = result {
                            self.update { $0.capabilities = capabilities }
                        }
                    }
                }
            } catch {
                // Capabilities are explanatory; the page still works without them.
            }
        }
    }

    func fetchOverview(origin: URL? = nil) {
        guard let origin = origin ?? self.current.origin else { return }
        #if DEBUG
        // UI-test hook: reaching the real manage server failure state would
        // require cutting network access for the whole simulator. The row
        // rendering is the same as a live failure.
        if ProcessInfo.processInfo.arguments.contains("-jarvis-overview-fail") {
            self.update { $0.overviewUnavailable = true }
            return
        }
        #endif
        self.withTicket { [weak self] ticket in
            guard let self, let ticket else { return }
            do {
                let request = try JarvisManageRequest.overview(origin: origin, ticket: ticket)
                self.manage.perform(request, as: JarvisOverview.self) { result in
                    DispatchQueue.main.async {
                        guard self.stillCurrent() else { return }
                        switch result {
                        case let .success(overview):
                            self.update {
                                $0.overview = overview
                                $0.overviewUnavailable = false
                            }
                        case .failure:
                            // Usage and the chat list are missing data, not an
                            // empty account: say so instead of claiming that no
                            // chat is authorized.
                            self.update { $0.overviewUnavailable = true }
                        }
                    }
                }
            } catch {
                // The other sections remain usable; the chat list says the
                // overview could not be loaded.
                self.update { $0.overviewUnavailable = true }
            }
        }
    }

    private func message(for error: JarvisManageError) -> String {
        switch error {
        case .authenticationRequired:
            return self.localized("Your session expired. Sign in again.", "登录状态已失效，请重新登录。")
        case .forbidden:
            return self.localized("This account cannot manage Jarvis settings.", "当前账号不能管理 Jarvis 设置。")
        case .hostedKeyRequired:
            return self.localized("Add a hosted key before selecting hosted mode.", "请先添加托管 Key，再选择托管模式。")
        case .operationFailed:
            return self.localized("The provider rejected that key. Check the key and model.", "服务商拒绝了这个 Key，请核对 Key 与模型名。")
        case .unavailable:
            return self.localized("Jarvis is unavailable right now.", "Jarvis 暂时不可用。")
        case .incompatibleResponse:
            return self.localized("This server returned an unsupported response.", "服务器返回了不兼容的结果。")
        case .invalidConfiguration:
            return self.localized("Jarvis settings are not configured correctly.", "Jarvis 设置配置有误。")
        }
    }

    private func showAlert(title: String, text: String) {
        guard let controller = self.controller, self.stillCurrent() else { return }
        controller.present(textAlertController(context: self.context, title: title, text: text, actions: [
            TextAlertAction(type: .defaultAction, title: self.localized("OK", "好"), action: {})
        ]), in: .window(.root))
    }

    private func showError(_ error: JarvisManageError) {
        self.showAlert(title: self.localized("Jarvis", "Jarvis"), text: self.message(for: error))
    }

    // MARK: - Mode

    /// "used / limit" for a free account, or the unlimited marker for Premium.
    private func usageValue(premium: Bool, used: Int?, limit: Int?) -> String {
        if premium {
            return self.localized("Unlimited", "不限")
        }
        return "\(used ?? 0) / \(limit ?? 0)"
    }

    /// The server can return a missing or empty title; show the peer id instead
    /// of a blank row that still looks tappable.
    private func chatDisplayTitle(_ title: String?, peerId: Int64) -> String {
        if let title = title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        return "#\(peerId)"
    }

    private var modeLabel: String {
        guard let configuration = self.current.configuration else {
            return self.localized("Loading…", "加载中…")
        }
        switch configuration.mode {
        case .platform:
            return self.localized("Platform model", "平台模型")
        case .hosted:
            return self.localized("Hosted key", "托管 Key")
        case .local:
            return self.localized("This device", "本机")
        }
    }

    func presentModePicker() {
        guard let controller = self.controller else { return }
        let actionSheet = ActionSheetController(presentationData: self.presentationData)
        var items: [ActionSheetItem] = [
            ActionSheetTextItem(title: self.localized("Where should Jarvis run?", "希望 Jarvis 在哪里运行？"))
        ]
        let currentMode = self.current.configuration?.mode
        let modes: [(JarvisModelMode, String, String)] = [
            (.platform, self.localized("Platform model", "平台模型"), self.localized("Talky's AI service. Voice and server tools keep working.", "使用 Talky 的 AI 服务，语音和服务端工具可用。")),
            (.hosted, self.localized("Hosted key", "托管 Key"), self.localized("Your key, encrypted on Talky servers. Server-side calls across your devices.", "你的 Key 加密保存在 Talky 服务器，服务端调用，跨设备可用。")),
            (.local, self.localized("This device", "本机"), self.localized("Your key stays on this device; the client calls the provider directly.", "Key 只保存在本设备，客户端直接请求供应商。"))
        ]
        for (mode, title, subtitle) in modes {
            let marker = mode == currentMode ? "✓ " : ""
            items.append(ActionSheetButtonItem(title: "\(marker)\(title)", subtitle: subtitle, color: .accent, font: mode == currentMode ? .bold : .default, action: { [weak self, weak actionSheet] in
                actionSheet?.dismissAnimated()
                self?.selectMode(mode)
            }))
        }
        items.append(ActionSheetButtonItem(title: self.localized("Cancel", "取消"), color: .accent, font: .bold, action: { [weak actionSheet] in
            actionSheet?.dismissAnimated()
        }))
        actionSheet.setItemGroups([ActionSheetItemGroup(items: items)])
        controller.present(actionSheet, in: .window(.root))
    }

    private func selectMode(_ mode: JarvisModelMode) {
        guard let origin = self.current.origin else { return }
        if mode == self.current.configuration?.mode {
            return
        }
        if mode == .hosted, self.current.configuration?.hostedKeyPresent != true {
            self.showAlert(
                title: self.localized("Hosted key required", "需要托管 Key"),
                text: self.localized("Add a hosted key first, then choose hosted mode.", "请先添加托管 Key，再选择托管模式。")
            )
            return
        }
        self.withTicket { [weak self] ticket in
            guard let self, let ticket else { return }
            do {
                let request = try JarvisManageRequest.select(origin: origin, ticket: ticket, mode: mode)
                self.manage.perform(request, as: JarvisModelConfiguration.self) { result in
                    DispatchQueue.main.async {
                        guard self.stillCurrent() else { return }
                        switch result {
                        case let .success(configuration):
                            self.update {
                                $0.configuration = configuration
                                $0.errorText = nil
                            }
                        case let .failure(error):
                            self.showError(error)
                        }
                    }
                }
            } catch {
                self.showAlert(title: self.localized("Jarvis", "Jarvis"), text: self.localized("Jarvis settings are unavailable.", "Jarvis 设置暂时不可用。"))
            }
        }
    }

    // MARK: - Local key (device)

    func presentDeviceKeyFlow() {
        guard let controller = self.controller else { return }
        if self.current.deviceKey != nil {
            let actionSheet = ActionSheetController(presentationData: self.presentationData)
            actionSheet.setItemGroups([ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: self.localized("Replace local key", "替换本机 Key"), color: .accent, action: { [weak self, weak actionSheet] in
                    actionSheet?.dismissAnimated()
                    self?.presentLocalKeyEditor()
                }),
                ActionSheetButtonItem(title: self.localized("Delete local key", "删除本机 Key"), color: .destructive, action: { [weak self, weak actionSheet] in
                    actionSheet?.dismissAnimated()
                    self?.confirmDeleteLocalKey()
                }),
                ActionSheetButtonItem(title: self.localized("Cancel", "取消"), color: .accent, font: .bold, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                })
            ])])
            controller.present(actionSheet, in: .window(.root))
        } else {
            self.presentLocalKeyEditor()
        }
    }

    private func presentLocalKeyEditor() {
        guard let controller = self.controller else { return }
        let editor = jarvisLocalKeyController(context: self.context, existing: self.current.deviceKey, onSaved: { [weak self] credential in
            guard let self, self.stillCurrent() else { return }
            self.update {
                $0.deviceKey = credential
                $0.deviceKeyUnavailable = false
            }
            self.offerLocalMode()
        })
        controller.push(editor)
    }

    private func offerLocalMode() {
        guard let controller = self.controller else { return }
        if self.current.configuration?.mode == .local {
            return
        }
        controller.present(textAlertController(context: self.context, title: self.localized("Local key saved", "本机 Key 已保存"), text: self.localized("This account is still using another model source. Switch this account to local mode?", "当前账号仍在使用其他模型来源。要把这个账号切换到本机模式吗？"), actions: [
            TextAlertAction(type: .genericAction, title: self.localized("Not now", "暂不"), action: {}),
            TextAlertAction(type: .defaultAction, title: self.localized("Use local mode", "使用本机模式"), action: { [weak self] in
                self?.selectMode(.local)
            })
        ]), in: .window(.root))
    }

    private func confirmDeleteLocalKey() {
        guard let controller = self.controller else { return }
        let alert = textAlertController(context: self.context, title: self.localized("Delete local key?", "删除本机 Key？"), text: self.localized("The key is removed from this device. The account's model source does not change.", "Key 会从这台设备删除；账号的模型来源不会改变。"), actions: [
            TextAlertAction(type: .genericAction, title: self.localized("Cancel", "取消"), action: {}),
            TextAlertAction(type: .destructiveAction, title: self.localized("Delete", "删除"), action: { [weak self] in
                guard let self, let keyStore = self.keyStore else { return }
                do {
                    try keyStore.delete()
                    self.update {
                        $0.deviceKey = nil
                        $0.deviceKeyUnavailable = false
                    }
                } catch {
                    self.showAlert(title: self.localized("Jarvis", "Jarvis"), text: self.localized("The key could not be deleted.", "无法删除这个 Key。"))
                }
            })
        ])
        controller.present(alert, in: .window(.root))
    }

    // MARK: - Hosted key

    private var hostedProviders: [(String, String, String)] {
        return [
            ("deepseek", "DeepSeek", "deepseek-chat"),
            ("openai", "OpenAI", "gpt-4o-mini"),
            ("gemini", "Gemini", "gemini-2.0-flash"),
            ("anthropic", "Anthropic", "claude-3-5-haiku-latest")
        ]
    }

    private var hostedProviderNames: [String: String] {
        var names: [String: String] = [:]
        for (provider, name, _) in self.hostedProviders {
            names[provider] = name
        }
        return names
    }

    func presentHostedKeyFlow() {
        guard let controller = self.controller else { return }
        if self.current.configuration?.hostedKeyPresent == true {
            let actionSheet = ActionSheetController(presentationData: self.presentationData)
            actionSheet.setItemGroups([ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: self.localized("Replace hosted key", "替换托管 Key"), color: .accent, action: { [weak self, weak actionSheet] in
                    actionSheet?.dismissAnimated()
                    self?.presentHostedProviderPicker()
                }),
                ActionSheetButtonItem(title: self.localized("Delete hosted key", "删除托管 Key"), color: .destructive, action: { [weak self, weak actionSheet] in
                    actionSheet?.dismissAnimated()
                    self?.confirmDeleteHostedKey()
                }),
                ActionSheetButtonItem(title: self.localized("Cancel", "取消"), color: .accent, font: .bold, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                })
            ])])
            controller.present(actionSheet, in: .window(.root))
        } else {
            self.presentHostedProviderPicker()
        }
    }

    private func presentHostedProviderPicker() {
        guard let controller = self.controller else { return }
        let actionSheet = ActionSheetController(presentationData: self.presentationData)
        var items: [ActionSheetItem] = [
            ActionSheetTextItem(title: self.localized("Choose a provider", "选择供应商"))
        ]
        for (provider, name, _) in self.hostedProviders {
            items.append(ActionSheetButtonItem(title: name, color: .accent, action: { [weak self, weak actionSheet] in
                actionSheet?.dismissAnimated()
                self?.presentHostedKeyForm(provider: provider, name: name)
            }))
        }
        items.append(ActionSheetButtonItem(title: self.localized("Cancel", "取消"), color: .accent, font: .bold, action: { [weak actionSheet] in
            actionSheet?.dismissAnimated()
        }))
        actionSheet.setItemGroups([ActionSheetItemGroup(items: items)])
        controller.present(actionSheet, in: .window(.root))
    }

    private func presentHostedKeyForm(provider: String, name: String) {
        guard let controller = self.controller else { return }
        let defaultModel = self.hostedProviders.first(where: { $0.0 == provider })?.2 ?? ""
        let alert = UIAlertController(
            title: self.localized("Hosted key", "托管 Key"),
            message: self.localized("The key is encrypted on Talky servers and used for server-side calls. It is not stored on this device.", "Key 加密保存在 Talky 服务器，用于服务端调用；不会保存在这台设备。"),
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.placeholder = self.localized("Model", "模型")
            field.text = defaultModel
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addTextField { field in
            field.placeholder = self.localized("API key", "API Key")
            field.isSecureTextEntry = true
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.textContentType = .password
        }
        alert.addAction(UIAlertAction(title: self.localized("Cancel", "取消"), style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: self.localized("Save", "保存"), style: .default, handler: { [weak self, weak alert] _ in
            guard let self, let alert else { return }
            let model = alert.textFields?[0].text ?? ""
            let key = alert.textFields?[1].text ?? ""
            self.saveHostedKey(provider: provider, model: model, key: key, name: name)
        }))
        controller.present(alert, animated: true, completion: nil)
    }

    private func saveHostedKey(provider: String, model: String, key: String, name: String) {
        guard let origin = self.current.origin else { return }
        self.withTicket { [weak self] ticket in
            guard let self, let ticket else { return }
            do {
                let request = try JarvisManageRequest.hostedKey(origin: origin, ticket: ticket, provider: provider, model: model, key: key)
                self.manage.perform(request, as: JarvisManageAcknowledgement.self) { result in
                    DispatchQueue.main.async {
                        guard self.stillCurrent() else { return }
                        switch result {
                        case .success:
                            self.fetchConfiguration(origin: origin)
                            self.showAlert(title: self.localized("Key saved", "Key 已保存"), text: self.localized("\(name) is now the hosted provider for this account.", "\(name) 现在是这个账号的托管供应商。"))
                        case let .failure(error):
                            self.showError(error)
                        }
                    }
                }
            } catch {
                self.showAlert(title: self.localized("Jarvis", "Jarvis"), text: self.localized("Jarvis settings are unavailable.", "Jarvis 设置暂时不可用。"))
            }
        }
    }

    func confirmDeleteHostedKey() {
        guard let controller = self.controller, let origin = self.current.origin else { return }
        let alert = textAlertController(context: self.context, title: self.localized("Delete hosted key?", "删除托管 Key？"), text: self.localized("The encrypted key is removed from Talky servers. The account's model source does not change.", "加密 Key 会从 Talky 服务器删除；账号的模型来源不会改变。"), actions: [
            TextAlertAction(type: .genericAction, title: self.localized("Cancel", "取消"), action: {}),
            TextAlertAction(type: .destructiveAction, title: self.localized("Delete", "删除"), action: { [weak self] in
                self?.deleteHostedKey(origin: origin)
            })
        ])
        controller.present(alert, in: .window(.root))
    }

    private func deleteHostedKey(origin: URL) {
        self.withTicket { [weak self] ticket in
            guard let self, let ticket else { return }
            do {
                let request = try JarvisManageRequest.deleteHostedKey(origin: origin, ticket: ticket)
                self.manage.perform(request, as: JarvisManageAcknowledgement.self) { result in
                    DispatchQueue.main.async {
                        guard self.stillCurrent() else { return }
                        switch result {
                        case .success:
                            self.fetchConfiguration(origin: origin)
                        case let .failure(error):
                            self.showError(error)
                        }
                    }
                }
            } catch {
                self.showAlert(title: self.localized("Jarvis", "Jarvis"), text: self.localized("Jarvis settings are unavailable.", "Jarvis 设置暂时不可用。"))
            }
        }
    }

    // MARK: - Authorized chats

    func presentAvailableChats() {
        guard let controller = self.controller, let origin = self.current.origin else { return }
        let available = self.current.overview?.available ?? []
        guard !available.isEmpty else {
            self.showAlert(title: self.localized("Jarvis", "Jarvis"), text: self.localized("There are no chats left to authorize. Join a group first.", "没有可授权的会话了，请先加入一个群组。"))
            return
        }
        let actionSheet = ActionSheetController(presentationData: self.presentationData)
        var items: [ActionSheetItem] = [
            ActionSheetTextItem(title: self.localized("Allow Jarvis to read through your membership", "允许 Jarvis 通过你的成员身份读取"))
        ]
        for chat in available {
            let title = self.chatDisplayTitle(chat.title, peerId: chat.peerId)
            items.append(ActionSheetButtonItem(title: title, color: .accent, action: { [weak self, weak actionSheet] in
                actionSheet?.dismissAnimated()
                self?.grant(peerId: chat.peerId, origin: origin)
            }))
        }
        items.append(ActionSheetButtonItem(title: self.localized("Cancel", "取消"), color: .accent, font: .bold, action: { [weak actionSheet] in
            actionSheet?.dismissAnimated()
        }))
        actionSheet.setItemGroups([ActionSheetItemGroup(items: items)])
        controller.present(actionSheet, in: .window(.root))
    }

    private func grant(peerId: Int64, origin: URL) {
        self.withTicket { [weak self] ticket in
            guard let self, let ticket else { return }
            do {
                let request = try JarvisManageRequest.grant(origin: origin, ticket: ticket, peerId: peerId)
                self.manage.perform(request, as: JarvisManageAcknowledgement.self) { result in
                    DispatchQueue.main.async {
                        guard self.stillCurrent() else { return }
                        switch result {
                        case .success:
                            self.fetchOverview(origin: origin)
                        case let .failure(error):
                            self.showError(error)
                        }
                    }
                }
            } catch {
                self.showAlert(title: self.localized("Jarvis", "Jarvis"), text: self.localized("Jarvis settings are unavailable.", "Jarvis 设置暂时不可用。"))
            }
        }
    }

    func confirmRevoke(peerId: Int64, title: String) {
        guard let controller = self.controller, let origin = self.current.origin else { return }
        let alert = textAlertController(context: self.context, title: self.localized("Revoke access?", "撤销授权？"), text: self.localized("Jarvis will no longer read \"\(title)\". The content already in this chat is not deleted.", "Jarvis 将不再读取「\(title)」。聊天中已有的内容不会被删除。"), actions: [
            TextAlertAction(type: .genericAction, title: self.localized("Cancel", "取消"), action: {}),
            TextAlertAction(type: .destructiveAction, title: self.localized("Revoke", "撤销"), action: { [weak self] in
                self?.revoke(peerId: peerId, origin: origin)
            })
        ])
        controller.present(alert, in: .window(.root))
    }

    private func revoke(peerId: Int64, origin: URL) {
        self.withTicket { [weak self] ticket in
            guard let self, let ticket else { return }
            do {
                let request = try JarvisManageRequest.revoke(origin: origin, ticket: ticket, peerId: peerId)
                self.manage.perform(request, as: JarvisManageAcknowledgement.self) { result in
                    DispatchQueue.main.async {
                        guard self.stillCurrent() else { return }
                        switch result {
                        case .success:
                            self.fetchOverview(origin: origin)
                        case let .failure(error):
                            self.showError(error)
                        }
                    }
                }
            } catch {
                self.showAlert(title: self.localized("Jarvis", "Jarvis"), text: self.localized("Jarvis settings are unavailable.", "Jarvis 设置暂时不可用。"))
            }
        }
    }

    // MARK: - Entries

    func entries() -> [JarvisSettingsEntry] {
        var entries: [JarvisSettingsEntry] = []
        entries.append(.modeHeader)
        let mode = self.current.configuration?.mode ?? .platform
        entries.append(.modeValue(mode, self.modeLabel))
        entries.append(.modeFooter(self.localized(
            "The model source is account-wide. A local key belongs to this device only; other devices need their own.",
            "模型来源是账号级设置。本机 Key 只属于这台设备，其他设备需要各自配置。"
        )))

        entries.append(.deviceHeader)
        let deviceLabel: String
        if let credential = self.current.deviceKey {
            let provider = jarvisLocalProviderName(credential.provider, self.strings)
            deviceLabel = self.localized("Configured · \(provider) · \(credential.model)", "已配置 · \(provider) · \(credential.model)")
        } else if self.current.deviceKeyUnavailable {
            deviceLabel = self.localized("Unavailable", "不可用")
        } else {
            deviceLabel = self.localized("Not configured", "未配置")
        }
        entries.append(.deviceKey(self.localized("Local key", "本机 Key"), deviceLabel))
        if mode == .local && self.current.deviceKey == nil {
            entries.append(.deviceFooter(self.localized(
                "This account is in local mode, but this device has no key. Local inference cannot run here until you add one.",
                "当前账号是本机模式，但这台设备没有 Key。添加 Key 之前，本机推理无法运行。"
            )))
        } else {
            entries.append(.deviceFooter(self.localized(
                "Stored in this device's secure storage. It is never sent to Talky.",
                "保存在这台设备的安全存储中，不会发往 Talky。"
            )))
        }

        entries.append(.hostedHeader)
        if self.current.configuration?.hostedKeyPresent == true {
            entries.append(.hostedKey(self.localized("Hosted key", "托管 Key"), self.localized("Configured", "已配置")))
            entries.append(.hostedDelete(self.localized("Delete hosted key", "删除托管 Key")))
            entries.append(.hostedFooter(self.localized(
                "Encrypted on Talky servers and used for server-side calls. Deleting it does not change the account's model source.",
                "加密保存在 Talky 服务器，用于服务端调用。删除它不会改变账号的模型来源。"
            )))
        } else {
            entries.append(.hostedKey(self.localized("Hosted key", "托管 Key"), self.localized("Not configured", "未配置")))
            entries.append(.hostedFooter(self.localized(
                "Bring your own key without keeping it on this device. The server verifies it before saving.",
                "不把 Key 留在这台设备上。服务器会在保存前验证。"
            )))
        }

        if let overview = self.current.overview {
            entries.append(.usageHeader)
            entries.append(.usageValue(
                index: 0,
                title: self.localized("Chat turns", "对话轮次"),
                label: self.usageValue(premium: overview.premium, used: overview.chatTurns, limit: overview.chatLimit)
            ))
            entries.append(.usageValue(
                index: 1,
                title: self.localized("Summaries", "摘要"),
                label: self.usageValue(premium: overview.premium, used: overview.summaries, limit: overview.summaryLimit)
            ))
            if overview.premium {
                entries.append(.usageFooter(self.localized(
                    "Premium has no daily limit. Counters reset at 00:00 UTC.",
                    "Premium 没有每日限额。计数在 UTC 0 点重置。"
                )))
            } else {
                entries.append(.usageFooter(self.localized(
                    "Free accounts get these turns and summaries each day; counters reset at 00:00 UTC. Premium and your own key do not use them.",
                    "免费账号每天获得这些对话轮次与摘要次数，计数在 UTC 0 点重置。Premium 和自带 Key 不占用这些额度。"
                )))
            }
        }

        entries.append(.chatsHeader)
        let chats = self.current.overview?.chats ?? []
        for (index, chat) in chats.enumerated() {
            entries.append(.chat(index: Int32(index), title: self.chatDisplayTitle(chat.title, peerId: chat.peerId), peerId: chat.peerId, left: chat.left == true))
        }
        entries.append(.chatAdd(self.localized("Authorize a chat", "授权一个会话")))
        if self.current.overview == nil {
            if self.current.overviewUnavailable && !self.current.loading {
                entries.append(.chatsFooter(self.localized(
                    "Could not load your authorized chats. Reopen this screen to try again.",
                    "无法加载已授权会话，请重新进入此页面重试。"
                )))
            }
        } else if chats.isEmpty {
            entries.append(.chatsFooter(self.localized(
                "No chats are authorized yet. Jarvis can only read chats you authorize here or with /grant.",
                "还没有授权任何会话。Jarvis 只能读取你在这里或用 /grant 授权的会话。"
            )))
        } else {
            entries.append(.chatsFooter(self.localized(
                "Jarvis reads through your membership. Leaving a group or revoking the grant removes access immediately.",
                "Jarvis 通过你的成员身份读取。退群或撤销授权会立即失去访问。"
            )))
        }

        entries.append(.capabilitiesHeader)
        let capabilityText: String
        switch self.current.configuration?.mode {
        case .platform?:
            capabilityText = self.localized(
                "Text, summaries, reminders and voice use the platform service. Answers are generated on Talky servers.",
                "文本、摘要、提醒和语音使用平台服务，回答在 Talky 服务器生成。"
            )
        case .hosted?:
            capabilityText = self.localized(
                "Text and summaries use your hosted key on Talky servers. Voice is unavailable with a personal key.",
                "文本和摘要使用你的托管 Key，在 Talky 服务器调用。个人 Key 下语音不可用。"
            )
        case .local?:
            capabilityText = self.localized(
                "Text answers run on this device. Reminders, voice and server-side tools are not available in local mode.",
                "文本回答在这台设备上运行。本机模式下提醒、语音和服务端工具不可用。"
            )
        case nil:
            // Never describe platform capabilities before the source is known.
            capabilityText = self.localized(
                "Capabilities appear once the model source is loaded.",
                "模型来源加载完成后会显示支持的能力。"
            )
        }
        entries.append(.capabilitiesText(capabilityText))
        return entries
    }
}

public func jarvisSettingsController(context: AccountContext, focus: JarvisSettingsFocus = .overview) -> ViewController {
    let model = JarvisSettingsModel(context: context)
    let signal = combineLatest(queue: .mainQueue(),
        context.sharedContext.presentationData,
        model.state.get()
    )
    |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(jarvisText(presentationData.strings, "Jarvis", "Jarvis")),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        var entries = model.entries()
        // Replace the source footer instead of inserting another one: two
        // entries with the same stableId make ItemListControllerNode's
        // ordering assertion fail (it crashed the settings page on first
        // render, while the configuration was still loading).
        let modeFooterIndex = entries.firstIndex(where: {
            if case .modeFooter = $0 {
                return true
            }
            return false
        })
        if state.loading && state.configuration == nil {
            if let modeFooterIndex {
                entries[modeFooterIndex] = .modeFooter(jarvisText(presentationData.strings, "Loading Jarvis settings…", "正在加载 Jarvis 设置…"))
            }
        } else if let error = state.errorText {
            if let modeFooterIndex {
                entries[modeFooterIndex] = .modeFooter(error)
            }
        }
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: entries,
            style: .blocks,
            ensureVisibleItemTag: focus == .keys ? JarvisDeviceKeyItemTag() : nil,
            animateChanges: true
        )
        return (controllerState, (listState, model))
    }
    let controller = ItemListController(context: context, state: signal)
    controller.navigationPresentation = .modal
    model.controller = controller
    model.load()
    return controller
}
