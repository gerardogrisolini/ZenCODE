//
//  String+Extension.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//
import Foundation

extension String {
    public func numberOfLines() -> Int {
        numberOfOccurrencesOf(string: "\n") + 1
    }

    public func numberOfOccurrencesOf(string: String) -> Int {
        components(separatedBy: string).count - 1
    }
}

extension StringProtocol {
    public func index<S: StringProtocol>(
        of string: S,
        options: String.CompareOptions = []
    ) -> Index? {
        range(of: string, options: options)?.lowerBound
    }

    public func endIndex<S: StringProtocol>(
        of string: S,
        options: String.CompareOptions = []
    ) -> Index? {
        range(of: string, options: options)?.upperBound
    }

    public func indices<S: StringProtocol>(
        of string: S,
        options: String.CompareOptions = []
    ) -> [Index] {
        ranges(of: string, options: options).map(\.lowerBound)
    }

    public func ranges<S: StringProtocol>(
        of string: S,
        options: String.CompareOptions = []
    ) -> [Range<Index>] {
        var result: [Range<Index>] = []
        var startIndex = self.startIndex
        while startIndex < endIndex,
              let range = self[startIndex...].range(of: string, options: options) {
            result.append(range)
            startIndex = range.lowerBound < range.upperBound
                ? range.upperBound
                : index(range.lowerBound, offsetBy: 1, limitedBy: endIndex) ?? endIndex
        }
        return result
    }
}
