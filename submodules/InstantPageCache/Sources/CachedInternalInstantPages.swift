import Foundation
import SwiftSignalKit
import TelegramCore
import AccountContext
import UrlHandling

public func extractAnchor(string: String) -> (String, String?) {
    var anchorValue: String?
    if let anchorRange = string.range(of: "#") {
        let anchor = string[anchorRange.upperBound...]
        if !anchor.isEmpty {
            anchorValue = String(anchor)
        }
    }
    var trimmedUrl = string
    if let anchor = anchorValue, let anchorRange = string.range(of: "#\(anchor)") {
        let url = string[..<anchorRange.lowerBound]
        if !url.isEmpty {
            trimmedUrl = String(url)
        }
    }
    return (trimmedUrl, anchorValue)
}

private let refreshTimeout: Int32 = 60 * 60 * 12

public func cachedFaqInstantPage(context: AccountContext) -> Signal<ResolvedUrl, NoError> {
    var faqUrl = context.sharedContext.currentPresentationData.with { $0 }.strings.Settings_FAQ_URL
    if faqUrl == "Settings.FAQ_URL" || faqUrl.isEmpty {
        faqUrl = "https://telegram.org/faq#general-questions"
    }
    return cachedInternalInstantPage(context: context, url: faqUrl)
}

public func cachedTermsPage(context: AccountContext) -> Signal<ResolvedUrl, NoError> {
    return cachedInternalInstantPage(context: context, url: "https://talkytalky.im/tos.html")
}

public func cachedPrivacyPage(context: AccountContext) -> Signal<ResolvedUrl, NoError> {
    return cachedInternalInstantPage(context: context, url: "https://talkytalky.im/privacy.html")
}

public func cachedWebAppTermsPage(context: AccountContext) -> Signal<ResolvedUrl, NoError> {
    var privacyUrl = context.sharedContext.currentPresentationData.with { $0 }.strings.WebApp_TermsOfUse_URL
    if privacyUrl == "WebApp.TermsOfUse_URL" || privacyUrl.isEmpty {
        privacyUrl = "https://telegram.org/tos/mini-apps"
    }
    return cachedInternalInstantPage(context: context, url: privacyUrl)
}

private func cachedInternalInstantPage(context: AccountContext, url: String) -> Signal<ResolvedUrl, NoError> {
    let (cachedUrl, anchor) = extractAnchor(string: url)
    return cachedInstantPage(engine: context.engine, url: cachedUrl)
    |> mapToSignal { cachedInstantPage -> Signal<ResolvedUrl, NoError> in
        let updated = resolveInstantViewUrl(account: context.account, url: url)
        |> mapToSignal { result -> Signal<ResolvedUrl, NoError> in
            guard case let .result(result) = result else {
                return .complete()
            }
            return .single(result)
        }
        |> afterNext { result in
            if case let .instantView(webPage, _) = result, case let .Loaded(content) = webPage.content, let instantPage = content.instantPage {
                if instantPage.isComplete {
                    let _ = updateCachedInstantPage(engine: context.engine, url: cachedUrl, webPage: webPage).start()
                } else {
                    let _ = (actualizedWebpage(account: context.account, webpage: webPage)
                    |> mapToSignal { webPage -> Signal<Never, NoError> in
                        if case let .Loaded(content) = webPage.content, let instantPage = content.instantPage, instantPage.isComplete {
                            return updateCachedInstantPage(engine: context.engine, url: cachedUrl, webPage: webPage)
                        } else {
                            return .complete()
                        }
                    }).start()
                }
            }
        }
        
        let now = Int32(CFAbsoluteTimeGetCurrent())
        if let cachedInstantPage = cachedInstantPage, case let .Loaded(content) = cachedInstantPage.webPage.content, let instantPage = content.instantPage, instantPage.isComplete {
            let current: Signal<ResolvedUrl, NoError> = .single(.instantView(cachedInstantPage.webPage, anchor))
            if now > cachedInstantPage.timestamp + refreshTimeout {
                return current
                |> then(updated)
            } else {
                return current
            }
        } else {
            return updated
        }
    }
}
