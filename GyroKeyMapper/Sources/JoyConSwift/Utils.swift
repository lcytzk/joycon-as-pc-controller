//
//  Utils.swift
//  JoyConSwift
//
//  Created by magicien on 2019/06/16.
//  Copyright © 2019 DarkHorse. All rights reserved.
//

import Foundation

// HID report fields aren't guaranteed to fall on 2/4-byte-aligned offsets,
// so these read byte-by-byte (little-endian, matching the Joy-Con protocol)
// instead of reinterpreting the pointer to a wider type — the latter traps
// on newer Swift runtimes when the address isn't properly aligned.

func ReadInt16(from ptr: UnsafePointer<UInt8>) -> Int16 {
    return Int16(bitPattern: ReadUInt16(from: ptr))
}

func ReadUInt16(from ptr: UnsafePointer<UInt8>) -> UInt16 {
    return UInt16(ptr[0]) | (UInt16(ptr[1]) << 8)
}

func ReadInt32(from ptr: UnsafePointer<UInt8>) -> Int32 {
    return Int32(bitPattern: ReadUInt32(from: ptr))
}

func ReadUInt32(from ptr: UnsafePointer<UInt8>) -> UInt32 {
    return UInt32(ptr[0]) | (UInt32(ptr[1]) << 8) | (UInt32(ptr[2]) << 16) | (UInt32(ptr[3]) << 24)
}
