import SwiftUI

struct Message: Identifiable {
    let id = UUID()
    let query: String
    let answer: RoutedAnswer?
    let isError: Bool
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
                // Session stats — the cost-savings headline.
                HStack {
                    Label("\(Int(engine.onDeviceRate * 100))% on-device", systemImage: "cpu")
                    Spacer()
                    Text("\(engine.auditLog.count) queries routed")
                        .foregroundStyle(.secondary)
                }
                .font(.footnote)
                .padding(.horizontal)
                .padding(.vertical, 8)

                Divider()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(messages) { message in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(message.query)
                                    .font(.headline)
                                if let answer = message.answer {
                                    RouteBadge(destination: answer.destination,
                                               latencyMs: answer.latencyMs)
                                    Text(answer.text)
                                        .font(.body)
                                } else if message.isError {
                                    Text("Something went wrong — check your connection and API key.")
                                        .foregroundStyle(.red)
                                }
                            }
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .padding()
                }

                Divider()

                HStack {
                    TextField("Ask anything…", text: $input)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isWorking)
                    Button("Send") { send() }
                        .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
                }
                .padding()
            }
            .navigationTitle("On-Device Router")
        }
    }

    private func send() {
        let query = input.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        input = ""
        isWorking = true
        Task {
            do {
                let answer = try await engine.answer(query)
                messages.append(Message(query: query, answer: answer, isError: false))
            } catch {
                messages.append(Message(query: query, answer: nil, isError: true))
            }
            isWorking = false
        }
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
