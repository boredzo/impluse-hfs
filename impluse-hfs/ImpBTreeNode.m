//
//  ImpBTreeNode.m
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-11-27.
//

#import "ImpBTreeNode.h"

#import "ImpByteOrder.h"
#import "ImpSizeUtilities.h"
#import "ImpBTreeFile.h"
#import "ImpBTreeHeaderNode.h"
#import "ImpBTreeIndexNode.h"

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

- (NSData *_Nonnull) recordDataAtIndex:(u_int16_t)idx {
	NSParameterAssert(idx < self.numberOfRecords);
	BTreeNodeOffset const *_Nonnull const offsets = _nodeData.bytes;
	enum { maxNumOffsets = sizeof(struct BTreeNode) / sizeof(BTreeNodeOffset), lastOffsetIdx = maxNumOffsets - 1 };
	BTreeNodeOffset const thisRecordOffset = L(offsets[lastOffsetIdx - idx]);
	BTreeNodeOffset const nextRecordOffset = L(offsets[lastOffsetIdx - (idx + 1)]);

	NSUInteger const length = nextRecordOffset - thisRecordOffset;
	NSRange const recordRange = { thisRecordOffset, length };
	NSData *_Nonnull const recordData = [_nodeData subdataWithRange:recordRange];
	NSLog(@"Record at index %u starts at offset %lu, length %lu: <\n%@>", idx, (unsigned long)thisRecordOffset, length, recordData.hexDump_Imp);
	return recordData;
}

- (void) forEachRecord:(void (^_Nonnull const)(NSData *_Nonnull const data))block {
	for (NSUInteger i = 0; i < _numberOfRecords; ++i) {
		NSData *_Nonnull const recordData = [self recordDataAtIndex:i];
		block(recordData);
	}
}

- (void) forEachCatalogRecord_file:(void (^_Nonnull const)(struct HFSCatalogKey const *_Nonnull const catalogKeyPtr, struct HFSCatalogFile const *_Nonnull const recordDataPtr))fileRecordBlock
	folder:(void (^_Nonnull const)(struct HFSCatalogKey const *_Nonnull const catalogKeyPtr, struct HFSCatalogFolder  const *_Nonnull const))folderRecordBlock
	thread:(void (^_Nonnull const)(struct HFSCatalogKey const *_Nonnull const catalogKeyPtr, struct HFSCatalogThread const *_Nonnull const))threadRecordBlock
{
	[self forEachRecord:^(NSData *const  _Nonnull data) {
		void const *_Nonnull const recordPtr = data.bytes;
		struct HFSCatalogKey const *_Nonnull const keyPtr = recordPtr;
		ptrdiff_t const keyLength = L(keyPtr->keyLength) + sizeof(keyPtr->keyLength);

		void const *_Nonnull const dataPtr = recordPtr + keyLength;
		int16_t const *recordTypePtr = dataPtr;
		//Officially, that low byte is reserved (IM:F)/always zero (TN1150). The “Descent” for Macintosh CD-ROM has at least some items that put other values in that low byte.
		//Also, the “Descent” CD-ROM has some entries that look like folder records but have record types like 0x4100 or 0x5100. There are also thread records with a type of 0x6400 that don't have a node name filled in. If you want to include these, change the switch below to “recordType & 0x0f00”.
		int16_t const recordType = L(*recordTypePtr) & 0xff00;

		NSLog(@"Record length: %lu; offset of record type in record is %lu; record type is 0x%04x", data.length, ((ptrdiff_t)recordTypePtr) - ((ptrdiff_t)recordPtr), recordType);
		switch (recordType /* & 0x0f00 */) {
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
				fprintf(stderr, "\tUnrecognized record type 0x%x of length %lu while trying to iterate catalog records; either this isn't a catalog file, or the parsing has gotten off-track somehow.\n", (unsigned)recordType, data.length - sizeof(*keyPtr));
//				NSAssert(false, @"Unrecognized record type 0x%x while trying to iterate catalog records; either this isn't a catalog file, or the parsing has gotten off-track somehow.", (unsigned)recordType);
				break;
		}
	}];
}

@end
