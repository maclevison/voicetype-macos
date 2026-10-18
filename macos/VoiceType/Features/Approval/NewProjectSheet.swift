import Core
import SwiftUI

/// "Novo projeto": a kebab-case slug, checked live for format and against
/// the vault's projects, and a short description for `index.md` and the
/// README. The project is only written to the vault with the meeting.
struct NewProjectSheet: View {
    let existing: [OKProject]
    let create: (_ slug: String, _ description: String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var slug = ""
    @State private var description = ""
    @State private var error: String?
    @State private var isCreating = false

    private var slugProblem: String? {
        guard !slug.isEmpty else { return nil }
        if !OKSlug.isValid(slug) { return ApprovalStrings.invalidSlug }
        if existing.contains(where: { $0.slug == slug }) { return ApprovalStrings.slugTaken }
        return nil
    }

    private var canCreate: Bool {
        !slug.isEmpty && slugProblem == nil && !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isCreating
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ApprovalStrings.newProjectTitle).font(.headline)
            TextField(ApprovalStrings.slugField, text: $slug)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
            if let slugProblem {
                Text(slugProblem).font(.caption).foregroundStyle(.red)
            }
            TextField(ApprovalStrings.descriptionField, text: $description)
                .textFieldStyle(.roundedBorder)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(ApprovalStrings.cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(ApprovalStrings.create) { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func submit() {
        isCreating = true
        Task {
            defer { isCreating = false }
            do {
                try await create(slug, description)
                dismiss()
            } catch let failure as OKApprovalSession.ProjectError {
                error = ApprovalStrings.projectError(failure)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
