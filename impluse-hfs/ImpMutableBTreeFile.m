//
//  ImpMutableBTreeFile.m
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-12-17.
//

#import "ImpMutableBTreeFile.h"

#import "NSData+ImpSubdata.h"
#import "ImpBTreeFile.h"
#import "ImpBTreeHeaderNode.h"
#import "ImpBTreeMapNode.h"
#import "ImpBTreeIndexNode.h"
//TEMP
#import "ImpTextEncodingConverter.h"

@interface ImpBTreeCursor ()

- (instancetype _Nonnull) initWithNode:(ImpBTreeNode *_Nonnull const)node recordIndex:(u_int16_t const)recordIdx;

@end

@implementation ImpMutableBTreeFile
{
	NSMutableData *_Nonnull _mutableBTreeData;
	ImpBTreeNode *_Nullable _lastLeafNode;
	u_int32_t _nextIndexNodeIndex;
	u_int32_t _nextLeafNodeIndex;
}

- (instancetype _Nullable)initWithVersion:(ImpBTreeVersion const)version convertTree:(ImpBTreeFile *_Nonnull const)sourceTree
{
	NSParameterAssert(version == (sourceTree.version << 8));

	//The superclass initializer requires data to back the tree. Estimate the size needed as 1.5 times the number of live nodes in the original tree.
	NSUInteger const estimatedNumNodes = (sourceTree.numberOfLiveNodes * 3) / 2;
	u_int16_t const nodeSize = [[self class] nodeSizeForVersion:version];
	u_int16_t const maxKeyLength = [[self class] maxKeyLengthForVersion:version];
	NSMutableData *_Nonnull const fileData = [NSMutableData dataWithLength:nodeSize * estimatedNumNodes];

	//Populate the header node of this data.
	//Do this before super init in case the superclass initializer needs to consult the header node.
	[ImpBTreeHeaderNode convertHeaderNode:sourceTree.headerNode forTreeVersion:version intoData:fileData nodeSize:nodeSize maxKeyLength:maxKeyLength];
	u_int8_t const *_Nonnull const bytePtr = fileData.bytes + sizeof(struct BTNodeDescriptor) + sizeof(struct BTHeaderRec) + 128;

	if ((self = [super initWithVersion:version data:fileData nodeSize:nodeSize copyData:false])) {
		_mutableBTreeData = fileData;

		_nextIndexNodeIndex = 1;
		_nextLeafNodeIndex = _nextIndexNodeIndex + 0;
	}

	return self;
}

#pragma mark Overrides of superclass methods

- (bool) hasMutableNodes {
	return true;
}

- (u_int64_t) offsetInFileOfPointer:(void const *_Nonnull const)ptr {
	return ptr - _mutableBTreeData.mutableBytes;
}

- (NSData *_Nonnull) sliceData:(NSData *_Nonnull const)data selectRange:(NSRange)range {
	return [data dangerouslyFastMutableSubdataWithRange_Imp:range];
}

///Allocates map nodes until there is enough space in the header node's map record + the total space in all map nodes to hold at least numberOfNodes bits. Returns the total number of bits of capacity allocated. Map nodes allocated will be connected as siblings to the header node (i.e., the header node's fLink will be the first map node, the first map node's fLink will be the second, and so on).
///This method also sets bits in the map to indicate that the positions of the header node (node 0) and any map nodes are allocated.
- (u_int32_t) allocateNodesForMapOfSize:(u_int32_t)numberOfNodes {
	ImpBTreeHeaderNode *_Nonnull const headerNode = (ImpBTreeHeaderNode *)[self nodeAtIndex:0];
	NSData *_Nonnull const initialMapData = [headerNode recordDataAtIndex:2];

	u_int32_t numPotentialNodesInMap = (u_int32_t)initialMapData.length * 8;

	ImpBTreeNode *_Nonnull lastNode = headerNode;

	//Add map records until we have enough nodes.
	while (numPotentialNodesInMap < numberOfNodes) {
		ImpBTreeMapNode *_Nullable mapNode = (ImpBTreeMapNode *_Nullable)lastNode.nextNode;
		if (! mapNode) {
			mapNode = (ImpBTreeMapNode *_Nonnull)[self allocateNewNodeOfKind:kBTMapNode populate:nil];
			[lastNode connectNextNode:mapNode];
		}
		numPotentialNodesInMap += mapNode.numberOfBits;
	}
	return numPotentialNodesInMap;
}

///Allocate this many blank index nodes. Does not attempt to connect them to each other. Returns the node indexes of all created index nodes, in breadth-first order.
- (NSArray <NSNumber *> *_Nonnull const) allocateNodesForIndexOfSize:(u_int32_t)numIndexNodes {
	NSMutableArray <NSNumber *> *_Nonnull const nodeIndexes = [NSMutableArray arrayWithCapacity:numIndexNodes];
	for (u_int32_t i = 0; i < numIndexNodes; ++i) {
		ImpBTreeNode *_Nonnull const node = [self allocateNewNodeOfKind:kBTIndexNode populate:nil];
		[nodeIndexes addObject:@(node.nodeNumber)];
	}
	return nodeIndexes;
}

///Append a leaf record (such as a catalog record) to the end of the row of leaf nodes. If the last leaf node in the row has enough space for it, adds the record to that node; otherwise, allocates a new node as the next sibling of the former last leaf node, then adds the record to that one. Returns the node the record was added to (i.e., the last leaf node, whether it existed before or not).
///Returns nil if the record data is simply too big to fit into a node.
- (ImpBTreeNode *_Nullable const) appendLeafRecord:(NSData *_Nonnull const)leafData {
	ImpBTreeNode *_Nullable lastLeafNode = _lastLeafNode;
	if (lastLeafNode == nil) {
		lastLeafNode = [self allocateNewNodeOfKind:kBTLeafNode populate:nil];
		_lastLeafNode = lastLeafNode;
	}

	bool const appendedToExistingLast = [lastLeafNode appendRecordWithData:leafData];
	if (! appendedToExistingLast) {
		ImpBTreeNode *_Nonnull const nextLeafNode = [self allocateNewNodeOfKind:kBTLeafNode populate:nil];
		[lastLeafNode connectNextNode:nextLeafNode];
		_lastLeafNode = lastLeafNode = nextLeafNode;
		bool const appendedToNewLast = [lastLeafNode appendRecordWithData:leafData];
		if (! appendedToNewLast) {
			lastLeafNode = nil;
		}
	}

	return lastLeafNode;
}

- (void) convertLeafNodesFromSourceCatalogTree:(ImpBTreeFile *_Nonnull const)sourceTree {
	/*The tricky bit is, we can't just convert leaf records straight across in the same order, for three reasons:
	 *- For files in the catalog file, we probably need to add a thread record (optional in HFS, mandatory in HFS+).
	 *- File thread records may be at a very different position in the leaf row from the corresponding file record, because the file thread record's key has the file ID as its “parent ID”, whereas the file record's key has the actual parent (directory) of the file. These are two different CNIDs and cannot be assumed to be anywhere near each other in the number sequence.
	 *- The order of names (and therefore items) may change between HFS's MacRoman-ish 8-bit encoding and HFS+'s Unicode flavor. This not only changes the leaf row, it can also ripple up into the index.
	 *
	 *We need to grab the keys, the source file or folder records, and the source thread records, and generate a list of items. Each item has a converted file or folder record with corresponding key, and a converted or generated thread record and corresponding key. From these items, we can extract both records and put those key-value pairs into a sorted array, and then use that array to populate the converted leaf row.
	 */
}

- (void) convertLeafNodesFromSourceExtentsOverflowTree:(ImpBTreeFile *_Nonnull const)sourceTree {
	//Unlike the catalog file, we can convert records in this file 1:1 (as long as we don't change items' CNIDs, which would necessitate re-sorting).

	ImpBTreeNode *_Nullable sourceLeaf = sourceTree.headerNode.firstLeafNode;
	while (sourceLeaf != nil) {

	}
}

///This method MUST be called after both the creation of the index (allocateNodesForIndexOfSize:) and the population of the leaf row (convertLeafNodesFromSourceTree:).
- (void) convertIndexNodesFromSourceTree:(ImpBTreeFile *_Nonnull const)sourceTree {
	ImpBTreeHeaderNode *_Nonnull const sourceHeaderNode = sourceTree.headerNode;
	NSMutableArray <NSMutableArray <ImpBTreeNode *> *> *_Nonnull const indexRows = [NSMutableArray arrayWithCapacity:sourceHeaderNode.treeDepth];

	NSUInteger rowWidth = 0;
	//Each index row starts with the first index node of a given height. When we hit a leaf node, we've exhausted the index rows.
	//The first index row is the row that starts with the root node.
	ImpBTreeNode *_Nonnull sourceNode = sourceHeaderNode.rootNode;
	while (sourceNode != nil && sourceNode.nodeType == kBTIndexNode) {
		NSData *_Nonnull const sourceNodeFirstPointerRecordPayload = [sourceNode recordPayloadDataAtIndex:0];
		ImpBTreeNode *_Nonnull const nextSourceNodeDown = [sourceTree nodeAtIndex:L(*(u_int32_t const *)sourceNodeFirstPointerRecordPayload.bytes)];

		while (sourceNode != nil)  {
			++rowWidth;
			sourceNode = sourceNode.nextNode;
		}
		NSMutableArray <ImpBTreeNode *> *_Nonnull const thisRow = [NSMutableArray arrayWithCapacity:rowWidth];

		sourceNode = nextSourceNodeDown;
		[indexRows addObject:thisRow];
		rowWidth = 0;
	}

	u_int32_t leafRowWidth = 0;
	//Iterate over our leaf row (not the source one!), populating the last index row with a record for every key.
	//Note that number of keys != number of records != number of nodes. HFS+ has two records for every key (a file or folder record and a thread record), and keys vary in size so the number of keys per node varies.

	//Filter the keys upward through the index rows up to the root node.
	//Note that the first key must ALWAYS remain in the tree:
	// 0            40          80       <-root node
	// 0      20    40    60    80
	// 0   10 20 30 40 50 60 70 80 90
	// 0 5 10   ...   ...   ...    90 95 <-last index row

}

- (void) reserveSpaceForNodes:(u_int32_t)numNodes ofKind:(BTreeNodeKind)kind {
	if (kind == kBTIndexNode) {
		_nextLeafNodeIndex = (_nextLeafNodeIndex - _nextIndexNodeIndex) + numNodes;
	}
}

///Returns the first available index for allocation of a new node of the specified kind, or 0 if no nodes are available. If this method returns 0, you will need to grow the file by some number of nodes, and potentially add a new map node.
- (u_int32_t) nextNodeIndexOfKind:(BTreeNodeKind)kind {
	u_int32_t idx = 0;

	//Start from an existing reservation or previous allocation if we have one. Otherwise, start from the beginning.
	switch (kind) {
		case kBTLeafNode:
			idx = _nextLeafNodeIndex;
			break;
		case kBTIndexNode:
			idx = _nextIndexNodeIndex;
			break;

		default:
			idx = 1;
			break;
	}
	bool const advanceBoth = (_nextLeafNodeIndex == _nextIndexNodeIndex);

	//Consult the map to find the next available node.
	u_int32_t const searchStartIdx = idx;
	while (idx < self.numberOfPotentialNodes && [self isNodeAllocatedAtIndex:idx]) {
		++idx;
	}
	if ([self isNodeAllocatedAtIndex:idx]) {
		//We ran out of indexes without finding an open slot. Try searching toward the beginning instead.
		for (idx = searchStartIdx; idx > 0 && [self isNodeAllocatedAtIndex:idx]; --idx);

		if ([self isNodeAllocatedAtIndex:idx]) {
			//Bummer. We're full—all nodes are in use. We'll need to grow the file.
			return 0;
		}
	}

	//Update one or both of our cursor variables with the final node index + 1.
	if (advanceBoth) {
		_nextLeafNodeIndex = idx + 1;
		_nextIndexNodeIndex = idx + 1;
	} else if (kind == kBTLeafNode) {
		_nextLeafNodeIndex = idx + 1;
	} else if (kind == kBTIndexNode) {
		_nextIndexNodeIndex = idx + 1;
	}

	return idx;
}

///Allocate one new node of the specified kind, and call the block to populate it with data. If the block is nil, the node will be left blank aside from its node descriptor.
///bytes is a pointer to the BTNodeDescriptor at the start of the node, and length is equal to the tree's nodeSize.
- (ImpBTreeNode *_Nonnull const) allocateNewNodeOfKind:(BTreeNodeKind const)kind populate:(void (^_Nullable const)(void *_Nonnull bytes, NSUInteger length))block {
	u_int32_t const nodeIndex = [self nextNodeIndexOfKind:kind];

	//Note: We can't use nodeDataAtIndex: since that may return an immutable NSData. We specifically need to populate this data.
	NSUInteger const bytesPerNode = self.bytesPerNode;
	NSRange const nodeByteRange = { bytesPerNode * nodeIndex, bytesPerNode };
	//TODO: Grow the backing data if NSMaxRange(nodeByteRange) > _mutableBTreeData.length.

	NSMutableData *_Nonnull const nodeData = (NSMutableData *)[self sliceData:_mutableBTreeData selectRange:nodeByteRange];
	struct BTNodeDescriptor *_Nonnull const nodeDesc = nodeData.mutableBytes;

	//In case we're reusing a deallocated node, zero out the node descriptor.
	bzero(nodeDesc, sizeof(*nodeDesc));
	S(nodeDesc->kind, kind);
	u_int16_t *_Nonnull const firstRecordOffsetPtr = (nodeData.mutableBytes + nodeByteRange.length - sizeof(u_int16_t) * 1);
	//First record offset: Offset to empty space.
	S(*firstRecordOffsetPtr, sizeof(*nodeDesc));

	[self markNodeAsAllocatedAtIndex:nodeIndex];

	ImpBTreeNode *_Nonnull const node = [ImpBTreeNode mutableNodeWithTree:self data:nodeData];
	node.nodeNumber = nodeIndex;
	node.byteRange = nodeByteRange;
	[self storeNode:node inCacheAtIndex:nodeIndex];

	if (block != nil) {
		block(nodeDesc, bytesPerNode);
	}

	return node;
}

#pragma mark Node allocation

//See superclass for isNodeAllocated:.

- (void) markNodeAsAllocatedAtIndex:(NSUInteger)nodeIdx {
	[self.headerNode allocateNode:nodeIdx];
}
- (void) markNodeAsFreeAtIndex:(NSUInteger)nodeIdx {
	[self.headerNode deallocateNode:nodeIdx];
}

#pragma mark Cursor-based searching

- (ImpBTreeCursor *_Nullable) searchCatalogTreeWithKeyComparator:(ImpBTreeRecordKeyComparator _Nonnull const)compareKeys {
	ImpBTreeNode *_Nullable foundNode = nil;
	u_int16_t recordIdx = 0;
	bool const found = [self searchTreeForItemWithKeyComparator:compareKeys
		getNode:&foundNode
		recordIndex:&recordIdx];

	if (found) {
		return [[ImpBTreeCursor alloc] initWithNode:foundNode recordIndex:recordIdx];
	}

	return false;
}

- (ImpBTreeCursor *_Nullable) searchCatalogTreeForItemWithParentID:(HFSCatalogNodeID)cnid
	name:(ConstStr31Param _Nonnull)nodeName
{
	struct HFSCatalogKey quarryCatalogKey = {
		.keyLength = sizeof(struct HFSCatalogKey),
		.reserved = 0,
	};
	S(quarryCatalogKey.parentID, cnid);
	memcpy(quarryCatalogKey.nodeName, nodeName, nodeName[0] + 1);
	quarryCatalogKey.keyLength -= sizeof(quarryCatalogKey.keyLength);
	S(quarryCatalogKey.keyLength, quarryCatalogKey.keyLength);

	ImpBTreeRecordKeyComparator _Nonnull const compareKeys = ^ImpBTreeComparisonResult(const void *const  _Nonnull foundKeyPtr) {
		struct HFSCatalogKey const *_Nonnull const foundCatKeyPtr = foundKeyPtr;
		return ImpBTreeCompareHFSCatalogKeys(&quarryCatalogKey, foundCatKeyPtr);
	};

	return [self searchCatalogTreeWithKeyComparator:compareKeys];
}

- (ImpBTreeCursor *_Nullable) searchCatalogTreeForItemWithParentID:(HFSCatalogNodeID)cnid
	unicodeName:(ConstHFSUniStr255Param _Nonnull)nodeName
{
	struct HFSPlusCatalogKey quarryCatalogKey = {
		.keyLength = sizeof(struct HFSPlusCatalogKey),
		.parentID = cnid,
	};
	memcpy(quarryCatalogKey.nodeName.unicode, nodeName->unicode, L(nodeName->length) * sizeof(UniChar));
	quarryCatalogKey.nodeName.length = nodeName->length;
	quarryCatalogKey.keyLength -= sizeof(quarryCatalogKey.keyLength);
//	ImpPrintf(@"Input node name is %u characters; node name in search key is %u characters", L(nodeName->length), L(quarryCatalogKey.nodeName.length));

	ImpTextEncodingConverter *_Nonnull const tec = [[ImpTextEncodingConverter alloc] initWithHFSTextEncoding:kTextEncodingMacRoman];
	ImpBTreeRecordKeyComparator _Nonnull const compareKeys = ^ImpBTreeComparisonResult(const void *const  _Nonnull foundKeyPtr) {
		struct HFSPlusCatalogKey const *_Nonnull const foundCatKeyPtr = foundKeyPtr;
		ImpBTreeComparisonResult const result = ImpBTreeCompareHFSPlusCatalogKeys(&quarryCatalogKey, foundCatKeyPtr);
		NSString *_Nonnull const quarryName = [tec stringFromHFSUniStr255:&(quarryCatalogKey.nodeName)];
		NSString *_Nonnull const foundName = [tec stringFromHFSUniStr255:&(foundCatKeyPtr->nodeName)];
//		ImpPrintf(@"Parent ID #%u, name “%@” vs parent ID #%u, name “%@” => %+d", L(quarryCatalogKey.parentID), quarryName, L(foundCatKeyPtr->parentID), foundName, result);
		return result;
	};

	return [self searchCatalogTreeWithKeyComparator:compareKeys];
}

@end

@implementation ImpBTreeCursor
{
	ImpBTreeNode *_Nonnull _node;
	u_int16_t _recordIdx;
}

- (instancetype _Nonnull) initWithNode:(ImpBTreeNode *_Nonnull const)node recordIndex:(u_int16_t const)recordIdx {
	if ((self = [super init])) {
		_node = node;
		_recordIdx = recordIdx;
	}
	return self;
}

- (NSData *_Nonnull) keyData {
	return [_node recordKeyDataAtIndex:_recordIdx];
}
- (NSData *_Nonnull) payloadData {
	return [_node recordPayloadDataAtIndex:_recordIdx];
}

- (void) setKeyData:(NSData *_Nonnull const)keyData {
	[_node replaceKeyOfRecordAtIndex:_recordIdx withKey:keyData];
}
- (void) setPayloadData:(NSData *_Nonnull const)payloadData {
	[_node replacePayloadOfRecordAtIndex:_recordIdx withPayload:payloadData];
}

@end
