import Foundation
import UIKit
import AsyncDisplayKit

public enum ActionSheetButtonColor {
    case accent
    case destructive
    case disabled
}

public enum ActionSheetButtonFont {
    case `default`
    case bold
}

public class ActionSheetButtonItem: ActionSheetItem {
    public let title: String
    public let subtitle: String?
    public let color: ActionSheetButtonColor
    public let font: ActionSheetButtonFont
    public let enabled: Bool
    public let action: () -> Void

    public init(title: String, subtitle: String? = nil, color: ActionSheetButtonColor = .accent, font: ActionSheetButtonFont = .default, enabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.color = color
        self.font = font
        self.enabled = enabled
        self.action = action
    }
    
    public func node(theme: ActionSheetControllerTheme) -> ActionSheetItemNode {
        let node = ActionSheetButtonNode(theme: theme)
        node.setItem(self)
        return node
    }
    
    public func updateNode(_ node: ActionSheetItemNode) {
        guard let node = node as? ActionSheetButtonNode else {
            assertionFailure()
            return
        }
        
        node.setItem(self)
        node.requestLayoutUpdate()
    }
}

public class ActionSheetButtonNode: ActionSheetItemNode {
    private let theme: ActionSheetControllerTheme
    
    private let defaultFont: UIFont
    private let boldFont: UIFont
    
    private var item: ActionSheetButtonItem?
    
    private let button: HighlightTrackingButton
    private let label: ImmediateTextNode
    private let subtitleLabel: ImmediateTextNode
    private let accessibilityArea: AccessibilityAreaNode
    
    private var pointerInteraction: PointerInteraction?
        
    override public init(theme: ActionSheetControllerTheme) {
        self.theme = theme
        
        self.defaultFont = Font.regular(floor(theme.baseFontSize * 20.0 / 17.0))
        self.boldFont = Font.medium(floor(theme.baseFontSize * 20.0 / 17.0))
        
        self.button = HighlightTrackingButton()
        self.button.isAccessibilityElement = false
        
        self.label = ImmediateTextNode()
        self.label.isUserInteractionEnabled = false
        self.label.maximumNumberOfLines = 1
        self.label.displaysAsynchronously = false
        self.label.truncationType = .end

        self.subtitleLabel = ImmediateTextNode()
        self.subtitleLabel.isUserInteractionEnabled = false
        self.subtitleLabel.isAccessibilityElement = false
        self.subtitleLabel.maximumNumberOfLines = 2
        self.subtitleLabel.displaysAsynchronously = false
        self.subtitleLabel.truncationType = .end

        self.accessibilityArea = AccessibilityAreaNode()
        
        super.init(theme: theme)
        
        self.view.addSubview(self.button)
        // VoiceOver reads the item through `accessibilityArea`; the touch button under it would be a second, unnamed
        // element.
        self.button.isAccessibilityElement = false
        self.button.accessibilityElementsHidden = true
        
        self.label.isUserInteractionEnabled = false
        self.addSubnode(self.label)
        self.addSubnode(self.subtitleLabel)

        self.addSubnode(self.accessibilityArea)
        
        self.button.highligthedChanged = { [weak self] highlighted in
            if let strongSelf = self {
                strongSelf.setHighlighted(highlighted, animated: true)
            }
        }
        
        self.button.addTarget(self, action: #selector(self.buttonPressed), for: .touchUpInside)
        self.accessibilityArea.activate = { [weak self] in
            self?.buttonPressed()
            return true
        }
    }
    
    override func setHighlighted(_ highlighted: Bool, animated: Bool) {
        self.highlightedUpdated(highlighted)
        if highlighted {
            self.backgroundNode.backgroundColor = self.theme.itemHighlightedBackgroundColor
        } else {
            if animated {
                UIView.animate(withDuration: 0.3, animations: {
                    self.backgroundNode.backgroundColor = self.theme.itemBackgroundColor
                })
            } else {
                self.backgroundNode.backgroundColor = self.theme.itemBackgroundColor
            }
        }
    }
    
    override func performAction() {
        self.buttonPressed()
    }
    
    public override func didLoad() {
        super.didLoad()
        
        self.pointerInteraction = PointerInteraction(node: self, style: .hover, willEnter: { [weak self] in
            if let strongSelf = self {
                strongSelf.setHighlighted(true, animated: false)
            }
        }, willExit: { [weak self] in
            if let strongSelf = self {
                strongSelf.setHighlighted(false, animated: false)
            }
        })
    }
    
    func setItem(_ item: ActionSheetButtonItem) {
        self.item = item
        
        let textColor: UIColor
        let textFont: UIFont
        switch item.color {
            case .accent:
                textColor = self.theme.standardActionTextColor
            case .destructive:
                textColor = self.theme.destructiveActionTextColor
            case .disabled:
                textColor = self.theme.disabledActionTextColor
        }
        switch item.font {
            case .default:
                textFont = Font.regular(floor(theme.baseFontSize * 20.0 / 17.0))
            case .bold:
                textFont = Font.medium(floor(theme.baseFontSize * 20.0 / 17.0))
        }
        self.label.attributedText = NSAttributedString(string: item.title, font: textFont, textColor: textColor)
        self.label.isAccessibilityElement = false

        if let subtitle = item.subtitle, !subtitle.isEmpty {
            self.subtitleLabel.attributedText = NSAttributedString(string: subtitle, font: Font.regular(floor(self.theme.baseFontSize * 14.0 / 17.0)), textColor: self.theme.secondaryTextColor)
            self.subtitleLabel.isHidden = false
            self.accessibilityArea.accessibilityLabel = "\(item.title), \(subtitle)"
        } else {
            self.subtitleLabel.attributedText = nil
            self.subtitleLabel.isHidden = true
            self.accessibilityArea.accessibilityLabel = item.title
        }

        self.button.isEnabled = item.enabled
        
        var accessibilityTraits: UIAccessibilityTraits = [.button]
        if !item.enabled {
            accessibilityTraits.insert(.notEnabled)
        }
        self.accessibilityArea.accessibilityTraits = accessibilityTraits
    }
    
    public override func updateLayout(constrainedSize: CGSize, transition: ContainedViewLayoutTransition) -> CGSize {
        let maxTextWidth = max(1.0, constrainedSize.width - 20.0)
        let labelSize = self.label.updateLayout(CGSize(width: maxTextWidth, height: .greatestFiniteMagnitude))
        let hasSubtitle = !self.subtitleLabel.isHidden && self.subtitleLabel.attributedText != nil
        var subtitleSize = CGSize()
        if hasSubtitle {
            subtitleSize = self.subtitleLabel.updateLayout(CGSize(width: maxTextWidth, height: .greatestFiniteMagnitude))
        }
        let contentHeight = labelSize.height + (hasSubtitle ? subtitleSize.height + 2.0 : 0.0)
        let size = CGSize(width: constrainedSize.width, height: max(57.0, ceil(contentHeight) + 20.0))

        self.button.frame = CGRect(origin: CGPoint(), size: size)

        if hasSubtitle {
            let totalHeight = labelSize.height + 2.0 + subtitleSize.height
            let top = floorToScreenPixels((size.height - totalHeight) / 2.0)
            self.label.frame = CGRect(origin: CGPoint(x: floorToScreenPixels((size.width - labelSize.width) / 2.0), y: top), size: labelSize)
            self.subtitleLabel.frame = CGRect(origin: CGPoint(x: floorToScreenPixels((size.width - subtitleSize.width) / 2.0), y: top + labelSize.height + 2.0), size: subtitleSize)
        } else {
            self.label.frame = CGRect(origin: CGPoint(x: floorToScreenPixels((size.width - labelSize.width) / 2.0), y: floorToScreenPixels((size.height - labelSize.height) / 2.0)), size: labelSize)
            self.subtitleLabel.frame = CGRect()
        }
        self.accessibilityArea.frame = CGRect(origin: CGPoint(), size: size)

        self.updateInternalLayout(size, constrainedSize: constrainedSize)
        return size
    }
    
    @objc func buttonPressed() {
        if let item = self.item {
            item.action()
        }
    }
}
