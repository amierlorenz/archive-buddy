import SwiftUI

struct ChatView: View {
    @Environment(DatabaseManager.self) private var db
    @Environment(LLM.self) private var llm
    @Environment(ArchiveQueryService.self) private var archiveQueryService
    let session: ChatSession

    @State private var vm: ChatViewModel?
    @State private var inputText = ""
    @State private var scrollID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            messageList
            inputBar
        }
        .navigationTitle(session.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard vm == nil else { return }
            vm = ChatViewModel(
                session: session,
                db: db,
                llm: llm,
                archiveQueryService: archiveQueryService
            )
        }
    }

    // MARK: - Message list

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(vm?.messages ?? []) { message in
                        messageRow(message)
                            .id(message.id)
                    }

                    // Live streaming bubble while response is in flight
                    if vm?.isSending == true, !llm.streamingResponse.isEmpty {
                        Text(llm.streamingResponse)
                            .padding(10)
                            .background(Color(.systemGray6))
                            .cornerRadius(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("streaming")
                    }
                }
                .padding()
            }
            .onChange(of: llm.streamingResponse) { _, _ in
                withAnimation { proxy.scrollTo("streaming") }
            }
            .onChange(of: vm?.messages.count) { _, _ in
                if let last = vm?.messages.last {
                    withAnimation { proxy.scrollTo(last.id) }
                }
            }
            .overlay {
                if (vm?.messages ?? []).isEmpty, vm?.isSending != true {
                    ContentUnavailableView("No Messages",
                                           systemImage: "text.bubble",
                                           description: Text("Type a message below to start chatting."))
                }
            }
        }
    }

    // MARK: - Input bar

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $inputText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)

            Button {
                let text = inputText
                inputText = ""
                Task { await vm?.sendMessage(text) }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || vm?.isSending == true)
        }
        .padding()
        .background(.bar)
    }

    // MARK: - Message row

    @ViewBuilder
    private func messageRow(_ message: ChatMessage) -> some View {
        VStack(alignment: message.isUser ? .trailing : .leading, spacing: 4) {
            Text(message.text)
                .padding(10)
                .background(message.isUser ? Color.blue.opacity(0.15) : Color(.systemGray6))
                .cornerRadius(10)
                .frame(maxWidth: .infinity, alignment: message.isUser ? .trailing : .leading)
                .textSelection(.enabled)

            if let citations = message.citations, !citations.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(citations) { citation in
                        Text(citation.displayString)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
