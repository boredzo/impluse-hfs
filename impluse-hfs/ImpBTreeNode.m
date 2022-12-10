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
#import "ImpBTreeHeaderNode.h"
#import "ImpBTreeIndexNode.h"
#import "ImpTextEncodingConverter.h"

#import "NSData+ImpHexDump.h"

typedef u_int16_t BTreeNodeOffset;

@interface ImpBTreeNode ()
@property(readwrite) u_int32_t forwardLink, backwardLink;
@property(readwrite) int8_t nodeType;
@property(readwrite) u_int8_t nodeHeight;
@property(readwrite) u_int16_t numberOfRecords;
@end

@implementation ImpBTreeNode
{
	NSData *_nodeData;
	NSMutableArray <NSData *> *_Nonnull _recordCache;
}

///Peek at the kind of node this is, and choose an appropriate subclass based on that.
+ (Class _Nonnull) nodeClassForData:(NSData *_Nonnull const)nodeData {
	Class nodeClass = self;
	struct BTreeNode const *_Nonnull const nodeDescriptor = nodeData.bytes;
	int8_t const nodeType = L(nodeDescriptor->header.kind);
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
	Class nodeClass = [self nodeClassForData:nodeData];
	return [[nodeClass alloc] initWithTree:tree data:nodeData];
}

- (instancetype _Nullable)initWithTree:(ImpBTreeFile *_Nonnull const)tree data:(NSData *_Nonnull const)nodeData {
	if ((self = [super init])) {
		_tree = tree;

		_nodeData = [nodeData copy];

		struct BTreeNode const *_Nonnull const nodeDescriptor = _nodeData.bytes;
		self.forwardLink = L(nodeDescriptor->header.fLink);
		self.backwardLink = L(nodeDescriptor->header.bLink);
		self.nodeType = L(nodeDescriptor->header.kind);
		self.nodeHeight = L(nodeDescriptor->header.height);
		self.numberOfRecords = L(nodeDescriptor->header.numRecords);
		//TODO: Should probably preserve the reserved field as well.
	}
	return self;
}

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

- (ImpBTreeNode *_Nullable)searchSiblingsForBestMatchingNodeWithComparator:(ImpBTreeRecordKeyComparator _Nonnull)comparator {
	if (self.numberOfRecords == 0) {
		return nil;
	}

	//First, if the first record in this node is already greater than the quarry, search the previous node.
	if (comparator([self recordDataAtIndex:0].bytes) == ImpBTreeComparisonQuarryIsLesser) {
		return [self.previousNode searchSiblingsForBestMatchingNodeWithComparator:comparator];
	}

	//If the last record in this node is less than the quarry, check the next node's first record and if it's less than or equal to the quarry, search it.
	if (self.numberOfRecords > 1 && comparator([self recordDataAtIndex:self.numberOfRecords - 1].bytes) == ImpBTreeComparisonQuarryIsGreater) {
		ImpBTreeNode *_Nullable const nextNode = self.nextNode;
		if (nextNode != nil && nextNode.numberOfRecords > 0) {
			ImpBTreeComparisonResult const comparisonResult = comparator([nextNode recordDataAtIndex:0].bytes);
			if (comparisonResult == ImpBTreeComparisonQuarryIsEqual) {
				return nextNode;
			} else if (comparisonResult == ImpBTreeComparisonQuarryIsGreater) {
				return [nextNode searchSiblingsForBestMatchingNodeWithComparator:comparator];
			}
		}
	}

	//Otherwise, the best matching node is somewhere in this node. Return this node.
	return self;
}

- (int16_t) indexOfBestMatchingRecord:(ImpBTreeRecordKeyComparator _Nonnull)comparator {
	//We *could* bisect this, but there are only likely to be a handful of records in a 512-byte node, so let's just search linearly.
	for (u_int16_t i = 0; i < (u_int16_t)_numberOfRecords; ++i) {
		ImpBTreeComparisonResult const comparisonResult = comparator([self recordDataAtIndex:i].bytes);
		if (comparisonResult == ImpBTreeComparisonQuarryIsLesser) {
			return i - 1;
		}
	}
	//At this point, every record in the node was less than or equal to the quarry, so the last record is the greatest candidate. Return its index.
	return self.numberOfRecords - 1;
}

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
				struct HFSCatalogKey const *_Nonnull const hfsCatKeyPtr = keyData.bytes;
				descriptionComponents[0] = [NSString stringWithFormat:@"Catalog key [parent ID #%u, node name “%@”]", L(hfsCatKeyPtr->parentID), [tec stringForPascalString:hfsCatKeyPtr->nodeName]];

				void const *_Nonnull const payloadPtr = payloadData.bytes;
				u_int8_t const *_Nonnull const recordTypePtr = payloadPtr;
				switch (*recordTypePtr << 8) {
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
						descriptionComponents[1] = [NSString stringWithFormat:@"🧵 %@ [parent ID #%u, name “%@”]", (*recordTypePtr << 8) == kHFSFileThreadRecord ? @"📄" : @"📁",  L(hfsThreadRecPtr->parentID), [tec stringForPascalString:hfsThreadRecPtr->nodeName]];
						break;
					}
					default:
						if (payloadData.length == sizeof(u_int32_t)) {
							u_int32_t const *_Nonnull const downwardNodeIndexPtr = payloadPtr;
							descriptionComponents[1] = [NSString stringWithFormat:@"Pointer to node #%u", L(*downwardNodeIndexPtr)];
						} else if (payloadData.length > 0) {
							descriptionComponents[1] = [NSString stringWithFormat:@"<unknown payload for record type 0x%02x with length %lu>", *recordTypePtr, payloadData.length];
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

- (NSData *_Nonnull) recordDataAtIndex:(u_int16_t)idx {
	NSParameterAssert(idx < self.numberOfRecords);

	[self buildRecordCache];
	return _recordCache[idx];
}
- (NSData *_Nonnull) recordDataAtIndex_nocache:(u_int16_t)idx {
	BTreeNodeOffset const *_Nonnull const offsets = _nodeData.bytes;
	enum { maxNumOffsets = sizeof(struct BTreeNode) / sizeof(BTreeNodeOffset), lastOffsetIdx = maxNumOffsets - 1 };
	BTreeNodeOffset const thisRecordOffset = L(offsets[lastOffsetIdx - idx]);
	BTreeNodeOffset const nextRecordOffset = L(offsets[lastOffsetIdx - (idx + 1)]);

	NSUInteger const length = nextRecordOffset - thisRecordOffset;
	NSRange const recordRange = { thisRecordOffset, length };
	NSData *_Nonnull const recordData = [_nodeData dangerouslyFastSubdataWithRange_Imp:recordRange];
//	ImpPrintf(@"Record at index %u starts at offset %lu, length %lu: <\n%@>", idx, (unsigned long)thisRecordOffset, length, recordData.hexDump_Imp);
	return recordData;
}

- (NSData *_Nullable) recordKeyDataAtIndex:(u_int16_t)idx {
	if (! (self.nodeType == kBTIndexNode || self.nodeType == kBTLeafNode) ) {
		return nil;
	}

	NSData *_Nonnull const wholeRecordData = [self recordDataAtIndex:idx];
	//TODO: Really need a way to make this not assume HFS vs. HFS+. Maybe ask the tree what its key length size is.
	u_int8_t const *_Nonnull const keyLengthPtr = wholeRecordData.bytes;
	u_int8_t keyLength = *keyLengthPtr;
	keyLength += sizeof(u_int8_t);
	return [wholeRecordData dangerouslyFastSubdataWithRange_Imp:(NSRange){ 0, keyLength }];
}

- (NSData *_Nullable) recordPayloadDataAtIndex:(u_int16_t)idx {
	if (! (self.nodeType == kBTIndexNode || self.nodeType == kBTLeafNode) ) {
		return nil;
	}

	NSData *_Nonnull const wholeRecordData = [self recordDataAtIndex:idx];
	//TODO: Really need a way to make this not assume HFS vs. HFS+. Maybe ask the tree what its key length size is.
	u_int8_t const *_Nonnull const keyLengthPtr = wholeRecordData.bytes;
	u_int8_t keyLength = *keyLengthPtr;
	keyLength += sizeof(u_int8_t);

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

	return [wholeRecordData dangerouslyFastSubdataWithRange_Imp:payloadRange];
}

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

- (void) forEachCatalogRecord_file:(void (^_Nonnull const)(struct HFSCatalogKey const *_Nonnull const catalogKeyPtr, struct HFSCatalogFile const *_Nonnull const recordDataPtr))fileRecordBlock
	folder:(void (^_Nonnull const)(struct HFSCatalogKey const *_Nonnull const catalogKeyPtr, struct HFSCatalogFolder  const *_Nonnull const))folderRecordBlock
	thread:(void (^_Nonnull const)(struct HFSCatalogKey const *_Nonnull const catalogKeyPtr, struct HFSCatalogThread const *_Nonnull const))threadRecordBlock
{
	[self forEachKeyedRecord:^bool(NSData *const  _Nonnull keyData, NSData *const  _Nonnull payloadData) {
		struct HFSCatalogKey const *_Nonnull const keyPtr = keyData.bytes;
		void const *_Nonnull dataPtr = payloadData.bytes;
		int8_t const *recordTypePtr = dataPtr;
		//Officially, that low byte is reserved (IM:F)/always zero (TN1150). The “Descent” for Macintosh CD-ROM has at least some items that put other values in that low byte.
		//Also, the “Descent” CD-ROM has some entries that look like folder records but have record types like 0x4100 or 0x5100. There are also thread records with a type of 0x6400 that don't have a node name filled in. If you want to include these, change the switch below to “recordType & 0x0f00”.
		int8_t const recordType = L(*recordTypePtr);

		switch (recordType << 8) {
			case kHFSFileRecord:
				fileRecordBlock(keyPtr, (struct HFSCatalogFile const *)dataPtr);
				break;
			case kHFSFolderRecord:
				folderRecordBlock(keyPtr, (struct HFSCatalogFolder const *)dataPtr);
				break;
			case kHFSFileThreadRecord:
			case kHFSFolderThreadRecord:
				threadRecordBlock(keyPtr, (struct HFSCatalogThread const *)dataPtr);
				break;
			default:
				fprintf(stderr, "\tUnrecognized record type 0x%x while trying to iterate catalog records; either this isn't a catalog file, or the parsing has gotten off-track somehow.\n", (unsigned)recordType);
				break;
		}

		return true;
	}];
}

@end
