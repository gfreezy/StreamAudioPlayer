//
//  File.swift
//  
//
//  Created by feichao on 2023/7/2.
//

import Foundation

public struct StreamAudioError: LocalizedError {
    public var errorDescription: String?
    public var failureReason: String?
    public var helpAnchor: String?
    public var recoverySuggestion: String?
}
