//
//  ImpBTreeFile.m
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-11-27.
//

#import "ImpBTreeFile.h"

#import <hfs/hfs_format.h>
#import "ImpByteOrder.h"
#import "NSData+ImpSubdata.h"
#import "ImpBTreeHeaderNode.h"
#import "ImpBTreeIndexNode.h"
#import "ImpTextEncodingConverter.h"

@implementation ImpBTreeFile
{
	NSData *_Nonnull _bTreeData;
	struct BTreeNode const *_Nonnull _nodes;
	NSUInteger _numNodes;
	NSMutableArray *_Nullable _lastEnumeratedObjects;
	NSMutableArray <ImpBTreeNode *> *_Nullable _nodeCache;
}

- (instancetype _Nullable)initWithData:(NSData *_Nonnull const)bTreeFileContents {
	if ((self = [super init])) {
		_bTreeData = [bTreeFileContents copy];
		[_bTreeData writeToURL:[[NSURL fileURLWithPath:@"/tmp" isDirectory:true] URLByAppendingPathComponent:@"hfs-catalog.dat" isDirectory:false] options:0 error:NULL];

		_nodes = _bTreeData.bytes;
		_numNodes = _bTreeData.length / sizeof(struct BTreeNode);

		_nodeCache = [NSMutableArray arrayWithCapacity:_numNodes];
		NSNull *_Nonnull const null = [NSNull null];
		for (NSUInteger i = 0; i < _numNodes; ++i) {
			[_nodeCache addObject:(ImpBTreeNode *)null];
		}
	}
	return self;
}

- (NSString *_Nonnull) description {
	return [NSString stringWithFormat:@"<%@ %p with estimated %lu nodes>", self.class, self, self.count];
}

- (NSUInteger)count {
	return _numNodes;
}

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

- (ImpBTreeNode *_Nonnull const) nodeAtIndex:(u_int32_t const)idx {
	if (idx >= _numNodes) {
		//This will throw a range exception.
		return _nodeCache[idx];
	}

	ImpBTreeNode *_Nonnull const oneWeMadeEarlier = [self alreadyCachedNodeAtIndex:idx];
	if (oneWeMadeEarlier != (ImpBTreeNode *)[NSNull null]) {
		return oneWeMadeEarlier;
	}

	//TODO: Create all of these once, probably up front, and keep them in an array. Turn this into objectAtIndex: and the fast enumeration into fast enumeration of that array.
	NSRange const nodeByteRange = { sizeof(struct BTreeNode) * idx, sizeof(struct BTreeNode) };
	NSData *_Nonnull const nodeData = [_bTreeData dangerouslyFastSubdataWithRange_Imp:nodeByteRange];

	ImpBTreeNode *_Nonnull const node = [ImpBTreeNode nodeWithTree:self data:nodeData];
	node.nodeNumber = idx;
	[self storeNode:node inCacheAtIndex:idx];

	return node;
}

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
		NSRange const nodeByteRange = { sizeof(struct BTreeNode) * ( nextReturnedRange.location + i), sizeof(struct BTreeNode) };
		NSData *_Nonnull const data = [_bTreeData subdataWithRange:nodeByteRange];
		ImpBTreeNode *_Nonnull const node = [ImpBTreeNode nodeWithTree:self data:data];
		node.nodeNumber = (u_int32_t)(nextReturnedRange.location + i);
		[_lastEnumeratedObjects addObject:node];
		outObjects[i] = node;
	}
	state->extra[0] = nextReturnedRange.location;
	state->extra[1] = nextReturnedRange.length;
	state->mutationsPtr = &_numNodes;
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
	for (ImpBTreeNode *_Nullable node = startNode; keepIterating && node != nil; node = node.nextNode) {
		if (node.nodeType == kBTIndexNode) {
			ImpBTreeIndexNode *_Nonnull const indexNode = (ImpBTreeIndexNode *_Nonnull const)node;
			for (ImpBTreeNode *_Nonnull const child in indexNode.children) {
				numNodesVisited = [self _walkNodeAndItsSiblingsAndThenItsChildren:child keepIterating:&keepIterating block:block];
				if (! keepIterating) break;
			}
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

#if 0
- (bool) SLOW_searchCatalogTreeForCatalogNodeID:(HFSCatalogNodeID)cnid
	getRecordKeyData:(NSData *_Nullable *_Nullable const)outRecordKeyData
	fileOrFolderRecordData:(NSData *_Nullable *_Nullable const)outItemRecordData
{
	__block bool found = false;

	bool const shouldReturnKey = outRecordKeyData != NULL;
	bool const shouldReturnItemRecord = outItemRecordData != NULL;

	[self walkBreadthFirst:^(ImpBTreeNode *_Nonnull const node) {
		if (found) return;
		if (node.nodeType == kBTLeafNode) {
			__block NSUInteger i = 0;
			[node forEachRecord:^bool(NSData *_Nonnull const recordData) {
				void const *_Nonnull const recordPtr = recordData.bytes;
				struct HFSCatalogKey const *_Nonnull const keyPtr = recordPtr;
				ptrdiff_t const keyLength = sizeof(keyPtr->keyLength) + L(keyPtr->keyLength);
				//TODO: We need the same pad-byte-skipping logic here as we have in the other place. (Or we need to consolidate both implementations into one.)

				struct HFSCatalogFile const *_Nonnull const fileRec = recordPtr + keyLength;
				struct HFSCatalogFolder const *_Nonnull const folderRec = recordPtr + keyLength;
				if ((L(fileRec->recordType) & 0xff00) == kHFSFileRecord) {
					if (L(fileRec->fileID) == cnid) {
						found = true;
						if (shouldReturnKey) *outRecordKeyData = [recordData subdataWithRange:(NSRange){ 0, keyLength }];
						if (shouldReturnItemRecord) *outItemRecordData = [recordData subdataWithRange:(NSRange){ keyLength, recordData.length - keyLength }];
						return false;
					}
				} else if ((L(folderRec->recordType) & 0xff00) == kHFSFolderRecord) {
					if (L(folderRec->folderID) == cnid) {
						found = true;
						if (shouldReturnKey) *outRecordKeyData = [recordData subdataWithRange:(NSRange){ 0, keyLength }];
						if (shouldReturnItemRecord) *outItemRecordData = [recordData subdataWithRange:(NSRange){ keyLength, recordData.length - keyLength }];
						return false;
					}
				}

				++i;
				return true;
			}];
		}
	}];

	return found;
}
#endif //0

- (bool) searchTreeForItemWithKeyComparator:(ImpBTreeRecordKeyComparator _Nonnull const)compareKeys
	getNode:(ImpBTreeNode *_Nullable *_Nullable const)outNode
	recordIndex:(u_int16_t *_Nullable const)outRecordIdx
{
	ImpTextEncodingConverter *_Nonnull const tec = [ImpTextEncodingConverter converterWithHFSTextEncoding:kTextEncodingMacRoman]; //TODO: Here, too, we need text encoding info.

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

			//If the best matching node on this tier is an index node, descend through it to the next tier.
			if (nextSearchNode != nil && nextSearchNode.nodeType == kBTIndexNode) {
				indexNode = (ImpBTreeIndexNode *_Nonnull)nextSearchNode;
//				ImpPrintf(@"3. This is an index node. Descending…");
				nextSearchNode = [indexNode descendWithKeyComparator:compareKeys];
//				ImpPrintf(@"4. Descended. Next search node is #%u at height %u", nextSearchNode.nodeNumber, (unsigned)nextSearchNode.nodeHeight);
			}
		}

		if (nextSearchNode != nil) {
//			ImpPrintf(@"Presumptive leaf node is #%u at height %u. Searching for records…", nextSearchNode.nodeNumber, (unsigned)nextSearchNode.nodeHeight);

			//Should be a leaf node.
			NSInteger const recordIdx = [nextSearchNode indexOfBestMatchingRecord:compareKeys];
//			ImpPrintf(@"Best matching record is #%lu", recordIdx);

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
		.keyLength = sizeof(struct HFSCatalogKey),
		.reserved = 0,
		.parentID = cnid,
	};
	memcpy(quarryCatalogKey.nodeName, nodeName, nodeName[0] + 1);
	quarryCatalogKey.keyLength -= sizeof(quarryCatalogKey.keyLength);
	ImpTextEncodingConverter *_Nonnull const tec = [ImpTextEncodingConverter converterWithHFSTextEncoding:kTextEncodingMacRoman]; //TODO: Here, too, we need text encoding info.
	NSString *_Nonnull const quarryNodeName = [tec stringForPascalString:quarryCatalogKey.nodeName];

	ImpBTreeRecordKeyComparator _Nonnull const compareKeys = ^ImpBTreeComparisonResult(const void *const  _Nonnull foundKeyPtr) {
		struct HFSCatalogKey const *_Nonnull const foundCatKeyPtr = foundKeyPtr;
		if (L(foundCatKeyPtr->parentID) < quarryCatalogKey.parentID) {
			return ImpBTreeComparisonQuarryIsGreater;
		}
		if (L(foundCatKeyPtr->parentID) > quarryCatalogKey.parentID) {
			return ImpBTreeComparisonQuarryIsLesser;
		}
		NSComparisonResult nameComparison;
		@autoreleasepool {
			NSString *_Nonnull const foundNodeName = [tec stringForPascalString:foundCatKeyPtr->nodeName];
			nameComparison = [quarryNodeName localizedStandardCompare:foundNodeName];
		}
		return nameComparison;
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

- (bool) searchCatalogTreeForItemWithParentID:(HFSCatalogNodeID)cnid
	name:(ConstStr31Param _Nonnull)nodeName
	getRecordKeyData:(NSData *_Nullable *_Nullable const)outRecordKeyData
	fileOrFolderRecordData:(NSData *_Nullable *_Nullable const)outItemRecordData
{
	struct HFSCatalogKey quarryCatalogKey = {
		.keyLength = sizeof(struct HFSCatalogKey),
		.reserved = 0,
		.parentID = cnid,
	};
	memcpy(quarryCatalogKey.nodeName, nodeName, nodeName[0] + 1);
	quarryCatalogKey.keyLength -= sizeof(quarryCatalogKey.keyLength);
	ImpTextEncodingConverter *_Nonnull const tec = [ImpTextEncodingConverter converterWithHFSTextEncoding:kTextEncodingMacRoman]; //TODO: Here, too, we need text encoding info.
	NSString *_Nonnull const quarryNodeName = [tec stringForPascalString:quarryCatalogKey.nodeName];

	ImpBTreeRecordKeyComparator _Nonnull const compareKeys = ^ImpBTreeComparisonResult(const void *const  _Nonnull foundKeyPtr) {
		struct HFSCatalogKey const *_Nonnull const foundCatKeyPtr = foundKeyPtr;
		if (L(foundCatKeyPtr->parentID) < quarryCatalogKey.parentID) {
			return ImpBTreeComparisonQuarryIsGreater;
		}
		if (L(foundCatKeyPtr->parentID) > quarryCatalogKey.parentID) {
			return ImpBTreeComparisonQuarryIsLesser;
		}
		NSComparisonResult nameComparison;
		@autoreleasepool {
			NSString *_Nonnull const foundNodeName = [tec stringForPascalString:foundCatKeyPtr->nodeName];
			nameComparison = [quarryNodeName localizedStandardCompare:foundNodeName];
		}
		return nameComparison;
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
			if (outItemRecordData != NULL) {
				*outItemRecordData = [foundNode recordPayloadDataAtIndex:recordIdx];
			}
			return true;
		}
	}

	return false;
}

- (NSUInteger) searchExtentsOverflowTreeForCatalogNodeID:(HFSCatalogNodeID)cnid
	fork:(ImpForkType)forkType
	firstExtentStart:(u_int32_t)startBlock
	forEachRecord:(bool (^_Nonnull const)(NSData *_Nonnull const recordData))block
{
	//TODO: Reimplement this in terms of searchTreeForItemWithKeyComparator:getNode:recordIndex:.

	NSUInteger numRecords = 0;

	struct HFSExtentKey quarryExtentKey = {
		.keyLength = sizeof(struct HFSExtentKey),
		.forkType = forkType,
		.fileID = cnid,
		.startBlock = (u_int16_t)startBlock,
	};
	quarryExtentKey.keyLength -= sizeof(quarryExtentKey.keyLength);

	ImpBTreeRecordKeyComparator _Nonnull const compareKey = ^ImpBTreeComparisonResult(void const *_Nonnull const foundKeyPtr) {
		struct HFSExtentKey const *_Nonnull const foundExtentKeyPtr = foundKeyPtr;
		if (quarryExtentKey.keyLength != L(foundExtentKeyPtr->keyLength)) {
		  //These keys are incomparable.
		  return ImpBTreeComparisonQuarryIsIncomparable;
		}
		if (quarryExtentKey.forkType < L(foundExtentKeyPtr->forkType)) {
		  return ImpBTreeComparisonQuarryIsLesser;
		}
		if (quarryExtentKey.forkType > L(foundExtentKeyPtr->forkType)) {
		  return ImpBTreeComparisonQuarryIsGreater;
		}
		if (quarryExtentKey.fileID < L(foundExtentKeyPtr->fileID)) {
		  return ImpBTreeComparisonQuarryIsLesser;
		}
		if (quarryExtentKey.fileID > L(foundExtentKeyPtr->fileID)) {
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

	ImpBTreeHeaderNode *_Nullable const headerNode = self.headerNode;
	ImpBTreeNode *_Nullable const rootNode = headerNode.rootNode;
	if (rootNode != nil) {
		ImpBTreeNode *_Nullable leafNode = nil;
		ImpBTreeIndexNode *_Nullable indexNode = (ImpBTreeIndexNode *_Nullable const)rootNode;
		while (indexNode != nil && indexNode.nodeType == kBTIndexNode) {
			ImpBTreeNode *_Nullable nextNodeDown = [indexNode descendWithKeyComparator:compareKey];
			if (nextNodeDown != nil && nextNodeDown.nodeType == kBTIndexNode) {
				indexNode = (ImpBTreeIndexNode *_Nonnull const)nextNodeDown;
			} else {
				indexNode = nil;
				leafNode = nextNodeDown;
			}
		}

		/*There are several possibilities from here:
		 - leafNode is nil. This should mean the tree is empty.
		 - There is exactly one exactly-matching record, and it's in this node. (It may be the last record in the node.)
		 - There are multiple exactly-matching records, and they're all in this node. (They may run right up to the last record in the node.)
		 - There are multiple exactly-matching records, and they start in this node and continue on into at least the next node.
		 - There are no exactly-matching records. If our quarry was in this tree, it would be in this node, but it isn't, so it's not in the tree at all.
		 */
	}
	return numRecords;
}

@end
