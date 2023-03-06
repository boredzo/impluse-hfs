//
//  ImpBTreeFile.h
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-11-27.
//

#import <Foundation/Foundation.h>

#import "ImpForkUtilities.h"
#import "ImpComparisonUtilities.h"
#import "ImpBTreeTypes.h"

@class ImpBTreeNode;
@class ImpBTreeHeaderNode;

@interface ImpBTreeFile : NSObject <NSFastEnumeration>
{
	NSData *_Nonnull _bTreeData;
	u_int16_t _nodeSize;
}

///This is meant for the mutable subclass's use.
+ (u_int16_t) nodeSizeForVersion:(ImpBTreeVersion const)version;
///This is meant for the mutable subclass's use.
+ (u_int16_t) maxKeyLengthForVersion:(ImpBTreeVersion const)version;

///This is meant for the mutable subclass's use.
- (instancetype _Nullable )initWithVersion:(ImpBTreeVersion const)version data:(NSData *_Nonnull const)bTreeFileContents nodeSize:(u_int16_t const)nodeSize copyData:(bool const)copyData;

- (instancetype _Nullable )initWithVersion:(ImpBTreeVersion const)version data:(NSData *_Nonnull const)bTreeFileContents;

@property(readonly) ImpBTreeVersion version;

///Size of each node in the file in bytes. All nodes in any B*-tree file have the same size. Corresponds to BTHeaderRec.nodeSize. For HFS trees, this is always kISOStandardBlockSize; for HFS+ trees, the minimum node size varies by kind of tree, and the true node size is given in the header node (BTHeaderRec.nodeSize).
- (u_int16_t) bytesPerNode;

///Size of the keyLength field at the start of every record key. In HFS trees, this is always 1. In HFS+ trees, this is 2 if a particular attribute is set in the header record's attributes, and that attribute is always set.
- (u_int16_t) keyLengthSize;

///Returns the number of total nodes in the tree, live or otherwise (that is, the total length in bytes of the file divided by the size of one node).
- (NSUInteger) numberOfPotentialNodes;
///Returns the number of nodes in the tree that are reachable: 1 for the header node, plus the number of map nodes (siblings to the header node), the number of index nodes, and the number of leaf nodes.
- (NSUInteger) numberOfLiveNodes;

///Returns the length that this B*-tree would take up on disk, in bytes.
- (u_int64_t) lengthInBytes;

///Provides NSData containing a representation of this B*-tree that can be written to disk. Because this method may provide an internal backing store to avoid unnecessary copying, it calls your block with the data as an argument.
- (void) serializeToData:(void (^_Nonnull const)(NSData *_Nonnull const data))block;

///Returns the first node in the file if there is one and it is a header node. Otherwise, returns nil.
- (ImpBTreeHeaderNode *_Nullable const) headerNode;

- (ImpBTreeNode *_Nonnull const) nodeAtIndex:(u_int32_t const)idx;

///This is meant for the mutable subclass's use.
- (void) storeNode:(ImpBTreeNode *_Nonnull const)node inCacheAtIndex:(NSUInteger)idx;

///Returns an NSData that is a subdata of some data. The smaller data may be backed by the larger data, so the larger data should be kept alive until all slices are no longer needed.
///Mutable B*-tree subclasses may override this to return an NSMutableData.
///(This is a total hack, needed because ImpBTreeFiles have immutable data and ImpMutableBTreeFiles have mutable data. The latter need slices to be based on the parent data so changes will affect the parent, but the former can't just unconditionally make mutable slices, because you can't make mutable slices of immutable data. So, this method, and the ability to override it in the mutable subclass.)
- (NSData *_Nonnull) sliceData:(NSData *_Nonnull const)data selectRange:(NSRange)range;

///Given a pointer obtained from node or record data, return its offset from the start of the file.
- (u_int64_t) offsetInFileOfPointer:(void const *_Nonnull const)ptr;

//TODO: Gut this and make it equivalent to walkBreadthFirst: instead.
///Walks through the entire file in linear order and yields every node-space, whether or not it contains a node that is reachable from the root node. Yields NSData objects, each big enough to contain one B*-tree node. Expect to receive both valid and invalid nodes, in effectively random order (except for the header node being first).
- (NSUInteger)countByEnumeratingWithState:(NSFastEnumerationState *_Nonnull)state objects:(__unsafe_unretained id  _Nullable [_Nonnull])outObjects count:(NSUInteger)maxNumObjects;

///Starting from the root node, call the block for every node in the tree, in breadth-first order. Note that the header node and any map nodes are not included in this walk.
- (NSUInteger) walkBreadthFirst:(bool (^_Nonnull const)(ImpBTreeNode *_Nonnull const node))block;

///Starting from the first leaf node, call the block for every node from that one until the last leaf node, following nextNode/fLink connections. Whereas walkBreadthFirst: visits index and leaf nodes, this method only visits leaf nodes.
- (NSUInteger) walkLeafNodes:(bool (^_Nonnull const)(ImpBTreeNode *_Nonnull const node))block;

///Given the CNID of a folder, call one of the blocks with each item in that folder. Either block can return false to stop iteration. Returns the number of items visited. If the CNID does not refer to a folder, returns 0. (This includes if it is a file.)
///You can pass nil for either or both blocks. If you pass nil for both blocks, you'll find out how many items are actually in the folder, regardless of what its valence says.
- (NSUInteger) forEachItemInDirectory:(HFSCatalogNodeID)dirID
	file:(bool (^_Nullable const)(struct HFSCatalogKey const *_Nonnull const keyPtr, struct HFSCatalogFile const *_Nonnull const fileRec))visitFile
	folder:(bool (^_Nullable const)(struct HFSCatalogKey const *_Nonnull const keyPtr, struct HFSCatalogFolder const *_Nonnull const folderRec))visitFolder;

///Internal method used by higher-level search methods in both this class and the mutable subclass.
- (bool) searchTreeForItemWithKeyComparator:(ImpBTreeRecordKeyComparator _Nonnull const)compareKeys
	getNode:(ImpBTreeNode *_Nullable *_Nullable const)outNode
	recordIndex:(u_int16_t *_Nullable const)outRecordIdx;

///Search an HFS catalog tree for the file or folder record that defines the item with this CNID. Returns by reference the catalog key and file or folder record and returns true, or returns false without touching the pointers if no matching record is found.
- (bool) searchCatalogTreeForItemWithParentID:(HFSCatalogNodeID)cnid
	name:(ConstStr31Param _Nonnull)nodeName
	getRecordKeyData:(NSData *_Nullable *_Nullable const)outRecordKeyData
	threadRecordData:(NSData *_Nullable *_Nullable const)outThreadRecordData;

///Search an HFS+ catalog tree for the file or folder record that defines the item with this CNID. Returns by reference the catalog key and file or folder record and returns true, or returns false without touching the pointers if no matching record is found.
- (bool) searchCatalogTreeForItemWithParentID:(HFSCatalogNodeID)cnid
	unicodeName:(ConstHFSUniStr255Param _Nonnull)nodeName
	getRecordKeyData:(NSData *_Nullable *_Nullable const)outRecordKeyData
	threadRecordData:(NSData *_Nullable *_Nullable const)outThreadRecordData;

///Search an HFS catalog tree for the file or folder record that defines the item whose parent is this CNID and with this name. Returns by reference the catalog key and file or folder record and returns true, or returns false without touching the pointers if no matching record is found.
- (bool) searchCatalogTreeForItemWithParentID:(HFSCatalogNodeID)cnid
	name:(ConstStr31Param _Nonnull)nodeName
	getRecordKeyData:(NSData *_Nullable *_Nullable const)outRecordKeyData
	fileOrFolderRecordData:(NSData *_Nullable *_Nullable const)outItemRecordData;

///Search an HFS+ catalog tree for the file or folder record that defines the item whose parent is this CNID and with this name. Returns by reference the catalog key and file or folder record and returns true, or returns false without touching the pointers if no matching record is found.
- (bool) searchCatalogTreeForItemWithParentID:(HFSCatalogNodeID)cnid
	unicodeName:(ConstHFSUniStr255Param _Nonnull)nodeName
	getRecordKeyData:(NSData *_Nullable *_Nullable const)outRecordKeyData
	fileOrFolderRecordData:(NSData *_Nullable *_Nullable const)outItemRecordData;

///Search for nodes matching a catalog ID, and call the block with every record under its leaf nodes, in order. Return the number of records encountered. Undefined if called on a B*-tree that isn't an extents overflow tree.
- (NSUInteger) searchExtentsOverflowTreeForCatalogNodeID:(HFSCatalogNodeID)cnid
	fork:(ImpForkType)forkType
	precededByNumberOfBlocks:(u_int32_t)totalBlockCount
	forEachRecord:(bool (^_Nonnull const)(NSData *_Nonnull const recordData))block;

#pragma mark Node map

///Returns whether the node at a given index (0-based) is allocated according to the header node's map record and any map nodes.
- (bool) isNodeAllocatedAtIndex:(NSUInteger)nodeIdx;

@end
