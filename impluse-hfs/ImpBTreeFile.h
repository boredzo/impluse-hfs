//
//  ImpBTreeFile.h
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-11-27.
//

#import <Foundation/Foundation.h>

#import "ImpForkUtilities.h"
#import "ImpBTreeNode.h"
#import "ImpBTreeHeaderNode.h"

@interface ImpBTreeFile : NSObject <NSFastEnumeration>

- (instancetype _Nullable )initWithData:(NSData *_Nonnull const)bTreeFileContents;

///Debugging method. Returns the number of total nodes in the tree, live or otherwise (that is, the total length in bytes of the file divided by the size of one node).
- (NSUInteger) numberOfPotentialNodes;
///Debugging method. Returns the number of nodes in the tree that are reachable: 1 for the header node, plus the number of map nodes (siblings to the header node), the number of index nodes, and the number of leaf nodes.
- (NSUInteger) numberOfLiveNodes;

///Returns the first node in the file if there is one and it is a header node. Otherwise, returns nil.
- (ImpBTreeHeaderNode *_Nullable const) headerNode;

- (ImpBTreeNode *_Nonnull const) nodeAtIndex:(u_int32_t const)idx;

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

///Search the catalog tree for the file or folder record that defines the item with this CNID. Returns by reference the catalog key and file or folder record and returns true, or returns false without touching the pointers if no matching record is found.
- (bool) searchCatalogTreeForItemWithParentID:(HFSCatalogNodeID)cnid
	name:(ConstStr31Param _Nonnull)nodeName
	getRecordKeyData:(NSData *_Nullable *_Nullable const)outRecordKeyData
	threadRecordData:(NSData *_Nullable *_Nullable const)outThreadRecordData;

///Search the catalog tree for the file or folder record that defines the item with this CNID. Returns by reference the catalog key and file or folder record and returns true, or returns false without touching the pointers if no matching record is found.
- (bool) searchCatalogTreeForItemWithParentID:(HFSCatalogNodeID)cnid
	name:(ConstStr31Param _Nonnull)nodeName
	getRecordKeyData:(NSData *_Nullable *_Nullable const)outRecordKeyData
	fileOrFolderRecordData:(NSData *_Nullable *_Nullable const)outItemRecordData;

///Search for nodes matching a catalog ID, and call the block with every record under its leaf nodes, in order. Return the number of records encountered. Undefined if called on a B*-tree that isn't an extents overflow tree.
- (NSUInteger) searchExtentsOverflowTreeForCatalogNodeID:(HFSCatalogNodeID)cnid
	fork:(ImpForkType)forkType
	firstExtentStart:(u_int32_t)startBlock
	forEachRecord:(bool (^_Nonnull const)(NSData *_Nonnull const recordData))block;

@end
