# My Todos — macOS 27 + Firebase

Native SwiftUI Mac app with email/password registration, login, logout, and five
todo categories: Personal, Work, Studies, Home and Others. Add, edit, delete and
complete tasks. Firebase Authentication stores the accounts; Cloud Firestore
stores each account's tasks and syncs changes while the app is open.

Your supplied Firebase configuration is already included and matches:

| Setting | Value |
| --- | --- |
| Bundle Identifier | `todo-app` |
| Firebase project | `todo-app-2c034` |
| App target and scheme | `TodoMac` |
| Product | `MyTodos.app` |
| Deployment target | macOS 27.0 |
| Firebase package | 13.1.1 or a compatible 13.x update |

## Run it in Xcode

1. Extract this ZIP.
2. Open `TodoMac/TodoMac.xcodeproj` in an Xcode version with the macOS 27 SDK.
3. Let Xcode finish downloading the Firebase Swift packages. The dependencies
   FirebaseCore, FirebaseAuth and FirebaseFirestore are already assigned.
4. Select the `TodoMac` scheme and the `My Mac` run destination.
5. Open the app target's Signing & Capabilities, enable automatic signing, and
   select your Apple development team. The Bundle Identifier is already `todo-app`.
6. Complete the two Firebase Console steps below, then press Run (Command-R).

The project has App Sandbox with Outgoing Connections enabled and Keychain
Sharing configured. Firebase Authentication uses Keychain to restore login.
Select a development team so Xcode can provision/sign that entitlement.
If automatic signing reports an identifier conflict, resolve it for your team;
changing the identifier also requires a matching Firebase app configuration.

You do not need to add the plist or SDKs again when using this included project.
No developer-team identifier was supplied, so the signing team is selected on
your Mac. This package contains source, not a precompiled or signed application.

## Required Firebase Console settings

Open https://console.firebase.google.com/ and select `todo-app-2c034`.

### Enable accounts

Open Authentication > Sign-in method (or Sign-in providers), enable
Email/Password, and Save. The app's Register button creates the account and
signs it in. The form confirms the password and Firebase enforces the project's
configured password policy.

### Create Firestore and publish rules

Create the default Cloud Firestore database in Standard edition / Native mode,
choose a region, and start in production mode. In Firestore > Rules, paste the
contents of `firestore.rules` from this package and Publish.

If this Firebase project already has other collections/rules, merge the included
todo rules with those rules so unrelated app behavior is preserved.

The client configuration file alone does not enable these services or publish
rules. These console settings have not been changed or verified remotely.

## How saving works

- Account UID and email belong to Firebase Authentication. Passwords are passed
  to Firebase Authentication; they are never saved as task/profile fields.
- Every task is a document at `users/{uid}/todos/{taskId}`. It contains title,
  category, completed state, createdAt and updatedAt.
- The security rules require the signed-in UID to match the UID in that path,
  and validate document fields. Other users cannot access those task paths
  through the client SDK when the included rules are published without broader
  overlapping allow rules.
- Firestore document IDs identify rows, avoiding changing array-index IDs.
- Cloud-confirmed tasks return when the same account logs in again, including
  after app reinstall or on another device. Logout clears the visible task list
  and stops its listener; it does not delete the cloud documents.
- Saving uses asynchronous Firebase APIs. A pending/offline save shows a syncing
  message, and logout is disabled until it finishes. Sidebar navigation remains
  available. Reconnect to finish saving.
- Existing tasks from MiniSwift's browser storage are not automatically imported.
- This version uses the requested email/password registration fields. A separate
  Firestore profile document is unnecessary; names or other profile fields can
  be added later.

Cloud storage persists until the data or project is deleted; it is not a separate
backup service. Keep the Firebase project active and within its service limits.

## If you want to paste the code into your own project

All Swift code is in `TodoMac/TodoMac/TodoMacApp.swift`. Create a macOS App using
SwiftUI. Replace the generated app entry file and ContentView with this file;
the target must have only one `@main` declaration.

Add the Firebase products, add `GoogleService-Info.plist` to the app target's
resources, set the Bundle Identifier to `todo-app`, and enable App Sandbox >
Outgoing Connections plus Keychain Sharing. Copy the entitlement configuration
from this project and select your signing team. Set the app Info.plist Boolean
`FirebaseAppDelegateProxyEnabled` to NO and add `-ObjC` to Other Linker Flags.

The included project selects Swift 5 language mode with nonisolated default
actor isolation. The UI and data store explicitly use the main actor. Firebase
itself is built by the current Swift toolchain through Swift Package Manager.

## Verification completed here

- Firebase plist parsed; its Bundle Identifier matches both build configurations.
- Swift syntax parsed without syntax errors.
- Xcode project OpenStep format and shared scheme XML parsed successfully.
- Project object references, resource paths, Firebase product links, deployment
  target, network entitlement and Keychain access-group configuration checked.
- Supplied Firebase configuration is preserved byte for byte in the package.
- The final ZIP passed its integrity check.

Xcode/macOS are not available in the build environment used for this package.
An Xcode compile, code-signing check, launch, and live Firebase account/database
test have not been performed. Syntax checks do not replace an Xcode build.

## Verify on your Mac

1. Build and run, register account A, and add a task in each category.
2. Edit, complete and delete tasks; quit and reopen the app and confirm the
   account and tasks return.
3. Log out, register account B, and confirm A's tasks are not visible.
4. Log back in as A and confirm its saved tasks return.
5. In Firebase Rules Playground, confirm an unauthenticated request fails and
   account B cannot read/write a task at `users/A_UID/todos/taskId`.
6. Open the app on a second Mac with the same account and verify changes sync.
7. Disconnect during saving, verify the UI still responds, reconnect, and
   confirm the saving indicator clears.

If you see a keychain error, check your signing team and Keychain Sharing.
If you see "operation not allowed", enable Email/Password Authentication.
If you see "missing or insufficient permissions", publish the rules in the
correct Firebase project. A connection error can also mean Firestore has not
been created or outgoing network access is disabled.

## Official references

- Firebase Apple setup: https://firebase.google.com/docs/ios/setup
- Mac Keychain requirements: https://firebase.google.com/docs/ios/troubleshooting-faq#macos-keychain-sharing
- Email/password login: https://firebase.google.com/docs/auth/ios/password-auth
- Firestore rules: https://firebase.google.com/docs/firestore/security/rules-conditions
- Firebase SDK releases: https://firebase.google.com/support/release-notes/ios
- AppKit delegate: https://developer.apple.com/documentation/swiftui/nsapplicationdelegateadaptor
- Outgoing connections: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.network.client
