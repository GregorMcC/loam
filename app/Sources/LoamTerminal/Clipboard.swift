// Parts of this file are ported from Ghostty's macOS host layer
// (macos/Sources/Ghostty/Ghostty.App.swift, Ghostty.ClipboardConfirmationRequest.swift,
// GhosttyPackage.swift, and Helpers/Extensions/NSPasteboard+Extension.swift)
// at the commit in ghostty.pin.
//
// MIT License
//
// Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import AppKit
import GhosttyKit
import UniformTypeIdentifiers

/// One representation of clipboard contents.
struct ClipboardContent {
    let mime: String
    let data: Data

    init(mime: String, data: Data) {
        self.mime = mime
        self.data = data
    }

    init?(_ content: ghostty_clipboard_content_s) {
        guard let mime = content.mime, let bytes = content.data else { return nil }
        self.mime = String(cString: mime)
        self.data = content.len > 0 ? Data(bytes: bytes, count: content.len) : Data()
    }

    /// Completes a clipboard read. The C copies live only for the call.
    static func complete(
        _ surface: ghostty_surface_t,
        contents: [ClipboardContent],
        available: [String],
        state: UnsafeMutableRawPointer?,
        confirmed: Bool = false
    ) {
        var strings: [UnsafeMutablePointer<CChar>] = []
        var buffers: [UnsafeMutableRawPointer] = []
        defer {
            strings.forEach { free($0) }
            buffers.forEach { $0.deallocate() }
        }
        var cContents: [ghostty_clipboard_content_s] = []
        for entry in contents {
            guard let mime = strdup(entry.mime) else { continue }
            strings.append(mime)
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: max(entry.data.count, 1), alignment: 1)
            buffers.append(buffer)
            entry.data.withUnsafeBytes { source in
                if let base = source.baseAddress { buffer.copyMemory(from: base, byteCount: source.count) }
            }
            cContents.append(ghostty_clipboard_content_s(
                mime: mime, data: buffer.assumingMemoryBound(to: CChar.self), len: entry.data.count))
        }
        var cAvailable: [UnsafePointer<CChar>?] = []
        for mime in available {
            guard let copy = strdup(mime) else { continue }
            strings.append(copy)
            cAvailable.append(UnsafePointer(copy))
        }
        cContents.withUnsafeBufferPointer { contentsBuffer in
            cAvailable.withUnsafeBufferPointer { availableBuffer in
                var done = ghostty_clipboard_complete_s(
                    contents: contentsBuffer.baseAddress, contents_len: contentsBuffer.count,
                    available: availableBuffer.baseAddress, available_len: availableBuffer.count,
                    confirmed: confirmed, remember: false)
                ghostty_surface_complete_clipboard_request(surface, &done, state)
            }
        }
    }
}

/// A clipboard request that waits for your answer: an unsafe paste, or a
/// program that reads or writes the clipboard (OSC 52 or the Kitty protocol).
/// The pane shows it as a sheet. It completes exactly once.
@MainActor
public final class ClipboardConfirmation {
    public enum Kind: Sendable, Equatable {
        case paste, osc52Read, osc52Write

        init?(_ request: ghostty_clipboard_request_e) {
            switch request {
            case GHOSTTY_CLIPBOARD_REQUEST_PASTE: self = .paste
            case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ, GHOSTTY_CLIPBOARD_REQUEST_KITTY_READ: self = .osc52Read
            case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE, GHOSTTY_CLIPBOARD_REQUEST_KITTY_WRITE: self = .osc52Write
            default: return nil
            }
        }
    }

    public let kind: Kind
    /// The text that the prompt shows.
    public let preview: String
    public private(set) var isAnswered = false

    private var completion: ((Bool) -> Void)?
    /// The pane clears its pending request here.
    var onAnswered: (() -> Void)?
    private weak var sheetParent: NSWindow?
    private weak var sheet: NSWindow?

    init(kind: Kind, preview: String, completion: @escaping (Bool) -> Void) {
        self.kind = kind
        self.preview = preview
        self.completion = completion
    }

    /// Answers the request and closes the sheet, if it shows.
    public func respond(_ confirmed: Bool) {
        guard !isAnswered else { return }
        isAnswered = true
        if let sheet, let sheetParent { sheetParent.endSheet(sheet) }
        let completion = self.completion
        self.completion = nil
        completion?(confirmed)
        onAnswered?()
        onAnswered = nil
    }

    var texts: (message: String, info: String, yes: String, no: String) {
        switch kind {
        case .paste:
            ("Paste this text?", "The text can run commands in this pane.", "Paste", "Cancel")
        case .osc52Read:
            ("Let a program read the clipboard?",
             "A program in this pane asks to read the clipboard. The clipboard holds the text below.", "Allow", "Deny")
        case .osc52Write:
            ("Let a program write to the clipboard?",
             "A program in this pane asks to put the text below on the clipboard.", "Allow", "Deny")
        }
    }

    /// Shows the request as a sheet on the window.
    func show(on window: NSWindow) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        let texts = self.texts
        alert.messageText = texts.message
        alert.informativeText = texts.info
        alert.addButton(withTitle: texts.yes)
        alert.addButton(withTitle: texts.no)
        // Return answers no. A stray Return must not paste commands.
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 140))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.string = String(preview.prefix(10_000))
        text.autoresizingMask = [.width]
        scroll.documentView = text
        alert.accessoryView = scroll

        sheetParent = window
        sheet = alert.window
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated { self?.respond(response == .alertFirstButtonReturn) }
        }
    }
}

extension NSPasteboard.PasteboardType {
    init?(mimeType: String) {
        if mimeType == "text/plain" {
            self = .string
            return
        }
        guard let type = UTType(mimeType: mimeType) else {
            self.init(mimeType)
            return
        }
        self.init(type.identifier)
    }
}

extension NSPasteboard {
    /// The pasteboard as one string. A copied file becomes its escaped path.
    func loamString() -> String? {
        let strings = (pasteboardItems ?? []).compactMap { item -> String? in
            if let plist = item.propertyList(forType: .fileURL),
               let url = NSURL(pasteboardPropertyList: plist, ofType: .fileURL) as URL?, url.isFileURL {
                return shellEscaped(url.path)
            }
            return item.string(forType: .string)
        }
        return strings.isEmpty ? nil : strings.joined(separator: " ")
    }

    private var fileURLs: [URL] {
        (pasteboardItems ?? []).compactMap { item in
            guard let plist = item.propertyList(forType: .fileURL),
                  let url = NSURL(pasteboardPropertyList: plist, ofType: .fileURL) as URL?, url.isFileURL else { return nil }
            return url
        }
    }

    func loamData(forMime mime: String) -> Data? {
        switch mime {
        case "text/plain":
            return loamString().map { Data($0.utf8) }
        case "text/uri-list":
            let urls = fileURLs
            return urls.isEmpty ? nil : Data(urls.map { $0.absoluteString + "\r\n" }.joined().utf8)
        default:
            guard let type = NSPasteboard.PasteboardType(mimeType: mime) else { return nil }
            return data(forType: type)
        }
    }

    /// The MIME types on the pasteboard. It reads only the declared types.
    func loamAvailableMimes() -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        let declared = types ?? []
        let mimeType: (NSPasteboard.PasteboardType) -> String? = { type in
            guard let mime = UTType(type.rawValue)?.preferredMIMEType else { return nil }
            return mime == "text/plain;charset=utf-8" ? "text/plain" : mime
        }
        let hasFile = declared.contains(.fileURL)
        if hasFile || declared.contains(where: { mimeType($0) == "text/plain" }) {
            result.append("text/plain")
            seen.insert("text/plain")
        }
        if hasFile {
            result.append("text/uri-list")
            seen.insert("text/uri-list")
        }
        for type in declared {
            guard let mime = mimeType(type), seen.insert(mime).inserted else { continue }
            result.append(mime)
        }
        return result
    }
}

/// Escapes the characters that a shell treats as special, with backslashes.
func shellEscaped(_ text: String) -> String {
    let special = Set("\\ ()[]{}<>\"'`!#$&;|*?\t")
    var result = ""
    for character in text {
        if special.contains(character) { result.append("\\") }
        result.append(character)
    }
    return result
}
