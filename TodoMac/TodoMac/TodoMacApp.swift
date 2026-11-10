import SwiftUI
import AppKit
import Combine
import FirebaseCore
import FirebaseAuth
import FirebaseFirestore

@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    @Published var isConfigured = false
    @Published var configurationError: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
              let options = FirebaseOptions(contentsOfFile: path) else {
            configurationError = "Add GoogleService-Info.plist to this app's target and run again."
            return
        }
        guard options.bundleID == Bundle.main.bundleIdentifier else {
            configurationError = "The app's Bundle Identifier must match the Firebase file: \(options.bundleID)."
            return
        }
        if FirebaseApp.app() == nil { FirebaseApp.configure(options: options) }
        isConfigured = true
    }
}

@main
@MainActor
struct TodoMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var delegate

    var body: some Scene {
        Window("My Todos", id: "main") {
            Group {
                if delegate.isConfigured {
                    ContentView()
                } else if let error = delegate.configurationError {
                    VStack(spacing: 12) {
                        Text("Firebase setup").font(.title2.bold())
                        Text(error).multilineTextAlignment(.center).textSelection(.enabled)
                    }
                    .padding(32)
                } else {
                    ProgressView("Starting…")
                }
            }
            .frame(minWidth: 720, minHeight: 520)
        }
        .defaultSize(width: 920, height: 640)
    }
}

enum TodoCategory: String, CaseIterable, Identifiable, Hashable, Sendable {
    case personal = "Personal", work = "Work", studies = "Studies"
    case home = "Home", others = "Others"
    var id: String { rawValue }
}

struct TodoItem: Identifiable, Sendable {
    let id: String
    let title: String
    let category: TodoCategory
    let isDone: Bool
    let createdAt: Date

    init?(document: QueryDocumentSnapshot) {
        let data = document.data()
        guard let title = data["title"] as? String,
              let categoryName = data["category"] as? String,
              let category = TodoCategory(rawValue: categoryName),
              let isDone = data["isDone"] as? Bool else { return nil }
        self.id = document.documentID
        self.title = title
        self.category = category
        self.isDone = isDone
        self.createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? .distantPast
    }
}

@MainActor
final class TodoStore: ObservableObject {
    @Published private(set) var userID: String?
    @Published private(set) var email = ""
    @Published private(set) var checkingSession = true
    @Published private(set) var authenticating = false
    @Published private(set) var loadingTodos = false
    @Published private(set) var isWriting = false
    @Published private(set) var hasPendingWrites = false
    @Published private(set) var usingCachedData = false
    @Published private(set) var todos: [TodoItem] = []
    @Published var message: String?

    private var authListener: AuthStateDidChangeListenerHandle?
    private var todoListener: ListenerRegistration?
    private var sessionToken = UUID()

    init() {
        authListener = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            let uid = user?.uid
            let email = user?.email ?? ""
            Task { @MainActor [weak self] in
                self?.changeSession(uid: uid, email: email)
            }
        }
    }

    deinit {
        todoListener?.remove()
        if let authListener { Auth.auth().removeStateDidChangeListener(authListener) }
    }

    private func changeSession(uid: String?, email: String) {
        self.email = email
        guard checkingSession || userID != uid else { return }
        checkingSession = false
        sessionToken = UUID()
        todoListener?.remove()
        todoListener = nil
        todos = []
        isWriting = false
        hasPendingWrites = false
        usingCachedData = false
        userID = uid
        loadingTodos = uid != nil
        guard let uid else { return }
        let token = sessionToken

        // Scope every query to the current user's UID. Rules enforce this too.
        todoListener = Firestore.firestore().collection("users").document(uid)
            .collection("todos").addSnapshotListener(includeMetadataChanges: true) {
                [weak self] snapshot, error in
                let items = snapshot?.documents.compactMap { TodoItem(document: $0) } ?? []
                let cached = snapshot?.metadata.isFromCache ?? false
                let pending = snapshot?.metadata.hasPendingWrites ?? false
                let errorText = error?.localizedDescription
                Task { @MainActor [weak self] in
                    guard let self, self.sessionToken == token else { return }
                    self.loadingTodos = false
                    if let errorText {
                        self.message = "Could not load tasks: \(errorText)"
                        return
                    }
                    self.todos = items.sorted {
                        if $0.createdAt == $1.createdAt { return $0.id < $1.id }
                        return $0.createdAt > $1.createdAt
                    }
                    self.usingCachedData = cached
                    self.hasPendingWrites = pending
                }
            }
    }

    func authenticate(email: String, password: String, register: Bool) async {
        guard !authenticating else { return }
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, !password.isEmpty else {
            message = "Enter your email and password."
            return
        }
        authenticating = true
        defer { authenticating = false }
        do {
            if register {
                _ = try await Auth.auth().createUser(withEmail: email, password: password)
            } else {
                _ = try await Auth.auth().signIn(withEmail: email, password: password)
            }
        } catch {
            message = error.localizedDescription
        }
    }

    func signOut() {
        guard !isWriting, !hasPendingWrites else {
            message = "Wait for your tasks to finish syncing before signing out."
            return
        }
        do {
            try Auth.auth().signOut()
            changeSession(uid: nil, email: "")
        } catch {
            message = error.localizedDescription
        }
    }

    func saveTodo(id: String?, title: String, category: TodoCategory, isDone: Bool) async -> Bool {
        guard let uid = userID, !isWriting else { return false }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 200 else {
            let error = "Enter a task between 1 and 200 characters."
            message = error
            return false
        }
        let collection = Firestore.firestore().collection("users").document(uid).collection("todos")
        let token = sessionToken
        isWriting = true
        defer { if sessionToken == token { isWriting = false } }
        do {
            let fields: [String: Any] = [
                "title": title, "category": category.rawValue, "isDone": isDone,
                "updatedAt": FieldValue.serverTimestamp()
            ]
            if let id {
                // Updating cannot silently recreate a task deleted on another device.
                try await collection.document(id).updateData(fields)
            } else {
                var newFields = fields
                newFields["createdAt"] = FieldValue.serverTimestamp()
                try await collection.document().setData(newFields)
            }
            return sessionToken == token
        } catch {
            if sessionToken == token {
                let text = "Could not save task: \(error.localizedDescription)"
                message = text
            }
            return false
        }
    }

    func deleteTodo(_ todo: TodoItem) async {
        guard let uid = userID, !isWriting else { return }
        let token = sessionToken
        isWriting = true
        defer { if sessionToken == token { isWriting = false } }
        do {
            try await Firestore.firestore().collection("users").document(uid)
                .collection("todos").document(todo.id).delete()
        } catch {
            if sessionToken == token { message = "Could not delete task: \(error.localizedDescription)" }
        }
    }
}


@MainActor
struct ContentView: View {
    @StateObject private var store = TodoStore()

    var body: some View {
        Group {
            if store.checkingSession {
                ProgressView("Checking login…")
            } else if let uid = store.userID {
                TodoWorkspaceView(store: store).id(uid)
            } else {
                AccountView(store: store)
            }
        }
        .alert("My Todos", isPresented: Binding(
            get: { store.message != nil },
            set: { if !$0 { store.message = nil } }
        )) {
            Button("OK", role: .cancel) { store.message = nil }
        } message: {
            Text(store.message ?? "")
        }
    }
}

@MainActor
struct AccountView: View {
    @ObservedObject var store: TodoStore
    @State private var email = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var registering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "checklist").font(.system(size: 38)).foregroundStyle(.blue)
            Text(registering ? "Create your account" : "Welcome back")
                .font(.largeTitle.bold())
            Text("Sign in to see your saved todos.").foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 7) {
                Text("Email")
                TextField("you@example.com", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("Password")
                SecureField("Password", text: $password).textFieldStyle(.roundedBorder)
            }
            if registering {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Confirm password")
                    SecureField("Confirm password", text: $confirmation)
                        .textFieldStyle(.roundedBorder)
                }
            }
            Button {
                submit()
            } label: {
                HStack {
                    Spacer()
                    if store.authenticating { ProgressView().controlSize(.small) }
                    Text(registering ? "Register" : "Log in")
                    Spacer()
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)

            Button(registering ? "Already have an account? Log in" : "New here? Register") {
                registering.toggle()
                password = ""
                confirmation = ""
            }
            .buttonStyle(.link)
        }
        .disabled(store.authenticating)
        .frame(width: 350)
        .padding(36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func submit() {
        guard !store.authenticating else { return }
        guard !registering || password == confirmation else {
            store.message = "The passwords do not match."
            return
        }
        Task {
            await store.authenticate(email: email, password: password, register: registering)
            password = ""
            confirmation = ""
        }
    }
}

@MainActor
struct TodoWorkspaceView: View {
    @ObservedObject var store: TodoStore
    @State private var selectedCategory: TodoCategory? = .personal

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(TodoCategory.allCases, selection: $selectedCategory) { category in
                    HStack {
                        Text(category.rawValue)
                        Spacer()
                        Text("\(store.todos.filter { $0.category == category }.count)")
                            .foregroundStyle(.secondary)
                    }
                    .tag(category)
                    .padding(.vertical, 5)
                }
                .listStyle(.sidebar)
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text(store.email).font(.caption).lineLimit(1)
                        .textSelection(.enabled)
                    Button("Log out") { store.signOut() }
                        .disabled(store.isWriting || store.hasPendingWrites)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Categories")
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        } detail: {
            if let category = selectedCategory {
                CategoryTodosView(store: store, category: category).id(category)
            } else {
                Text("Choose a category in the sidebar.").foregroundStyle(.secondary)
            }
        }
    }
}

@MainActor
struct CategoryTodosView: View {
    @ObservedObject var store: TodoStore
    let category: TodoCategory
    @State private var taskText = ""
    @State private var editingID: String?
    @State private var deleting: TodoItem?

    private var categoryTodos: [TodoItem] {
        store.todos.filter { $0.category == category }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(category.rawValue).font(.largeTitle.bold())
                Spacer()
                Text("\(categoryTodos.count) tasks").foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                TextField("Enter a task", text: $taskText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { save() }
                Button(editingID == nil ? "Add" : "Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(taskText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if editingID != nil {
                    Button("Cancel") { cancelEditing() }
                }
            }
            .controlSize(.large)
            .disabled(store.isWriting)

            if store.isWriting || store.hasPendingWrites {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Syncing… Reconnect to the internet if saving is still pending.")
                }
                .font(.caption).foregroundStyle(.secondary)
            } else if store.usingCachedData {
                Text("Showing cached tasks. Checking for cloud updates…")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if store.loadingTodos {
                ProgressView("Loading tasks…")
            } else if categoryTodos.isEmpty {
                Text("No tasks yet. Add your first one!")
                    .foregroundStyle(.secondary).padding(.top, 12)
            }

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(categoryTodos) { todo in
                        HStack(spacing: 12) {
                            Button {
                                Task {
                                    _ = await store.saveTodo(id: todo.id, title: todo.title,
                                        category: todo.category, isDone: !todo.isDone)
                                }
                            } label: {
                                Image(systemName: todo.isDone ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(todo.isDone ? "Mark incomplete" : "Mark complete")
                            Text(todo.title).strikethrough(todo.isDone)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                            Button("Edit") {
                                taskText = todo.title
                                editingID = todo.id
                            }
                            Button("Delete", role: .destructive) { deleting = todo }
                        }
                        .padding(14)
                        .background(Color.primary.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .disabled(store.isWriting)
                    }
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle(category.rawValue)
        .confirmationDialog("Delete this task?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        ), titleVisibility: .visible, presenting: deleting) { todo in
            Button("Delete", role: .destructive) {
                if editingID == todo.id { cancelEditing() }
                Task { await store.deleteTodo(todo) }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        }
    }

    private func save() {
        guard !store.isWriting else { return }
        let isDone = store.todos.first { $0.id == editingID }?.isDone ?? false
        Task {
            let success = await store.saveTodo(id: editingID, title: taskText,
                                               category: category, isDone: isDone)
            if success { cancelEditing() }
        }
    }

    private func cancelEditing() {
        taskText = ""
        editingID = nil
    }
}
