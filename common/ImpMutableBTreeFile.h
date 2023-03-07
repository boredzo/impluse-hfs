//
//  ImpMutableBTreeFile.h
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-12-17.
//

#import <Foundation/Foundation.h>

#import "ImpBTreeFile.h"

///A cursor represents a particular record of a particular node in the tree. As long as no records or nodes are added or removed, a cursor remains valid. It's used to retrieve data, alter it, and write it back without having to search the tree multiple times for the same key.
@interface ImpBTreeCursor : NSObject

@property(nonatomic, copy) NSData *_Nonnull keyData;
@property(nonatomic, copy) NSData *_Nonnull payloadData;
@property(nonatomic, copy) NSData *_Nonnull wholeRecordData;

@end

@interface ImpMutableBTreeFile : ImpBTreeFile

///Returns nil if the version isn't compatible with the original tree (like if you're trying to convert a catalog file to an extents overflow file).
///Node size must be at least [ImpBTreeFile nodeSizeForVersion:version] and must be a power of two.
///Node count is the number of nodes to allocate space for. It must be at least enough to hold the header node, plus enough leaf nodes to hold all records, plus the index nodes, plus any map nodes.
///(It is not yet possible to lengthen a tree after the fact, so you will need to either have an exact number or overestimate.)
///If you're building a catalog, use ImpCatalogBuilder, which has a property you can access after you have finished adding entries to get the node count you will pass here, and a method to then copy the entries into this tree.
- (instancetype _Nullable )initWithVersion:(const ImpBTreeVersion)version
	bytesPerNode:(u_int16_t const)nodeSize
	nodeCount:(NSUInteger const)numPotentialNodes
	convertTree:(ImpBTreeFile *_Nonnull const)sourceTree;

///Allocate one new node of the specified kind, and call the block to populate it with data. If the block is nil, the node will be left blank aside from its node descriptor.
///bytes is a pointer to the BTNodeDescriptor at the start of the node, and length is equal to the tree's nodeSize.
- (ImpBTreeNode *_Nonnull const) allocateNewNodeOfKind:(BTreeNodeKind const)kind populate:(void (^_Nullable const)(void *_Nonnull bytes, NSUInteger length))block;

///Reserve space for a certain number of nodes of some type. Allocations of other nodes may be allocated from other space if possible (though this method is advisory and the reservation is not guaranteed to be respected). One use of this method is to reserve space at the start of the file for index nodes, leaving the leaf nodes to later.
- (void) reserveSpaceForNodes:(u_int32_t)numNodes ofKind:(BTreeNodeKind)kind;

#pragma mark Cursor-based searching

///Returns a cursor pointing to the matching record if one is found, or nil.
- (ImpBTreeCursor *_Nullable) searchCatalogTreeForItemWithParentID:(HFSCatalogNodeID)cnid
	name:(ConstStr31Param _Nonnull)nodeName;

///Returns a cursor pointing to the matching record if one is found, or nil.
- (ImpBTreeCursor *_Nullable) searchCatalogTreeForItemWithParentID:(HFSCatalogNodeID)cnid
	unicodeName:(ConstHFSUniStr255Param _Nonnull)nodeName;

@end
