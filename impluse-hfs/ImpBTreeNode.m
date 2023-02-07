//
//  ImpBTreeNode.m
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-11-27.
//

#import "ImpBTreeNode.h"

#import "ImpByteOrder.h"
#import "ImpSizeUtilities.h"
#import "NSData+ImpSubdata.h"
#import "ImpBTreeFile.h"
#import "ImpMutableBTreeFile.h"
#import "ImpBTreeHeaderNode.h"
#import "ImpBTreeIndexNode.h"
#import "ImpTextEncodingConverter.h"

#import "NSData+ImpHexDump.h"

@interface ImpBTreeNode ()
@property(readwrite, nonatomic) u_int32_t forwardLink, backwardLink;
@property(readwrite) BTreeNodeKind nodeType;
@property(readwrite) u_int8_t nodeHeight;
@property(readwrite) u_int16_t numberOfRecords;
@end

@implementation ImpBTreeNode
{
	NSData *_nodeData;
	NSMutableArray <NSData *> *_Nonnull _recordCache;
	bool _dataIsMutable;
}

///Peek at the kind of node this is, and choose an appropriate subclass based on that.
+ (Class _Nonnull) nodeClassForData:(NSData *_Nonnull const)nodeData {
	Class nodeClass = self;
	struct BTNodeDescriptor const *_Nonnull const nodeDescriptor = nodeData.bytes;
	BTreeNodeKind const nodeType = L(nodeDescriptor->kind);
	switch(nodeType) {
		case kBTHeaderNode:
			nodeClass = [ImpBTreeHeaderNode class];
			break;
		case kBTIndexNode:
			nodeClass = [ImpBTreeIndexNode class];
			break;
		default:
			nodeClass = self;
			break;
	}
	return nodeClass;
}

+ (instancetype _Nullable) nodeWithTree:(ImpBTreeFile *_Nonnull const)tree data:(NSData *_Nonnull const)nodeData {
	return [self nodeWithTree:tree data:nodeData copy:true mutable:false];
}

+ (instancetype _Nullable) mutableNodeWithTree:(ImpBTreeFile *_Nonnull const)tree data:(NSData *_Nonnull const)nodeData {
	return [self nodeWithTree:tree data:nodeData copy:false mutable:true];
}

- (instancetype _Nullable)initWithTree:(ImpBTreeFile *_Nonnull const)tree data:(NSData *_Nonnull const)nodeData {
	return [self initWithTree:tree data:nodeData copy:true mutable:false];
}

+ (instancetype _Nullable) nodeWithTree:(ImpBTreeFile *_Nonnull const)tree data:(NSData *_Nonnull const)nodeData copy:(bool const)shouldCopyData mutable:(bool const)dataShouldBeMutable {
	Class nodeClass = [self nodeClassForData:nodeData];
	return [[nodeClass alloc] initWithTree:tree data:nodeData copy:shouldCopyData mutable:dataShouldBeMutable];
}

- (instancetype _Nullable) initWithTree:(ImpBTreeFile *_Nonnull const)tree data:(NSData *_Nonnull const)nodeData copy:(bool const)shouldCopyData mutable:(bool const)dataShouldBeMutable {
	if ((self = [super init])) {
		_tree = tree;

		_nodeData = shouldCopyData ? (dataShouldBeMutable ? [nodeData mutableCopy] : [nodeData copy]) : nodeData;
		_dataIsMutable = dataShouldBeMutable;

		struct BTNodeDescriptor const *_Nonnull const nodeDescriptor = _nodeData.bytes;
		_forwardLink = L(nodeDescriptor->fLink);
		_backwardLink = L(nodeDescriptor->bLink);
		_nodeType = L(nodeDescriptor->kind);
		_nodeHeight = L(nodeDescriptor->height);
		_numberOfRecords = L(nodeDescriptor->numRecords);
		//TODO: Should probably preserve the reserved field as well.
	}
	return self;
}

#pragma mark Node connections

- (ImpBTreeNode *_Nullable) previousNode {
	u_int32_t const bLink = self.backwardLink;
	if (bLink > 0) {
		return [self.tree nodeAtIndex:bLink];
	}
	return nil;
}
- (ImpBTreeNode *_Nullable) nextNode {
	u_int32_t const fLink = self.forwardLink;
	if (fLink > 0) {
		return [self.tree nodeAtIndex:fLink];
	}
	return nil;
}

- (void)connectNextNode:(ImpBTreeNode *_Nullable const)newNextNode {
	ImpBTreeNode *_Nullable const oldNextNode = self.nextNode;

	newNextNode.backwardLink = self.nodeNumber;

	self.forwardLink = newNextNode.nodeNumber;
	oldNextNode.backwardLink = 0;
}

- (void) setForwardLink:(u_int32_t)forwardLink {
	_forwardLink = forwardLink;
	if (_dataIsMutable) {
		struct BTNodeDescriptor *_Nonnull const ourNodeDesc = ((NSMutableData *)_nodeData).mutableBytes;
		S(ourNodeDesc->fLink, _forwardLink);
	}
}
- (void) setBackwardLink:(u_int32_t)backwardLink {
	_backwardLink = backwardLink;
	if (_dataIsMutable) {
		struct BTNodeDescriptor *_Nonnull const ourNodeDesc = ((NSMutableData *)_nodeData).mutableBytes;
		S(ourNodeDesc->bLink, _backwardLink);
	}
}

#pragma mark Properties

- (void) peekAtDataRepresentation:(void (^_Nonnull const)(NSData *_Nonnull const data NS_NOESCAPE))block {
	block(_nodeData);
}

- (NSString *)nodeTypeName {
	switch(self.nodeType) {
		case kBTHeaderNode: return @"header";
		case kBTMapNode: return @"map";
		case kBTIndexNode: return @"index";
		case kBTLeafNode: return @"leaf";
		default: return @"mysterious";
	}
}

- (NSString *)description {
	return [NSString stringWithFormat:@"<%@ #%u %p is a %@ node with %u records>",
		self.class, self.nodeNumber, self,
		self.nodeTypeName,
		(unsigned)self.numberOfRecords
	];
}

+ (NSString *_Nonnull const) describeHFSCatalogKeyWithData:(NSData *_Nonnull const)keyData {
	struct HFSCatalogKey const *_Nonnull const catKeyPtr = keyData.bytes;
	HFSCatalogNodeID const parentID = L(catKeyPtr->parentID);
	ImpTextEncodingConverter *_Nonnull const tec = [[ImpTextEncodingConverter alloc] initWithHFSTextEncoding:kTextEncodingMacRoman];
	NSString *_Nonnull const nodeName = [tec stringForPascalString:catKeyPtr->nodeName];
	return [NSString stringWithFormat:@"%u/“%@”", parentID, nodeName];
}
+ (NSString *_Nonnull const) describeHFSPlusCatalogKeyWithData:(NSData *_Nonnull const)keyData {
	struct HFSPlusCatalogKey const *_Nonnull const catKeyPtr = keyData.bytes;
	HFSCatalogNodeID const parentID = L(catKeyPtr->parentID);
	ImpTextEncodingConverter *_Nonnull const tec = [[ImpTextEncodingConverter alloc] initWithHFSTextEncoding:kTextEncodingMacRoman];
	NSString *_Nonnull const nodeName = [tec stringFromHFSUniStr255:&(catKeyPtr->nodeName)];
	return [NSString stringWithFormat:@"%u/“%@”", parentID, nodeName];
}

- (int16_t) indexOfBestMatchingRecord:(ImpBTreeRecordKeyComparator _Nonnull)comparator {
	//We *could* bisect this, but there are only likely to be a handful of records in each node, so let's just search linearly.
	for (u_int16_t i = 0; i < (u_int16_t)_numberOfRecords; ++i) {
		ImpBTreeComparisonResult const comparisonResult = comparator([self recordDataAtIndex:i].bytes);
		if (comparisonResult == ImpBTreeComparisonQuarryIsEqual) {
			return i;
		} else if (comparisonResult == ImpBTreeComparisonQuarryIsLesser) {
			return i - 1;
		}
	}
	//At this point, every record in the node was less than or equal to the quarry, so the last record is the greatest candidate. Return its index.
	return self.numberOfRecords - 1;
}

#pragma mark Walking and searching neighbors

- (void) walkRow:(bool (^_Nonnull const)(ImpBTreeNode *_Nonnull const node))block {
	ImpBTreeNode *_Nullable node = self;
	while (node != nil) {
		block(node);
		node = node.nextNode;
	}
}

- (ImpBTreeNode *_Nullable)searchSiblingsForBestMatchingNodeWithComparator:(ImpBTreeRecordKeyComparator _Nonnull)comparator {
	if (self.numberOfRecords == 0) {
		return nil;
	}

	//First, if the first record in this node is already greater than the quarry, search the previous node.
//	NSLog(@"%s: Checking first record for need to visit previous sibling", sel_getName(_cmd));
	if (comparator([self recordDataAtIndex:0].bytes) == ImpBTreeComparisonQuarryIsLesser) {
//		NSLog(@"%s: Continuing search in previous sibling", sel_getName(_cmd));
		return [self.previousNode searchSiblingsForBestMatchingNodeWithComparator:comparator];
	}

	//If the last record in this node is less than the quarry, check the next node's first record and if it's less than or equal to the quarry, search it.
//	ImpPrintf(@"%s: Checking last record for need to visit next node", sel_getName(_cmd));
	if (self.numberOfRecords > 1 && comparator([self recordDataAtIndex:self.numberOfRecords - 1].bytes) == ImpBTreeComparisonQuarryIsGreater) {
		ImpBTreeNode *_Nullable const nextNode = self.nextNode;
		if (nextNode != nil && nextNode.numberOfRecords > 0) {
//			ImpPrintf(@"%s: Checking next sibling's first record for need to visit next node", sel_getName(_cmd));
			ImpBTreeComparisonResult const comparisonResult = comparator([nextNode recordDataAtIndex:0].bytes);
			if (comparisonResult == ImpBTreeComparisonQuarryIsEqual) {
//				ImpPrintf(@"%s: Found exact match", sel_getName(_cmd));
				return nextNode;
			} else if (comparisonResult == ImpBTreeComparisonQuarryIsGreater) {
//				ImpPrintf(@"%s: Continuing search in next sibling", sel_getName(_cmd));
				return [nextNode searchSiblingsForBestMatchingNodeWithComparator:comparator];
			}
		}
	}

//	ImpPrintf(@"%s: Selecting %@", sel_getName(_cmd), self);

	//Otherwise, the best matching node is somewhere in this node. Return this node.
	return self;
}

#pragma mark Record access

- (void) buildRecordCache {
	if (_recordCache == nil) {
		_recordCache = [NSMutableArray arrayWithCapacity:_numberOfRecords];
		for (u_int16_t i = 0; i < (u_int16_t)_numberOfRecords; ++i) {
			[_recordCache addObject:[self recordDataAtIndex_nocache:i]];
		}
	}
}

- (bool) hasKeyedRecords {
	return (self.nodeType == kBTIndexNode || self.nodeType == kBTLeafNode);
}

///Returns an array of strings describing the records in this node. Primarily useful from a debugger.
- (NSArray <NSString *> *_Nonnull const) inventory {
	NSMutableArray *_Nonnull const descriptions = [NSMutableArray arrayWithCapacity:self.numberOfRecords];
	NSMutableArray *_Nonnull const descriptionComponents = [NSMutableArray arrayWithObjects:@"key", @"payload", nil];
	ImpTextEncodingConverter *_Nonnull const tec = [ImpTextEncodingConverter converterWithHFSTextEncoding:kTextEncodingMacRoman];

	ImpBTreeFile *_Nonnull const tree = self.tree;
	ImpBTreeVersion const treeVersion = tree.version;

	if (self.hasKeyedRecords) {
		[self forEachKeyedRecord:^bool(NSData *const  _Nonnull keyData, NSData *const  _Nonnull payloadData) {
			//Let's just focus on catalog keys for now.
			bool const isExtentKey =
				false &&
				keyData.length == sizeof(struct HFSExtentKey);
			if (isExtentKey) {
				struct HFSExtentKey const *_Nonnull const hfsExtKeyPtr = keyData.bytes;
				descriptionComponents[0] = [NSString stringWithFormat:@"Extent key [%@ fork for file ID #%u, starting at block #%u]", L(hfsExtKeyPtr->forkType) == 0 ? @"data" : @"rsrc", L(hfsExtKeyPtr->fileID), L(hfsExtKeyPtr->startBlock)];
				struct HFSExtentDescriptor const *_Nonnull const hfsExtRecPtr = payloadData.bytes;
				descriptionComponents[1] = [NSString stringWithFormat:@"Extents { %u, %u }, { %u, %u }, { %u, %u }", hfsExtRecPtr[0].startBlock, hfsExtRecPtr[0].blockCount, hfsExtRecPtr[1].startBlock, hfsExtRecPtr[1].blockCount, hfsExtRecPtr[2].startBlock, hfsExtRecPtr[3].blockCount];
			} else {
				u_int16_t recordType = 0x0000;
				void const *_Nonnull const payloadPtr = payloadData.bytes;

				if (treeVersion == ImpBTreeVersionHFSPlusCatalog) {
					struct HFSPlusCatalogKey const *_Nonnull const hfsPlusCatKeyPtr = keyData.bytes;
					descriptionComponents[0] = [NSString stringWithFormat:@"Catalog key [parent ID #%u, node name “%@”]", L(hfsPlusCatKeyPtr->parentID), [tec stringFromHFSUniStr255:&(hfsPlusCatKeyPtr->nodeName)]];
					u_int16_t const *_Nonnull const recordTypePtr = payloadPtr;
					recordType = L(*recordTypePtr);
				} else if (treeVersion == ImpBTreeVersionHFSCatalog) {
					struct HFSCatalogKey const *_Nonnull const hfsCatKeyPtr = keyData.bytes;
					descriptionComponents[0] = [NSString stringWithFormat:@"Catalog key [parent ID #%u, node name “%@”]", L(hfsCatKeyPtr->parentID), [tec stringForPascalString:hfsCatKeyPtr->nodeName]];
					u_int8_t const *_Nonnull const recordTypePtr = payloadPtr;
					recordType = *recordTypePtr;
				} else {
					NSLog(@"Warning: Trying to inventory a node from a tree whose version is 0x%04lx", (unsigned long)treeVersion);
					u_int16_t const *_Nonnull const recordTypePtr = payloadPtr;
					recordType = L(*recordTypePtr);
				}

				switch (recordType) {
					case kHFSFileRecord: {
						struct HFSCatalogFile const *_Nonnull const hfsFileRecPtr = payloadPtr;
						descriptionComponents[1] = [NSString stringWithFormat:@"📄 [ID #%u, type %@, creator %@]", L(hfsFileRecPtr->fileID), NSFileTypeForHFSTypeCode(L(hfsFileRecPtr->userInfo.fdType)), NSFileTypeForHFSTypeCode(L(hfsFileRecPtr->userInfo.fdCreator))];
						break;
					}
					case kHFSFolderRecord: {
						struct HFSCatalogFolder const *_Nonnull const hfsFolderRecPtr = payloadPtr;
						descriptionComponents[1] = [NSString stringWithFormat:@"📁 [ID #%u, %u items]", L(hfsFolderRecPtr->folderID), L(hfsFolderRecPtr->valence)];
						break;
					}
					case kHFSFileThreadRecord:
					case kHFSFolderThreadRecord: {
						struct HFSCatalogThread const *_Nonnull const hfsThreadRecPtr = payloadPtr;
						descriptionComponents[1] = [NSString stringWithFormat:@"🧵 %@ [parent ID #%u, name “%@”]", recordType == kHFSFileThreadRecord ? @"📄" : @"📁",  L(hfsThreadRecPtr->parentID), [tec stringForPascalString:hfsThreadRecPtr->nodeName]];
						break;
					}
					case kHFSPlusFileRecord: {
						struct HFSPlusCatalogFile const *_Nonnull const hfsPlusFileRecPtr = payloadPtr;
						descriptionComponents[1] = [NSString stringWithFormat:@"📄 [ID #%u, type %@, creator %@]", L(hfsPlusFileRecPtr->fileID), NSFileTypeForHFSTypeCode(L(hfsPlusFileRecPtr->userInfo.fdType)), NSFileTypeForHFSTypeCode(L(hfsPlusFileRecPtr->userInfo.fdCreator))];
						break;
					}
					case kHFSPlusFolderRecord: {
						struct HFSPlusCatalogFolder const *_Nonnull const hfsPlusFolderRecPtr = payloadPtr;
						descriptionComponents[1] = [NSString stringWithFormat:@"📁 [ID #%u, %u items]", L(hfsPlusFolderRecPtr->folderID), L(hfsPlusFolderRecPtr->valence)];
						break;
					}
					case kHFSPlusFileThreadRecord:
					case kHFSPlusFolderThreadRecord: {
						struct HFSPlusCatalogThread const *_Nonnull const hfsPlusThreadRecPtr = payloadPtr;
						descriptionComponents[1] = [NSString stringWithFormat:@"🧵 %@ [parent ID #%u, name “%@”]", recordType == kHFSPlusFileThreadRecord ? @"📄" : @"📁",  L(hfsPlusThreadRecPtr->parentID), [tec stringFromHFSUniStr255:&(hfsPlusThreadRecPtr->nodeName)]];
						break;
					}
					default:
						if (payloadData.length == sizeof(u_int32_t)) {
							u_int32_t const *_Nonnull const downwardNodeIndexPtr = payloadPtr;
							descriptionComponents[1] = [NSString stringWithFormat:@"Pointer to node #%u", L(*downwardNodeIndexPtr)];
						} else if (payloadData.length > 0) {
							descriptionComponents[1] = [NSString stringWithFormat:@"<unknown payload for record type 0x%02x with length %lu>", recordType, payloadData.length];
						} else {
							descriptionComponents[1] = @"<empty payload>";
						}
						break;
				}
			}

			[descriptions addObject:[descriptionComponents componentsJoinedByString:@": "]];
			return true;
		}];
	} else {
		[descriptions addObject:[NSString stringWithFormat:@"%u non-keyed records", self.numberOfRecords]];
	}

	return descriptions;
}

///Get the offset into this node where a particular record starts, and the offset where it ends (the offset of the record after it, or of empty space, or of the last offset in the offset stack). If idx is the number of records, then *outThisOffset will be the offset of empty space, and *outNextOffset will be the offset of the two bytes above the top of the offset stack. (Note that if there are less than two bytes of empty space, *outNextOffset will point into a record! You must check the amount of empty space before attempting to append a record. Fortunately, appendRecordWithData: does this check for you.)
- (bool) forRecordAtIndex:(u_int16_t const)idx getItsOffset:(BTreeNodeOffset *_Nullable const)outThisOffset andTheOneAfterThat:(BTreeNodeOffset *_Nullable const)outNextOffset {
	BTreeNodeOffset const *_Nonnull const offsets = _nodeData.bytes;

	/*We need to turn our indexes upside down; idx is relative to the end of the node, but we're going to index from the topmost slot. This numbers the offset slots from 0 to n:
	 *	Offset of slot	Index	Value (offset of record start)
	 *	0x…		0	Offset of empty space, or itself
	 *	⋮
	 *	0x…a	n-2 >*(n-1)
	 *	0x…c	n-1 >*(n-0)
	 *	0x…e	n-0	0x0e
	 *bottomOffsetIndex is the index that retrieves the bottom-most offset.
	 */
	u_int16_t const maxNumOffsets = (u_int16_t)(_nodeData.length / sizeof(BTreeNodeOffset));
	u_int16_t const bottomOffsetIdx = maxNumOffsets - 1;

	bool const isValidIndex = idx <= maxNumOffsets;
	if (isValidIndex) {
		if (outThisOffset != NULL) {
			BTreeNodeOffset const thisRecordOffset = L(offsets[bottomOffsetIdx - idx]);
			*outThisOffset = thisRecordOffset;
		}
		if (outNextOffset != NULL) {
			if (idx <= bottomOffsetIdx) {
				BTreeNodeOffset const nextRecordOffset = L(offsets[bottomOffsetIdx - (idx + 1)]);
				*outNextOffset = nextRecordOffset;
			} else {
				//idx is maxNumOffsets. Return the offset of the next offset slot above the offset stack.
				BTreeNodeOffset const *lastRecordOffsetPtr = offsets + bottomOffsetIdx;
				ptrdiff_t const nextOffsetOffset = (lastRecordOffsetPtr - sizeof(BTreeNodeOffset)) - offsets;
				*outNextOffset = (BTreeNodeOffset)nextOffsetOffset;
			}
		}
	}

	return isValidIndex;
}

///Get the offset into this node where a particular record starts, and the record's length (based on the offset of the next record, or of empty space).
///If idx is the number of records, returns the start of empty space and the number of bytes remaining.
///Note that adding the length to the record offset is not guaranteed to produce an offset to a record in the node, *or* to empty space. It depends on how idx compares to the number of items (if it's the last item, then the next offset is to empty space *if there is any*) and how full the node is (if there is no empty space, the next offset points to the offsets stack, and you do *not* want to overwrite that).
///Always use the appendRecord…: methods to append records, rather than doing unspeakable sorcery with raw offsets.
- (bool) forRecordAtIndex:(u_int16_t const)idx getItsOffset:(BTreeNodeOffset *_Nonnull const)outThisOffset andLength:(u_int16_t *_Nonnull const)outLength {
	BTreeNodeOffset const *_Nonnull const offsets = _nodeData.bytes;

	/*We need to turn our indexes upside down; idx is relative to the end of the node, but we're going to index from the topmost slot. This numbers the offset slots from 0 to n:
	 *	Offset of slot	Index	Value (offset of record start)
	 *	0x…		0	Offset of empty space, or itself
	 *	⋮
	 *	0x…a	n-2 >*(n-1)
	 *	0x…c	n-1 >*(n-0)
	 *	0x…e	n-0	0x0e
	 *bottomOffsetIndex is the index that retrieves the bottom-most offset.
	 */
	u_int16_t const maxNumOffsets = (u_int16_t)(_nodeData.length / sizeof(BTreeNodeOffset));
	u_int16_t const bottomOffsetIdx = maxNumOffsets - 1;

	bool const isValidIndex = idx <= _numberOfRecords;
	if (isValidIndex) {
		BTreeNodeOffset const thisRecordOffset = L(offsets[bottomOffsetIdx - idx]);
		*outThisOffset = thisRecordOffset;

		if (idx < _numberOfRecords) {
			BTreeNodeOffset const nextRecordOffset = L(offsets[bottomOffsetIdx - (idx + 1)]);
			*outLength = nextRecordOffset - thisRecordOffset;
		} else {
			//We're getting the range of empty space. Measure from the start of empty space (this offset) to the top of the offsets stack.
			u_int16_t offsetOfTopOfStack = (u_int16_t)(_nodeData.length - ((_numberOfRecords + 1) * sizeof(BTreeNodeOffset)));
			*outLength = offsetOfTopOfStack - thisRecordOffset;
		}
	}

	return isValidIndex;
}

- (NSData *_Nonnull) recordDataAtIndex:(u_int16_t)idx {
	NSParameterAssert(idx < self.numberOfRecords);

	[self buildRecordCache];
	NSData *_Nonnull const recordData = _recordCache[idx];
	NSAssert(recordData != nil, @"Consistency error! Node has %u records, so a record index of %u is valid, but somehow this node didn't have a record for that index.", self.numberOfRecords, idx);
	return recordData;
}
- (NSData *_Nonnull) recordDataAtIndex_nocache:(u_int16_t)idx {
	BTreeNodeOffset thisRecordOffset;
	u_int16_t length = 0;
	[self forRecordAtIndex:idx getItsOffset:&thisRecordOffset andLength:&length];
//	ImpPrintf(@"%@Node #%u: Record at index %u starts at offset %u and runs for %u bytes", self.byteRange.length ? [NSString stringWithFormat:@"(Byte offset +0x%04lx) ", self.byteRange.location + thisRecordOffset] : @"", (unsigned)self.nodeNumber, (unsigned)idx, (unsigned)thisRecordOffset, (unsigned)length);

	NSRange const recordRange = { thisRecordOffset, length };
	@try {
		NSData *_Nonnull const recordData = [self.tree sliceData:_nodeData selectRange:recordRange];
//	ImpPrintf(@"Record at index %u starts at offset %lu, length %lu: <\n%@>", idx, (unsigned long)thisRecordOffset, length, recordData.hexDump_Imp);
	return recordData;
	} @catch(NSException *_Nonnull const exc) {
		[self forRecordAtIndex:idx getItsOffset:&thisRecordOffset andLength:&length];
	}
}

- (u_int16_t) keyLengthFromRecordData:(NSData *_Nonnull const) wholeRecordData {
	u_int16_t const keyLengthSize = self.tree.keyLengthSize;
	if (keyLengthSize == sizeof(u_int16_t)) {
		u_int16_t const *_Nonnull const keyLengthPtr = wholeRecordData.bytes;
		return L(*keyLengthPtr);
	} else if (keyLengthSize == sizeof(u_int8_t)) {
		u_int8_t const *_Nonnull const keyLengthPtr = wholeRecordData.bytes;
		return L(*keyLengthPtr);
	}
	NSAssert((keyLengthSize == sizeof(u_int16_t)) || (keyLengthSize == sizeof(u_int8_t)), @"Unexpected size of key lengths: %u bytes", keyLengthSize);
	return 0;
}

- (NSData *_Nullable) recordKeyDataAtIndex:(u_int16_t)idx {
	if (! (self.nodeType == kBTIndexNode || self.nodeType == kBTLeafNode) ) {
		NSAssert(false, @"A %@ node does not have keyed records", self.nodeTypeName);
		return nil;
	}

	NSData *_Nonnull const wholeRecordData = [self recordDataAtIndex:idx];
	ImpBTreeFile *_Nullable const tree = self.tree;
	u_int16_t keyLength = [self keyLengthFromRecordData:wholeRecordData];
	keyLength += tree.keyLengthSize;
	return [tree sliceData:wholeRecordData selectRange:(NSRange){ 0, keyLength }];
}

- (NSData *_Nullable) recordPayloadDataAtIndex:(u_int16_t)idx {
	if (! (self.nodeType == kBTIndexNode || self.nodeType == kBTLeafNode) ) {
		return nil;
	}

	NSData *_Nonnull const wholeRecordData = [self recordDataAtIndex:idx];
	ImpBTreeFile *_Nullable const tree = self.tree;
	u_int16_t keyLength = [self keyLengthFromRecordData:wholeRecordData];
	keyLength += tree.keyLengthSize;

	NSRange payloadRange = {
		.location = keyLength,
		.length = wholeRecordData.length - keyLength,
	};
	//If the name of a catalog record has an even number of characters (such that adding the length byte makes an odd-numbered length), there will be a pad byte between the name and the record data so that the record data always begins on a word (2-byte) boundary. Skip over this pad byte.
	//Annoyingly, the pad byte doesn't get included in the keyLength, so we need to work it out from the length of the payload. HFS's payloads are all even-numbered lengths, so we can detect the pad byte by the remaining length being odd, and assume the pad byte is in the middle.
	if (payloadRange.length % 2 == 1) {
		++payloadRange.location;
		--payloadRange.length;
	}

	return [tree sliceData:wholeRecordData selectRange:payloadRange];
}

#pragma mark Record searching

- (NSUInteger) forEachRecord:(bool (^_Nonnull const)(NSData *_Nonnull const data))block {
	NSUInteger numVisited = 0;

	bool keepIterating = true;
	for (u_int16_t i = 0; i < (u_int16_t)_numberOfRecords; ++i) {
		++numVisited;

		NSData *_Nonnull const recordData = [self recordDataAtIndex:i];
		keepIterating = keepIterating && block(recordData);
		if (! keepIterating) {
			break;
		}
	}
	return numVisited;
}

- (NSUInteger) forEachKeyedRecord:(bool (^_Nonnull const)(NSData *_Nonnull const keyData, NSData *_Nonnull const payloadData))block {
	NSUInteger numVisited = 0;

	bool keepIterating = true;
	for (u_int16_t i = 0; i < (u_int16_t)_numberOfRecords; ++i) {
		++numVisited;

		NSData *_Nonnull const keyData = [self recordKeyDataAtIndex:i];
		NSData *_Nonnull const payloadData = [self recordPayloadDataAtIndex:i];

		keepIterating = keepIterating && block(keyData, payloadData);
		if (! keepIterating) {
			break;
		}
	}
	return numVisited;
}

- (void) forEachHFSCatalogRecord_file:(void (^_Nullable const)(struct HFSCatalogKey const *_Nonnull const catalogKeyPtr, struct HFSCatalogFile const *_Nonnull const recordDataPtr))fileRecordBlock
	folder:(void (^_Nullable const)(struct HFSCatalogKey const *_Nonnull const catalogKeyPtr, struct HFSCatalogFolder  const *_Nonnull const))folderRecordBlock
	thread:(void (^_Nullable const)(struct HFSCatalogKey const *_Nonnull const catalogKeyPtr, struct HFSCatalogThread const *_Nonnull const))threadRecordBlock
{
	if (self.tree.version != ImpBTreeVersionHFSCatalog) {
		return;
	}
	[self forEachKeyedRecord:^bool(NSData *const  _Nonnull keyData, NSData *const  _Nonnull payloadData) {
		struct HFSCatalogKey const *_Nonnull const keyPtr = keyData.bytes;
		void const *_Nonnull dataPtr = payloadData.bytes;
		int8_t const *recordTypePtr = dataPtr;
		//Officially, that low byte is reserved (IM:F)/always zero (TN1150). The “Descent” for Macintosh CD-ROM has at least some items that put other values in that low byte.
		//Also, the “Descent” CD-ROM has some entries that look like folder records but have record types like 0x4100 or 0x5100. There are also thread records with a type of 0x6400 that don't have a node name filled in. If you want to include these, change the switch below to “recordType & 0x0f00”.
		int8_t const recordType = L(*recordTypePtr);

		@autoreleasepool {
			switch (recordType << 8) {
				case kHFSFileRecord:
					if (fileRecordBlock != NULL) {
						fileRecordBlock(keyPtr, (struct HFSCatalogFile const *)dataPtr);
					}
					break;
				case kHFSFolderRecord:
					if (folderRecordBlock != NULL) {
						folderRecordBlock(keyPtr, (struct HFSCatalogFolder const *)dataPtr);
					}
					break;
				case kHFSFileThreadRecord:
				case kHFSFolderThreadRecord:
					if (threadRecordBlock != NULL) {
						threadRecordBlock(keyPtr, (struct HFSCatalogThread const *)dataPtr);
					}
					break;
				default:
					fprintf(stderr, "\tUnrecognized record type 0x%x while trying to iterate catalog records; either this isn't a catalog file, or the parsing has gotten off-track somehow.\n", (unsigned)recordType);
					break;
			}
		}

		return true;
	}];
}
- (void) forEachHFSPlusCatalogRecord_file:(void (^_Nullable const)(struct HFSPlusCatalogKey const *_Nonnull const catalogKeyPtr, struct HFSPlusCatalogFile const *_Nonnull const recordDataPtr))fileRecordBlock
	folder:(void (^_Nullable const)(struct HFSPlusCatalogKey const *_Nonnull const catalogKeyPtr, struct HFSPlusCatalogFolder  const *_Nonnull const))folderRecordBlock
	thread:(void (^_Nullable const)(struct HFSPlusCatalogKey const *_Nonnull const catalogKeyPtr, struct HFSPlusCatalogThread const *_Nonnull const))threadRecordBlock
{
	if (self.tree.version != ImpBTreeVersionHFSPlusCatalog) {
		return;
	}
	[self forEachKeyedRecord:^bool(NSData *const  _Nonnull keyData, NSData *const  _Nonnull payloadData) {
		struct HFSPlusCatalogKey const *_Nonnull const keyPtr = keyData.bytes;
		void const *_Nonnull dataPtr = payloadData.bytes;
		int16_t const *recordTypePtr = dataPtr;
		int16_t const recordType = L(*recordTypePtr);

		@autoreleasepool {
			switch (recordType) {
				case kHFSPlusFileRecord:
					if (fileRecordBlock != NULL) {
						fileRecordBlock(keyPtr, (struct HFSPlusCatalogFile const *)dataPtr);
					}
					break;
				case kHFSPlusFolderRecord:
					if (folderRecordBlock != NULL) {
						folderRecordBlock(keyPtr, (struct HFSPlusCatalogFolder const *)dataPtr);
					}
					break;
				case kHFSPlusFileThreadRecord:
				case kHFSPlusFolderThreadRecord:
					if (threadRecordBlock != NULL) {
						threadRecordBlock(keyPtr, (struct HFSPlusCatalogThread const *)dataPtr);
					}
					break;
				default:
					fprintf(stderr, "\tUnrecognized record type 0x%x while trying to iterate catalog records; either this isn't a catalog file, or the parsing has gotten off-track somehow.\n", (unsigned)recordType);
					break;
			}
		}

		return true;
	}];
}

#pragma mark Record mutation

///Returns the number of bytes of empty space: the distance between the value of the last record offset (which points to the start of empty space after the last record) and the position of the top of the record offset stack (which is immediately after the end of empty space). May return zero (the last record offset points to itself).
- (u_int32_t) numberOfBytesAvailable {
	BTreeNodeOffset startOfEmptySpace = 0;
	u_int16_t lengthOfEmptySpace = 0;
	[self forRecordAtIndex:self.numberOfRecords getItsOffset:&startOfEmptySpace andLength:&lengthOfEmptySpace];
	return lengthOfEmptySpace;
}

- (NSMutableData *_Nonnull) mutableRecordDataAtIndex:(u_int16_t)idx {
	BTreeNodeOffset thisRecordOffset;
	u_int16_t length = 0;
	[self forRecordAtIndex:idx getItsOffset:&thisRecordOffset andLength:&length];
//	void *_Nonnull const mutableBytes = [(NSMutableData *)_nodeData mutableBytes];
//	NSMutableData *_Nonnull const recordData = [NSMutableData dataWithBytesNoCopy:mutableBytes length:length freeWhenDone:false];
	NSRange const recordRange = { thisRecordOffset, length };
	//mutableRecordDataAtIndex: should only ever be sent to a node that's part of a mutable tree, in which case sliceData:selectRange: should return a mutable data.
	NSMutableData *_Nonnull const recordData = (NSMutableData *)[self.tree sliceData:_nodeData selectRange:recordRange];

//	ImpPrintf(@"Record at index %u starts at offset %lu, length %lu: <\n%@>", idx, (unsigned long)thisRecordOffset, length, recordData.hexDump_Imp);
	return recordData;
}

- (void) replaceKeyOfRecordAtIndex:(u_int16_t const)idx withKey:(NSData *_Nonnull const)keyData {
	void const *_Nonnull const newBytes = keyData.bytes;
	u_int16_t const *_Nonnull const newKeyLengthPtr = newBytes;

	NSMutableData *_Nonnull const mutableRecordData = [self mutableRecordDataAtIndex:idx];
	void *_Nonnull const mutableBytes = mutableRecordData.mutableBytes;
	u_int16_t const *_Nonnull const existingKeyLengthPtr = mutableBytes;
	NSAssert(L(*existingKeyLengthPtr) == L(*newKeyLengthPtr), @"Resizing records is not yet implemented; can't change key length from %u to %u", L(*existingKeyLengthPtr), L(*newKeyLengthPtr));

	[keyData getBytes:mutableBytes length:keyData.length];
}

///Overwrite the payload portion of this record with a different payload.
- (void) replacePayloadOfRecordAtIndex:(u_int16_t const)idx withPayload:(NSData *_Nonnull const)payloadData {
	NSMutableData *_Nonnull const mutableRecordData = [self mutableRecordDataAtIndex:idx];
	void *_Nonnull const mutableBytes = mutableRecordData.mutableBytes;
	u_int16_t const *_Nonnull const existingKeyLengthPtr = mutableBytes;
	ptrdiff_t const offset = L(*existingKeyLengthPtr) + sizeof(*existingKeyLengthPtr);
	NSAssert((offset + payloadData.length) <= mutableRecordData.length, @"Resizing records is not yet implemented; can't write payload of %lu bytes into record of %lu bytes", payloadData.length, mutableRecordData.length);

	[payloadData getBytes:mutableBytes + offset length:payloadData.length];
}

//TODO: Do we actually need this? ImpMutableBTreeFile does this before creating a node object.
///Writes 0x000e (sizeof(BTNodeDescriptor)) to the last two bytes of the node. This is the offset of empty space in a new node. Throws an exception if numberOfRecords > 0.
- (void) initRecordOffsetsStack {
	NSAssert(self.numberOfRecords == 0, @"Attempt to initialize the record offsets stack in a non-empty node (has %u records)", self.numberOfRecords);

	void *_Nonnull const nodeBytes = ((NSMutableData *)_nodeData).mutableBytes;
	BTreeNodeOffset *_Nonnull const offsets = nodeBytes;

	//Note: This may be called to push the initial 0x0e into the first offset slot, so don't assume there are any offsets already.
	u_int16_t const maxNumOffsets = (u_int16_t)(_nodeData.length / sizeof(BTreeNodeOffset));
	u_int16_t const bottomOffsetInverseIdx = maxNumOffsets - 1;
	BTreeNodeOffset *_Nonnull const nextOffsetPtr = offsets + bottomOffsetInverseIdx;
	S(*nextOffsetPtr, (u_int16_t)sizeof(BTNodeDescriptor));
}

///Add a new record offset to the stack of record offsets at the end of the node and increase numberOfRecords by 1. Returns true if it was successfully added; returns false if there wasn't room. Throws an exception if this node is not mutable, or if the new offset is less than or equal to an offset already in the stack.
- (bool) pushOffsetOntoRecordOffsetsStack:(u_int16_t const)recordOffset {
	if (sizeof(u_int16_t) > self.numberOfBytesAvailable) {
		return false;
	}

	void *_Nonnull const nodeBytes = ((NSMutableData *)_nodeData).mutableBytes;
	BTreeNodeOffset *_Nonnull const offsets = nodeBytes;

	u_int16_t const maxNumOffsets = (u_int16_t)(_nodeData.length / sizeof(BTreeNodeOffset));
	u_int16_t const curNumOffsets = self.numberOfRecords;
	u_int16_t const newOffsetIdx = curNumOffsets + 1;

	//Do a couple of consistency checks.
	u_int16_t const topmostExistingOffsetIdx = curNumOffsets - 1;
	BTreeNodeOffset topmostExistingOffset = 0;
	u_int16_t emptySpaceLength = 0;
	[self forRecordAtIndex:topmostExistingOffsetIdx getItsOffset:&topmostExistingOffset andLength:&emptySpaceLength];

	//#1: The new offset must be strictly greater than the offset already at the top of the stack. (There is always at least one, as the offset of empty space is always at the top of the stack.)
	//An attempt to add an offset equal to the existing top offset is an attempt to add an empty record. (*Technically* not invalid, I guess, but why would you do that?)
	//An attempt to add an offset less than the existing top offset is, at best, an attempt to insert or split a record. This is not supported. Moreover, if you're calling *this* method to do it, you are definitely doing something wrong.
	NSAssert(recordOffset > topmostExistingOffset, @"Consistency error appending to node %p with %u records! Attempt to add new %u'th offset %u that is ≤ existing topmost (%u'th) offset %u", self, _numberOfRecords, newOffsetIdx, recordOffset, topmostExistingOffsetIdx, topmostExistingOffset);

	//#2: Use emptySpaceLength to make sure the new offset is no greater than the offset it will end up at. If recordOffset - topmostExistingOffset > emptySpaceLength, that's bad.
	NSAssert((recordOffset - topmostExistingOffset) > emptySpaceLength, @"Consistency check failure: Attempt to add offset (%u) that points into the offset stack (would start at %u)", recordOffset, topmostExistingOffset);

	//Regular indexes are indexes from the last (bottom) offset in the stack. The bottom offset has an index of 0.
	//Inverse indexes are indexes from the start of the node. The bottom offset has an index of (maximum possible number of offsets if the node were made entirely out of offsets) - 1. For example, if the node is 4096 bytes, that's 2048 offsets, so the bottom offset's inverse index is 2047.
	//The bottom offset's inverse index is effectively a constant for a given node size. Regular indexes are converted to inverse indexes by subtracting from the bottom constant.
	//Example: When adding the first record, newOffsetInverseIdx is 0. bottomOffsetInverseIdx - 0 should already contain 0xe, which is the start of that new record. We'll be called upon to add the new offset of empty space after it, at inverse index 1 (regular index bottomOffsetInverseIdx - 1).
	u_int16_t const bottomOffsetInverseIdx = maxNumOffsets - 1;
	u_int16_t const newOffsetInverseIdx = bottomOffsetInverseIdx - newOffsetIdx;
	NSAssert(newOffsetInverseIdx < maxNumOffsets, @"Write out-of-bounds detected attempting to write new offset in inverse index %u out of %u", newOffsetInverseIdx, maxNumOffsets);
	BTreeNodeOffset *_Nonnull const nextOffsetPtr = offsets + newOffsetInverseIdx;
	S(*nextOffsetPtr, recordOffset);

	//We need to do this here so that the read-back check (next paragraph) can work. forRecordAtIndex:getItsOffset:andLength: will fail if the index >= numberOfRecords.
	++_numberOfRecords;
	struct BTNodeDescriptor *_Nonnull const nodeDesc = nodeBytes;
	S(nodeDesc->numRecords, _numberOfRecords);

	//Attempt to read back the offset at this index and make sure we get what we just wrote.
	//Yes, this used to fail. It's here for a reason.
	BTreeNodeOffset readBackOffset = 0;
	u_int16_t readBackLength = 0;
	[self forRecordAtIndex:newOffsetIdx getItsOffset:&readBackOffset andLength:&readBackLength];
	NSAssert(readBackOffset == recordOffset, @"Failed to write new offset into stack at index %u: Wrote offset %u (0x%04x) at +0x%lx bytes into node, but got back %u (0x%04x)", newOffsetIdx, recordOffset, recordOffset, (unsigned long)(ptrdiff_t)(((void *)nextOffsetPtr) - nodeBytes), readBackOffset, readBackOffset);

	return true;
}

- (bool) appendRecordWithData:(NSData *_Nonnull const)data {
	u_int16_t const oldNumRecords = self.numberOfRecords;
	u_int16_t const newRecordIdx = oldNumRecords;

	BTreeNodeOffset offsetOfEmptySpace;
	u_int16_t lengthOfEmptySpace = lengthOfEmptySpace;
	[self forRecordAtIndex:newRecordIdx getItsOffset:&offsetOfEmptySpace andLength:&lengthOfEmptySpace];

	if ((data.length + sizeof(BTreeNodeOffset)) > lengthOfEmptySpace) {
		ImpPrintf(@"Can't append record to node %@: it would take %lu bytes, and there are only %u bytes available", self, (data.length + sizeof(BTreeNodeOffset)), lengthOfEmptySpace);
		return false;
	}

	void *_Nonnull const nodeBytes = ((NSMutableData *)_nodeData).mutableBytes;
	struct BTNodeDescriptor *_Nonnull const nodeDesc = nodeBytes;

	BTreeNodeOffset const destOffset = offsetOfEmptySpace;
	void *_Nonnull const destPtr = nodeBytes + destOffset;
	[data getBytes:destPtr length:data.length];

	//What was the offset of empty space is now the offset of our new record.
	//Add a new offset above it, pointing to the remaining empty space (if any, or itself if not).
	offsetOfEmptySpace += data.length;
	//Note that we checked the length above *including* the new offset, so this should succeed.
	[self pushOffsetOntoRecordOffsetsStack:offsetOfEmptySpace];

	_recordCache = nil;

	return true;
}

- (bool) appendRecordWithKey:(NSData *_Nonnull const)keyData payload:(NSData *_Nonnull const)payloadData {
	NSUInteger const totalLength = keyData.length + payloadData.length;

	if ((totalLength + sizeof(BTreeNodeOffset)) > self.numberOfBytesAvailable) {
		ImpPrintf(@"Can't append record to node %@: it would take %lu bytes (%lu + %lu + %lu), and there are only %u bytes available", self, totalLength, keyData.length, payloadData.length, sizeof(BTreeNodeOffset), self.numberOfBytesAvailable);
		return false;
	}

	NSMutableData *_Nonnull const data = [NSMutableData dataWithCapacity:totalLength];
	[data appendData:keyData];
	[data appendData:payloadData];

	return [self appendRecordWithData:data];
}

@end
