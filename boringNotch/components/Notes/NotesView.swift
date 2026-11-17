//
//  NotesView.swift
//  boringNotch
//

import Carbon.HIToolbox
import Defaults
import SwiftUI

struct NotesView: View {
    @Default(.notes) private var notes
    private let maxNotes = 4

    var body: some View {
        HStack(spacing: 8) {
            VStack(spacing: 8) {
                ForEach(Array(stride(from: 0, to: notes.count, by: 2)), id: \.self) { row in
                    HStack(spacing: 8) {
                        noteCard(row)
                        if row + 1 < notes.count {
                            noteCard(row + 1)
                        } else {
                            Color.clear
                        }
                    }
                }
            }

            if notes.count < maxNotes {
                Button {
                    withAnimation(.smooth) { notes.append(Data()) }
                } label: {
                    Image(systemName: "plus")
                        .frame(maxHeight: .infinity)
                        .frame(width: 28)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.gray)
            }
        }
        .padding(.top, 4)
    }

    private func noteCard(_ index: Int) -> some View {
        // Bounds-checked binding: the editor can read its binding after a removal, before ForEach rebuilds.
        let rtf = Binding(
            get: { index < notes.count ? notes[index] : Data() },
            set: { if index < notes.count { notes[index] = $0 } }
        )
        return RichNoteEditor(rtf: rtf)
            .padding(6)
            .overlay(alignment: .topLeading) {
                if rtf.wrappedValue.isEmpty {
                    Text("Note \(index + 1)")
                        .font(.system(size: 12))
                        .foregroundStyle(.gray)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topTrailing) {
                if notes.count > 1 {
                    Button {
                        withAnimation(.smooth) { _ = notes.remove(at: index) }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.gray)
                    .padding(4)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08)))
    }
}

/// NSTextView-backed note editor: SwiftUI's TextEditor has no rich text before macOS 26.
/// ⌘B toggles bold, ⌘U toggles underline. Content is stored as RTF.
private struct RichNoteEditor: NSViewRepresentable {
    @Binding var rtf: Data

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NoteTextView(frame: .zero)
        textView.isRichText = true
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 12)
        textView.textColor = .white
        textView.insertionPointColor = .white
        textView.textContainerInset = .zero
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = context.coordinator

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        // Reload only on outside changes (e.g. a note was removed and indices shifted), not our own edits.
        guard rtf != context.coordinator.lastRTF,
              let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.lastRTF = rtf
        textView.textStorage?.setAttributedString(NSAttributedString(rtf: rtf, documentAttributes: nil) ?? NSAttributedString())
        if rtf.isEmpty {
            // Empty storage carries no attributes; keep new text white 12pt on the dark notch.
            textView.typingAttributes = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.white]
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichNoteEditor
        var lastRTF: Data?

        init(_ parent: RichNoteEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let storage = (notification.object as? NSTextView)?.textStorage else { return }
            let range = NSRange(location: 0, length: storage.length)
            let data = storage.length == 0 ? Data() :
                (try? storage.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])) ?? Data()
            lastRTF = data
            parent.rtf = data
        }
    }
}

/// The notch app has no menu bar, so ⌘B / ⌘U are handled here instead of the Format menu.
private final class NoteTextView: NSTextView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        // Non-Latin input (e.g. 2-Set Korean) sends ⌘B as "ㅠ" and ⌘U as "ㅕ", so fall back to the key
        // position there. ASCII layouts (incl. Dvorak) keep matching by character.
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let isASCII = chars.unicodeScalars.allSatisfy(\.isASCII)
        func matches(_ char: String, _ keyCode: Int) -> Bool {
            isASCII ? chars == char : Int(event.keyCode) == keyCode
        }
        if matches("b", kVK_ANSI_B) { toggleBold(); return true }
        if matches("u", kVK_ANSI_U) { underline(nil); return true }
        return super.performKeyEquivalent(with: event)
    }

    private func toggleBold() {
        let fontManager = NSFontManager.shared
        func toggled(_ font: NSFont, makeBold: Bool) -> NSFont {
            makeBold ? fontManager.convert(font, toHaveTrait: .boldFontMask)
                     : fontManager.convert(font, toNotHaveTrait: .boldFontMask)
        }
        let isBold = { (font: NSFont) in fontManager.traits(of: font).contains(.boldFontMask) }
        let fallback = NSFont.systemFont(ofSize: 12)

        let range = selectedRange()
        if range.length == 0 {
            let font = typingAttributes[.font] as? NSFont ?? fallback
            typingAttributes[.font] = toggled(font, makeBold: !isBold(font))
            return
        }

        guard let storage = textStorage, shouldChangeText(in: range, replacementString: nil) else { return }
        var allBold = true
        storage.enumerateAttribute(.font, in: range) { value, _, _ in
            if !isBold(value as? NSFont ?? fallback) { allBold = false }
        }
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            storage.addAttribute(.font, value: toggled(value as? NSFont ?? fallback, makeBold: !allBold), range: subrange)
        }
        storage.endEditing()
        didChangeText()
    }
}

#Preview {
    NotesView()
        .frame(width: 600, height: 140)
        .padding()
        .background(.black)
        .preferredColorScheme(.dark)
}
