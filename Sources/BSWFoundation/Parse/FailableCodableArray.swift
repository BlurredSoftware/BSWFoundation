import Foundation

public struct FailableCodableArray<Element : Decodable> : Decodable {

    public var elements: [Element]

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let elements = try container.decode([FailableDecodable<Element>].self)
        self.elements = elements.compactMap { $0.base }
    }
}

private struct FailableDecodable<Base : Decodable> : Decodable {

    let base: Base?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.base = try? container.decode(Base.self)
    }
}
