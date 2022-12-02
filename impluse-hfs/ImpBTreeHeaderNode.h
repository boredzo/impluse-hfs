//
//  ImpBTreeHeaderNode.h
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-11-28.
//

#import "ImpBTreeNode.h"

@class ImpBTreeFile;

@interface ImpBTreeHeaderNode : ImpBTreeNode

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

@property(readonly) NSData *_Nonnull reserved3;

@end
