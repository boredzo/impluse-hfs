//
//  ImpBTreeFile.h
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-11-27.
//

#import <Foundation/Foundation.h>

#import "ImpBTreeNode.h"
#import "ImpBTreeHeaderNode.h"

@interface ImpBTreeFile : NSObject <NSFastEnumeration>

- (instancetype _Nullable )initWithData:(NSData *_Nonnull const)bTreeFileContents;

///Returns the first node in the file if there is one and it is a header node. Otherwise, returns nil.
- (ImpBTreeHeaderNode *_Nullable const) headerNode;

- (ImpBTreeNode *_Nonnull const) nodeAtIndex:(u_int32_t const)idx;

//TODO: Gut this and make it equivalent to walkBreadthFirst: instead.
///Walks through the entire file in linear order and yields every node-space, whether or not it contains a node that is reachable from the root node. Yields NSData objects, each big enough to contain one B*-tree node. Expect to receive both valid and invalid nodes, in effectively random order (except for the header node being first).
- (NSUInteger)countByEnumeratingWithState:(NSFastEnumerationState *_Nonnull)state objects:(__unsafe_unretained id  _Nullable [_Nonnull])outObjects count:(NSUInteger)maxNumObjects;

///Starting from the root node, call the block for every node in the tree, in breadth-first order. Note that the header node is not included in this walk.
- (NSUInteger) walkBreadthFirst:(void (^_Nonnull const)(ImpBTreeNode *_Nonnull const node))block;

@end
