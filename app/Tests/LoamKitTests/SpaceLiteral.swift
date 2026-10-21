import LoamKit

/// In the tests, a string literal is a plot: `tabs(of: "p1")` reads `tabs(of: .plot("p1"))`. The app
/// code names `.plot` or `.home`, so no plot ID there can stand for Home by mistake.
extension Space: ExpressibleByStringLiteral {
    public init(stringLiteral id: String) { self = .plot(id) }
}
