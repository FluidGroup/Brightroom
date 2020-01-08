//
//  Lock.swift
//  AssetsPicker
//
//  Created by Antoine Marandon on 18/11/2019.
//  Copyright © 2019 eure. All rights reserved.
//

import Foundation

extension NSLock {
    func exec<T>(proc: () -> T) -> T {
        self.lock()
        let result = proc()
        self.unlock()
        return result
    }
}
