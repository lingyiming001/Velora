import SwiftUI

struct SearchPanel: View {
    @ObservedObject var model: WorkspaceModel
    @Binding var isPresented: Bool
    @State private var query = ""
    @State private var results: [Page] = []
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L10n.tr("搜索页面与内容"), text: $query)
                    .textFieldStyle(.plain).focused($focused)
                    .onSubmit { openFirst() }
            }
            .font(.system(size: 18))
            .padding(18)
            Divider()
            List(results) { page in
                Button {
                    Task { await model.flushAll(); model.select(page.id); isPresented = false }
                } label: {
                    Label(page.title.isEmpty ? L10n.tr("未命名") : page.title, systemImage: "doc.text")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
        .frame(width: 560, height: 410)
        .task { focused = true; results = await model.performSearch("") }
        .task(id: query) { results = await model.performSearch(query) }
    }

    private func openFirst() {
        guard let page = results.first else { return }
        Task { await model.flushAll(); model.select(page.id); isPresented = false }
    }
}
