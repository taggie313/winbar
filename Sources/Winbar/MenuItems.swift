import AppKit

// The other half of `MenuShape`: turning the menu's shape into NSMenuItems.
//
// This used to be a private method of AppDelegate, and an AppDelegate can't be made in a test: it puts
// an icon in the menu bar as it is created. So nothing checked it. MenuShapeTests proved the value
// right while the lines that tick Launch at Login and set the modifier masks could be deleted with
// every test still green, and the menu bar would have lost the tick and Force Stop's ⌥ (and with it
// Force Stop's place as Shut Down's alternate). Out here it needs only the object its actions go to,
// how to name those actions, and the Choose VM submenu, so MenuItemsTests builds real NSMenuItems
// with it and reads them back.

extension NSMenuItem {
    /// The NSMenuItem `spec` describes. An item with an action sends it to `target`, as `selector`
    /// names it; the Choose VM item opens `chooseMenu`, which the caller fills when it is opened.
    ///
    /// Every field of `MenuItem` has its line here, and MenuItemsTests reads each one back: a line lost
    /// here changes the menu bar without changing the value MenuShapeTests pins.
    static func make(_ spec: MenuItemSpec, target: AnyObject, selector: (MenuAction) -> Selector,
                     chooseMenu: NSMenu) -> NSMenuItem {
        switch spec {
        case .header(let title):
            return NSMenuItem.sectionHeader(title: title)
        case .separator:
            return .separator()
        case .status(let title):
            let line = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            line.isEnabled = false
            return line
        case .item(let spec):
            let item = NSMenuItem(title: spec.title, action: spec.action.map(selector), keyEquivalent: spec.key)
            if spec.action != nil { item.target = target }
            item.isEnabled = spec.enabled
            var mask: NSEvent.ModifierFlags = []
            if spec.modifiers.contains(.command) { mask.insert(.command) }
            if spec.modifiers.contains(.option) { mask.insert(.option) }
            item.keyEquivalentModifierMask = mask
            item.isAlternate = spec.isAlternate
            item.state = spec.checked ? .on : .off
            item.toolTip = spec.toolTip
            // The whole VM as UTM listed it, for the action to read its id back from.
            if case .chooseVM(let vm) = spec.action { item.representedObject = vm }
            switch spec.submenu {
            case .chooseVM: item.submenu = chooseMenu
            case nil: break
            }
            return item
        }
    }
}

extension NSMenu {
    /// Replaces the items with the ones `specs` describe, built by `NSMenuItem.make`.
    ///
    /// Returns the status line, when there is one, because it is the one item that changes while the
    /// menu is open: `render()` keeps this reference and retitles it as a start or a readiness probe
    /// moves on.
    @discardableResult
    func fill(with specs: [MenuItemSpec], target: AnyObject, selector: (MenuAction) -> Selector,
              chooseMenu: NSMenu) -> NSMenuItem? {
        removeAllItems()
        var statusLine: NSMenuItem?
        for spec in specs {
            let item = NSMenuItem.make(spec, target: target, selector: selector, chooseMenu: chooseMenu)
            if case .status = spec { statusLine = item }
            addItem(item)
        }
        return statusLine
    }
}
