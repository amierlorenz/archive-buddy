import SwiftUI

struct ChatListView: View {
    @Environment(DatabaseManager.self) private var db
    @Environment(LLM.self) private var llm
    @Environment(ArchiveQueryService.self) private var archiveQueryService
    @State private var vm: ChatListViewModel?
    @State private var showNewChat = false
    @State private var activeSession: ChatSession?

    private var hasChats: Bool {
        vm?.sessions.isEmpty == false
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(vm?.sessions ?? []) { session in
                    NavigationLink {
                        ChatView(session: session)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(session.displayTitle)
                            Text(session.updatedAt, style: .relative)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        if let session = vm?.sessions[index] {
                            vm?.deleteSession(session)
                        }
                    }
                }
            }
            .overlay {
                if !hasChats {
                    ContentUnavailableView(
                        "No Chats",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text(
                            "Tap New Chat to start a conversation."
                        )
                    )
                }
            }
            .navigationTitle("Chats")
            .toolbar {
                Button("New Chat") { showNewChat = true }
            }
            .navigationDestination(item: $activeSession) { session in
                ChatView(session: session, focusOnAppear: true)
            }
            .sheet(isPresented: $showNewChat) {
                if let vm {
                    NewChatView(chatListVM: vm, activeSession: $activeSession)
                }
            }
        }
        .task {
            guard vm == nil else { return }
            let v = ChatListViewModel(db: db)
            v.loadSessions()
            vm = v
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication.willEnterForegroundNotification
            )
        ) { _ in
            vm?.loadSessions()
        }
    }
}
