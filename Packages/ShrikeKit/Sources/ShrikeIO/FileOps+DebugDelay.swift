//
//  FileOps+DebugDelay.swift
//  ShrikeIO
//
//  Debug builds only: a wait before each photo of a copy / move, so an
//  on-screen reviewer can see "quit during a copy". Set by
//  the app from `-ShrikeDebugTransferDelay <seconds>`; 0 (the default)
//  changes nothing. Not compiled into Release.
//

#if DEBUG
import os

extension FileOps {
    /// Seconds to wait before each photo of a copy / move; 0 = none.
    public static let debugPerFileDelay = OSAllocatedUnfairLock<Double>(initialState: 0)
}
#endif
