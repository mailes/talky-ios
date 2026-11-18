import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import PresentationDataUtils
import AccountContext
import LocalizedPeerData
import WallpaperBackgroundNode

// In-chat local answer. The screen is pushed by /ask in an authorized group or
// channel. It reads the server-scoped recent excerpts for THAT chat, sends
// them only to the device-local provider, and shows the server-issued source
// IDs. A source is clickable only when it came back in this response; a
// citation the model invents never becomes a link.
//
// The transcript is drawn with the same message preview item the rest of the
// app uses, so answers and sources look and time-stamp like chat messages
// instead of flat settings rows. Sources are resolved against the local
// Postbox first, which restores the real author and timestamp.

private func jarvisAskText(_ strings: PresentationStrings, _ en: String, _ zh: String) -> String {
    return strings.baseLanguageCode.hasPrefix("zh") ? zh : en
}

private struct JarvisAskSource: Equatable {
    let sourceId: String
    let peerId: Int64
    let messageId: Int
    let text: String
    let truncated: Bool
}

private struct JarvisAskSourceContent: Equatable {
    let text: String
    let authorName: String
    let timestamp: Int32
}

private enum JarvisAskPhase: Equatable {
    case loading
    case answered
    case failed
    case cancelled
}

private struct JarvisAskTurn: Equatable {
    let id: Int32
    let question: String
    let askedAt: Int32
    var answer: String?
    var answeredAt: Int32?
    var sources: [JarvisAskSource] = []
    var sourceContent: [String: JarvisAskSourceContent] = [:]
    var scope: String?
    var phase: JarvisAskPhase = .loading
    var error: String?
    var needsSettings = false
}

private struct JarvisAskState: Equatable {
    var turns: [JarvisAskTurn] = []
}

// MARK: - Model

private final class JarvisAskModel {
    let context: AccountContext
    let state: ValuePromise<JarvisAskState>
    weak var controller: ViewController?

    private let peerId: Int64
    private let peerTitle: String
    private let accountId: Int64
    private let userId: Int64
    private let manage = JarvisManageClient()
    private let localModel = JarvisLocalModelClient()
    private let keyStore: JarvisLocalKeyStore?
    private let openSource: (Int) -> Void
    private let openSettings: () -> Void
    private var current: JarvisAskState
    private var dataTask: URLSessionDataTask?
    private var cancelled = false
    private var turnCounter: Int32 = 0
    private var isDismissing = false

    init(context: AccountContext, peerId: Int64, peerTitle: String, openSource: @escaping (Int) -> Void, openSettings: @escaping () -> Void) {
        self.context = context
        self.peerId = peerId
        self.peerTitle = peerTitle
        self.accountId = context.account.id.int64
        self.userId = context.account.peerId.id._internalGetInt64Value()
        self.keyStore = try? JarvisLocalKeyStore(userId: self.userId)
        self.openSource = openSource
        self.openSettings = openSettings
        self.current = JarvisAskState()
        self.state = ValuePromise(self.current)
    }

    private var strings: PresentationStrings {
        return self.context.sharedContext.currentPresentationData.with { $0 }.strings
    }

    private func localized(_ en: String, _ zh: String) -> String {
        return jarvisAskText(self.strings, en, zh)
    }

    private func stillCurrent() -> Bool {
        return self.context.account.id.int64 == self.accountId
    }

    private func publish() {
        guard self.stillCurrent() else { return }
        self.state.set(self.current)
    }

    private func updateTurn(_ turnId: Int32, _ transform: (inout JarvisAskTurn) -> Void) {
        guard self.stillCurrent(), let index = self.current.turns.firstIndex(where: { $0.id == turnId }) else {
            return
        }
        // A cancelled or already answered turn must not be overwritten by a
        // late callback from a request that was superseded.
        guard self.current.turns[index].phase == .loading else { return }
        transform(&self.current.turns[index])
        self.publish()
    }

    func ask(question: String) {
        guard self.stillCurrent() else { return }
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !self.current.turns.contains(where: { $0.phase == .loading }) else { return }

        self.cancelled = false
        self.turnCounter += 1
        self.current.turns.append(JarvisAskTurn(
            id: self.turnCounter,
            question: trimmed,
            askedAt: Int32(Date().timeIntervalSince1970)
        ))
        self.publish()
        self.request(turnId: self.turnCounter, question: trimmed)
    }

    private func request(turnId: Int32, question: String) {
        let configuration = self.context.currentAppConfiguration.with { $0 }
        guard let rawOrigin = configuration.data?["jarvis_manage_origin"] as? String,
              let origin = JarvisManageRequest.trustedOrigin(rawOrigin) else {
            self.fail(turnId: turnId, message: self.localized("Jarvis management is not configured on this server.", "此服务器没有配置 Jarvis 管理地址。"), needsSettings: false)
            return
        }
        self.withTicket { [weak self] ticket in
            guard let self, let ticket else {
                self?.fail(turnId: turnId, message: self?.localized("Your session expired. Sign in again.", "登录状态已失效，请重新登录。") ?? "", needsSettings: false)
                return
            }
            do {
                let request = try JarvisManageRequest.context(origin: origin, ticket: ticket, peerId: self.peerId, query: "")
                self.dataTask = self.manage.perform(request, as: JarvisAuthorizedContext.self) { result in
                    DispatchQueue.main.async {
                        guard self.stillCurrent(), !self.cancelled else { return }
                        switch result {
                        case let .success(authorized):
                            self.generateAnswer(turnId: turnId, context: authorized, question: question)
                        case let .failure(error):
                            if error == .forbidden {
                                self.fail(turnId: turnId, message: self.localized("This chat is not authorized. Open Jarvis settings to authorize it, then ask again.", "这个会话还没有授权。请打开 Jarvis 设置完成授权后再提问。"), needsSettings: true)
                            } else {
                                self.fail(turnId: turnId, message: self.message(for: error), needsSettings: false)
                            }
                        }
                    }
                }
            } catch {
                self.fail(turnId: turnId, message: self.localized("Jarvis settings are unavailable.", "Jarvis 设置暂时不可用。"), needsSettings: false)
            }
        }
    }

    private func withTicket(_ completion: @escaping (String?) -> Void) {
        let _ = (self.context.account.network.jarvisSessionTicket(userId: self.userId)
        |> take(1)
        |> deliverOnMainQueue).start(next: { ticket in
            completion(ticket)
        })
    }

    private func generateAnswer(turnId: Int32, context: JarvisAuthorizedContext, question: String) {
        let key: JarvisLocalCredential
        do {
            guard let keyStore = self.keyStore, let loaded = try keyStore.load() else {
                self.fail(turnId: turnId, message: self.localized("This device has no local key. Add one in Jarvis settings, then ask again.", "这台设备没有本机 Key。请先在 Jarvis 设置中添加，然后再提问。"), needsSettings: true)
                return
            }
            key = loaded
        } catch {
            self.fail(turnId: turnId, message: self.localized("This device's local key could not be read. Try again or replace it in Jarvis settings.", "无法读取这台设备的本机 Key。请重试或在 Jarvis 设置中替换。"), needsSettings: true)
            return
        }
        let sources = context.sources.map { source in
            JarvisAskSource(sourceId: source.sourceId, peerId: source.peerId, messageId: source.messageId, text: source.text, truncated: source.truncated)
        }
        if sources.isEmpty {
            self.fail(turnId: turnId, message: self.localized("No readable messages were found in this chat. Jarvis only reads chats you authorize.", "这个会话里没有可读消息。Jarvis 只读取你授权的会话。"), needsSettings: true)
            return
        }
        do {
            self.dataTask = try self.localModel.generate(credential: key, context: context.prompt, question: question) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self, self.stillCurrent(), !self.cancelled else { return }
                    switch result {
                    case let .success(answer):
                        self.resolveSources(sources: sources, completion: { [weak self] resolved in
                            guard let self, self.stillCurrent(), !self.cancelled else { return }
                            self.updateTurn(turnId) {
                                $0.phase = .answered
                                $0.answer = answer
                                $0.answeredAt = Int32(Date().timeIntervalSince1970)
                                $0.sources = sources
                                $0.sourceContent = resolved
                                $0.scope = context.scope
                                $0.error = nil
                            }
                        })
                    case let .failure(error):
                        self.fail(turnId: turnId, message: self.localMessage(for: error), needsSettings: false)
                    }
                }
            }
        } catch {
            self.fail(turnId: turnId, message: self.localized("The local key configuration is invalid. Check it in Jarvis settings.", "本机 Key 配置无效，请在 Jarvis 设置中检查。"), needsSettings: true)
        }
    }

    /// Looks the cited messages up in the local Postbox. This gives the source
    /// bubbles their real author and real send time instead of the server
    /// excerpt's anonymous snapshot.
    private func resolveSources(sources: [JarvisAskSource], completion: @escaping ([String: JarvisAskSourceContent]) -> Void) {
        if sources.isEmpty {
            completion([:])
            return
        }
        let chatPeerId = EnginePeer.Id(namespace: Namespaces.Peer.CloudChannel, id: EnginePeer.Id.Id._internalFromInt64Value(self.peerId))
        let peerTitle = self.peerTitle
        let ids = Set(sources.map { source in
            return EngineMessage.Id(peerId: chatPeerId, namespace: Namespaces.Message.Cloud, id: Int32(source.messageId))
        })
        let _ = (self.context.engine.data.get(TelegramEngine.EngineData.Item.Messages.Messages(ids: ids))
        |> deliverOnMainQueue).start(next: { messages in
            var result: [String: JarvisAskSourceContent] = [:]
            for source in sources {
                let messageId = EngineMessage.Id(peerId: chatPeerId, namespace: Namespaces.Message.Cloud, id: Int32(source.messageId))
                guard let message = messages[messageId] else { continue }
                let text = message.text.isEmpty ? source.text : message.text
                result[source.sourceId] = JarvisAskSourceContent(
                    text: text,
                    authorName: message.author?.compactDisplayTitle ?? peerTitle,
                    timestamp: message.timestamp
                )
            }
            completion(result)
        })
    }

    private func fail(turnId: Int32, message: String, needsSettings: Bool) {
        guard self.stillCurrent() else { return }
        self.updateTurn(turnId) {
            $0.phase = .failed
            $0.error = message
            $0.needsSettings = needsSettings
        }
    }

    private func message(for error: JarvisManageError) -> String {
        switch error {
        case .authenticationRequired:
            return self.localized("Your session expired. Sign in again.", "登录状态已失效，请重新登录。")
        case .forbidden:
            return self.localized("This chat is not authorized for Jarvis.", "这个会话没有授权给 Jarvis。")
        case .hostedKeyRequired:
            return self.localized("Add a hosted key in Jarvis settings first.", "请先在 Jarvis 设置中添加托管 Key。")
        case .operationFailed:
            return self.localized("The provider rejected the request.", "服务商拒绝了请求。")
        case .invalidConfiguration:
            return self.localized("Jarvis settings are not configured correctly.", "Jarvis 设置配置有误。")
        case .incompatibleResponse:
            return self.localized("This server returned an unsupported response.", "服务器返回了不兼容的结果。")
        case .unavailable:
            return self.localized("Jarvis is unavailable right now.", "Jarvis 暂时不可用。")
        }
    }

    private func localMessage(for error: JarvisLocalModelError) -> String {
        switch error {
        case .providerRejected:
            return self.localized("The provider rejected the local key. Check it in Jarvis settings.", "供应商拒绝了本机 Key，请在 Jarvis 设置中检查。")
        case .rateLimited:
            return self.localized("The provider is rate-limiting this key. Try again later.", "供应商对该 Key 限流，请稍后再试。")
        case .invalidConfiguration:
            return self.localized("The local key configuration is invalid.", "本机 Key 配置无效。")
        case .credentialUnavailable:
            return self.localized("The local key could not be read. Check it in Jarvis settings.", "无法读取本机 Key，请在 Jarvis 设置中检查。")
        case .invalidResponse, .unavailable:
            return self.localized("The answer could not be generated. Check your connection and try again.", "无法生成答案，请检查网络后重试。")
        }
    }

    func cancel() {
        self.cancelled = true
        self.dataTask?.cancel()
        self.dataTask = nil
        guard let index = self.current.turns.lastIndex(where: { $0.phase == .loading }) else { return }
        self.current.turns[index].phase = .cancelled
        self.current.turns[index].error = nil
        self.publish()
    }

    func openSource(sourceId: String) {
        guard let source = self.current.turns.flatMap({ $0.sources }).first(where: { $0.sourceId == sourceId }) else { return }
        // The controller (and with it this model) is torn down by the pop, so
        // the next step must not hold the model.
        let open = self.openSource
        let messageId = source.messageId
        self.dismissThen {
            open(messageId)
        }
    }

    func openSettingsAction() {
        let openSettings = self.openSettings
        self.dismissThen {
            openSettings()
        }
    }

    /// `ViewController.dismiss` drops the completion it is given, so the pop
    /// is followed by a short wait before running the next step.
    private func dismissThen(_ action: @escaping () -> Void) {
        guard !self.isDismissing else {
            return
        }
        self.isDismissing = true
        guard let controller = self.controller else {
            self.isDismissing = false
            action()
            return
        }
        controller.dismiss(animated: true)
        Queue.mainQueue().after(0.4, { [weak self] in
            self?.isDismissing = false
            action()
        })
    }
}

// MARK: - Transcript items

private func jarvisCaptionAttributedText(_ text: String, color: UIColor) -> NSAttributedString {
    return NSAttributedString(string: text, attributes: [
        .font: Font.regular(13.0),
        .foregroundColor: color
    ])
}

private final class JarvisAskCaptionItem: ListViewItem {
    let text: NSAttributedString
    let accessibilityText: String
    let fillColor: UIColor
    let action: (() -> Void)?
    let identifier: String?

    init(text: NSAttributedString, accessibilityText: String, fillColor: UIColor, action: (() -> Void)? = nil, identifier: String? = nil) {
        self.text = text
        self.accessibilityText = accessibilityText
        self.fillColor = fillColor
        self.action = action
        self.identifier = identifier
    }

    var neighborDescriptor: AnyEquatable {
        return AnyEquatable.noNeighborInfluence
    }

    var selectable: Bool {
        return self.action != nil
    }

    var approximateHeight: CGFloat {
        return 34.0
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, neighbors: ListViewItemNeighbors, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        async {
            let node = JarvisAskCaptionItemNode()
            let (layout, apply) = node.asyncLayout()(self, params)
            node.contentSize = layout.contentSize
            node.insets = layout.insets
            Queue.mainQueue().async {
                completion(node, {
                    return (nil, { _ in apply() })
                })
            }
        }
    }

    func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, neighbors: ListViewItemNeighbors, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        Queue.mainQueue().async {
            guard let nodeValue = node() as? JarvisAskCaptionItemNode else {
                return
            }
            let (layout, apply) = nodeValue.asyncLayout()(self, params)
            completion(layout, { _ in
                apply()
            })
        }
    }

    func selected(listView: ListView) {
        self.action?()
    }
}

private final class JarvisAskCaptionItemNode: ListViewItemNode {
    private let pillNode: ASDisplayNode
    private let textNode: TextNode
    private let accessibilityNode: AccessibilityAreaNode
    private var item: JarvisAskCaptionItem?

    init() {
        self.pillNode = ASDisplayNode()
        self.pillNode.isLayerBacked = true
        self.pillNode.cornerRadius = 10.0

        self.textNode = TextNode()
        self.textNode.isUserInteractionEnabled = false

        self.accessibilityNode = AccessibilityAreaNode()

        super.init(layerBacked: false)

        self.addSubnode(self.pillNode)
        self.addSubnode(self.textNode)
        self.addSubnode(self.accessibilityNode)
    }

    func asyncLayout() -> (_ item: JarvisAskCaptionItem, _ params: ListViewItemLayoutParams) -> (ListViewItemNodeLayout, () -> Void) {
        let makeTextLayout = TextNode.asyncLayout(self.textNode)

        return { [weak self] item, params in
            let (textLayout, textApply) = makeTextLayout(TextNodeLayoutArguments(
                attributedString: item.text,
                backgroundColor: nil,
                maximumNumberOfLines: 0,
                truncationType: .end,
                constrainedSize: CGSize(width: max(0.0, params.width - params.leftInset - params.rightInset - 48.0), height: CGFloat.greatestFiniteMagnitude),
                alignment: .center,
                cutout: nil,
                insets: UIEdgeInsets()
            ))

            let contentHeight = textLayout.size.height + 22.0
            let layout = ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: contentHeight), insets: .zero)

            return (layout, {
                guard let strongSelf = self else { return }
                strongSelf.item = item

                let pillWidth = textLayout.size.width + 24.0
                let pillHeight = textLayout.size.height + 14.0
                let pillFrame = CGRect(
                    x: params.leftInset + floor((params.width - params.leftInset - params.rightInset - pillWidth) / 2.0),
                    y: floor((contentHeight - pillHeight) / 2.0),
                    width: pillWidth,
                    height: pillHeight
                )

                let _ = textApply()
                strongSelf.pillNode.backgroundColor = item.fillColor
                strongSelf.pillNode.frame = pillFrame
                strongSelf.pillNode.cornerRadius = pillHeight / 2.0
                strongSelf.textNode.frame = CGRect(
                    x: pillFrame.minX + floor((pillFrame.width - textLayout.size.width) / 2.0),
                    y: pillFrame.minY + floor((pillFrame.height - textLayout.size.height) / 2.0),
                    width: textLayout.size.width,
                    height: textLayout.size.height
                )

                strongSelf.accessibilityNode.frame = pillFrame
                strongSelf.accessibilityNode.accessibilityLabel = item.accessibilityText
                strongSelf.accessibilityNode.accessibilityIdentifier = item.identifier
                strongSelf.accessibilityNode.accessibilityTraits = item.action != nil ? .button : .staticText
                strongSelf.accessibilityNode.activate = item.action.map { action in
                    return {
                        action()
                        return true
                    }
                }
            })
        }
    }
}

/// Hosts a chat message cell inside a container rotated by half a turn, which
/// is how the cell expects to be drawn outside the chat's rotated history
/// list. Optionally exposes the row as one accessibility element and turns a
/// tap into `action`.
private final class JarvisAskBubbleItem: ListViewItem {
    fileprivate let inner: ListViewItem
    fileprivate let identifier: String?
    fileprivate let accessibilityLabel: String?
    fileprivate let action: (() -> Void)?

    init(inner: ListViewItem, identifier: String?, accessibilityLabel: String?, action: (() -> Void)?) {
        self.inner = inner
        self.identifier = identifier
        self.accessibilityLabel = accessibilityLabel
        self.action = action
    }

    var neighborDescriptor: AnyEquatable {
        return self.inner.neighborDescriptor
    }

    var accessoryItem: ListViewAccessoryItem? {
        return self.inner.accessoryItem
    }

    var headerAccessoryItem: ListViewAccessoryItem? {
        return self.inner.headerAccessoryItem
    }

    var selectable: Bool {
        return self.action != nil
    }

    var approximateHeight: CGFloat {
        return self.inner.approximateHeight
    }

    var pinToEdgeWithInset: Bool {
        return self.inner.pinToEdgeWithInset
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, neighbors: ListViewItemNeighbors, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        let identifier = self.identifier
        let accessibilityLabel = self.accessibilityLabel
        let action = self.action
        self.inner.nodeConfiguredForParams(async: async, params: params, synchronousLoads: synchronousLoads, neighbors: neighbors, completion: { innerNode, apply in
            let node = JarvisAskBubbleItemNode()
            node.configure(identifier: identifier, accessibilityLabel: accessibilityLabel, action: action)
            node.adopt(innerNode: innerNode)
            node.contentSize = innerNode.contentSize
            node.insets = innerNode.insets
            completion(node, {
                return (nil, { applyContext in
                    _ = apply().1(applyContext)
                    node.update(innerLayout: ListViewItemNodeLayout(contentSize: innerNode.contentSize, insets: innerNode.insets))
                })
            })
        })
    }

    func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, neighbors: ListViewItemNeighbors, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        self.inner.updateNode(async: async, node: {
            return (node() as? JarvisAskBubbleItemNode)?.innerNode ?? node()
        }, params: params, neighbors: neighbors, animation: animation, completion: { layout, apply in
            completion(layout, { applyContext in
                apply(applyContext)
                (node() as? JarvisAskBubbleItemNode)?.update(innerLayout: layout)
            })
        })
    }

    func selected(listView: ListView) {
        self.action?()
    }
}

/// Hosts a chat message cell inside a container rotated by half a turn: the
/// cell is drawn for the chat's rotated history list, so outside it the
/// content would come out upside down.
private final class JarvisAskBubbleItemNode: ListViewItemNode {
    private let containerNode: ASDisplayNode
    fileprivate private(set) var innerNode: ListViewItemNode?
    private var tapAction: (() -> Void)?

    init() {
        self.containerNode = ASDisplayNode()
        self.containerNode.subnodeTransform = CATransform3DMakeRotation(CGFloat.pi, 0.0, 0.0, 1.0)

        super.init(layerBacked: false)

        self.addSubnode(self.containerNode)
    }

    func configure(identifier: String?, accessibilityLabel: String?, action: (() -> Void)?) {
        self.tapAction = action
        let exposesAccessibility = identifier != nil || accessibilityLabel != nil
        self.view.isAccessibilityElement = exposesAccessibility
        self.view.accessibilityIdentifier = identifier
        self.view.accessibilityLabel = accessibilityLabel
        self.view.accessibilityTraits = action != nil ? .button : .staticText
        if action != nil {
            self.addTapRecognizerIfNeeded()
        }
    }

    override func didLoad() {
        super.didLoad()
        self.addTapRecognizerIfNeeded()
    }

    private func addTapRecognizerIfNeeded() {
        guard self.isNodeLoaded, self.tapAction != nil, self.tapRecognizer == nil else {
            return
        }
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(self.handleTapGesture))
        self.view.addGestureRecognizer(recognizer)
        self.tapRecognizer = recognizer
    }

    private var tapRecognizer: UITapGestureRecognizer?

    @objc private func handleTapGesture() {
        self.tapAction?()
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // Hand every touch in this row to the row itself. The chat cell inside
        // is a real message bubble with its own tap recognizer: if the touch
        // reaches it, that recognizer wins and cancels the touches the list
        // needs to select the row, so neither the row's action nor the list's
        // selection ever fires.
        let view = self.view
        guard view.point(inside: point, with: event),
              !view.isHidden,
              view.alpha > 0.01,
              view.isUserInteractionEnabled else {
            return nil
        }
        return view
    }

    func adopt(innerNode: ListViewItemNode) {
        self.innerNode = innerNode
        if innerNode.supernode == nil {
            self.containerNode.addSubnode(innerNode)
        }
        innerNode.isUserInteractionEnabled = false
    }

    func update(innerLayout: ListViewItemNodeLayout) {
        let frame = CGRect(origin: CGPoint(), size: innerLayout.size)
        self.containerNode.frame = frame
        self.innerNode?.updateFrame(frame, within: frame.size)
        self.contentSize = innerLayout.contentSize
        self.insets = innerLayout.insets
    }
}

// MARK: - Composer

private final class JarvisAskComposerNode: ASDisplayNode {
    private let capsuleNode: ASDisplayNode
    private let inputNode: TextFieldNode
    private let sendButton: ASButtonNode

    private var presentationData: PresentationData
    private var sendIcon: UIImage?
    private var stopIcon: UIImage?

    var send: ((String) -> Void)?
    var cancel: (() -> Void)?
    private(set) var isLoading = false

    init(presentationData: PresentationData) {
        self.presentationData = presentationData
        self.capsuleNode = ASDisplayNode()
        self.capsuleNode.cornerRadius = 22.0
        self.inputNode = TextFieldNode()
        self.sendButton = ASButtonNode()
        self.sendButton.cornerRadius = 18.0
        self.sendButton.imageNode.contentMode = .center

        super.init()

        self.addSubnode(self.capsuleNode)
        self.capsuleNode.addSubnode(self.inputNode)
        self.addSubnode(self.sendButton)

        self.sendButton.addTarget(self, action: #selector(self.buttonPressed), forControlEvents: .touchUpInside)
        self.isLoading = false
    }

    override func didLoad() {
        super.didLoad()

        self.inputNode.textField.font = Font.regular(17.0)
        self.inputNode.textField.returnKeyType = .send
        self.inputNode.textField.autocapitalizationType = .sentences
        self.inputNode.textField.textContentType = .none
        self.inputNode.textField.accessibilityIdentifier = "jarvis-ask-input"
        // The send/cancel control is a bare ASButtonNode, which UIKit maps to
        // a generic element; it is a button and should read as one.
        self.sendButton.view.accessibilityTraits = .button
        self.sendButton.view.accessibilityIdentifier = "jarvis-ask-send"
        self.inputNode.textField.addTarget(self, action: #selector(self.returnPressed), for: .editingDidEndOnExit)
        self.applyPresentationData()
    }

    func update(presentationData: PresentationData, isLoading: Bool) {
        self.presentationData = presentationData
        if self.isLoading != isLoading {
            self.isLoading = isLoading
            if self.isNodeLoaded {
                self.applyPresentationData()
            }
        } else if self.isNodeLoaded {
            self.applyPresentationData()
        }
    }

    private func applyPresentationData() {
        let theme = self.presentationData.theme
        let strings = self.presentationData.strings

        self.capsuleNode.backgroundColor = theme.chat.inputPanel.inputBackgroundColor
        self.sendButton.backgroundColor = self.isLoading ? theme.chat.inputPanel.panelControlDestructiveColor : theme.chat.inputPanel.panelControlAccentColor

        self.inputNode.textField.textColor = theme.chat.inputPanel.inputTextColor
        self.inputNode.textField.tintColor = theme.chat.inputPanel.panelControlAccentColor
        self.inputNode.textField.keyboardAppearance = theme.rootController.keyboardColor.keyboardAppearance
        self.inputNode.textField.attributedPlaceholder = NSAttributedString(
            string: jarvisAskText(strings, "Ask a follow-up…", "继续追问…"),
            attributes: [
                .font: Font.regular(17.0),
                .foregroundColor: theme.chat.inputPanel.inputPlaceholderColor
            ]
        )

        if let sendIcon = PresentationResourcesChat.chatInputPanelSendIconImage(theme) {
            self.sendIcon = sendIcon
        }
        if self.stopIcon == nil {
            self.stopIcon = generateImage(CGSize(width: 12.0, height: 12.0), rotatedContext: { size, context in
                context.setFillColor(UIColor.white.cgColor)
                context.addPath(CGPath(roundedRect: CGRect(origin: CGPoint(), size: size), cornerWidth: 3.0, cornerHeight: 3.0, transform: nil))
                context.fillPath()
            })
        }

        if self.isLoading {
            self.sendButton.setImage(self.stopIcon, for: .normal)
            self.sendButton.accessibilityLabel = jarvisAskText(strings, "Cancel", "取消")
        } else {
            self.sendButton.setImage(self.sendIcon, for: .normal)
            self.sendButton.accessibilityLabel = jarvisAskText(strings, "Send", "发送")
        }
    }

    func updateLayout(width: CGFloat, safeInsets: UIEdgeInsets) {
        let buttonSize: CGFloat = 36.0
        let sideInset: CGFloat = 8.0
        let capsuleHeight: CGFloat = 44.0
        let topInset: CGFloat = 6.0

        let capsuleFrame = CGRect(
            x: safeInsets.left + sideInset,
            y: topInset,
            width: max(0.0, width - safeInsets.left - safeInsets.right - sideInset * 2.0 - buttonSize - 8.0),
            height: capsuleHeight
        )
        self.capsuleNode.frame = capsuleFrame
        self.inputNode.frame = CGRect(x: 14.0, y: 0.0, width: max(0.0, capsuleFrame.width - 28.0), height: capsuleHeight)
        self.sendButton.frame = CGRect(
            x: width - safeInsets.right - sideInset - buttonSize,
            y: topInset + floor((capsuleHeight - buttonSize) / 2.0),
            width: buttonSize,
            height: buttonSize
        )
    }

    @objc private func buttonPressed() {
        if self.isLoading {
            self.cancel?()
        } else {
            self.submit()
        }
    }

    @objc private func returnPressed() {
        if !self.isLoading {
            self.submit()
        }
    }

    private func submit() {
        guard let text = self.inputNode.textField.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return
        }
        self.inputNode.textField.text = ""
        self.send?(text)
    }
}

// MARK: - Controller node

private final class JarvisAskControllerNode: ViewControllerTracingNode {
    private let context: AccountContext
    private let peerId: Int64
    private let peerTitle: String
    private let requestOpenSource: (String) -> Void
    private let requestOpenSettings: () -> Void

    private var presentationData: PresentationData
    private var state = JarvisAskState()

    private let wallpaperNode: WallpaperBackgroundNode
    private let listNode: ListView
    private let composerBackgroundNode: NavigationBackgroundNode
    private let composerSeparatorNode: ASDisplayNode
    private let composerNode: JarvisAskComposerNode

    private var appliedItems: [ListViewItem] = []
    private var validLayout: (ContainerViewLayout, CGFloat)?

    init(context: AccountContext, peerId: Int64, peerTitle: String, presentationData: PresentationData, wallpaper: TelegramWallpaper, openSource: @escaping (String) -> Void, openSettings: @escaping () -> Void, send: @escaping (String) -> Void, cancel: @escaping () -> Void) {
        self.context = context
        self.peerId = peerId
        self.peerTitle = peerTitle
        self.presentationData = presentationData
        self.requestOpenSource = openSource
        self.requestOpenSettings = openSettings

        self.wallpaperNode = createWallpaperBackgroundNode(context: context, forChatDisplay: false)
        // Use the wallpaper of the chat that sent /ask (it may be set per
        // chat), so the transcript reads as that conversation.
        self.wallpaperNode.update(wallpaper: wallpaper, animated: false)
        self.wallpaperNode.updateBubbleTheme(bubbleTheme: presentationData.theme, bubbleCorners: presentationData.chatBubbleCorners)

        self.listNode = ListViewImpl()
        self.listNode.backgroundColor = .clear
        // The transcript scrolls behind the input bar; without a surface and
        // a hairline here the last bubbles and the composer read as one
        // block of floating text.
        self.composerBackgroundNode = NavigationBackgroundNode(color: presentationData.theme.chat.inputPanel.panelBackgroundColor)
        self.composerBackgroundNode.isUserInteractionEnabled = false
        self.composerSeparatorNode = ASDisplayNode()
        self.composerSeparatorNode.backgroundColor = presentationData.theme.chat.inputPanel.panelSeparatorColor
        self.composerNode = JarvisAskComposerNode(presentationData: presentationData)
        self.composerNode.send = send
        self.composerNode.cancel = cancel

        let presentationDataCopy = presentationData
        super.init()

        self.listNode.accessibilityPageScrolledString = { row, count in
            return presentationDataCopy.strings.VoiceOver_ScrollStatus(row, count).string
        }

        self.addSubnode(self.wallpaperNode)
        self.addSubnode(self.listNode)
        self.addSubnode(self.composerBackgroundNode)
        self.composerBackgroundNode.addSubnode(self.composerSeparatorNode)
        self.addSubnode(self.composerNode)
    }

    func update(presentationData: PresentationData, state: JarvisAskState) {
        let previousTheme = self.presentationData.theme
        self.presentationData = presentationData
        self.state = state
        if previousTheme !== presentationData.theme {
            self.wallpaperNode.updateBubbleTheme(bubbleTheme: presentationData.theme, bubbleCorners: presentationData.chatBubbleCorners)
            self.composerBackgroundNode.updateColor(color: presentationData.theme.chat.inputPanel.panelBackgroundColor, transition: .immediate)
            self.composerSeparatorNode.backgroundColor = presentationData.theme.chat.inputPanel.panelSeparatorColor
        }
        self.composerNode.update(presentationData: presentationData, isLoading: self.isLoading)

        self.rebuildItems()

        if let (layout, navigationBarHeight) = self.validLayout {
            self.applyItems(layout: layout, navigationBarHeight: navigationBarHeight, transition: .immediate, scrollToBottom: true)
        }
    }

    private var isLoading: Bool {
        return self.state.turns.contains(where: { $0.phase == .loading })
    }

    func containerLayoutUpdated(_ layout: ContainerViewLayout, navigationBarHeight: CGFloat, transition: ContainedViewLayoutTransition) {
        let hadLayout = self.validLayout != nil
        self.validLayout = (layout, navigationBarHeight)

        transition.updateFrame(node: self.wallpaperNode, frame: CGRect(origin: CGPoint(), size: layout.size))
        // The wallpaper builds its pattern/photo content on an explicit
        // layout pass; without it the node stays blank.
        self.wallpaperNode.updateLayout(size: layout.size, displayMode: .aspectFill, transition: transition)

        let inputInset = layout.insets(options: [.input]).bottom
        let composerHeight: CGFloat = 56.0
        let composerTop = layout.size.height - inputInset - composerHeight
        transition.updateFrame(node: self.composerNode, frame: CGRect(
            x: 0.0,
            y: composerTop,
            width: layout.size.width,
            height: composerHeight
        ))
        transition.updateFrame(node: self.composerBackgroundNode, frame: CGRect(
            x: 0.0,
            y: composerTop,
            width: layout.size.width,
            height: layout.size.height - composerTop
        ))
        self.composerBackgroundNode.update(size: CGSize(width: layout.size.width, height: layout.size.height - composerTop), transition: transition)
        let separatorHeight = 1.0 / max(1.0, UIScreen.main.scale)
        transition.updateFrame(node: self.composerSeparatorNode, frame: CGRect(
            x: 0.0,
            y: 0.0,
            width: layout.size.width,
            height: separatorHeight
        ))
        self.composerNode.updateLayout(width: layout.size.width, safeInsets: layout.safeInsets)

        transition.updateFrame(node: self.listNode, frame: CGRect(origin: CGPoint(), size: layout.size))

        if !hadLayout {
            self.rebuildItems()
        }
        self.applyItems(layout: layout, navigationBarHeight: navigationBarHeight, transition: transition, scrollToBottom: !hadLayout)
    }

    private func listInsets(_ layout: ContainerViewLayout, navigationBarHeight: CGFloat) -> UIEdgeInsets {
        let inputInset = layout.insets(options: [.input]).bottom
        return UIEdgeInsets(
            top: navigationBarHeight + 8.0,
            left: layout.safeInsets.left,
            bottom: inputInset + 56.0 + 8.0,
            right: layout.safeInsets.right
        )
    }

    private func applyItems(layout: ContainerViewLayout, navigationBarHeight: CGFloat, transition: ContainedViewLayoutTransition, scrollToBottom: Bool) {
        let duration: Double
        switch transition {
        case let .animated(durationValue, _):
            duration = durationValue
        default:
            duration = 0.0
        }
        let insets = self.listInsets(layout, navigationBarHeight: navigationBarHeight)
        let updateSizeAndInsets = ListViewUpdateSizeAndInsets(
            size: layout.size,
            insets: insets,
            duration: duration,
            curve: .Default(duration: duration == 0.0 ? nil : duration)
        )

        var scrollToItem: ListViewScrollToItem?
        if scrollToBottom, !self.items.isEmpty {
            let anchor = self.scrollAnchorIndex.flatMap { $0 < self.items.count ? $0 : nil }
            scrollToItem = ListViewScrollToItem(
                index: anchor ?? self.items.count - 1,
                position: anchor != nil ? .top(8.0) : .bottom(0.0),
                animated: false,
                curve: .Default(duration: nil),
                directionHint: .Down
            )
        }

        let deletions = self.appliedItems.indices.map { ListViewDeleteItem(index: $0, directionHint: nil) }
        let insertions = self.items.enumerated().map { ListViewInsertItem(index: $0.offset, previousIndex: nil, item: $0.element, directionHint: nil) }
        self.appliedItems = self.items

        self.listNode.transaction(
            deleteIndices: deletions,
            insertIndicesAndItems: insertions,
            updateIndicesAndItems: [],
            options: [.Synchronous, .LowLatency],
            scrollToItem: scrollToItem,
            updateSizeAndInsets: updateSizeAndInsets,
            stationaryItemRange: nil,
            updateOpaqueState: nil,
            completion: { _ in }
        )
    }

    private var items: [ListViewItem] = []
    /// The item the transcript scrolls to after a change: the newest answer,
    /// or its question while the answer is still loading. Keeping the answer
    /// in view matters more than showing the source list's end, which sits
    /// below it and can be scrolled to.
    private var scrollAnchorIndex: Int?

    private func rebuildItems() {
        var items: [ListViewItem] = []
        var messageCounter: Int32 = 1
        var anchorIndex: Int?

        if let firstScope = self.state.turns.first(where: { $0.phase == .answered })?.scope {
            let count = self.state.turns.first(where: { $0.phase == .answered })?.sources.count ?? 0
            let scope = firstScope == "recent_excerpt"
                ? jarvisAskText(self.presentationData.strings, "recent excerpts", "最近片段")
                : firstScope
            let text = jarvisAskText(self.presentationData.strings, "Using \(count) server-scoped \(scope) from \"\(self.peerTitle)\".", "使用「\(self.peerTitle)」的 \(count) 条服务端限定\(scope)。")
            items.append(JarvisAskCaptionItem(
                text: jarvisCaptionAttributedText(text, color: self.presentationData.theme.chat.serviceMessage.components.withDefaultWallpaper.primaryText),
                accessibilityText: text,
                fillColor: self.presentationData.theme.chat.serviceMessage.components.withDefaultWallpaper.fill
            ))
        }

        for turn in self.state.turns {
            messageCounter += 1
            let questionEntities = JarvisAskEntities(text: turn.question)
            items.append(self.makeBubbleItem(
                text: questionEntities.text,
                entities: questionEntities.entities,
                outgoing: true,
                authorName: "",
                timestamp: turn.askedAt,
                messageId: messageCounter,
                identifier: "jarvis-question-\(turn.id)",
                accessibilityLabel: turn.question
            ))

            anchorIndex = items.count - 1
            switch turn.phase {
            case .loading:
                messageCounter += 1
                let loadingText = jarvisAskText(self.presentationData.strings, "Reading recent messages…", "正在读取最近的消息…")
                items.append(self.makeBubbleItem(
                    text: loadingText,
                    entities: [],
                    outgoing: false,
                    authorName: "Jarvis",
                    timestamp: turn.askedAt,
                    messageId: messageCounter,
                    identifier: "jarvis-loading-\(turn.id)",
                    accessibilityLabel: loadingText
                ))
            case .answered:
                if let answer = turn.answer {
                    messageCounter += 1
                    let answerEntities = JarvisAskEntities(text: answer)
                    items.append(self.makeBubbleItem(
                        text: answerEntities.text,
                        entities: answerEntities.entities,
                        outgoing: false,
                        authorName: "Jarvis",
                        timestamp: turn.answeredAt ?? turn.askedAt,
                        messageId: messageCounter,
                        identifier: "jarvis-answer-\(turn.id)",
                        accessibilityLabel: answerEntities.text
                    ))
                    anchorIndex = items.count - 1
                }
                if !turn.sources.isEmpty {
                    let sourcesTitle = jarvisAskText(self.presentationData.strings, "Sources (\(turn.sources.count))", "来源（\(turn.sources.count)）")
                    items.append(JarvisAskCaptionItem(
                        text: jarvisCaptionAttributedText(sourcesTitle, color: self.presentationData.theme.chat.serviceMessage.components.withDefaultWallpaper.primaryText),
                        accessibilityText: sourcesTitle,
                        fillColor: self.presentationData.theme.chat.serviceMessage.components.withDefaultWallpaper.fill
                    ))
                    for source in turn.sources {
                        messageCounter += 1
                        let content = turn.sourceContent[source.sourceId]
                        let sourceText = content?.text ?? source.text
                        let authorName = content?.authorName ?? self.peerTitle
                        let timestamp = content?.timestamp ?? turn.answeredAt ?? turn.askedAt
                        let clipped = jarvisClippedSourceText(sourceText)
                        items.append(self.makeBubbleItem(
                            text: clipped,
                            entities: [],
                            outgoing: false,
                            authorName: authorName,
                            timestamp: timestamp,
                            messageId: messageCounter,
                            identifier: "jarvis-source-\(source.sourceId)",
                            accessibilityLabel: "\(authorName), \(clipped)",
                            action: { [weak self] in
                                self?.requestOpenSource(source.sourceId)
                            }
                        ))
                    }
                }
            case .failed:
                if let error = turn.error {
                    items.append(JarvisAskCaptionItem(
                        text: jarvisCaptionAttributedText(error, color: self.presentationData.theme.chat.serviceMessage.components.withDefaultWallpaper.scam),
                        accessibilityText: error,
                        fillColor: self.presentationData.theme.chat.serviceMessage.components.withDefaultWallpaper.fill
                    ))
                }
                if turn.needsSettings {
                    let actionTitle = jarvisAskText(self.presentationData.strings, "Open Jarvis settings", "打开 Jarvis 设置")
                    items.append(JarvisAskCaptionItem(
                        text: jarvisCaptionAttributedText(actionTitle, color: self.presentationData.theme.chat.inputPanel.panelControlAccentColor),
                        accessibilityText: actionTitle,
                        fillColor: self.presentationData.theme.chat.serviceMessage.components.withDefaultWallpaper.fill,
                        action: { [weak self] in
                            self?.requestOpenSettings()
                        },
                        identifier: "jarvis-open-settings"
                    ))
                }
            case .cancelled:
                let cancelledText = jarvisAskText(self.presentationData.strings, "Cancelled.", "已取消。")
                items.append(JarvisAskCaptionItem(
                    text: jarvisCaptionAttributedText(cancelledText, color: self.presentationData.theme.chat.serviceMessage.components.withDefaultWallpaper.primaryText),
                    accessibilityText: cancelledText,
                    fillColor: self.presentationData.theme.chat.serviceMessage.components.withDefaultWallpaper.fill
                ))
            }
        }

        self.items = items
        self.scrollAnchorIndex = anchorIndex
    }

    private func makeBubbleItem(text: String, entities: [MessageTextEntity], outgoing: Bool, authorName: String, timestamp: Int32, messageId: Int32, identifier: String? = nil, accessibilityLabel: String? = nil, action: (() -> Void)? = nil) -> ListViewItem {
        let chatPeer = JarvisAskSyntheticPeers.chatPeer
        let authorPeer: TelegramUser
        if outgoing {
            authorPeer = JarvisAskSyntheticPeers.accountPeer(context: self.context)
        } else {
            authorPeer = JarvisAskSyntheticPeers.authorPeer(name: authorName, index: messageId)
        }

        var peers = EngineSimpleDictionary<EnginePeer.Id, EngineRawPeer>()
        peers[chatPeer.id] = chatPeer
        peers[authorPeer.id] = authorPeer

        var attributes: [EngineMessage.Attribute] = []
        if !entities.isEmpty {
            attributes.append(TextEntitiesMessageAttribute(entities: entities))
        }

        let message = EngineRawMessage(
            stableId: UInt32(bitPattern: messageId),
            stableVersion: 0,
            id: EngineMessage.Id(peerId: chatPeer.id, namespace: 0, id: messageId),
            globallyUniqueId: nil,
            groupingKey: nil,
            groupInfo: nil,
            threadId: nil,
            timestamp: timestamp,
            flags: outgoing ? [] : [.Incoming],
            tags: [],
            globalTags: [],
            localTags: [],
            customTags: [],
            forwardInfo: nil,
            author: authorPeer,
            text: text,
            attributes: attributes,
            media: [],
            peers: peers,
            associatedMessages: EngineSimpleDictionary(),
            associatedMessageIds: [],
            associatedMedia: [:],
            associatedThreadInfo: nil,
            associatedStories: [:]
        )

        let item = self.context.sharedContext.makeChatMessagePreviewItem(
            context: self.context,
            messages: [EngineMessage(message)],
            theme: self.presentationData.theme,
            strings: self.presentationData.strings,
            wallpaper: self.presentationData.chatWallpaper,
            fontSize: self.presentationData.chatFontSize,
            chatBubbleCorners: self.presentationData.chatBubbleCorners,
            dateTimeFormat: self.presentationData.dateTimeFormat,
            nameOrder: self.presentationData.nameDisplayOrder,
            forcedResourceStatus: nil,
            tapMessage: nil,
            clickThroughMessage: nil,
            backgroundNode: self.wallpaperNode,
            availableReactions: nil,
            accountPeer: JarvisAskSyntheticPeers.accountEnginePeer(context: self.context),
            isCentered: false,
            isPreview: true,
            isStandalone: false,
            rank: nil,
            rankRole: nil,
            isGiftMessageComposerPreview: false,
            activateGiftMessageInput: nil
        )
        // A chat message cell is drawn for the rotated chat history list; in
        // a regular list its content comes out upside down, so every bubble
        // goes through a container rotated by half a turn.
        return JarvisAskBubbleItem(inner: item, identifier: identifier, accessibilityLabel: accessibilityLabel, action: action)
    }
}

private enum JarvisAskSyntheticPeers {
    static let chatPeer: TelegramChannel = TelegramChannel(
        id: EnginePeer.Id(namespace: Namespaces.Peer.CloudChannel, id: EnginePeer.Id.Id._internalFromInt64Value(9_000_000_001)),
        accessHash: nil,
        title: "Jarvis",
        username: nil,
        photo: [],
        creationDate: 0,
        version: 0,
        participationStatus: .member,
        info: .group(TelegramChannelGroupInfo(flags: [])),
        flags: [],
        restrictionInfo: nil,
        adminRights: nil,
        bannedRights: nil,
        defaultBannedRights: nil,
        usernames: [],
        storiesHidden: nil,
        nameColor: nil,
        backgroundEmojiId: nil,
        profileColor: nil,
        profileBackgroundEmojiId: nil,
        emojiStatus: nil,
        approximateBoostLevel: nil,
        subscriptionUntilDate: nil,
        verificationIconFileId: nil,
        sendPaidMessageStars: nil,
        linkedMonoforumId: nil
    )

    static func accountPeer(context: AccountContext) -> TelegramUser {
        return TelegramUser(
            id: context.account.peerId,
            accessHash: nil,
            firstName: nil,
            lastName: nil,
            username: nil,
            phone: nil,
            photo: [],
            botInfo: nil,
            restrictionInfo: nil,
            flags: [],
            emojiStatus: nil,
            usernames: [],
            storiesHidden: nil,
            nameColor: nil,
            backgroundEmojiId: nil,
            profileColor: nil,
            profileBackgroundEmojiId: nil,
            subscriberCount: nil,
            verificationIconFileId: nil
        )
    }

    static func accountEnginePeer(context: AccountContext) -> EnginePeer {
        return .user(accountPeer(context: context))
    }

    static func authorPeer(name: String, index: Int32) -> TelegramUser {
        return TelegramUser(
            id: EnginePeer.Id(namespace: Namespaces.Peer.CloudUser, id: EnginePeer.Id.Id._internalFromInt64Value(9_100_000_000 + Int64(index))),
            accessHash: nil,
            firstName: name,
            lastName: "",
            username: nil,
            phone: nil,
            photo: [],
            botInfo: nil,
            restrictionInfo: nil,
            flags: [],
            emojiStatus: nil,
            usernames: [],
            storiesHidden: nil,
            nameColor: nil,
            backgroundEmojiId: nil,
            profileColor: nil,
            profileBackgroundEmojiId: nil,
            subscriberCount: nil,
            verificationIconFileId: nil
        )
    }
}

private struct JarvisAskEntities {
    let text: String
    let entities: [MessageTextEntity]

    init(text: String) {
        let spans = jarvisMarkdownSpans(text)
        var result = ""
        var entities: [MessageTextEntity] = []
        for span in spans {
            let range = NSRange(location: (result as NSString).length, length: (span.text as NSString).length)
            result += span.text
            switch span.kind {
            case .bold:
                entities.append(MessageTextEntity(range: range.location ..< (range.location + range.length), type: .Bold))
            case .code:
                entities.append(MessageTextEntity(range: range.location ..< (range.location + range.length), type: .Code))
            case .italic:
                entities.append(MessageTextEntity(range: range.location ..< (range.location + range.length), type: .Italic))
            case nil:
                break
            }
        }
        self.text = result
        self.entities = entities
    }
}

private func jarvisClippedSourceText(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let limit = 320
    if trimmed.count > limit {
        return String(trimmed.prefix(limit)) + "…"
    }
    return trimmed
}

// MARK: - Controller

public final class JarvisAskController: ViewController {
    private let context: AccountContext
    private let peerId: Int64
    private let peerTitle: String
    private let initialQuestion: String
    private let wallpaper: TelegramWallpaper
    private var model: JarvisAskModel!
    private var presentationDataDisposable: Disposable?

    private var presentationData: PresentationData

    private var controllerNode: JarvisAskControllerNode {
        return self.displayNode as! JarvisAskControllerNode
    }

    private var started = false

    public init(context: AccountContext, peerId: Int64, peerTitle: String, question: String, wallpaper: TelegramWallpaper, openSource: @escaping (Int) -> Void, openSettings: @escaping () -> Void) {
        self.context = context
        self.peerId = peerId
        self.peerTitle = peerTitle
        self.initialQuestion = question
        self.wallpaper = wallpaper
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }

        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: self.presentationData))

        self.title = jarvisAskText(self.presentationData.strings, "Ask Jarvis", "问 Jarvis")
        self.statusBar.statusBarStyle = self.presentationData.theme.rootController.statusBarStyle.style
        self.navigationItem.backBarButtonItem = UIBarButtonItem(title: self.presentationData.strings.Common_Back, style: .plain, target: nil, action: nil)

        let model = JarvisAskModel(context: context, peerId: peerId, peerTitle: peerTitle, openSource: openSource, openSettings: openSettings)
        model.controller = self
        self.model = model
    }

    required public init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.presentationDataDisposable?.dispose()
    }

    override public func loadDisplayNode() {
        self.displayNode = JarvisAskControllerNode(
            context: self.context,
            peerId: self.peerId,
            peerTitle: self.peerTitle,
            presentationData: self.presentationData,
            wallpaper: self.wallpaper,
            openSource: { [weak self] sourceId in
                self?.model.openSource(sourceId: sourceId)
            },
            openSettings: { [weak self] in
                self?.model.openSettingsAction()
            },
            send: { [weak self] question in
                self?.model.ask(question: question)
            },
            cancel: { [weak self] in
                self?.model.cancel()
            }
        )
        self.displayNodeDidLoad()
    }

    override public func viewDidLoad() {
        super.viewDidLoad()

        self.presentationDataDisposable = (combineLatest(queue: .mainQueue(),
            self.context.sharedContext.presentationData,
            self.model.state.get()
        )
        |> deliverOnMainQueue).start(next: { [weak self] presentationData, state in
            guard let self else { return }
            self.presentationData = presentationData
            self.controllerNode.update(presentationData: presentationData, state: state)
        })
    }

    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !self.started {
            self.started = true
            self.model.ask(question: self.initialQuestion)
        }
    }

    override public func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        self.controllerNode.containerLayoutUpdated(layout, navigationBarHeight: self.cleanNavigationHeight, transition: transition)
    }
}

public func jarvisAskController(context: AccountContext, peerId: Int64, peerTitle: String, question: String, wallpaper: TelegramWallpaper, openSource: @escaping (Int) -> Void, openSettings: @escaping () -> Void) -> ViewController {
    return JarvisAskController(context: context, peerId: peerId, peerTitle: peerTitle, question: question, wallpaper: wallpaper, openSource: openSource, openSettings: openSettings)
}
