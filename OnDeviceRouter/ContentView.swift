import SwiftUI

struct Message: Identifiable {
    let id = UUID()
    let query: String
    var answer: RoutedAnswer?
    var isError = false
    var errorMessage: String?
    var isLoading = true
}

@available(iOS 26.0, *)
struct ContentView: View {
    @StateObject private var engine = RoutingEngine()
    @State private var messages: [Message] = []
    @State private var input = ""
    @State private var isWorking = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // This build intentionally bypasses all routing and cloud code.
                HStack {
                    Label("Local-only memory lab", systemImage: "iphone")
                    Spacer()
                    Text("\(engine.auditLog.count) local turns")
                        .foregroundStyle(.secondary)
                }
                .font(.footnote)
                .padding(.horizontal)
                .padding(.vertical, 8)

                LlamaStatusRow(status: engine.localModelStatus)
                    .padding(.horizontal)
                    .padding(.bottom, 8)

                MemoryStatusRow(
                    diagnostics: engine.memoryDiagnostics,
                    lastRecallHitCount: engine.lastRecallHitCount
                )
                .padding(.horizontal)
                .padding(.bottom, 8)

                Divider()

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 16) {
                            ForEach(messages) { message in
                                MessageRow(message: message)
                                    .id(message.id)
                                    .transition(.move(edge: .bottom).combined(with: .opacity))
                            }
                        }
                        .padding()
                    }
                    .onChange(of: messages.count) {
                        scrollToLatest(using: proxy)
                    }
                    .onChange(of: isWorking) {
                        scrollToLatest(using: proxy)
                    }
                }

                Divider()

                HStack {
                    TextField("Ask anything…", text: $input)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.send)
                        .onSubmit(send)
                        .disabled(isWorking)
                    Button("Send") { send() }
                        .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
                }
                .padding()
            }
            .navigationTitle("Local Memory Lab")
            .task { await engine.refreshMemoryDiagnostics() }
        }
    }

    private func send() {
        let query = input.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }

        let pendingMessage = Message(query: query)
        input = ""
        isWorking = true

        withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
            messages.append(pendingMessage)
        }

        Task {
            do {
                let answer = try await engine.answer(query)
                withAnimation(.easeInOut(duration: 0.25)) {
                    updateMessage(pendingMessage.id) { message in
                        message.answer = answer
                        message.isLoading = false
                    }
                }
            } catch {
                withAnimation(.easeInOut(duration: 0.25)) {
                    updateMessage(pendingMessage.id) { message in
                        message.isError = true
                        message.errorMessage = error.localizedDescription
                        message.isLoading = false
                    }
                }
            }
            isWorking = false
        }
    }

    private func updateMessage(_ id: UUID, update: (inout Message) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        update(&messages[index])
    }

    private func scrollToLatest(using proxy: ScrollViewProxy) {
        guard let id = messages.last?.id else { return }
        withAnimation(.easeOut(duration: 0.3)) {
            proxy.scrollTo(id, anchor: .bottom)
        }
    }
}

private struct MemoryStatusRow: View {
    let diagnostics: MemoryDiagnostics
    let lastRecallHitCount: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: diagnostics.persistenceError == nil
                  ? "externaldrive.fill.badge.checkmark"
                  : "externaldrive.fill.badge.exclamationmark")
                .foregroundStyle(diagnostics.persistenceError == nil ? .green : .red)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(diagnostics.storedCount) turns stored locally")
                    .font(.caption.bold())
                if let error = diagnostics.persistenceError {
                    Text("Save failed: \(error)")
                        .foregroundStyle(.red)
                } else {
                    Text("Last lookup: \(lastRecallHitCount) memories · \(diagnostics.embeddedCount) vectors · \(diagnostics.graphEdgeCount) graph edges")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption2)
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }
}

private struct MessageRow: View {
    let message: Message

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Spacer(minLength: 48)
                Text(message.query)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16))
            }

            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    if message.isLoading {
                        ThinkingIndicator()
                    } else if let answer = message.answer {
                        RouteBadge(destination: answer.destination,
                                   latencyMs: answer.latencyMs)
                        Text(answer.text)
                            .font(.body)
                            .textSelection(.enabled)
                            .transition(.opacity)
                    } else if message.isError {
                        Label(message.errorMessage ?? "Something went wrong.",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
                Spacer(minLength: 48)
            }
        }
    }
}

private struct LlamaStatusRow: View {
    let status: LocalModelStatus

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text("Built with Meta Llama 3.2 1B")
                    .font(.caption.bold())
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if case .downloading(let fraction) = status {
                ProgressView(value: fraction)
                    .frame(width: 72)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        switch status {
        case .waiting:
            return "Downloads once on the first on-device request"
        case .downloading(let fraction):
            return "Downloading locally… \(Int(fraction * 100))%"
        case .loading:
            return "Loading model into memory…"
        case .generating:
            return "Generating privately on this iPhone…"
        case .ready:
            return "Ready for offline on-device inference"
        case .failed(let message):
            return message
        }
    }

    private var icon: String {
        switch status {
        case .failed: "exclamationmark.triangle.fill"
        case .ready: "checkmark.circle.fill"
        case .generating: "cpu"
        default: "arrow.down.circle"
        }
    }

    private var color: Color {
        switch status {
        case .failed: .red
        case .ready: .green
        default: .accentColor
        }
    }
}

private struct ThinkingIndicator: View {
    @State private var isAnimating = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(.tint)

            Text("Thinking")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(.secondary)
                        .frame(width: 6, height: 6)
                        .scaleEffect(isAnimating ? 1 : 0.55)
                        .opacity(isAnimating ? 1 : 0.35)
                        .animation(
                            .easeInOut(duration: 0.55)
                                .repeatForever(autoreverses: true)
                                .delay(Double(index) * 0.16),
                            value: isAnimating
                        )
                }
            }
        }
        .onAppear { isAnimating = true }
    }
}

struct RouteBadge: View {
    let destination: RouteDestination
    let latencyMs: Int

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: destination == .local ? "cpu" : "cloud")
            Text(destination == .local ? "On-device" : "Cloud")
            Text("· \(latencyMs)ms")
                .foregroundStyle(.secondary)
        }
        .font(.caption.bold())
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(destination == .local ? Color.green.opacity(0.15) : Color.blue.opacity(0.15),
                    in: Capsule())
    }
}
