//
//  ImpBTreeFile.m
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-11-27.
//

#import "ImpBTreeFile.h"

#import <hfs/hfs_format.h>
#import "ImpByteOrder.h"
#import "ImpSizeUtilities.h"
#import "ImpComparisonUtilities.h"
#import "NSData+ImpSubdata.h"
#import "ImpBTreeHeaderNode.h"
#import "ImpBTreeIndexNode.h"
#import "ImpTextEncodingConverter.h"

@implementation ImpBTreeFile
{
	struct BTNodeDescriptor const *_Nonnull _nodes;
	NSUInteger _numPotentialNodes;
	NSMutableArray *_Nullable _lastEnumeratedObjects;
	NSMutableArray <ImpBTreeNode *> *_Nullable _nodeCache;
}

+ (u_int16_t) nodeSizeForVersion:(ImpBTreeVersion const)version {
	switch (version) {
		case ImpBTreeVersionHFSCatalog:
			return BTreeNodeLengthHFSStandard;
			break;
		case ImpBTreeVersionHFSExtentsOverflow:
			return BTreeNodeLengthHFSStandard;
			break;
		case ImpBTreeVersionHFSPlusCatalog:
			return BTreeNodeLengthHFSPlusCatalogMinimum;
			break;
		case ImpBTreeVersionHFSPlusExtentsOverflow:
			return BTreeNodeLengthHFSPlusExtentsOverflowMinimum;
			break;
		case ImpBTreeVersionHFSPlusAttributes:
			return BTreeNodeLengthHFSPlusAttributesMinimum;
			break;
		default:
			NSAssert(false, @"Can't determine node size for unrecognized B*-tree version 0x%02lx", (unsigned long)version);
			return 0;
	}
}

+ (u_int16_t) maxKeyLengthForVersion:(ImpBTreeVersion const)version {
	switch (version) {
		case ImpBTreeVersionHFSCatalog:
			return kHFSCatalogKeyMaximumLength;
			break;
		case ImpBTreeVersionHFSExtentsOverflow:
			return kHFSExtentKeyMaximumLength;
			break;
		case ImpBTreeVersionHFSPlusCatalog:
			return kHFSPlusCatalogKeyMaximumLength;
			break;
		case ImpBTreeVersionHFSPlusExtentsOverflow:
			return kHFSPlusExtentKeyMaximumLength;
			break;
		case ImpBTreeVersionHFSPlusAttributes:
			//TN1150: “The maximum key length for the attributes B-tree will probably be a little larger than for the catalog file.” ¯\_(ツ)_/¯
			return kHFSPlusCatalogKeyMaximumLength;
			break;
		default:
			NSAssert(false, @"Can't determine max key length for unrecognized B*-tree version 0x%02lx", (unsigned long)version);
			return 0;
	}
}

- (instancetype _Nullable )initWithVersion:(ImpBTreeVersion const)version data:(NSData *_Nonnull const)bTreeFileContents nodeSize:(u_int16_t const)nodeSize copyData:(bool const)copyData {
	if ((self = [super init])) {
		_version = version;

		_bTreeData = copyData ? [bTreeFileContents copy] : bTreeFileContents;
		_nodes = _bTreeData.bytes;
		_nodeSize = nodeSize;

		_numPotentialNodes = _bTreeData.length / _nodeSize;

		_nodeCache = [NSMutableArray arrayWithCapacity:_numPotentialNodes];
		NSNull *_Nonnull const null = [NSNull null];
		for (NSUInteger i = 0; i < _numPotentialNodes; ++i) {
			[_nodeCache addObject:(ImpBTreeNode *)null];
		}
	}
	return self;
}

- (instancetype _Nullable )initWithVersion:(ImpBTreeVersion const)version data:(NSData *_Nonnull const)bTreeFileContents {
	_version = version;
	u_int16_t nodeSize = [[self class] nodeSizeForVersion:_version];

	NSString *_Nullable versionName = nil;
	switch (_version) {
		case ImpBTreeVersionHFSCatalog:
			versionName = @"HFS catalog";
			break;
		case ImpBTreeVersionHFSExtentsOverflow:
			versionName = @"HFS extents overflow";
			break;
		case ImpBTreeVersionHFSPlusCatalog:
			versionName = @"HFS+ catalog";
			break;
		case ImpBTreeVersionHFSPlusExtentsOverflow:
			versionName = @"HFS+ extents overflow";
			break;
		case ImpBTreeVersionHFSPlusAttributes:
			versionName = @"HFS+ attributes";
			break;
		default:
			NSAssert(false, @"Unrecognized B*-tree version 0x%02lx", (unsigned long)version);
	}

	NSAssert(bTreeFileContents.length >= _nodeSize, @"Cannot read B*-tree from data of length %lu when expected node size is (at least) %u for an %@ tree", bTreeFileContents.length, _nodeSize, versionName);

	bool copyData = false;

	struct BTNodeDescriptor const *_Nonnull const nodes = bTreeFileContents.bytes;
	BTreeNodeKind const thisNodeKind = L(nodes[0].kind);
	if (thisNodeKind == kBTHeaderNode) {
		//This is data from an HFS volume (rather than blank data we've been given by our mutable subclass).
		copyData = true;

		//Get the actual node size for the later things which may depend on having the right size.
		ImpBTreeHeaderNode *_Nonnull const headerNode = [ImpBTreeHeaderNode nodeWithTree:self data:bTreeFileContents];
		nodeSize = headerNode.bytesPerNode;
	} else {
		//This is not a valid B*-tree file.
		self = nil;
	}

	return [self initWithVersion:version data:bTreeFileContents nodeSize:nodeSize copyData:copyData];
}

- (NSString *_Nonnull) description {
	return [NSString stringWithFormat:@"<%@ %p with up to %lu nodes>", self.class, self, _numPotentialNodes];
}

- (NSUInteger)count {
	return _numPotentialNodes;
}

- (u_int16_t) bytesPerNode {
	return _nodeSize;
}

- (u_int16_t) keyLengthSize {
	switch (self.version) {
		case ImpBTreeVersionHFSCatalog:
		case ImpBTreeVersionHFSExtentsOverflow:
			return sizeof(u_int8_t);

		case ImpBTreeVersionHFSPlusCatalog:
		case ImpBTreeVersionHFSPlusExtentsOverflow:
		case ImpBTreeVersionHFSPlusAttributes:
			return self.headerNode.hasBigKeys ? sizeof(u_int16_t) : sizeof(u_int8_t);

		default:
			return 0;
	}
}

///Debugging method. Returns the number of total nodes in the tree, live or otherwise (that is, the total length in bytes of the file divided by the size of one node).
- (NSUInteger) numberOfPotentialNodes {
	return _numPotentialNodes;
}
///Debugging method. Returns the number of nodes in the tree that are reachable: 1 for the header node, plus the number of map nodes (siblings to the header node), the number of index nodes, and the number of leaf nodes.
- (NSUInteger) numberOfLiveNodes {
	__block NSUInteger count = 0;

	//Count up the header node and any map nodes.
	for (ImpBTreeNode *_Nullable node = self.headerNode; node != nil; node = node.nextNode) {
		++count;
	}

	//Count up the index and leaf nodes.
	NSMutableSet *_Nonnull const nodesAlreadyEncountered = [NSMutableSet setWithCapacity:_numPotentialNodes - count];
	[self walkBreadthFirst:^bool(ImpBTreeNode *const  _Nonnull node) {
		[nodesAlreadyEncountered addObject:node];
		return true;
	}];
	count += nodesAlreadyEncountered.count;

	return count;
}

#pragma mark Serialization

- (u_int64_t) lengthInBytes {
	return _bTreeData.length;
}
- (void) serializeToData:(void (^_Nonnull const)(NSData *_Nonnull const data))block {
	block(_bTreeData);
}

#pragma mark Node access

- (ImpBTreeNode *_Nullable) alreadyCachedNodeAtIndex:(NSUInteger)idx {
	return idx < _nodeCache.count
		? _nodeCache[idx]
		: nil;
}
- (void) storeNode:(ImpBTreeNode *_Nonnull const)node inCacheAtIndex:(NSUInteger)idx {
	_nodeCache[idx] = node;
}

- (ImpBTreeHeaderNode *_Nullable const) headerNode {
	ImpBTreeNode *_Nonnull const node = [self nodeAtIndex:0];
	if (node.nodeType == kBTHeaderNode) {
		return (ImpBTreeHeaderNode *_Nonnull const)node;
	}
	return nil;
}

- (u_int64_t) offsetInFileOfPointer:(void const *_Nonnull const)ptr {
	return ptr - _bTreeData.bytes;
}

- (NSData *_Nonnull) sliceData:(NSData *_Nonnull const)data selectRange:(NSRange)range {
	return [data dangerouslyFastSubdataWithRange_Imp:range];
}

///Given the index (aka node number) of a node in the file, return an NSData containing that node's raw bytes, either sourced from disk or suitable for writing to disk.
///This may or may not be a subdata of a larger NSData. Subclasses may override this if they keep node data in a different format, such as an array of individual NSDatas.
- (NSData *_Nonnull const) nodeDataAtIndex:(u_int32_t const)idx {
	NSRange const nodeByteRange = { _nodeSize * idx, _nodeSize };
	NSData *_Nonnull const nodeData = [self sliceData:_bTreeData selectRange:nodeByteRange];
	return nodeData;
}

- (bool) hasMutableNodes {
	return false;
}

- (bool) isValidIndex:(u_int32_t const)nodeIndex {
	return nodeIndex == 0 || nodeIndex < self.numberOfPotentialNodes;
}

- (ImpBTreeNode *_Nonnull const) nodeAtIndex:(u_int32_t const)idx {
	if (idx >= _numPotentialNodes) {
		//This will throw a range exception.
		return _nodeCache[idx];
	}

	ImpBTreeNode *_Nonnull const oneWeMadeEarlier = [self alreadyCachedNodeAtIndex:idx];
	if (oneWeMadeEarlier != (ImpBTreeNode *)[NSNull null]) {
		return oneWeMadeEarlier;
	}

	//TODO: Create all of these once, probably up front, and keep them in an array. Turn this into objectAtIndex: and the fast enumeration into fast enumeration of that array.
	NSData *_Nonnull const nodeData = [self nodeDataAtIndex:idx];
	ImpBTreeNode *_Nonnull const node = [ImpBTreeNode nodeWithTree:self data:nodeData copy:false mutable:self.hasMutableNodes]; //copy:false because we either already copied it when the tree was created or we're intentionally creating a mutable subdata of a mutable data.
	node.nodeNumber = idx;
	NSRange const nodeByteRange = { _nodeSize * idx, _nodeSize };
	node.byteRange = nodeByteRange;
	[self storeNode:node inCacheAtIndex:idx];

	return node;
}

#pragma mark Node traversal and search

- (NSUInteger)countByEnumeratingWithState:(NSFastEnumerationState *_Nonnull)state
	objects:(__unsafe_unretained id  _Nullable [_Nonnull])outObjects
	count:(NSUInteger)maxNumObjects
{
	NSRange const lastReturnedRange = {
		state->extra[0],
		state->extra[1],
	};
	NSRange nextReturnedRange = {
		lastReturnedRange.location + lastReturnedRange.length,
		maxNumObjects,
	};
	if (nextReturnedRange.location >= self.count) {
		return 0;
	}
	if (NSMaxRange(nextReturnedRange) >= self.count) {
		nextReturnedRange.length = self.count - nextReturnedRange.location;
	}

	if (_lastEnumeratedObjects == nil) {
		_lastEnumeratedObjects = [NSMutableArray arrayWithCapacity:nextReturnedRange.length];
	} else {
		[_lastEnumeratedObjects removeAllObjects];
	}
	for (NSUInteger	i = 0; i < nextReturnedRange.length; ++i) {
		u_int32_t const nodeNumber = (u_int32_t)(nextReturnedRange.location + i);

		NSData *_Nonnull const data = [self nodeDataAtIndex:nodeNumber];
		ImpBTreeNode *_Nonnull const node = [ImpBTreeNode nodeWithTree:self data:data];
		node.nodeNumber = nodeNumber;

		[_lastEnumeratedObjects addObject:node];
		outObjects[i] = node;
	}
	state->extra[0] = nextReturnedRange.location;
	state->extra[1] = nextReturnedRange.length;
	state->mutationsPtr = &_numPotentialNodes;
	state->itemsPtr = outObjects;
	return nextReturnedRange.length;
}

- (NSUInteger) _walkNodeAndItsSiblingsAndThenItsChildren:(ImpBTreeNode *_Nonnull const)startNode keepIterating:(bool *_Nullable const)outKeepIterating block:(bool (^_Nonnull const)(ImpBTreeNode *_Nonnull const node))block {
	NSUInteger numNodesVisited = 0;
	bool keepIterating = true;

	for (ImpBTreeNode *_Nullable node = startNode; keepIterating && node != nil; node = node.nextNode) {
		keepIterating = block(node);
		++numNodesVisited;
	}
	//An older, slower version of this method would at this point loop through the whole row again, and then each node's children, calling _walkNodeAndBlahBlah::: on each child. Guess what—that visits every node an incredibly excessive number of redundant times!
	//I hadn't yet figured out that HFS B*-trees are organized into rows. We don't need to visit every child of every node—the first child of this node gets us down to the next row.
	//In theory we should rewind to the start of the row via bLink members, but in practice we are only called by walkBreadthFirst:, so we can assume startNode is always the first node on a row.
	if (startNode.nodeType == kBTIndexNode) {
		ImpBTreeIndexNode *_Nonnull const indexNode = (ImpBTreeIndexNode *_Nonnull const)startNode;
		ImpBTreeNode *_Nullable const firstChild = indexNode.children.firstObject;
		if (firstChild != nil) {
			numNodesVisited = [self _walkNodeAndItsSiblingsAndThenItsChildren:firstChild keepIterating:&keepIterating block:block];
		}
	}

	if (outKeepIterating != NULL) {
		*outKeepIterating = keepIterating;
	}

	return numNodesVisited;
}
- (NSUInteger) walkBreadthFirst:(bool (^_Nonnull const)(ImpBTreeNode *_Nonnull const node))block {
	ImpBTreeHeaderNode *_Nullable const headerNode = self.headerNode;
	if (headerNode == nil) {
		//No header node. Welp!
		return 0;
	}

	ImpBTreeNode *_Nullable const rootNode = headerNode.rootNode;
	if (rootNode == nil) {
		//No root node. Welp!
		return 0;
	}

	return [self _walkNodeAndItsSiblingsAndThenItsChildren:rootNode keepIterating:NULL block:block];
}

- (NSUInteger) walkLeafNodes:(bool (^_Nonnull const)(ImpBTreeNode *_Nonnull const node))block {
	ImpBTreeHeaderNode *_Nullable const headerNode = self.headerNode;
	if (headerNode == nil) {
		//No header node. Welp!
		return 0;
	}

	NSUInteger numVisited = 0;

	ImpBTreeNode *_Nullable firstNode = headerNode.firstLeafNode;
	ImpBTreeNode *_Nullable node = firstNode;
	while (node != nil) {
		++numVisited;

		bool const keepIterating = block(node);
		if (! keepIterating) break;

		node = node.nextNode;
	}

	return numVisited;
}

- (NSUInteger) forEachItemInHFSDirectory:(HFSCatalogNodeID)dirID
	file:(bool (^_Nullable const)(struct HFSCatalogKey const *_Nonnull const keyPtr, struct HFSCatalogFile const *_Nonnull const fileRec))visitFile
	folder:(bool (^_Nullable const)(struct HFSCatalogKey const *_Nonnull const keyPtr, struct HFSCatalogFolder const *_Nonnull const folderRec))visitFolder
{
	__block NSUInteger numVisited = 0;
	__block bool keepIterating = true;

	//We're looking for a thread record with this CNID. Thread records have an empty name and are the first record that has this CNID in its key. All of the (zero or more) file and folder records after it that have this CNID in their key are immediate children of this folder.
	ImpBTreeRecordKeyComparator _Nonnull const compareKeys = ^ImpBTreeComparisonResult(const void *const  _Nonnull foundKeyPtr) {
		struct HFSCatalogKey const *_Nonnull const foundCatKeyPtr = foundKeyPtr;
		if (dirID < L(foundCatKeyPtr->parentID)) {
			return ImpBTreeComparisonQuarryIsLesser;
		}
		if (dirID > L(foundCatKeyPtr->parentID)) {
			return ImpBTreeComparisonQuarryIsGreater;
		}
		//We're searching for an empty name because it's the first one with a given parent ID. Any non-empty name comes after it.
		if (foundCatKeyPtr->nodeName[0] > 0) {
			return ImpBTreeComparisonQuarryIsLesser;
		}
		return ImpBTreeComparisonQuarryIsEqual;
	};

	ImpBTreeNode *_Nullable threadRecordNode = nil;
	u_int16_t threadRecordIdx;
	if ([self searchTreeForItemWithKeyComparator:compareKeys getNode:&threadRecordNode recordIndex:&threadRecordIdx]) {
		ImpBTreeNode *_Nullable node = threadRecordNode;
		u_int16_t recordIdx = threadRecordIdx + 1;

		while (keepIterating && node != nil) {
			for (u_int16_t i = recordIdx; keepIterating && i < node.numberOfRecords; ++i) {
				NSData *_Nonnull const keyData = [node recordKeyDataAtIndex:i];
				struct HFSCatalogKey const *_Nonnull const keyPtr = keyData.bytes;

				if (L(keyPtr->parentID) != dirID) {
					//We've run out of items with the parent we're looking for. Time to bail.
					keepIterating = false;
				} else {
					++numVisited;

					NSData *_Nonnull const payloadData = [node recordPayloadDataAtIndex:i];
					void const *_Nonnull const payloadPtr = payloadData.bytes;

					u_int8_t const *_Nonnull const recordTypePtr = payloadPtr;
					switch (*recordTypePtr << 8) {
						case kHFSFileRecord:
							if (visitFile != nil) {
								keepIterating = visitFile(keyPtr, payloadPtr);
							}
							break;
						case kHFSFolderRecord:
							if (visitFolder != nil) {
								keepIterating = visitFolder(keyPtr, payloadPtr);
							}
							break;
						case kHFSFileThreadRecord:
						case kHFSFolderThreadRecord:
						default:
							//Not really anything here to do anything—although, if we find a thread record *after* the thread record we should have already found, that seems sus.
							break;
					}
				}
			}
			node = node.nextNode;
			recordIdx = 0;
		}
	}

	return numVisited;
}

- (NSUInteger) forEachItemInHFSCatalog:(id _Nullable)reserved
	file:(bool (^_Nullable const)(struct HFSCatalogKey const *_Nonnull const keyPtr, struct HFSCatalogFile const *_Nonnull const fileRec))visitFile
	folder:(bool (^_Nullable const)(struct HFSCatalogKey const *_Nonnull const keyPtr, struct HFSCatalogFolder const *_Nonnull const folderRec))visitFolder
{
	__block NSUInteger numVisited = 0;
	__block bool keepIterating = true;
	[self walkLeafNodes:^bool(ImpBTreeNode *_Nonnull const node) {
		[node forEachHFSCatalogRecord_file:^(struct HFSCatalogKey const *_Nonnull const catalogKeyPtr, struct HFSCatalogFile const *_Nonnull const fileRecPtr) {
			if (keepIterating) {
				++numVisited;
				if (visitFile != nil) {
					keepIterating = visitFile(catalogKeyPtr, fileRecPtr);
				}
			}
		} folder:^(struct HFSCatalogKey const *_Nonnull const catalogKeyPtr, struct HFSCatalogFolder const *_Nonnull const folderRecPtr) {
			if (keepIterating) {
				++numVisited;
				if (visitFolder != nil) {
					keepIterating = visitFolder(catalogKeyPtr, folderRecPtr);
				}
			}
		} thread:^(struct HFSCatalogKey const *_Nonnull const catalogKeyPtr, struct HFSCatalogThread const *_Nonnull const threadRecPtr) {
		}];
		return keepIterating;
	}];

	return numVisited;
}

- (bool) searchTreeForItemWithKeyComparator:(ImpBTreeRecordKeyComparator _Nonnull const)compareKeys
	getNode:(ImpBTreeNode *_Nullable *_Nullable const)outNode
	recordIndex:(u_int16_t *_Nullable const)outRecordIdx
{
	ImpBTreeHeaderNode *_Nullable const headerNode = self.headerNode;
	ImpBTreeNode *_Nullable const rootNode = headerNode.rootNode;
//	ImpPrintf(@"Searching catalog file starting from root node #%u at height %u", rootNode.nodeNumber, (unsigned)rootNode.nodeHeight);
	if (rootNode != nil) {
		ImpBTreeNode *_Nullable nextSearchNode = rootNode;
		while (nextSearchNode != nil && nextSearchNode.nodeType == kBTIndexNode) {
			ImpBTreeIndexNode *_Nonnull indexNode = (ImpBTreeIndexNode *_Nonnull)nextSearchNode;
//			ImpPrintf(@"1. Searching siblings of node #%u at height %u", indexNode.nodeNumber, (unsigned)indexNode.nodeHeight);
			nextSearchNode = [indexNode searchSiblingsForBestMatchingNodeWithComparator:compareKeys];
//			ImpPrintf(@"2. Next search node is #%u at height %u", nextSearchNode.nodeNumber, (unsigned)nextSearchNode.nodeHeight);

			NSAssert(nextSearchNode.nodeType == kBTIndexNode || nextSearchNode.nodeType == kBTLeafNode, @"Index node %@ claimed that sibling %@ was a better match for this search", indexNode, nextSearchNode);

			//If the best matching node on this tier is an index node, descend through it to the next tier.
			if (nextSearchNode != nil && nextSearchNode.nodeType == kBTIndexNode) {
				indexNode = (ImpBTreeIndexNode *_Nonnull)nextSearchNode;
//				ImpPrintf(@"3. This is an index node. Descending…");
				nextSearchNode = [indexNode descendWithKeyComparator:compareKeys];
//				ImpPrintf(@"4. Descended. Next search node is #%u at height %u", nextSearchNode.nodeNumber, (unsigned)nextSearchNode.nodeHeight);
			}

			NSAssert(nextSearchNode.nodeType == kBTIndexNode || nextSearchNode.nodeType == kBTLeafNode, @"Index node %@ claimed that %@ was a descendant and a better match for this search", indexNode, nextSearchNode);
		}

		if (nextSearchNode != nil) {
//			ImpPrintf(@"5. Presumptive leaf node is #%u at height %u. Searching for records…", nextSearchNode.nodeNumber, (unsigned)nextSearchNode.nodeHeight);

			//Should be a leaf node.
			int16_t const recordIdx = [nextSearchNode indexOfBestMatchingRecord:compareKeys];
//			ImpPrintf(@"6. Best matching record is #%u", recordIdx);

			//TODO: If outItemRecordData is non-NULL, we need a file or folder record—a thread record will not do.
			//We'll need to look before or after this record for a non-thread record. It might not be in this node. It might not even be in this catalog (although I'm not sure what it would mean for a catalog to have a thread record but no file or folder record—is that possible when items are deleted?).

			NSData *_Nonnull const recordKeyData = [nextSearchNode recordKeyDataAtIndex:recordIdx];
			ImpBTreeComparisonResult const comparisonResult = compareKeys(recordKeyData.bytes);
			if (comparisonResult != ImpBTreeComparisonQuarryIsEqual) {
//				ImpPrintf(@"Not an exact match. Bummer.");
			}
			if (comparisonResult == ImpBTreeComparisonQuarryIsEqual) {
//				ImpPrintf(@"This is a match!!!");
				if (outNode != NULL) {
					*outNode = nextSearchNode;
				}
				if (outRecordIdx != NULL) {
					*outRecordIdx = recordIdx;
				}
				return true;
			}
		}
	}

	return false;
}

- (bool) searchCatalogTreeForItemWithParentID:(HFSCatalogNodeID)cnid
	name:(ConstStr31Param _Nonnull)nodeName
	getRecordKeyData:(NSData *_Nullable *_Nullable const)outRecordKeyData
	threadRecordData:(NSData *_Nullable *_Nullable const)outThreadRecordData
{
	struct HFSCatalogKey quarryCatalogKey = {
		.reserved = 0,
	};
	S(quarryCatalogKey.parentID, cnid);
	memcpy(quarryCatalogKey.nodeName, nodeName, nodeName[0] + 1);
	S(quarryCatalogKey.keyLength, (u_int8_t)(sizeof(struct HFSCatalogKey) - sizeof(quarryCatalogKey.keyLength)));

	//TODO: Factor this out into -hfsCatalogKeyComparator and -hfsPlusCatalogKeyComparator (the latter should use Unicode name comparisons)
	ImpBTreeRecordKeyComparator _Nonnull const compareKeys = ^ImpBTreeComparisonResult(const void *const  _Nonnull foundKeyPtr) {
		struct HFSCatalogKey const *_Nonnull const foundCatKeyPtr = foundKeyPtr;
		return ImpBTreeCompareHFSCatalogKeys(&quarryCatalogKey, foundCatKeyPtr);
	};

	ImpBTreeNode *_Nullable foundNode = nil;
	u_int16_t recordIdx = 0;
	bool const found = [self searchTreeForItemWithKeyComparator:compareKeys
		getNode:&foundNode
		recordIndex:&recordIdx];

	if (found) {
		NSData *_Nonnull const recordKeyData = [foundNode recordKeyDataAtIndex:recordIdx];
		ImpBTreeComparisonResult const comparisonResult = compareKeys(recordKeyData.bytes);
		if (comparisonResult != ImpBTreeComparisonQuarryIsEqual) {
//			ImpPrintf(@"Not an exact match. Bummer.");
		}
		if (comparisonResult == ImpBTreeComparisonQuarryIsEqual) {
//			ImpPrintf(@"This is a match!!!");
			if (outRecordKeyData != NULL) {
				*outRecordKeyData = [foundNode recordKeyDataAtIndex:recordIdx];
			}
			if (outThreadRecordData != NULL) {
				*outThreadRecordData = [foundNode recordPayloadDataAtIndex:recordIdx];
			}
			return true;
		}
	}

	return false;
}

- (bool) searchCatalogTreeWithKeyComparator:(ImpBTreeRecordKeyComparator _Nonnull const)compareKeys
	getRecordKeyData:(NSData *_Nullable *_Nullable const)outRecordKeyData
	payloadData:(NSData *_Nullable *_Nullable const)outPayloadData
{
	ImpBTreeNode *_Nullable foundNode = nil;
	u_int16_t recordIdx = 0;
	bool const found = [self searchTreeForItemWithKeyComparator:compareKeys
		getNode:&foundNode
		recordIndex:&recordIdx];

	if (found) {
		NSData *_Nonnull const recordKeyData = [foundNode recordKeyDataAtIndex:recordIdx];
		ImpBTreeComparisonResult const comparisonResult = compareKeys(recordKeyData.bytes);
		if (comparisonResult != ImpBTreeComparisonQuarryIsEqual) {
//			ImpPrintf(@"Not an exact match. Bummer.");
		}
		if (comparisonResult == ImpBTreeComparisonQuarryIsEqual) {
//			ImpPrintf(@"This is a match!!!");
			if (outRecordKeyData != NULL) {
				*outRecordKeyData = [foundNode recordKeyDataAtIndex:recordIdx];
			}
			if (outPayloadData != NULL) {
				*outPayloadData = [foundNode recordPayloadDataAtIndex:recordIdx];
			}
			return true;
		}
	}

	return false;
}

- (bool) searchCatalogTreeForItemWithParentID:(HFSCatalogNodeID)cnid
	name:(ConstStr31Param _Nonnull)nodeName
	getRecordKeyData:(NSData *_Nullable *_Nullable const)outRecordKeyData
	fileOrFolderRecordData:(NSData *_Nullable *_Nullable const)outItemRecordData
{
	struct HFSCatalogKey quarryCatalogKey = {
		.reserved = 0,
	};
	S(quarryCatalogKey.parentID, cnid);
	memcpy(quarryCatalogKey.nodeName, nodeName, nodeName[0] + 1);
	S(quarryCatalogKey.keyLength, (u_int8_t)(sizeof(struct HFSCatalogKey) - sizeof(quarryCatalogKey.keyLength)));

	ImpBTreeRecordKeyComparator _Nonnull const compareKeys = ^ImpBTreeComparisonResult(const void *const  _Nonnull foundKeyPtr) {
		struct HFSCatalogKey const *_Nonnull const foundCatKeyPtr = foundKeyPtr;
		return ImpBTreeCompareHFSCatalogKeys(&quarryCatalogKey, foundCatKeyPtr);
	};

	return [self searchCatalogTreeWithKeyComparator:compareKeys getRecordKeyData:outRecordKeyData payloadData:outItemRecordData];
}

- (bool) searchCatalogTreeForItemWithParentID:(HFSCatalogNodeID)cnid
	unicodeName:(ConstHFSUniStr255Param _Nonnull)nodeName
	getRecordKeyData:(NSData *_Nullable *_Nullable const)outRecordKeyData
	fileOrFolderRecordData:(NSData *_Nullable *_Nullable const)outItemRecordData
{
	struct HFSPlusCatalogKey quarryCatalogKey;
	S(quarryCatalogKey.parentID, cnid);
	memcpy(quarryCatalogKey.nodeName.unicode, nodeName->unicode, nodeName->length * sizeof(UniChar));
	quarryCatalogKey.nodeName.length = nodeName->length;
	S(quarryCatalogKey.keyLength, (u_int16_t)(sizeof(struct HFSPlusCatalogKey) - self.keyLengthSize));

	ImpBTreeRecordKeyComparator _Nonnull const compareKeys = ^ImpBTreeComparisonResult(const void *const  _Nonnull foundKeyPtr) {
		struct HFSPlusCatalogKey const *_Nonnull const foundCatKeyPtr = foundKeyPtr;
		return ImpBTreeCompareHFSPlusCatalogKeys(&quarryCatalogKey, foundCatKeyPtr);
	};

	return [self searchCatalogTreeWithKeyComparator:compareKeys getRecordKeyData:outRecordKeyData payloadData:outItemRecordData];
}
- (bool) searchCatalogTreeForItemWithParentID:(HFSCatalogNodeID)cnid
	unicodeName:(ConstHFSUniStr255Param _Nonnull)nodeName
	getRecordKeyData:(NSData *_Nullable *_Nullable const)outRecordKeyData
	threadRecordData:(NSData *_Nullable *_Nullable const)outThreadRecordData
{
	struct HFSPlusCatalogKey quarryCatalogKey;
	S(quarryCatalogKey.parentID, cnid);
	memcpy(quarryCatalogKey.nodeName.unicode, nodeName->unicode, nodeName->length * sizeof(UniChar));
	quarryCatalogKey.nodeName.length = nodeName->length;
	S(quarryCatalogKey.keyLength, (u_int16_t)(sizeof(struct HFSPlusCatalogKey) - self.keyLengthSize));

	ImpBTreeRecordKeyComparator _Nonnull const compareKeys = ^ImpBTreeComparisonResult(const void *const  _Nonnull foundKeyPtr) {
		struct HFSPlusCatalogKey const *_Nonnull const foundCatKeyPtr = foundKeyPtr;
		return ImpBTreeCompareHFSPlusCatalogKeys(&quarryCatalogKey, foundCatKeyPtr);
	};

	return [self searchCatalogTreeWithKeyComparator:compareKeys getRecordKeyData:outRecordKeyData payloadData:outThreadRecordData];
}

- (NSUInteger) searchExtentsOverflowTreeForCatalogNodeID:(HFSCatalogNodeID)cnid
	fork:(ImpForkType)forkType
	precededByNumberOfBlocks:(u_int32_t)totalBlockCount
	forEachRecord:(bool (^_Nonnull const)(NSData *_Nonnull const recordData))block
{
	//TODO: Reimplement this in terms of searchTreeForItemWithKeyComparator:getNode:recordIndex:.

	__block NSUInteger numRecords = 0;

	struct HFSExtentKey quarryExtentKey = {
		.keyLength = sizeof(struct HFSExtentKey),
		.forkType = forkType,
		.fileID = cnid,
		.startBlock = (u_int16_t)totalBlockCount,
	};
	quarryExtentKey.keyLength -= sizeof(quarryExtentKey.keyLength);
//	ImpPrintf(@"Searching extents overflow file for fork type 0x%02x, file ID #%u, preceding block count %u", forkType, cnid, totalBlockCount);

	ImpBTreeRecordKeyComparator _Nonnull const compareKey = ^ImpBTreeComparisonResult(void const *_Nonnull const foundKeyPtr) {
		struct HFSExtentKey const *_Nonnull const foundExtentKeyPtr = foundKeyPtr;
		if (quarryExtentKey.keyLength != L(foundExtentKeyPtr->keyLength)) {
		  //These keys are incomparable.
		  return ImpBTreeComparisonQuarryIsIncomparable;
		}

		if (quarryExtentKey.fileID < L(foundExtentKeyPtr->fileID)) {
		  return ImpBTreeComparisonQuarryIsLesser;
		}
		if (quarryExtentKey.fileID > L(foundExtentKeyPtr->fileID)) {
		  return ImpBTreeComparisonQuarryIsGreater;
		}

		u_int8_t const foundForkType = L(foundExtentKeyPtr->forkType);
		if (quarryExtentKey.forkType < foundForkType) {
		  return ImpBTreeComparisonQuarryIsLesser;
		}
		if (quarryExtentKey.forkType > foundForkType) {
		  return ImpBTreeComparisonQuarryIsGreater;
		}

		if (quarryExtentKey.startBlock < L(foundExtentKeyPtr->startBlock)) {
		  return ImpBTreeComparisonQuarryIsLesser;
		}
		if (quarryExtentKey.startBlock > L(foundExtentKeyPtr->startBlock)) {
		  return ImpBTreeComparisonQuarryIsGreater;
		}

		return ImpBTreeComparisonQuarryIsEqual;
	};

	ImpBTreeNode *_Nullable foundNode = nil;
	u_int16_t foundRecordIndex = 0;
	if ([self searchTreeForItemWithKeyComparator:compareKey getNode:&foundNode recordIndex:&foundRecordIndex]) {
		NSData *_Nonnull const payloadData = [foundNode recordPayloadDataAtIndex:foundRecordIndex];
				block(payloadData);
				++numRecords;
	}

	return numRecords;
}

#pragma mark Node map

- (bool) isNodeAllocatedAtIndex:(NSUInteger)nodeIdx {
	//Note: This refers the request to a map node if the index is beyond the header node's map record.
	return [self.headerNode isNodeAllocated:nodeIdx];
}

@end
