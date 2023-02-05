//
//  ImpBTreeHeaderNode.h
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-11-28.
//

#import "ImpBTreeNode.h"
#import "ImpBTreeMapNode.h"
#import "ImpBTreeFile.h"

///ImpBTreeHeaderNode inherits the map API from ImpBTreeMapNode since every header node contains a map record. Thus, the header node offers all the same methods for testing node allocations and allocating and deallocating nodes as a map node has. The difference is that a map node has only one record, which is a map record, whereas a header node has multiple records, of which the third is a map record.
@interface ImpBTreeHeaderNode : ImpBTreeMapNode

@property(readonly) u_int16_t treeDepth;
@property(nonatomic, readonly) ImpBTreeNode *_Nonnull const rootNode;
@property(readonly) u_int32_t numberOfLeafRecords;
@property(nonatomic, readonly) ImpBTreeNode *_Nonnull const firstLeafNode;
@property(nonatomic, readonly) ImpBTreeNode *_Nonnull const lastLeafNode;
@property(readonly) u_int16_t bytesPerNode;
///Some well-known values for this are kHFSCatalogKeyMaximumLength, kHFSExtentKeyMaximumLength, kHFSPlusCatalogKeyMaximumLength, and kHFSPlusExtentKeyMaximumLength.
@property(readonly) u_int16_t maxKeyLength;
@property(readonly) u_int32_t numberOfTotalNodes;
@property(readonly) u_int32_t numberOfFreeNodes;
@property(readonly) u_int16_t reserved1;
@property(readonly) u_int32_t clumpSize;
///One of kHFSBTreeType, kUserBTreeType, or kReservedBTreeType.
@property(readonly) u_int8_t btreeType;
///Used by HFSX. Otherwise a reserved field.
@property(readonly) u_int8_t keyCompareType;
@property(readonly) u_int32_t attributes;

///Only defined for HFS+. Should be 0 for HFS, but the attributes field didn't exist yet, so some HFS volumes may have garbage there.
@property(readonly) bool hasBigKeys;
///Only defined for HFS+. Should be 0 for HFS, but the attributes field didn't exist yet, so some HFS volumes may have garbage there.
@property(readonly) bool hasVariableSizedKeysInIndexNodes;

///Accessor to be used by converter objects. Properties will be updated from any changed values.
- (void) reviseHeaderRecord:(void (^_Nonnull const)(struct BTHeaderRec *_Nonnull const))block;

@property(readonly) NSData *_Nonnull reserved3;

///Used by ImpMutableBTreeFile to make a temporary copy of the header node of the corresponding B*-tree file from an HFS volume, but with certain values changed to meet HFS+ requirements.
+ (void) convertHeaderNode:(ImpBTreeHeaderNode *_Nonnull const)theOriginal
	forTreeVersion:(ImpBTreeVersion const)destVersion
	intoData:(NSMutableData *_Nonnull const)mutableBTreeData
	nodeSize:(u_int16_t const)nodeSize
	maxKeyLength:(u_int16_t)maxKeyLength;

@end
