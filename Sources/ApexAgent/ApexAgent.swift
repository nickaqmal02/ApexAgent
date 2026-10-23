// The Swift Programming Language
// https://docs.swift.org/swift-book
import Foundation

struct Commmand {
    let name: String
    let description: String
    let usage: String
    let category: Category

    enum Category {
        case system
        case apps
        case utility // help, exit
    }
}

// MARK: Command Registry



@main
struct ApexAgent {
    static func main() {
        let name = "Jev"
        var version = 1
        version = 2

        print("Agent: \(name) v\(version)")
        print("Type of name: \(type(of: name))")
    }
}
