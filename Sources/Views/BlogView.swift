import SwiftUI
import AppKit

/// SKULDSWYRD ONLINE EDITION — the blog studio. Write posts inside the
/// ledger while trading; pull the live session's notes in as raw material;
/// export clean markdown (file or clipboard) for posting anywhere.
/// Mostly for the trader's own eyes — export is the only way out.
struct BlogView: View {
    @EnvironmentObject private var store: SessionStore
    @Environment(\.dismiss) private var dismiss

    @State private var selectedId: String?
    @State private var draftTitle = ""
    @State private var draftBody = ""
    @State private var draftStatus = "draft"
    @State private var confirmDelete = false
    @State private var flash: String?
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.cardBorder)
            HStack(spacing: 0) {
                postList
                    .frame(width: 250)
                Divider().overlay(Theme.cardBorder)
                editor
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 960, height: 660)
        .background(Theme.bg)
        .foregroundColor(Theme.text)
        .onAppear {
            if selectedId == nil, let first = store.blogPosts.first {
                select(first)
            }
        }
        .onDisappear { flushSave() }
        .confirmationDialog(
            "Delete this post?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { deleteSelected() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes the post from the journal. Exported files stay on disk.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Text("SKULDSWYRD ONLINE EDITION")
                .font(Theme.mono.weight(.bold))
                .kerning(1.5)
                .foregroundStyle(Theme.text)
            Text("write it while it's happening")
                .font(Theme.monoSmall)
                .foregroundStyle(Theme.textDim)
            Spacer()
            if let flash {
                Text(flash)
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.green)
                    .transition(.opacity)
            }
            Button {
                flushSave()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.textDim)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Post list

    private var postList: some View {
        VStack(spacing: 0) {
            Button {
                flushSave()
                if let post = store.createBlogPost() { select(post) }
            } label: {
                Label("New post", systemImage: "plus")
                    .font(Theme.mono)
                    .foregroundStyle(Theme.bg)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Theme.green))
            }
            .buttonStyle(.plain)
            .padding(10)

            if store.blogPosts.isEmpty {
                Spacer()
                Text("No posts yet.\nFirst one starts here.")
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.textDim)
                    .multilineTextAlignment(.center)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(store.blogPosts) { post in
                            postRow(post)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
            }
        }
        .background(Theme.card.opacity(0.5))
    }

    private func postRow(_ post: BlogPostRecord) -> some View {
        Button {
            select(post)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(post.isFinal ? Theme.green : Theme.amber)
                        .frame(width: 6, height: 6)
                    Text(post.id == selectedId ? draftTitleOrUntitled : post.displayTitle)
                        .font(Theme.monoSmall.weight(.semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(String(post.updatedAt.prefix(10)))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Theme.textDim)
                    if let tag = sessionTag(post) {
                        Text(tag)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(Theme.cyan)
                            .lineLimit(1)
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(post.id == selectedId ? Theme.inset : Color.clear))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(post.id == selectedId ? Theme.purple.opacity(0.6) : Theme.cardBorder,
                            lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    private var draftTitleOrUntitled: String {
        let t = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Untitled" : t
    }

    private func sessionTag(_ post: BlogPostRecord) -> String? {
        guard let sid = post.sessionId,
              let s = store.allSessions.first(where: { $0.id == sid }) else { return nil }
        return s.displayTitle
    }

    // MARK: - Editor

    @ViewBuilder
    private var editor: some View {
        if selectedId == nil {
            VStack(spacing: 8) {
                Text("Pick a post or start a new one.")
                    .font(Theme.mono)
                    .foregroundStyle(Theme.textDim)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                TextField("Title", text: $draftTitle)
                    .textFieldStyle(.plain)
                    .font(.system(.title2, design: .monospaced).weight(.bold))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .onChange(of: draftTitle) { _, _ in scheduleSave() }

                Divider().overlay(Theme.cardBorder)

                actionBar

                TextEditor(text: $draftBody)
                    .font(Theme.mono)
                    .foregroundStyle(Theme.text)
                    .scrollContentBackground(.hidden)
                    .background(Theme.bg)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .onChange(of: draftBody) { _, _ in scheduleSave() }

                Divider().overlay(Theme.cardBorder)
                footer
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            Button {
                pullSessionNotes()
            } label: {
                Label("Pull session notes", systemImage: "square.and.arrow.down.on.square")
                    .font(Theme.monoSmall)
                    .foregroundStyle(store.session == nil ? Theme.textDim : Theme.cyan)
            }
            .buttonStyle(.plain)
            .disabled(store.session == nil)
            .help(store.session == nil
                  ? "Open a session first — the digest reads the session on screen"
                  : "Append the live session's stats, levels and timeline as markdown")

            Spacer()

            Button {
                toggleStatus()
            } label: {
                Text(draftStatus == "final" ? "FINAL" : "DRAFT")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(draftStatus == "final" ? Theme.green : Theme.amber)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill((draftStatus == "final" ? Theme.green : Theme.amber).opacity(0.12)))
                    .overlay(Capsule().stroke((draftStatus == "final" ? Theme.green : Theme.amber).opacity(0.5)))
            }
            .buttonStyle(.plain)
            .help("Toggle draft / final")

            Button {
                copyMarkdown()
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.text)
            }
            .buttonStyle(.plain)
            .help("Copy the whole post as markdown — paste straight into X or anywhere")

            Button {
                exportMarkdown()
            } label: {
                Label("Export .md", systemImage: "square.and.arrow.up")
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.purple)
            }
            .buttonStyle(.plain)
            .help("Write Blog/exports/<date>-<title>.md and show it in Finder")

            Button {
                confirmDelete = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.red.opacity(0.8))
            }
            .buttonStyle(.plain)
            .help("Delete this post")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Theme.card.opacity(0.5))
    }

    private var footer: some View {
        HStack(spacing: 12) {
            let words = draftBody.split { $0.isWhitespace || $0.isNewline }.count
            Text("\(words) words · \(draftBody.count) chars")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.textDim)
            Spacer()
            Text("autosaves as you type")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.textDim.opacity(0.7))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    // MARK: - Actions

    private func select(_ post: BlogPostRecord) {
        guard post.id != selectedId else { return }
        flushSave()
        selectedId = post.id
        draftTitle = post.title
        draftBody = post.body
        draftStatus = post.status
    }

    private func pullSessionNotes() {
        guard let digest = store.sessionDigestMarkdown() else { return }
        draftBody += (draftBody.isEmpty ? "" : "\n\n") + digest
        scheduleSave()
        showFlash("session notes pulled")
    }

    private func toggleStatus() {
        draftStatus = draftStatus == "final" ? "draft" : "final"
        commit()
    }

    private func copyMarkdown() {
        commit()
        guard let post = currentPost() else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(BlogExporter.composed(post), forType: .string)
        showFlash("copied to clipboard")
    }

    private func exportMarkdown() {
        commit()
        guard let id = selectedId else { return }
        if store.exportBlogPost(id: id) != nil {
            showFlash("exported to Blog/exports/")
        }
    }

    private func deleteSelected() {
        guard let id = selectedId else { return }
        saveTask?.cancel()
        store.deleteBlogPost(id: id)
        selectedId = nil
        draftTitle = ""
        draftBody = ""
        draftStatus = "draft"
        if let next = store.blogPosts.first { select(next) }
    }

    private func currentPost() -> BlogPostRecord? {
        guard let id = selectedId else { return nil }
        return store.blogPosts.first { $0.id == id }
    }

    // MARK: - Autosave (debounced — SQLite write per keystroke is heat)

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { commit() }
        }
    }

    private func commit() {
        saveTask?.cancel()
        guard var post = currentPost() else { return }
        guard post.title != draftTitle || post.body != draftBody
                || post.status != draftStatus else { return }
        post.title = draftTitle
        post.body = draftBody
        post.status = draftStatus
        store.saveBlogPost(post)
    }

    private func flushSave() {
        commit()
    }

    private func showFlash(_ text: String) {
        withAnimation { flash = text }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run { withAnimation { flash = nil } }
        }
    }
}
