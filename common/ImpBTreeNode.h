//
//  ImpBTreeNode.h
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-11-27.
//

#import <Foundation/Foundation.h>

#import "ImpComparisonUtilities.h"
#import "ImpBTreeTypes.h"

@class ImpBTreeFile;

@interface ImpBTreeNode : NSObject

///Returns a name for this B*-tree variant. Mainly for debugging.
+ (NSString *_Nonnull) describeBTreeVersion:(ImpBTreeVersion const)version;

///May return an instance of a subclass, such as ImpBTreeHeaderNode. Tree is used to convert inter-node references such as firstLeafNode into pointers to node objects.
+ (instancetype _Nullable) nodeWithTree:(ImpBTreeFile *_Nonnull const)tree data:(NSData *_Nonnull const)nodeData;

///For use by -[ImpMutableBTree allocateNewNodeOfKind:populate:]. 
+ (instancetype _Nullable) mutableNodeWithTree:(ImpBTreeFile *_Nonnull const)tree data:(NSData *_Nonnull const)nodeData;

///Tree is used to convert inter-node references such as firstLeafNode into pointers to node objects.
- (instancetype _Nullable)initWithTree:(ImpBTreeFile *_Nonnull const)tree data:(NSData *_Nonnull const)nodeData;

///May return an instance of a subclass, such as ImpBTreeHeaderNode. Tree is used to convert inter-node references such as firstLeafNode into pointers to node objects.
///This method is meant for implementation use. Code outside of the B*-tree class hierarchy should use nodeWithTree:data: (which calls this with copy:true).
+ (instancetype _Nullable) nodeWithTree:(ImpBTreeFile *_Nonnull const)tree data:(NSData *_Nonnull const)nodeData copy:(bool const)shouldCopyData mutable:(bool const)dataShouldBeMutable;

///Tree is used to convert inter-node references such as firstLeafNode into pointers to node objects.
///This method is meant for implementation use. Code outside of the B*-tree class hierarchy should use initWithTree:data: (which calls this with copy:true).
- (instancetype _Nullable)initWithTree:(ImpBTreeFile *_Nonnull const)tree data:(NSData *_Nonnull const)nodeData copy:(bool const)shouldCopyData mutable:(bool const)dataShouldBeMutable NS_DESIGNATED_INITIALIZER;

@property(readonly, weak) ImpBTreeFile *_Nullable tree;
///The range within the original B*-tree file from which this node was instantiated. location must always be a multiple of 512, and length must always be 512 (or 4096 in HFS+).
@property(readwrite) NSRange byteRange;

@property(readwrite) u_int32_t nodeNumber;
@property(readonly, nonatomic) u_int32_t forwardLink, backwardLink;
@property(readonly) BTreeNodeKind nodeType;
@property(readonly) NSString *_Nonnull nodeTypeName;
@property(readonly) u_int8_t nodeHeight;
@property(readonly) u_int16_t numberOfRecords;

///Returns true if the node's backward link is 0 (non-reference) or an index that is within the bounds of the tree. Returns false if it is an index out of bounds.
- (bool) validateLinkToPreviousNode;
///Returns true if the node's forward link is 0 (non-reference) or an index that is within the bounds of the tree. Returns false if it is an index out of bounds.
- (bool) validateLinkToNextNode;

@property(nonatomic, readonly) ImpBTreeNode *_Nullable previousNode;
@property(nonatomic, readonly) ImpBTreeNode *_Nullable nextNode;

///Set the next node of the receiver, and the previous node of the receiver's current next node (to nil/0) and of the new next node (to the receiver). If newNextNode is nil, set the next node of the receiver and the previous node of the hitherto next node (if any) to nil/0.
///This is not “setNextNode:” precisely because it modifies both sides of the relationship (it also sets the two other nodes' previousNode) and not just one.
- (void) connectNextNode:(ImpBTreeNode *_Nullable const)newNextNode;

///Call the block with an NSData object containing this node's descriptor and records. Do not attempt to modify the data or retain the data object outside the block.
- (void) peekAtDataRepresentation:(void (^_Nonnull const)(NSData *_Nonnull const data NS_NOESCAPE))block;

///Return a string concisely describing an HFS catalog key. If the data does not represent (or at least start with) an HFS catalog key, results are undefined. For debugging purposes only.
+ (NSString *_Nonnull const) describeHFSCatalogKeyWithData:(NSData *_Nonnull const)keyData;
///Return a string concisely describing an HFS+ catalog key. If the data does not represent (or at least start with) an HFS+ catalog key, results are undefined. For debugging purposes only.
+ (NSString *_Nonnull const) describeHFSPlusCatalogKeyWithData:(NSData *_Nonnull const)keyData;
///Extract the node name from an HFS+ catalog key and return it as an NSString. For debugging purposes only.
+ (NSString *_Nonnull const) nodeNameFromHFSPlusCatalogKey:(NSData *_Nonnull const)keyData;

///Iterate from a given node forward to the end of its row.
- (void) walkRow:(bool (^_Nonnull const)(ImpBTreeNode *_Nonnull const node))block;

///Given a comparator block, search the siblings *only* of this node for the best-matching node. It may be an index node, in which case descent and further searching may be required to find the leaf node that will either have an exact match or not.
///The best-matching node is the one with the greatest record that is less than or equal to the quarry. How each record in these nodes compares to the quarry is for the comparator block to determine.
///May return nil if this node contains no records, or contains no comparable records.
- (ImpBTreeNode *_Nullable) searchSiblingsForBestMatchingNodeWithComparator:(ImpBTreeRecordKeyComparator _Nonnull)comparator;

///Search this node for the record with the greatest key that is less than or equal to the quarry. Returns its index. Returns -1 if the first key in this node is greater than the quarry.
- (int16_t) indexOfBestMatchingRecord:(ImpBTreeRecordKeyComparator _Nonnull)comparator;

#pragma mark Records

///The number of bytes in the node not allocated to any record. In other words, the number of bytes between the end of the last record and the start of the last record's offset.
@property(nonatomic, readonly) u_int32_t numberOfBytesAvailable;

///Compute the number of bytes in use, regardless of the node descriptor's stated number of bytes available, by totaling up the size of the node descriptor, all records, and the record offsets stack.
- (u_int32_t) totalNumberOfBytesUsed;

///This is for subclasses' use.
- (bool) forRecordAtIndex:(u_int16_t const)idx getItsOffset:(BTreeNodeOffset *_Nullable const)outThisOffset andTheOneAfterThat:(BTreeNodeOffset *_Nullable const)outNextOffset;

///Returns the whole catalog record, key and payload, at the given index within the node.
- (NSData *_Nonnull) recordDataAtIndex:(u_int16_t)idx;

///Returns only the key from this record. This data is a prefix of the corresponding recordDataAtIndex:. Returns nil if this node is not an index or leaf node. (Header and map nodes don't have key-value records.)
- (NSData *_Nullable) recordKeyDataAtIndex:(u_int16_t)idx;

///Returns only the payload from this record. This data is a suffix of the corresponding recordDataAtIndex:. Returns nil if this node is not an index or leaf node. (Header and map nodes don't have key-value records.)
- (NSData *_Nullable) recordPayloadDataAtIndex:(u_int16_t)idx;

///Overwrite the key portion of this record with a different key.
- (void) replaceKeyOfRecordAtIndex:(u_int16_t const)idx withKey:(NSData *_Nonnull const)keyData;
///Overwrite the payload portion of this record with a different payload.
- (void)  replacePayloadOfRecordAtIndex:(u_int16_t const)idx withPayload:(NSData *_Nonnull const)payloadData;

///Returns a mutable data that wraps the range of the node containing this record.
///Note: If multiple mutable datas exist for the same record in the same node, changing the bytes of any one of them changes all of them.
///Note: You cannot change the length of the data—it is not possible to resize a record in-place.
///Note: This method may throw if you send it to a node that isn't part of a mutable tree.
- (NSMutableData *_Nonnull) mutableRecordDataAtIndex:(u_int16_t)idx;

///Call this block for every record in this node. Stops iterating if the block returns false. Returns the number of records visited (which may be less than the number of records in the node, if the block called an early stop).
- (NSUInteger) forEachRecord:(bool (^_Nonnull const)(NSData *_Nonnull const data))block;

///Call this block for every record in this node. Stops iterating if the block returns false. Returns the number of records visited (which may be less than the number of records in the node, if the block called an early stop).
- (NSUInteger) forEachKeyedRecord:(bool (^_Nonnull const)(NSData *_Nonnull const keyData, NSData *_Nonnull const payloadData))block;

///Call these blocks with every catalog record in this B*-tree node, assuming that this B*-tree node is in an HFS catalog file. If this node came from HFS+ or from a non-catalog file, no HFS catalog records will be found and your blocks will not be called.
- (void) forEachHFSCatalogRecord_file:(void (^_Nullable const)(struct HFSCatalogKey const *_Nonnull const catalogKeyPtr, struct HFSCatalogFile const *_Nonnull const))fileRecordBlock
	folder:(void (^_Nullable const)(struct HFSCatalogKey const *_Nonnull const catalogKeyPtr, struct HFSCatalogFolder const *_Nonnull const))folderRecordBlock
	thread:(void (^_Nullable const)(struct HFSCatalogKey const *_Nonnull const catalogKeyPtr, struct HFSCatalogThread const *_Nonnull const))threadRecordBlock;

///Call these blocks with every catalog record in this B*-tree node, assuming that this B*-tree node is in an HFS+ catalog file. If this node came from HFS or from a non-catalog file, no HFS+ catalog records will be found and your blocks will not be called.
- (void) forEachHFSPlusCatalogRecord_file:(void (^_Nullable const)(struct HFSPlusCatalogKey const *_Nonnull const catalogKeyPtr, struct HFSPlusCatalogFile const *_Nonnull const recordDataPtr))fileRecordBlock
	folder:(void (^_Nullable const)(struct HFSPlusCatalogKey const *_Nonnull const catalogKeyPtr, struct HFSPlusCatalogFolder  const *_Nonnull const))folderRecordBlock
	thread:(void (^_Nullable const)(struct HFSPlusCatalogKey const *_Nonnull const catalogKeyPtr, struct HFSPlusCatalogThread const *_Nonnull const))threadRecordBlock;

///Append a new record to this node, copying the given data verbatim. Returns true if this succeeded; returns false if there wasn't enough free space in this node to add the record.
- (bool) appendRecordWithData:(NSData *_Nonnull const)data;

///Append a new record to this node, concatenating the key and payload as is typical of index and leaf nodes. Returns true if this succeeded; returns false if there wasn't enough free space in this node to add the record.
- (bool) appendRecordWithKey:(NSData *_Nonnull const)keyData payload:(NSData *_Nonnull const)payloadData;

@end
