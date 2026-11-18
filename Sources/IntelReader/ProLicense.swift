import AppKit
import CryptoKit
import Foundation

extension Notification.Name {
    static let proLicenseDidChange = Notification.Name("EasyReadProLicenseDidChange")
}

struct ProLicensePayload: Codable {
    let v: Int
    let product: String
    let kind: String
    let licenseId: String
    let issuedAt: Int
    let orderId: String?
    let expiresAt: Int?
}

enum ProLicenseError: LocalizedError {
    case invalidFormat
    case invalidSignature
    case unsupported
    case expired
    case configuration

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return L("授权码格式不正确，请完整粘贴以 ERPRO1. 开头的授权码。",
                     "The license code format is invalid. Paste the complete code starting with ERPRO1.")
        case .invalidSignature:
            return L("授权码无效或已被修改。", "The license code is invalid or was modified.")
        case .unsupported:
            return L("这个授权码不适用于当前版本。", "This license code is not supported by this version.")
        case .expired:
            return L("授权码已过期。", "The license code has expired.")
        case .configuration:
            return L("应用内的授权公钥无效，请重新下载安装包。",
                     "The built-in license public key is invalid. Download the app again.")
        }
    }
}

enum ProPurchaseConfig {
    /// Set `EasyReadProPurchaseURL` in Info.plist after creating the 爱发电
    /// product. Keeping it in Info.plist makes the purchase link replaceable
    /// without touching the license verification code.
    static var purchaseURL: URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "EasyReadProPurchaseURL") as? String else {
            return nil
        }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            return nil
        }
        return url
    }
}

final class ProLicenseManager {
    static let shared = ProLicenseManager()

    static let productID = "easyread.pro.webdav"
    static let priceDisplay = "¥8"
    static let purchaseDescription = L("一次购买，永久使用", "One-time purchase, lifetime access")

    private static let licensePrefix = "ERPRO1"
    private static let defaultsKey = "EasyReadProLicense"
    // Ed25519 public key. The matching private key is intentionally kept
    // outside this repository (default: ~/.easyread-license/private.key).
    private static let publicKeyBase64 = "dLfepSvGfcOIPUuBiTjaoWeCcEl4kFCjYh13zZBFWbQ="

    private(set) var payload: ProLicensePayload?
    private(set) var rawLicense: String?

    var isPro: Bool {
        payload != nil
    }

    var licenseIDDescription: String? {
        guard let id = payload?.licenseId, !id.isEmpty else { return nil }
        return String(id.prefix(8)).uppercased()
    }

    private init() {
        guard let stored = UserDefaults.standard.string(forKey: Self.defaultsKey) else {
            return
        }
        switch Self.verify(stored) {
        case .success(let payload):
            self.payload = payload
            self.rawLicense = Self.normalize(stored)
        case .failure:
            UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        }
    }

    @discardableResult
    func activate(_ code: String) -> Result<ProLicensePayload, ProLicenseError> {
        let normalized = Self.normalize(code)
        switch Self.verify(normalized) {
        case .success(let payload):
            self.payload = payload
            self.rawLicense = normalized
            UserDefaults.standard.set(normalized, forKey: Self.defaultsKey)
            NotificationCenter.default.post(name: .proLicenseDidChange, object: self)
            return .success(payload)
        case .failure(let error):
            return .failure(error)
        }
    }

    static func verify(_ code: String) -> Result<ProLicensePayload, ProLicenseError> {
        let normalized = normalize(code)
        let parts = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == Self.licensePrefix else {
            return .failure(.invalidFormat)
        }
        guard let payloadData = base64URLDecode(String(parts[1])),
              let signatureData = base64URLDecode(String(parts[2])) else {
            return .failure(.invalidFormat)
        }
        guard let publicKeyData = Data(base64Encoded: Self.publicKeyBase64),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData) else {
            return .failure(.configuration)
        }
        guard publicKey.isValidSignature(signatureData, for: payloadData) else {
            return .failure(.invalidSignature)
        }
        guard let payload = try? JSONDecoder().decode(ProLicensePayload.self, from: payloadData) else {
            return .failure(.unsupported)
        }
        guard payload.v == 1,
              payload.product == Self.productID,
              payload.kind == "lifetime" else {
            return .failure(.unsupported)
        }
        if let expiresAt = payload.expiresAt,
           expiresAt < Int(Date().timeIntervalSince1970) {
            return .failure(.expired)
        }
        return .success(payload)
    }

    private static func normalize(_ code: String) -> String {
        code.components(separatedBy: .whitespacesAndNewlines).joined()
    }

    private static func base64URLDecode(_ string: String) -> Data? {
        var value = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while value.count % 4 != 0 {
            value.append("=")
        }
        return Data(base64Encoded: value)
    }
}

final class ProUnlockWindowController: NSWindowController, NSTextFieldDelegate {
    var onUnlocked: (() -> Void)?

    private let stateIcon = NSImageView()
    private let stateLabel = NSTextField(labelWithString: "")
    private let priceLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let licenseField = NSTextField()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let purchaseButton = NSButton()
    private let activateButton = NSButton()
    private let closeButton = NSButton()
    private weak var proRootView: NSView?
    private weak var proCardView: NSView?
    private weak var proDividerView: NSView?

    init(appearance: NSAppearance?) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 430),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "EasyRead Pro"
        window.isReleasedWhenClosed = false
        // Follow EasyRead's own day/night theme instead of the system theme.
        window.appearance = appearance
        super.init(window: window)
        buildContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildContent() {
        guard let window, let root = window.contentView else { return }
        root.wantsLayer = true
        proRootView = root

        let titleLabel = NSTextField(labelWithString: "EasyRead Pro")
        titleLabel.font = NSFont.systemFont(ofSize: 20, weight: .semibold)

        let subtitleLabel = NSTextField(wrappingLabelWithString: L(
            "本地书库永久免费；WebDAV 书库 \(ProLicenseManager.priceDisplay) 永久解锁。",
            "The local library stays free; unlock the WebDAV library for \(ProLicenseManager.priceDisplay) once."
        ))
        subtitleLabel.font = NSFont.systemFont(ofSize: 11.5)
        subtitleLabel.textColor = .secondaryLabelColor

        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.borderWidth = 1
        proCardView = card

        stateIcon.imageScaling = .scaleProportionallyDown
        stateLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)

        priceLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        priceLabel.textColor = .secondaryLabelColor
        priceLabel.alignment = .right

        detailLabel.font = NSFont.systemFont(ofSize: 11.5)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 3

        purchaseButton.title = L("购买授权（\(ProLicenseManager.priceDisplay)）",
                                 "Buy a license (\(ProLicenseManager.priceDisplay))")
        purchaseButton.bezelStyle = .rounded
        purchaseButton.image = NSImage(systemSymbolName: "cart", accessibilityDescription: nil)
        purchaseButton.imagePosition = .imageLeading
        purchaseButton.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        purchaseButton.bezelColor = .controlAccentColor
        purchaseButton.target = self
        purchaseButton.action = #selector(purchaseClicked)

        let divider = NSView()
        divider.wantsLayer = true
        proDividerView = divider

        let licenseTitle = NSTextField(labelWithString: L("已有授权码", "Already have a license?"))
        licenseTitle.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        licenseTitle.textColor = .secondaryLabelColor

        licenseField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        licenseField.placeholderString = L("粘贴以 ERPRO1. 开头的授权码",
                                           "Paste a license code starting with ERPRO1.")
        licenseField.lineBreakMode = .byTruncatingMiddle
        licenseField.usesSingleLineMode = true
        licenseField.delegate = self

        activateButton.title = L("激活", "Activate")
        activateButton.bezelStyle = .rounded
        activateButton.image = NSImage(systemSymbolName: "key.fill", accessibilityDescription: nil)
        activateButton.imagePosition = .imageLeading
        activateButton.font = NSFont.systemFont(ofSize: 12)
        activateButton.target = self
        activateButton.action = #selector(activateClicked)
        activateButton.isEnabled = false
        activateButton.keyEquivalent = "\r"
        activateButton.setContentHuggingPriority(.required, for: .horizontal)
        activateButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        closeButton.title = ""
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.image = NSImage(
            systemSymbolName: "xmark.circle.fill",
            accessibilityDescription: L("关闭", "Close")
        )
        closeButton.contentTintColor = NSColor(calibratedWhite: 0.55, alpha: 1)
        closeButton.toolTip = L("关闭（Esc）", "Close (Esc)")
        closeButton.keyEquivalent = "\u{1b}"
        closeButton.target = self
        closeButton.action = #selector(closeClicked)

        let footerLabel = NSTextField(wrappingLabelWithString: L(
            "授权码在本机离线验证，不需要登录。购买与激活只解锁 WebDAV 书库；本地书库、导入和阅读进度始终免费。",
            "License codes are verified offline on this Mac and need no account. Buying Pro only unlocks the WebDAV library; the local library, imports, and reading progress stay free."
        ))
        footerLabel.font = NSFont.systemFont(ofSize: 10)
        footerLabel.textColor = .secondaryLabelColor

        func add(_ view: NSView, to parent: NSView) {
            view.translatesAutoresizingMaskIntoConstraints = false
            parent.addSubview(view)
        }

        add(titleLabel, to: root)
        add(subtitleLabel, to: root)
        add(closeButton, to: root)
        add(card, to: root)
        [stateIcon, stateLabel, priceLabel, detailLabel, purchaseButton,
         divider, licenseTitle, licenseField, activateButton, statusLabel].forEach { add($0, to: card) }
        add(footerLabel, to: root)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 26),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -52),
            closeButton.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            closeButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            closeButton.widthAnchor.constraint(equalToConstant: 24),
            closeButton.heightAnchor.constraint(equalToConstant: 24),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            subtitleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 26),
            subtitleLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -26),

            card.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 18),
            card.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 26),
            card.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -26),

            stateIcon.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
            stateIcon.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            stateIcon.widthAnchor.constraint(equalToConstant: 22),
            stateIcon.heightAnchor.constraint(equalToConstant: 22),
            stateLabel.centerYAnchor.constraint(equalTo: stateIcon.centerYAnchor),
            stateLabel.leadingAnchor.constraint(equalTo: stateIcon.trailingAnchor, constant: 9),
            stateLabel.trailingAnchor.constraint(lessThanOrEqualTo: priceLabel.leadingAnchor, constant: -12),

            priceLabel.centerYAnchor.constraint(equalTo: stateIcon.centerYAnchor),
            priceLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),

            detailLabel.topAnchor.constraint(equalTo: stateIcon.bottomAnchor, constant: 8),
            detailLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            detailLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),

            purchaseButton.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 14),
            purchaseButton.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            purchaseButton.heightAnchor.constraint(equalToConstant: 30),
            purchaseButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),

            divider.topAnchor.constraint(equalTo: purchaseButton.bottomAnchor, constant: 16),
            divider.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            divider.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            divider.heightAnchor.constraint(equalToConstant: 1),

            licenseTitle.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 14),
            licenseTitle.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            licenseTitle.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -18),

            licenseField.topAnchor.constraint(equalTo: licenseTitle.bottomAnchor, constant: 6),
            licenseField.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            licenseField.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            licenseField.heightAnchor.constraint(equalToConstant: 26),

            activateButton.topAnchor.constraint(equalTo: licenseField.bottomAnchor, constant: 10),
            activateButton.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            activateButton.heightAnchor.constraint(equalToConstant: 26),
            activateButton.widthAnchor.constraint(equalToConstant: 104),

            statusLabel.centerYAnchor.constraint(equalTo: activateButton.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: activateButton.trailingAnchor, constant: 10),
            statusLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            statusLabel.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18),

            footerLabel.topAnchor.constraint(equalTo: card.bottomAnchor, constant: 12),
            footerLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 26),
            footerLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -26),
            footerLabel.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -16)
        ])

        refreshLayerColors()
        refreshState()
        root.layoutSubtreeIfNeeded()
        let fittingHeight = root.fittingSize.height
        if fittingHeight > 300 {
            window.setContentSize(NSSize(width: 560, height: fittingHeight))
        }
    }

    func applyAppearance(_ appearance: NSAppearance?) {
        window?.appearance = appearance
        refreshLayerColors()
    }

    private func refreshLayerColors() {
        let appearance = window?.appearance ?? NSApp.effectiveAppearance
        appearance.performAsCurrentDrawingAppearance { [weak self] in
            guard let self else { return }
            self.proRootView?.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            self.proCardView?.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            self.proCardView?.layer?.borderColor = NSColor.separatorColor.cgColor
            self.proDividerView?.layer?.backgroundColor = NSColor.separatorColor.cgColor
        }
    }

    private func refreshState() {
        let manager = ProLicenseManager.shared
        if manager.isPro {
            stateIcon.image = NSImage(
                systemSymbolName: "lock.open.fill",
                accessibilityDescription: L("已解锁", "Unlocked")
            )
            stateIcon.contentTintColor = .systemGreen
            stateLabel.stringValue = L("WebDAV 书库已解锁", "WebDAV library unlocked")
            stateLabel.textColor = .systemGreen
            priceLabel.stringValue = L("永久授权", "Lifetime")
            if let id = manager.licenseIDDescription {
                detailLabel.stringValue = L("授权 ID：\(id)… · 已在本机离线验证",
                                            "License ID: \(id)… · Verified offline on this Mac")
            } else {
                detailLabel.stringValue = L("已在本机离线验证。", "Verified offline on this Mac.")
            }
            purchaseButton.isHidden = true
            licenseField.placeholderString = L("粘贴新的授权码可替换当前授权",
                                               "Paste a new code to replace the current license")
        } else {
            stateIcon.image = NSImage(
                systemSymbolName: "lock.fill",
                accessibilityDescription: L("未解锁", "Locked")
            )
            stateIcon.contentTintColor = .systemOrange
            stateLabel.stringValue = L("WebDAV 书库未解锁", "WebDAV library locked")
            stateLabel.textColor = .labelColor
            priceLabel.stringValue = L("\(ProLicenseManager.priceDisplay) · 永久",
                                       "\(ProLicenseManager.priceDisplay) · Lifetime")
            detailLabel.stringValue = L(
                "购买后会把授权码发给你；粘贴到下面即可解锁，不需要注册账号。",
                "After purchase you will receive a license code. Paste it below to unlock; no account is required."
            )
            purchaseButton.isHidden = false
            licenseField.placeholderString = L("粘贴以 ERPRO1. 开头的授权码",
                                               "Paste a license code starting with ERPRO1.")
        }
        activateButton.isEnabled = !licenseField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func setStatus(_ text: String, color: NSColor) {
        statusLabel.stringValue = text
        statusLabel.textColor = color
        statusLabel.toolTip = text
    }

    @objc private func purchaseClicked() {
        guard let url = ProPurchaseConfig.purchaseURL else {
            let alert = NSAlert()
            alert.messageText = L("购买链接尚未配置", "Purchase link is not configured")
            alert.informativeText = L(
                "开发者还没有填写爱发电商品链接。请暂时直接联系开发者获取授权码，或稍后重新下载已配置链接的版本。",
                "The developer has not added the 爱发电 product link yet. Contact the developer for a code, or download a build with the purchase link configured."
            )
            alert.alertStyle = .informational
            alert.addButton(withTitle: L("好", "OK"))
            if let window {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
            return
        }
        NSWorkspace.shared.open(url)
        setStatus(L("已在浏览器打开购买页面；付款后把收到的授权码粘贴到下面。",
                    "The purchase page is open in your browser. Paste the code you receive below."),
                  color: .secondaryLabelColor)
    }

    @objc private func activateClicked() {
        let code = licenseField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else {
            setStatus(L("请先粘贴授权码。", "Paste a license code first."), color: .systemOrange)
            return
        }
        switch ProLicenseManager.shared.activate(code) {
        case .success:
            licenseField.stringValue = ""
            refreshState()
            setStatus(L("激活成功。关闭此窗口后，在书库菜单中选择 WebDAV 书库。",
                        "Activated. Close this window, then choose WebDAV Library from the library menu."),
                      color: .systemGreen)
            onUnlocked?()
        case .failure(let error):
            setStatus(error.localizedDescription, color: .systemRed)
        }
    }

    @objc private func closeClicked() {
        closeSheet()
    }

    private func closeSheet() {
        guard let window else { return }
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            window.close()
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        let hasText = !licenseField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        activateButton.isEnabled = hasText
        if !statusLabel.stringValue.isEmpty {
            setStatus("", color: .secondaryLabelColor)
        }
    }
}
