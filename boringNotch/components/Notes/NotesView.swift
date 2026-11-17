//
//  NotesView.swift
//  boringNotch
//

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
                    withAnimation(.smooth) { notes.append("") }
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
        // Bounds-checked binding: TextEditor can read its binding after a removal, before ForEach rebuilds.
        let text = Binding(
            get: { index < notes.count ? notes[index] : "" },
            set: { if index < notes.count { notes[index] = $0 } }
        )
        return TextEditor(text: text)
            .font(.system(size: 12))
            .scrollContentBackground(.hidden)
            .padding(6)
            .overlay(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
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

#Preview {
    NotesView()
        .frame(width: 600, height: 140)
        .padding()
        .background(.black)
        .preferredColorScheme(.dark)
}
