//
//  GrayImage.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/09/2026.
//

/// GrayImage owns row-major luminance samples in the range 0...255.
struct GrayImage {
    let width: Int
    let height: Int
    var pixels: [Float]
}
