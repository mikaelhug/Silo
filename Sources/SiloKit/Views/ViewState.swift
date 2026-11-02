import SwiftUI

/// SwiftUI's `State` property wrapper, under a name that is NOT also a macro.
///
/// From the macOS 27.2 SDK on, `SwiftUICore` declares `@State` as an attached macro
/// (`SwiftUIMacros.StateMacro`) alongside the `State<Value>` property wrapper, and the attribute resolves to
/// the macro. Its compiler plugin ships only with full Xcode — the Command Line Tools this project builds
/// with (constraint #1) don't carry `SwiftUIMacros`, so every `@State` fails with "plugin for module
/// 'SwiftUIMacros' not found". A module-level `typealias State` does not help (the imported macro still
/// wins), but an alias under another name resolves to the property wrapper itself — exactly what `@State`
/// meant on every earlier SDK. Use `@ViewState` for view-local state everywhere in this module.
typealias ViewState<Value> = SwiftUI.State<Value>
