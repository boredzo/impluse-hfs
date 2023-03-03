//
//  ImpBTreeMapNode.h
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-12-18.
//

#import <Foundation/Foundation.h>

#import "ImpBTreeNode.h"

@interface ImpBTreeMapNode : ImpBTreeNode

///This is for subclasses to override. It returns the index of the node's map record. Map nodes always return 0 (they only ever contain one record); a header node returns 2.
@property(nonatomic, readonly) u_int16_t mapRecordIndex;

///Tells this node how many bits have come before it in the overall map (header map + any intervening sibling map nodes), for conversion between absolute indexes (into the overall map) and relative indexes (into this node).
///This should be set only once, by the governing ImpBTreeFile, and then never touched again.
@property NSUInteger firstRelativeIndex;

///Returns whether an absolute index falls within this node's map record. Returns NSOrderedSame if so, NSOrderedAscending if the bit is in a preceding map record, NSOrderedDescending if the bit is in a subsequent map record.
- (NSComparisonResult) containsBitIndex:(NSUInteger)absIdx;

///Returns the number of bits in this node's contribution to the map.
@property(nonatomic, readonly) NSUInteger numberOfBits;

///Determine whether a block is allocated or deallocated using an absolute index relative to the whole map.
///If this bit isn't within this node, walks through sibling nodes until a node that includes this bit is found.
- (bool) isNodeAllocated:(NSUInteger)absIdx;

///Determine whether a block is allocated or deallocated using an index relative to this node.
- (bool) testBitAtRelativeIndex:(NSUInteger)idx;

///Mark a node as allocated or deallocated using an index relative to this node.
- (void) setBitAtRelativeIndex:(NSUInteger)idx toValue:(bool)value;

///Mark a node as allocated using an index relative to the whole map. Will refer the request to another node if necessary.
- (void) allocateNode:(NSUInteger)absIdx;

///Mark a node as deallocated using an index relative to the whole map. Will refer the request to another node if necessary.
- (void) deallocateNode:(NSUInteger)absIdx;

@end
