import Foundation
import UIKit
import Display
import AccountContext
import SwiftSignalKit
import TelegramCore
import SettingsUI
import PeerInfoStoryGridScreen
import CallListUI
import ContactListUI
import PassportUI
import AccountUtils
import OverlayStatusController
import PremiumUI
import TelegramPresentationData
import PresentationDataUtils
import PasswordSetupUI
import InstantPageCache
import WalletContext
import UndoUI

extension PeerInfoScreenNode {
    func openSettings(section: PeerInfoSettingsSection) {
        let push: (ViewController) -> Void = { [weak self] c in
            guard let strongSelf = self, let navigationController = strongSelf.controller?.navigationController as? NavigationController else {
                return
            }
            
            if strongSelf.isMyProfile {
                navigationController.pushViewController(c)
            } else {
                var updatedControllers = navigationController.viewControllers
                for controller in navigationController.viewControllers.reversed() {
                    if controller !== strongSelf && !(controller is TabBarController) {
                        updatedControllers.removeLast()
                    } else {
                        break
                    }
                }
                updatedControllers.append(c)
                
                var animated = true
                if let validLayout = strongSelf.validLayout?.0, case .regular = validLayout.metrics.widthClass {
                    switch c.navigationPresentation {
                    case .default, .master:
                        animated = false
                    case .modal, .flatModal, .standaloneModal, .standaloneFlatModal, .modalInLargeLayout, .modalInCompactLayout:
                        break
                    }
                }
                navigationController.setViewControllers(updatedControllers, animated: animated)
            }
        }
        switch section {
        case .avatar:
            self.controller?.openAvatarForEditing()
        case .edit:
            self.performNavigationButtonAction?(.edit, nil, nil)
        case .proxy:
            self.controller?.push(proxySettingsController(context: self.context))
        case .profile:
            self.controller?.push(PeerInfoScreenImpl(
                context: self.context,
                updatedPresentationData: self.controller?.updatedPresentationData,
                peerId: self.context.account.peerId,
                avatarInitiallyExpanded: false,
                isOpenedFromChat: false,
                reactionSourceMessageId: nil,
                callMessages: [],
                isMyProfile: true,
                profileGiftsContext: self.data?.profileGiftsContext
            ))
        case .stories:
            push(PeerInfoStoryGridScreen(context: self.context, peerId: self.context.account.peerId, scope: .saved))
        case .savedMessages:
            let _ = (self.context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: self.context.account.peerId))
            |> deliverOnMainQueue).startStandalone(next: { [weak self] peer in
                guard let self, let peer = peer else {
                    return
                }
                if let controller = self.controller, let navigationController = controller.navigationController as? NavigationController {
                    self.context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigationController, context: self.context, chatLocation: .peer(peer)))
                }
            })
        case .recentCalls:
            push(CallListController(context: context, mode: .navigation))
        case .contacts:
            push(ContactsController(context: context))
        case .devices:
            let _ = (self.activeSessionsContextAndCount.get()
            |> take(1)
            |> deliverOnMainQueue).startStandalone(next: { [weak self] activeSessionsContextAndCount in
                if let strongSelf = self, let activeSessionsContextAndCount = activeSessionsContextAndCount {
                    let (activeSessionsContext, _, webSessionsContext) = activeSessionsContextAndCount
                    push(recentSessionsController(context: strongSelf.context, activeSessionsContext: activeSessionsContext, webSessionsContext: webSessionsContext, websitesOnly: false))
                }
            })
        case .chatFolders:
            let controller = self.context.sharedContext.makeFilterSettingsController(context: self.context, modal: false, scrollToTags: false, dismissed: nil)
            push(controller)
        case .notificationsAndSounds:
            if let settings = self.data?.globalSettings {
                push(notificationsAndSoundsController(context: self.context, exceptionsList: settings.notificationExceptions))
            }
        case .privacyAndSecurity:
            if let settings = self.data?.globalSettings {
                let _ = (combineLatest(self.blockedPeers.get(), self.hasTwoStepAuth.get())
                |> take(1)
                |> deliverOnMainQueue).startStandalone(next: { [weak self] blockedPeersContext, hasTwoStepAuth in
                    if let strongSelf = self {
                        let loginEmailPattern = strongSelf.twoStepAuthData.get() |> map { data -> String? in
                            return data?.loginEmailPattern
                        }
                        push(privacyAndSecurityController(context: strongSelf.context, initialSettings: settings.privacySettings, updatedSettings: { [weak self] settings in
                            self?.privacySettings.set(.single(settings))
                        }, updatedBlockedPeers: { [weak self] blockedPeersContext in
                            self?.blockedPeers.set(.single(blockedPeersContext))
                        }, updatedHasTwoStepAuth: { [weak self] hasTwoStepAuthValue in
                            self?.hasTwoStepAuth.set(.single(hasTwoStepAuthValue))
                        }, focusOnItemTag: nil, activeSessionsContext: settings.activeSessionsContext, webSessionsContext: settings.webSessionsContext, blockedPeersContext: blockedPeersContext, hasTwoStepAuth: hasTwoStepAuth, loginEmailPattern: loginEmailPattern, updatedTwoStepAuthData: { [weak self] in
                            if let strongSelf = self {
                                strongSelf.twoStepAuthData.set(
                                    strongSelf.context.engine.auth.twoStepAuthData()
                                    |> map(Optional.init)
                                    |> `catch` { _ -> Signal<TwoStepAuthData?, NoError> in
                                        return .single(nil)
                                    }
                                )
                            }
                        }, requestPublicPhotoSetup: { [weak self] completion in
                            if let self {
                                self.controller?.openAvatarForEditing(mode: .fallback, completion: completion)
                            }
                        }, requestPublicPhotoRemove: { [weak self] completion in
                            if let self {
                                self.controller?.openAvatarRemoval(mode: .fallback, completion: completion)
                            }
                        }))
                    }
                })
            }
        case .passwordSetup:
            DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 0.6, execute: { [weak self] in
                guard let self else {
                    return
                }
                let _ = self.context.engine.notices.dismissServerProvidedSuggestion(suggestion: ServerProvidedSuggestion.setupPassword.id).startStandalone()
            })
            
            let controller = self.context.sharedContext.makeSetupTwoFactorAuthController(context: self.context)
            push(controller)
        case .dataAndStorage:
            push(dataAndStorageController(context: self.context))
        case .appearance:
            push(themeSettingsController(context: self.context))
        case .language:
            push(LocalizationListController(context: self.context))
        case .premium:
            let controller = self.context.sharedContext.makePremiumIntroController(context: self.context, source: .settings, forceDark: false, dismissed: nil)
            self.controller?.push(controller)
        case .premiumGift:
            guard let controller = self.controller, !controller.presentAccountFrozenInfoIfNeeded() else {
                return
            }
            let _ = (self.context.account.stateManager.contactBirthdays
            |> take(1)
            |> deliverOnMainQueue).start(next: { [weak self] birthdays in
                guard let self else {
                    return
                }
                let giftsController = self.context.sharedContext.makePremiumGiftController(context: self.context, source: .settings(birthdays), completion: nil)
                self.controller?.push(giftsController)
            })
        case .stickers:
            if let settings = self.data?.globalSettings {
                push(installedStickerPacksController(context: self.context, mode: .general, archivedPacks: settings.archivedStickerPacks, updatedPacks: { [weak self] packs in
                    self?.archivedPacks.set(.single(packs))
                }))
            }
        case .passport:
            self.controller?.push(SecureIdAuthController(context: self.context, mode: .list))
        case .watch:
            push(watchSettingsController(context: self.context))
        case .support:
            // This deployment has no support peer: resolving one returned nil and
            // the old alert ended in a dead OK button. Support lives on the website.
            self.openTalkyWebPage("https://talkytalky.im/help.html")
        case .faq:
            self.openFaq()
        case .tips:
            self.openTips()
        case .phoneNumber:
            guard let controller = self.controller, !controller.presentAccountFrozenInfoIfNeeded() else {
                return
            }
            if case let .user(user) = self.data?.peer, let phoneNumber = user.phone {
                let introController = PrivacyIntroController(context: self.context, mode: .changePhoneNumber(phoneNumber), proceedAction: { [weak self] in
                    if let strongSelf = self, let navigationController = strongSelf.controller?.navigationController as? NavigationController {
                        navigationController.replaceTopController(ChangePhoneNumberController(context: strongSelf.context), animated: true)
                    }
                })
                push(introController)
            }
        case .username:
            guard let controller = self.controller, !controller.presentAccountFrozenInfoIfNeeded() else {
                return
            }
            push(usernameSetupController(context: self.context))
        case .addAccount:
            let _ = (activeAccountsAndPeers(context: context)
            |> take(1)
            |> deliverOnMainQueue
            ).startStandalone(next: { [weak self] accountAndPeer, accountsAndPeers in
                guard let strongSelf = self else {
                    return
                }
                var maximumAvailableAccounts: Int = 3
                if accountAndPeer?.1.isPremium == true && !strongSelf.context.account.testingEnvironment {
                    maximumAvailableAccounts = 4
                }
                var count: Int = 1
                for (accountContext, peer, _) in accountsAndPeers {
                    if !accountContext.account.testingEnvironment {
                        if peer.isPremium {
                            maximumAvailableAccounts = 4
                        }
                        count += 1
                    }
                }
                
                if count >= maximumAvailableAccounts {
                    var replaceImpl: ((ViewController) -> Void)?
                    let controller = PremiumLimitScreen(context: strongSelf.context, subject: .accounts, count: Int32(count), action: {
                        let controller = PremiumIntroScreen(context: strongSelf.context, source: .accounts)
                        replaceImpl?(controller)
                        return true
                    })
                    replaceImpl = { [weak controller] c in
                        controller?.replace(with: c)
                    }
                    if let navigationController = strongSelf.context.sharedContext.mainWindow?.viewController as? NavigationController {
                        navigationController.pushViewController(controller)
                    }
                } else {
                    strongSelf.context.sharedContext.beginNewAuth(testingEnvironment: strongSelf.context.account.testingEnvironment)
                }
            })
        case .logout:
            if case let .user(user) = self.data?.peer, let phoneNumber = user.phone {
                if let controller = self.controller, let navigationController = controller.navigationController as? NavigationController {
                    self.controller?.push(logoutOptionsController(context: self.context, navigationController: navigationController, canAddAccounts: true, phoneNumber: phoneNumber))
                }
            }
        case .rememberPassword:
            let context = self.context
            let controller = TwoFactorDataInputScreen(sharedContext: self.context.sharedContext, engine: .authorized(self.context.engine), mode: .rememberPassword(doneText: self.presentationData.strings.TwoFactorSetup_Done_Action), stateUpdated: { _ in
            }, presentation: .modalInLargeLayout)
            controller.twoStepAuthSettingsController = { configuration in
                return twoStepVerificationUnlockSettingsController(context: context, mode: .access(intro: false, data: .single(TwoStepVerificationUnlockSettingsControllerData.access(configuration: TwoStepVerificationAccessConfiguration(configuration: configuration, password: nil)))))
            }
            controller.passwordRemembered = {
                let _ = context.engine.notices.dismissServerProvidedSuggestion(suggestion: ServerProvidedSuggestion.validatePassword.id).startStandalone()
            }
            push(controller)
        case .emojiStatus:
            self.headerNode.invokeDisplayPremiumIntro()
        case .profileColor:
            self.interaction.editingOpenNameColorSetup()
        case .powerSaving:
            push(energySavingSettingsScreen(context: self.context))
        case .businessSetup:
            guard let controller = self.controller, !controller.presentAccountFrozenInfoIfNeeded() else {
                return
            }
            push(self.context.sharedContext.makeBusinessSetupScreen(context: self.context))
        case .premiumManagement:
            guard let controller = self.controller else {
                return
            }
            let premiumConfiguration = PremiumConfiguration.with(appConfiguration: self.context.currentAppConfiguration.with { $0 })
            let url = premiumConfiguration.subscriptionManagementUrl
            guard !url.isEmpty else {
                return
            }
            self.context.sharedContext.openExternalUrl(context: self.context, urlContext: .generic, url: url, forceExternal: !url.hasPrefix("tg://") && !url.contains("?start="), presentationData: self.context.sharedContext.currentPresentationData.with({$0}), navigationController: controller.navigationController as? NavigationController, dismissInput: {})
        case .stars:
            if let starsContext = self.controller?.starsContext {
                push(self.context.sharedContext.makeStarsTransactionsScreen(context: self.context, starsContext: starsContext))
            }
        case .ton:
            if let tonContext = self.controller?.tonContext {
                push(self.context.sharedContext.makeStarsTransactionsScreen(context: self.context, starsContext: tonContext))
            }
        case .wallet:
            guard WalletConfiguration.with(appConfiguration: self.context.currentAppConfiguration.with { $0 }).isAvailable else {
                self.controller?.present(UndoOverlayController(presentationData: self.presentationData, content: .info(title: nil, text: self.presentationData.strings.Wallet_Unavailable, timeout: nil, customUndoText: nil), action: { _ in return false }), in: .window(.root))
                return
            }
            push(self.context.sharedContext.makeWalletScreen(context: self.context))
        }
    }

    func setupFaqIfNeeded() {
        if !self.didSetCachedFaq {
            self.cachedFaq.set(.single(nil) |> then(cachedFaqInstantPage(context: self.context) |> map(Optional.init)))
            self.didSetCachedFaq = true
        }
    }
    
    func openFaq(anchor: String? = nil) {
        // Talky documents itself: the bundled FAQ instant page is telegram.org's
        // and would both look wrong and describe another product.
        self.openTalkyWebPage("https://talkytalky.im/help/faq.html")
    }
    
    /// Opens one of the product's own web pages (FAQ, features, help).
    ///
    /// Replaces flows that depended on Telegram-side peers and pages - a support
    /// account, a "tips" channel, an instant-view FAQ - none of which exist on a
    /// self-hosted deployment, which is why those rows appeared to do nothing.
    private func openTalkyWebPage(_ url: String) {
        guard let controller = self.controller else {
            return
        }
        self.context.sharedContext.openExternalUrl(
            context: self.context,
            urlContext: .generic,
            url: url,
            forceExternal: false,
            presentationData: self.presentationData,
            navigationController: controller.navigationController as? NavigationController,
            dismissInput: {}
        )
    }
    
    private func openTips() {
        // Settings_TipsUsername is "TelegramTips" upstream; that peer does not
        // exist here, so the old lookup resolved nothing and the row was inert.
        self.openTalkyWebPage("https://talkytalky.im/features.html")
    }

}
