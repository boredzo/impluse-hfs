//
//  ImpBTreeHeaderNode.m
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-11-28.
//

#import "ImpBTreeHeaderNode.h"

#import "ImpByteOrder.h"
#import "ImpBTreeFile.h"

@interface ImpBTreeHeaderNode ()

@property(readwrite) u_int16_t treeDepth;
@property(readwrite) u_int32_t rootNodeIndex;
@property(readwrite) u_int32_t firstLeafNodeIndex;
@property(readwrite) u_int32_t lastLeafNodeIndex;
@property(readwrite) u_int32_t numberOfLeafRecords;
@property(readwrite) u_int16_t bytesPerNode;
@property(readwrite) u_int16_t maxKeyLength;
@property(readwrite) u_int32_t numberOfTotalNodes;
@property(readwrite) u_int32_t numberOfFreeNodes;
@property(readwrite) u_int16_t reserved1;
@property(readwrite) u_int32_t clumpSize;
///One of kHFSBTreeType, kUserBTreeType, or kReservedBTreeType.
@property(readwrite) u_int8_t btreeType;
///Used by HFSX. Otherwise a reserved field.
@property(readwrite) u_int8_t keyCompareType;
@property(readwrite) u_int32_t attributes;
@property(readwrite) bool hasBigKeys;
@property(readwrite) bool hasVariableSizedKeysInIndexNodes;

@property(readwrite) NSData *_Nonnull reserved3;

@end

@implementation ImpBTreeHeaderNode

- (instancetype _Nullable) initWithTree:(ImpBTreeFile *_Nonnull const)tree data:(NSData *_Nonnull const)nodeData copy:(bool const)shouldCopyData mutable:(bool const)dataShouldBeMutable {
	if ((self = [super initWithTree:tree data:nodeData copy:shouldCopyData mutable:dataShouldBeMutable])) {
		NSData *_Nonnull const firstRecordData = [self recordDataAtIndex:0];
		struct BTHeaderRec const *_Nonnull const headerRec = firstRecordData.bytes;
		if (headerRec == NULL) {
			//A header node with no records? Unpossible!
			return nil;
		}

		[self populatePropertiesFromHeaderRecordData:firstRecordData];
	}
	return self;
}

- (void) populatePropertiesFromHeaderRecordData:(NSData *_Nonnull const)firstRecordData {
	struct BTHeaderRec const *_Nonnull const headerRec = firstRecordData.bytes;

	self.treeDepth = L(headerRec->treeDepth);

	self.rootNodeIndex = L(headerRec->rootNode);
	self.numberOfLeafRecords = L(headerRec->leafRecords);
	self.firstLeafNodeIndex = L(headerRec->firstLeafNode);
	self.lastLeafNodeIndex = L(headerRec->lastLeafNode);

	self.bytesPerNode = L(headerRec->nodeSize);
	self.maxKeyLength = L(headerRec->maxKeyLength);

	self.numberOfTotalNodes = L(headerRec->totalNodes);
	self.numberOfFreeNodes = L(headerRec->freeNodes);

	self.reserved1 = L(headerRec->reserved1);

	self.clumpSize = L(headerRec->clumpSize);

	self.btreeType = L(headerRec->btreeType);
	self.keyCompareType = L(headerRec->keyCompareType);

	u_int32_t const attributes = L(headerRec->attributes);
	self.attributes = attributes;
	self.hasBigKeys = attributes & kBTBigKeysMask;
	self.hasVariableSizedKeysInIndexNodes = attributes & kBTVariableIndexKeysMask;

	self.reserved3 = [firstRecordData subdataWithRange:(NSRange){ offsetof(BTHeaderRec, reserved3), sizeof(headerRec->reserved3) }];
}

+ (void) convertHeaderNode:(ImpBTreeHeaderNode *_Nonnull const)theOriginal
	forTreeVersion:(ImpBTreeVersion const)destVersion
	intoData:(NSMutableData *_Nonnull const)mutableBTreeData
	nodeSize:(u_int16_t const)nodeSize
	maxKeyLength:(u_int16_t)maxKeyLength
{
	void *_Nonnull const mutableBytes = mutableBTreeData.mutableBytes;

	struct BTNodeDescriptor *_Nonnull const nodeDesc = mutableBytes;
	S(nodeDesc->bLink, theOriginal.backwardLink);
	S(nodeDesc->fLink, 0); //TODO: Arguably we should clone all the map nodes along with this.
	S(nodeDesc->kind, theOriginal.nodeType);
	S(nodeDesc->height, theOriginal.nodeHeight);
	S(nodeDesc->numRecords, 3);
	S(nodeDesc->reserved, 0);

	void *_Nonnull const headerRecStart = mutableBytes + sizeof(*nodeDesc);
	struct BTHeaderRec *_Nonnull const headerRec = headerRecStart;
	S(headerRec->treeDepth, theOriginal.treeDepth);
	S(headerRec->nodeSize, nodeSize);
	S(headerRec->maxKeyLength, maxKeyLength);
	S(headerRec->reserved1, theOriginal.reserved1);
	//TN1150: “Ignored for HFS Plus B-trees. The clumpSize field of the HFSPlusForkData record is used instead. For maximum compatibility, an implementation should probably set the clumpSize in the node descriptor to the same value as the clumpSize in the HFSPlusForkData when initializing a volume. Otherwise, it should treat the header records's clumpSize as reserved.”
	//We set the clump size of the fork data to the node size in both places.
	//Note that copying the clump size from the original tree doesn't make sense because it's likely an HFS tree. This field didn't exist in HFS. In theory, it *should* be zero because it was reserved; in practice, not every HFS implementation was meticulous about keeping reserved space zeroed.
	S(headerRec->clumpSize, nodeSize);
	S(headerRec->btreeType, theOriginal.btreeType);
	S(headerRec->keyCompareType, theOriginal.keyCompareType);
	//TN1150 on BigKeys: “If this bit is set, the keyLength field of the keys in index and leaf nodes is UInt16; otherwise, it is a UInt8. This bit must be set for all HFS Plus B-trees.”
	bool const hasBigKeys = true;
	bool hasVariableSizeIndexKeys = false;
	switch (destVersion) {
		case ImpBTreeVersionHFSCatalog:
		case ImpBTreeVersionHFSExtentsOverflow:
			hasVariableSizeIndexKeys = false;
			break;
		case ImpBTreeVersionHFSPlusCatalog:
		case ImpBTreeVersionHFSPlusAttributes:
			hasVariableSizeIndexKeys = true;
			break;
		case ImpBTreeVersionHFSPlusExtentsOverflow:
			hasVariableSizeIndexKeys = false;
			break;
	}
	S(headerRec->attributes, theOriginal.attributes | (hasBigKeys ? kBTBigKeysMask : 0) | (hasVariableSizeIndexKeys ? kBTVariableIndexKeysMask : 0));
	NSData *_Nonnull const reserved3 = theOriginal.reserved3;
	memcpy(headerRec->reserved3, reserved3.bytes, reserved3.length);
	//All the rest of this is subject to change as the tree gets populated, so set it fresh rather than copying it over.
	S(headerRec->rootNode, 0);
	S(headerRec->leafRecords, 0);
	S(headerRec->firstLeafNode, 0);
	S(headerRec->lastLeafNode, 0);
	S(headerRec->totalNodes, 1);
	S(headerRec->freeNodes, 0);

	void *_Nonnull const userDataRecStart = headerRecStart + sizeof(struct BTHeaderRec);
	//The user data record is always blank, so we just skip it.
	enum { userDataRecLength = 128 };

	void *_Nonnull const mapRecStart = userDataRecStart + userDataRecLength;
	u_int8_t *_Nonnull const mapBytes = mapRecStart;
	//Mark the header node as used and no others.
	*mapBytes = 1 << 7;

	void *_Nonnull const theVeryEnd = mutableBytes + nodeSize;
	u_int16_t *_Nonnull const negativeFirstRecordIndex = theVeryEnd;
	u_int16_t *_Nonnull const firstRecordIndex = negativeFirstRecordIndex - 1;
	u_int16_t *_Nonnull const secondRecordIndex = firstRecordIndex - 1;
	u_int16_t *_Nonnull const thirdRecordIndex = secondRecordIndex - 1;
	u_int16_t *_Nonnull const fourthRecordIndex = thirdRecordIndex - 1;
	void *_Nonnull const offsetStackStart = fourthRecordIndex;

	S(*firstRecordIndex, (u_int16_t)(headerRecStart - mutableBytes));
	S(*secondRecordIndex, (u_int16_t)(userDataRecStart - mutableBytes));
	S(*thirdRecordIndex, (u_int16_t)(mapRecStart - mutableBytes));
	S(*fourthRecordIndex, (u_int16_t)(offsetStackStart - mutableBytes));
}

+ (void) writeHeaderNodeForTreeVersion:(ImpBTreeVersion const)destVersion
	intoData:(NSMutableData *_Nonnull const)mutableBTreeData
	nodeSize:(u_int16_t const)nodeSize
	maxKeyLength:(u_int16_t)maxKeyLength
{
	void *_Nonnull const mutableBytes = mutableBTreeData.mutableBytes;

	struct BTNodeDescriptor *_Nonnull const nodeDesc = mutableBytes;
	S(nodeDesc->bLink, 0);
	S(nodeDesc->fLink, 0);
	S(nodeDesc->kind, kBTHeaderNode);
	S(nodeDesc->height, 0);
	S(nodeDesc->numRecords, 3);
	S(nodeDesc->reserved, 0);

	void *_Nonnull const headerRecStart = mutableBytes + sizeof(*nodeDesc);
	struct BTHeaderRec *_Nonnull const headerRec = headerRecStart;
	S(headerRec->treeDepth, 0);
	S(headerRec->nodeSize, nodeSize);
	S(headerRec->maxKeyLength, maxKeyLength);
	S(headerRec->reserved1, 0);
	//TN1150: “Ignored for HFS Plus B-trees. The clumpSize field of the HFSPlusForkData record is used instead. For maximum compatibility, an implementation should probably set the clumpSize in the node descriptor to the same value as the clumpSize in the HFSPlusForkData when initializing a volume. Otherwise, it should treat the header records's clumpSize as reserved.”
	//We set the clump size of the fork data to the node size in both places.
	//Note that copying the clump size from the original tree doesn't make sense because it's likely an HFS tree. This field didn't exist in HFS. In theory, it *should* be zero because it was reserved; in practice, not every HFS implementation was meticulous about keeping reserved space zeroed.
	S(headerRec->clumpSize, nodeSize);

	S(headerRec->btreeType, BTreeTypeHFS);
	//kHFSCaseFolding is only defined for HFSX.
	S(headerRec->keyCompareType, 0);

	//TN1150 on BigKeys: “If this bit is set, the keyLength field of the keys in index and leaf nodes is UInt16; otherwise, it is a UInt8. This bit must be set for all HFS Plus B-trees.”
	bool const hasBigKeys = true;
	bool hasVariableSizeIndexKeys = false;
	switch (destVersion) {
		case ImpBTreeVersionHFSCatalog:
		case ImpBTreeVersionHFSExtentsOverflow:
			hasVariableSizeIndexKeys = false;
			break;
		case ImpBTreeVersionHFSPlusCatalog:
		case ImpBTreeVersionHFSPlusAttributes:
			hasVariableSizeIndexKeys = true;
			break;
		case ImpBTreeVersionHFSPlusExtentsOverflow:
			hasVariableSizeIndexKeys = false;
			break;
	}
	S(headerRec->attributes, (hasBigKeys ? kBTBigKeysMask : 0) | (hasVariableSizeIndexKeys ? kBTVariableIndexKeysMask : 0));
	NSData *_Nonnull const reserved3 = [NSMutableData dataWithLength:sizeof(headerRec->reserved3)];
	memcpy(headerRec->reserved3, reserved3.bytes, reserved3.length);
	//All the rest of this is subject to change as the tree gets populated, so set it fresh rather than copying it over.
	S(headerRec->rootNode, 0);
	S(headerRec->leafRecords, 0);
	S(headerRec->firstLeafNode, 0);
	S(headerRec->lastLeafNode, 0);
	S(headerRec->totalNodes, 1);
	S(headerRec->freeNodes, 0);

	void *_Nonnull const userDataRecStart = headerRecStart + sizeof(struct BTHeaderRec);
	//The user data record is always blank, so we just skip it.
	enum { userDataRecLength = 128 };

	void *_Nonnull const mapRecStart = userDataRecStart + userDataRecLength;
	u_int8_t *_Nonnull const mapBytes = mapRecStart;
	//Mark the header node as used and no others.
	*mapBytes = 1 << 7;

	void *_Nonnull const theVeryEnd = mutableBytes + nodeSize;
	u_int16_t *_Nonnull const negativeFirstRecordIndex = theVeryEnd;
	u_int16_t *_Nonnull const firstRecordIndex = negativeFirstRecordIndex - 1;
	u_int16_t *_Nonnull const secondRecordIndex = firstRecordIndex - 1;
	u_int16_t *_Nonnull const thirdRecordIndex = secondRecordIndex - 1;
	u_int16_t *_Nonnull const fourthRecordIndex = thirdRecordIndex - 1;
	void *_Nonnull const offsetStackStart = fourthRecordIndex;

	S(*firstRecordIndex, (u_int16_t)(headerRecStart - mutableBytes));
	S(*secondRecordIndex, (u_int16_t)(userDataRecStart - mutableBytes));
	S(*thirdRecordIndex, (u_int16_t)(mapRecStart - mutableBytes));
	S(*fourthRecordIndex, (u_int16_t)(offsetStackStart - mutableBytes));
}

- (instancetype _Nonnull) initByCloningHeaderNode:(ImpBTreeHeaderNode *_Nonnull const)theOriginal nodeSize:(u_int16_t)nodeSize maxKeyLength:(u_int16_t)maxKeyLength forTree:(ImpBTreeFile *_Nonnull const)tree {
	NSMutableData *_Nonnull const data = [NSMutableData dataWithLength:nodeSize];
	void *_Nonnull const mutableBytes = data.mutableBytes;

	struct BTNodeDescriptor *_Nonnull const nodeDesc = mutableBytes;
	S(nodeDesc->bLink, theOriginal.backwardLink);
	S(nodeDesc->fLink, 0); //TODO: Arguably we should clone all the map nodes along with this.
	S(nodeDesc->kind, theOriginal.nodeType);
	S(nodeDesc->height, theOriginal.nodeHeight);
	S(nodeDesc->numRecords, 0);
	S(nodeDesc->reserved, 0);

	NSMutableData *_Nonnull const headerRecData = [NSMutableData dataWithLength:sizeof(struct BTHeaderRec)];
	struct BTHeaderRec *_Nonnull const headerRec = headerRecData.mutableBytes;
	S(headerRec->treeDepth, theOriginal.treeDepth);
	S(headerRec->nodeSize, nodeSize);
	S(headerRec->maxKeyLength, maxKeyLength);
	S(headerRec->reserved1, theOriginal.reserved1);
	//TN1150: “Ignored for HFS Plus B-trees. The clumpSize field of the HFSPlusForkData record is used instead. For maximum compatibility, an implementation should probably set the clumpSize in the node descriptor to the same value as the clumpSize in the HFSPlusForkData when initializing a volume. Otherwise, it should treat the header records's clumpSize as reserved.”
	//We set the clump size of the fork data to the node size in both places.
	//Note that copying the clump size from the original tree doesn't make sense because it's likely an HFS tree. This field didn't exist in HFS. In theory, it *should* be zero because it was reserved; in practice, not every HFS implementation was meticulous about keeping reserved space zeroed.
	S(headerRec->clumpSize, nodeSize);
	S(headerRec->btreeType, theOriginal.btreeType);
	S(headerRec->keyCompareType, theOriginal.keyCompareType);
	//TN1150 on BigKeys: “If this bit is set, the keyLength field of the keys in index and leaf nodes is UInt16; otherwise, it is a UInt8. This bit must be set for all HFS Plus B-trees.”
	//TODO: Need to also set kBTVariableIndexKeysMask when this is a catalog file but not when this is an extents overflow file.
	bool hasVariableSizeIndexKeys = false;
	switch(tree.version) {
		case ImpBTreeVersionHFSCatalog:
		case ImpBTreeVersionHFSExtentsOverflow:
			hasVariableSizeIndexKeys = false;
			break;
		case ImpBTreeVersionHFSPlusCatalog:
		case ImpBTreeVersionHFSPlusAttributes:
			hasVariableSizeIndexKeys = true;
			break;
		case ImpBTreeVersionHFSPlusExtentsOverflow:
			hasVariableSizeIndexKeys = false;
			break;
	}
	S(headerRec->attributes, theOriginal.attributes | kBTBigKeysMask | (hasVariableSizeIndexKeys ? kBTVariableIndexKeysMask : 0));
	NSData *_Nonnull const reserved3 = theOriginal.reserved3;
	memcpy(headerRec->reserved3, reserved3.bytes, reserved3.length);
	//All the rest of this is subject to change as the tree gets populated, so set it fresh rather than copying it over.
	S(headerRec->rootNode, 0);
	S(headerRec->leafRecords, 0);
	S(headerRec->firstLeafNode, 0);
	S(headerRec->lastLeafNode, 0);
	S(headerRec->totalNodes, 1);
	S(headerRec->freeNodes, 0);

	bool const appendedHeaderRec = [self appendRecordWithData:headerRecData];
	if (! appendedHeaderRec) {
		self = nil;
	} else {
		NSMutableData *_Nonnull const userDataRecData = [NSMutableData dataWithLength:128];
		bool const appendedUserDataRec = [self appendRecordWithData:userDataRecData];
		if (! appendedUserDataRec) {
			self = nil;
		} else {
			NSUInteger const remainingSpace = self.numberOfBytesAvailable;
			NSMutableData *_Nonnull const mapRecData = [NSMutableData dataWithLength:remainingSpace];
			bool const appendedMapDataRec = [self appendRecordWithData:mapRecData];
			if (! appendedMapDataRec) {
				self = nil;
			}
		}
	}

	self = [super initWithTree:tree data:data];

	return self;
}

///An ImpBTreeHeaderNode might be instantiated from the whole B*-tree file in order to find out the node size, since it isn't necessarily known at file load time. The default ImpBTreeNode logic for finding record bounds uses the offsets at the end of the node, but that isn't helpful when the node size isn't known yet.
///So in this override, we cheat and count on the fact that the first two records are of known size. We can return those boundaries without needing the node size.
- (bool) forRecordAtIndex:(u_int16_t const)idx getItsOffset:(BTreeNodeOffset *_Nullable const)outThisOffset andTheOneAfterThat:(BTreeNodeOffset *_Nullable const)outNextOffset {
#if USE_ENUM
	enum {
		firstRecordStart = sizeof(BTNodeDescriptor),
		firstRecordEnd = firstRecordStart + sizeof(BTHeaderRec),
		secondRecordStart = firstRecordEnd,
		secondRecordEnd = secondRecordStart + 0x80,
		thirdRecordStart = secondRecordEnd,
		//thirdRecordEnd is the one we don't actually know.
	};
#else
	BTreeNodeOffset const firstRecordStart = sizeof(BTNodeDescriptor);
	BTreeNodeOffset const firstRecordEnd = firstRecordStart + sizeof(BTHeaderRec);
	BTreeNodeOffset const secondRecordStart = firstRecordEnd;
	BTreeNodeOffset const secondRecordEnd = secondRecordStart + 0x80;
	BTreeNodeOffset const thirdRecordStart = secondRecordEnd;
	//thirdRecordEnd is the one we don't actually know.
	BTreeNodeOffset thirdRecordEnd = thirdRecordStart + 1;
#endif

	if (idx >= self.numberOfRecords) {
		return false;
	}

	switch (idx) {
		case 0:
			if (outThisOffset != NULL) *outThisOffset = firstRecordStart;
			if (outNextOffset != NULL) *outNextOffset = firstRecordEnd;
			return true;

		case 1:
			if (outThisOffset != NULL) *outThisOffset = secondRecordStart;
			if (outNextOffset != NULL) *outNextOffset = secondRecordEnd;
			return true;

		case 2:
			if (outThisOffset != NULL) *outThisOffset = secondRecordStart;
			if (outNextOffset != NULL) {
				//Well, boogers. We need the end of the third offset, but for that, we need the node size.
				//Cheat here by getting the range of the *first* record, getting the node size, and working it out from there, independently of the usual logic.
				//… except we already know the range of the first record (the point of this method is that it's constant!), so just use it.
				__block u_int16_t nodeSize = 0;
				[self peekAtDataRepresentation:^(NS_NOESCAPE NSData *_Nonnull const data) {
					struct BTHeaderRec const *_Nonnull const headerRec = data.bytes + firstRecordStart;
					nodeSize = L(headerRec->nodeSize);
				}];
				//3 record starts, plus the offset to the end of the last record (i.e., the offset of the last offset).
				thirdRecordEnd = nodeSize - sizeof(BTreeNodeOffset) * 4;
				*outNextOffset = thirdRecordEnd;
			}
			return true;

		default:
			return [super forRecordAtIndex:idx getItsOffset:outThisOffset andTheOneAfterThat:outNextOffset];
	}
}
- (bool) forRecordAtIndex:(u_int16_t const)idx getItsOffset:(BTreeNodeOffset *_Nonnull const)outThisOffset andLength:(u_int16_t *_Nonnull const)outLength {
#if USE_ENUM
	enum {
		firstRecordStart = sizeof(BTNodeDescriptor),
		firstRecordEnd = firstRecordStart + sizeof(BTHeaderRec),
		secondRecordStart = firstRecordEnd,
		secondRecordEnd = secondRecordStart + 0x80,
		thirdRecordStart = secondRecordEnd,
		//thirdRecordEnd is the one we don't actually know.
	};
#else
	BTreeNodeOffset const firstRecordStart = sizeof(BTNodeDescriptor);
	BTreeNodeOffset const firstRecordEnd = firstRecordStart + sizeof(BTHeaderRec);
	BTreeNodeOffset const secondRecordStart = firstRecordEnd;
	BTreeNodeOffset const secondRecordEnd = secondRecordStart + 0x80;
	BTreeNodeOffset const thirdRecordStart = secondRecordEnd;
	//thirdRecordEnd is the one we don't actually know.
	BTreeNodeOffset thirdRecordEnd = thirdRecordStart + 1;
#endif

	if (idx >= self.numberOfRecords) {
		return false;
	}

	switch (idx) {
		case 0:
			if (outThisOffset != NULL) *outThisOffset = firstRecordStart;
			if (outLength != NULL) *outLength = firstRecordEnd - firstRecordStart;
			return true;

		case 1:
			if (outThisOffset != NULL) *outThisOffset = secondRecordStart;
			if (outLength != NULL) *outLength = secondRecordEnd - secondRecordStart;
			return true;

		case 2:
			if (outThisOffset != NULL) *outThisOffset = thirdRecordStart;
			if (outLength != NULL) {
				//Well, boogers. We need the end of the third offset, but for that, we need the node size.
				//Cheat here by getting the range of the *first* record, getting the node size, and working it out from there, independently of the usual logic.
				//… except we already know the range of the first record (the point of this method is that it's constant!), so just use it.
				__block u_int16_t nodeSize = 0;
				[self peekAtDataRepresentation:^(NS_NOESCAPE NSData *_Nonnull const data) {
					struct BTHeaderRec const *_Nonnull const headerRec = data.bytes + firstRecordStart;
					nodeSize = L(headerRec->nodeSize);
				}];
				//3 record starts, plus the offset to the end of the last record (i.e., the offset of the last offset).
				thirdRecordEnd = nodeSize - sizeof(BTreeNodeOffset) * 4;
				*outLength = thirdRecordEnd - thirdRecordStart;
			}
			return true;

		default:
			return [super forRecordAtIndex:idx getItsOffset:outThisOffset andTheOneAfterThat:outLength];
	}
}

- (ImpBTreeNode *_Nonnull const) rootNode {
	return [self.tree nodeAtIndex:self.rootNodeIndex];
}

- (ImpBTreeNode *_Nonnull const) firstLeafNode {
	return [self.tree nodeAtIndex:self.firstLeafNodeIndex];
}
- (ImpBTreeNode *_Nonnull const) lastLeafNode {
	return [self.tree nodeAtIndex:self.lastLeafNodeIndex];
}

- (void) reviseHeaderRecord:(void (^_Nonnull const)(struct BTHeaderRec *_Nonnull const))block {
	NSMutableData *_Nonnull const headerRecData = [self mutableRecordDataAtIndex:0];
	struct BTHeaderRec *_Nonnull const headerRecPtr = headerRecData.mutableBytes;

	block(headerRecPtr);

	[self populatePropertiesFromHeaderRecordData:headerRecData];
}

#pragma mark ImpBTreeMapNode subclass

///In a header node, the third record is the first map record of the file.
- (u_int16_t) mapRecordIndex  {
	return 2;
}

- (bool) appendRecordWithData:(NSData *_Nonnull const)data {
	NSAssert(self.numberOfRecords <= 3, @"Attempt to append records to a header node beyond the requisite three. Something is deeply wrong!");
	return [super appendRecordWithData:data];
}

@end
