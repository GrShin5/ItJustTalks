import SwiftUI

/// SwiftUI's `State` property wrapper, used through this alias on purpose.
///
/// In the macOS 27 SDK, writing `@State` resolves to the `State()` macro, whose implementation
/// (`SwiftUIMacros`) ships only with full Xcode. Command Line Tools cannot expand it, so a source
/// build would require Xcode. Spelling the attribute through a type alias selects the
/// `@propertyWrapper struct State` instead, which needs no compiler plugin and keeps the same
/// view-state storage semantics. Use `@ViewState` instead of `@State` in this package.
typealias ViewState<Value> = SwiftUI.State<Value>
