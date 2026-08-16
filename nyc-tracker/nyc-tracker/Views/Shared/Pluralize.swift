import Foundation

/// "1 friend" / "2 friends", for plain-`String` contexts.
///
/// SwiftUI's inflection markup — `^[\(n) friend](inflect: true)` — is processed
/// only when the string is a `LocalizedStringKey`, which happens when it is
/// written as a literal directly in `Text(...)`, `Label(...)` or
/// `.accessibilityLabel(...)`. Build the same string in a `String` variable
/// first and the markup reaches the screen verbatim, brackets and all. That
/// failure is invisible until it renders, so anywhere a count has to pass
/// through a `String` uses this instead.
func pluralized(_ count: Int, _ singular: String, _ plural: String? = nil) -> String {
    let noun = count == 1 ? singular : (plural ?? singular + "s")
    return "\(count) \(noun)"
}
