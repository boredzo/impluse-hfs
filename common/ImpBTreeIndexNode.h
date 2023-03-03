//
//  ImpBTreeIndexNode.h
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-11-30.
//

#import "ImpBTreeNode.h"

@interface ImpBTreeIndexNode : ImpBTreeNode

- (NSArray <ImpBTreeNode *> *_Nonnull) children;

///Search this index node and its forward siblings for the nearest key to some search quarry. The block is called to perform comparisons; it receives as its only argument a key from one of the index nodes being searched. Upon a match (either an exact match or the greatest lesser key), returns the node indicated by the pointer record, thereby descending one level. If the index node is empty, or the
- (ImpBTreeNode *_Nullable) descendWithKeyComparator:(ImpBTreeRecordKeyComparator _Nonnull const)block;

@end
