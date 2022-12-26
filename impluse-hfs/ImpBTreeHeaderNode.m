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

@property(readwrite) NSData *_Nonnull reserved3;

@end

@implementation ImpBTreeHeaderNode
{
	u_int32_t _rootNodeIndex;
	u_int32_t _firstLeafNodeIndex;
	u_int32_t _lastLeafNodeIndex;
}

- (instancetype _Nullable)initWithTree:(ImpBTreeFile *_Nonnull const)tree data:(NSData *_Nonnull const)nodeData {
	if ((self = [super initWithTree:tree data:nodeData])) {
		NSData *_Nonnull const firstRecordData = [self recordDataAtIndex:0];
		struct BTHeaderRec const *_Nonnull const headerRec = firstRecordData.bytes;
		if (headerRec == NULL) {
			//A header node with no records? Unpossible!
			return nil;
		}

		self.treeDepth = L(headerRec->treeDepth);

		_rootNodeIndex = L(headerRec->rootNode);
		self.numberOfLeafRecords = L(headerRec->leafRecords);
		_firstLeafNodeIndex = L(headerRec->firstLeafNode);
		_lastLeafNodeIndex = L(headerRec->lastLeafNode);

		self.bytesPerNode = L(headerRec->nodeSize);
		self.maxKeyLength = L(headerRec->maxKeyLength);

		self.numberOfTotalNodes = L(headerRec->totalNodes);
		self.numberOfFreeNodes = L(headerRec->freeNodes);

		self.reserved1 = L(headerRec->reserved1);

		self.clumpSize = L(headerRec->clumpSize);

		self.btreeType = L(headerRec->btreeType);
		self.keyCompareType = L(headerRec->keyCompareType);

		self.attributes = L(headerRec->attributes);

		self.reserved3 = [firstRecordData subdataWithRange:(NSRange){ offsetof(BTHeaderRec, reserved3), sizeof(headerRec->reserved3) }];
	}
	return self;
}

- (ImpBTreeNode *_Nonnull const) rootNode {
	return [self.tree nodeAtIndex:_rootNodeIndex];
}

- (ImpBTreeNode *_Nonnull const) firstLeafNode {
	return [self.tree nodeAtIndex:_firstLeafNodeIndex];
}
- (ImpBTreeNode *_Nonnull const) lastLeafNode {
	return [self.tree nodeAtIndex:_lastLeafNodeIndex];
}

@end
