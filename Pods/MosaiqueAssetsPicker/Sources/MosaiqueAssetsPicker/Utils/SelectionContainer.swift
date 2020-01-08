//
//  SelectionContainer.swift
//  AssetsPicker
//
//  Created by Aymen Rebouh on 2018/10/19.
//  Copyright © 2018 eure. All rights reserved.
//

import Foundation
import Photos

public protocol ItemIdentifier {
    associatedtype Identifier : Equatable

    var identifier: Self.Identifier { get }
}

public final class SelectionContainer<T: ItemIdentifier> {
    
    // MARK: Properties
    
    private(set) var selectedItems: [T] = []
    private(set) var size: Int
    
    var selectedCount: Int {
        return selectedItems.count
    }
    
    var isEmpty: Bool {
        return selectedItems.isEmpty
    }
    
    var isFilled: Bool {
        return !(selectedItems.count < size)
    }
    
    // MARK: Lifecycle
    
    init(withSize size: Int) {
        self.size = size
    }
    
    // MARK: Core
    
    func item(for key: T.Identifier) -> T? {
        let items = selectedItems
        return items.firstIndex(where: { $0.identifier == key }).map { items[$0] }
    }
    
    func append(item: T, removeFirstIfAlreadyFilled: Bool = false) {
        if selectedItems.contains(where: { $0.identifier == item.identifier }) {
            remove(item: item)
        }
        
        if isFilled {
            if removeFirstIfAlreadyFilled {
                let items = selectedItems
                selectedItems = items.dropFirst() + [item]
            }
        } else {
            selectedItems.append(item)
        }
    }
    
    func remove(item: T) {
        var items = selectedItems
        
        guard let index = items.firstIndex(where: { $0.identifier == item.identifier }) else { return }
        
        items.remove(at: index)
        
        selectedItems = items
    }
    
    func purge() {
        selectedItems = []
    }
}
